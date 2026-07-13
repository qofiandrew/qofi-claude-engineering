#!/usr/bin/python3 -I
"""Bounded owner-local control client for the Codex App Server manager."""

from __future__ import annotations

import argparse
import ctypes
import errno
import http.client
import json
import os
import socket
import stat
import sys
from typing import NoReturn


SCHEMA = "qofi-codex-app-server-manager/v1"
MANAGER_VERSION = "0.1.0"
PROTOCOL_VERSION = "0.144.1"
MAX_CONTROL_RESPONSE = 64 * 1024
MAX_REVIEW_PROMPT = 5_242_880
MAX_REVIEW_OUTPUT = 1024 * 1024
MAX_REVIEW_RESPONSE = 8 * 1024 * 1024
MAX_REVIEW_WIRE = 32 * 1024 * 1024


class ControlError(RuntimeError):
    pass


def fail(message: str, status: int = 1) -> NoReturn:
    sys.stderr.write(f"codex-manager-control: {message}\n")
    raise SystemExit(status)


def identity(info: os.stat_result) -> tuple[int, int, int, int]:
    return (info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode))


def has_extended_acl(path: str) -> bool:
    if sys.platform != "darwin":
        return False
    libc = ctypes.CDLL(None, use_errno=True)
    get_acl = libc.acl_get_link_np
    get_acl.argtypes = [ctypes.c_char_p, ctypes.c_int]
    get_acl.restype = ctypes.c_void_p
    free_acl = libc.acl_free
    free_acl.argtypes = [ctypes.c_void_p]
    free_acl.restype = ctypes.c_int
    ctypes.set_errno(0)
    acl = get_acl(os.fsencode(path), 0x00000100)  # ACL_TYPE_EXTENDED
    if not acl:
        error = ctypes.get_errno()
        if error in (0, errno.ENOENT):
            return False
        raise ControlError(f"could not inspect extended ACL on {path}: errno {error}")
    try:
        return True
    finally:
        free_acl(acl)


def attest_socket(path: str) -> tuple[int, int, int, int]:
    if (
        not os.path.isabs(path)
        or os.path.normpath(path) != path
        or "\x00" in path
        or len(os.fsencode(path)) > 100
    ):
        raise ControlError("manager socket path must be absolute, normalized, and portable")
    parent = os.path.dirname(path)
    if os.path.realpath(parent) != parent:
        raise ControlError("manager socket parent must be canonical")
    parent_info = os.lstat(parent)
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or stat.S_ISLNK(parent_info.st_mode)
        or parent_info.st_uid != os.getuid()
        or stat.S_IMODE(parent_info.st_mode) != 0o700
        or has_extended_acl(parent)
    ):
        raise ControlError("manager socket parent must be an owner mode-0700 real directory")
    info = os.lstat(path)
    if (
        not stat.S_ISSOCK(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o600
        or has_extended_acl(path)
    ):
        raise ControlError("manager endpoint must be an owner mode-0600 socket")
    return identity(info)


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, expected: tuple[int, int, int, int], timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path
        self.expected = expected

    def connect(self) -> None:
        if attest_socket(self.socket_path) != self.expected:
            raise ControlError("manager socket identity changed before connect")
        connected = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connected.settimeout(self.timeout)
        try:
            connected.connect(self.socket_path)
            if attest_socket(self.socket_path) != self.expected:
                raise ControlError("manager socket identity changed while connecting")
        except BaseException:
            connected.close()
            raise
        self.sock = connected


def request_json(
    socket_path: str,
    method: str,
    route: str,
    value: dict[str, object] | None,
    *,
    timeout: float,
    max_request: int,
    max_response: int,
) -> dict[str, object]:
    expected = attest_socket(socket_path)
    body = b"" if value is None else json.dumps(
        value, ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8", "strict")
    if len(body) > max_request:
        raise ControlError("manager request exceeds its byte bound")
    headers = {"Accept": "application/json"}
    if value is not None:
        headers.update({
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        })
    connection = UnixHTTPConnection(socket_path, expected, timeout)
    try:
        connection.request(method, route, body=body or None, headers=headers)
        response = connection.getresponse()
        if response.getheader("Content-Encoding"):
            raise ControlError("manager response must not be encoded")
        content_type = (response.getheader("Content-Type") or "").split(";", 1)[0].strip()
        if content_type != "application/json":
            raise ControlError("manager response is not JSON")
        declared = response.getheader("Content-Length")
        if declared is None or not declared.isdecimal() or int(declared) > max_response:
            raise ControlError("manager response length is absent or out of bounds")
        raw = response.read(max_response + 1)
        if len(raw) > max_response or len(raw) != int(declared):
            raise ControlError("manager response length differs from its bounded declaration")
        try:
            result = json.loads(raw.decode("utf-8", "strict"))
        except (UnicodeDecodeError, ValueError) as error:
            raise ControlError(f"manager response is malformed JSON: {error}") from error
        if not isinstance(result, dict):
            raise ControlError("manager response must be a JSON object")
        if response.status < 200 or response.status >= 300:
            detail = result.get("error")
            if not isinstance(detail, str) or not detail:
                detail = f"HTTP {response.status}"
            raise ControlError(f"manager refused {route}: {detail[:1024]}")
        if attest_socket(socket_path) != expected:
            raise ControlError("manager socket identity changed after response")
        return result
    finally:
        connection.close()


def integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def generation(value: object) -> bool:
    return integer(value) and value > 0


def validate_health(value: dict[str, object], *, require_ready: bool) -> None:
    statuses = {
        "ready", "drained", "busy", "review-pending", "cleanup-pending",
        "ambiguous", "stopping",
    }
    phases = {
        "starting", "idle", "reserved", "active", "completion-review-pending",
        "completion-review-complete", "terminal-cleanup-pending",
        "drained", "ambiguous", "stopping",
    }
    upstream_states = {"ready", "stopped", "cleanup-pending", "ambiguous"}
    if (
        value.get("schema") != SCHEMA
        or value.get("managerVersion") != MANAGER_VERSION
        or value.get("protocolVersion") != PROTOCOL_VERSION
        or value.get("cliVersion") != PROTOCOL_VERSION
        or value.get("status") not in statuses
        or value.get("phase") not in phases
        or value.get("upstreamState") not in upstream_states
        or not generation(value.get("generation"))
        or not integer(value.get("registeredSwarmCount"))
        or not isinstance(value.get("upstreamReady"), bool)
    ):
        raise ControlError("manager health contract is incompatible or malformed")
    if require_ready and not (
        value.get("status") == "ready"
        and value.get("phase") == "idle"
        and value.get("upstreamState") == "ready"
        and value.get("upstreamReady") is True
    ):
        raise ControlError(f"manager is not ready (phase={value.get('phase')})")


def validate_generation_ack(value: dict[str, object], key: str) -> None:
    if value.get(key) is not True or not generation(value.get("generation")):
        raise ControlError("manager returned a malformed lifecycle acknowledgement")


def review(socket_path: str) -> int:
    prompt = sys.stdin.buffer.read(MAX_REVIEW_PROMPT + 1)
    if len(prompt) > MAX_REVIEW_PROMPT:
        raise ControlError("review prompt exceeds 5MiB")
    try:
        text = prompt.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise ControlError("review prompt is not UTF-8") from error
    if not text:
        raise ControlError("review prompt is empty")
    request_id = os.urandom(16).hex()
    result = request_json(
        socket_path, "POST", "/v1/review/start",
        {"requestId": request_id, "prompt": text},
        timeout=190.0, max_request=MAX_REVIEW_WIRE, max_response=MAX_REVIEW_RESPONSE,
    )
    lease = result.get("leaseId")
    cleanup = result.get("cleanupToken")
    terminal = result.get("result")
    if (
        not isinstance(lease, str)
        or not isinstance(cleanup, str)
        or result.get("cleanupRequired") is not True
        or not isinstance(terminal, dict)
        or not isinstance(terminal.get("ok"), bool)
        or not isinstance(terminal.get("messages"), list)
        or any(not isinstance(item, str) for item in terminal["messages"])
    ):
        raise ControlError("manager returned a malformed review result")
    ack = request_json(
        socket_path, "POST", "/v1/turn/cleanup-complete",
        {"cleanupToken": cleanup, "leaseId": lease, "ok": True},
        timeout=60.0, max_request=MAX_CONTROL_RESPONSE, max_response=MAX_CONTROL_RESPONSE,
    )
    validate_generation_ack(ack, "ready")
    messages = terminal["messages"]
    if sum(len(item.encode("utf-8")) for item in messages) > MAX_REVIEW_OUTPUT:
        raise ControlError("review messages exceed the output bound")
    if not terminal["ok"]:
        detail = terminal.get("error")
        raise ControlError(
            "review turn failed" + (f": {str(detail)[:1024]}" if detail else ""),
        )
    sys.stdout.write("\n".join(messages))
    if messages:
        sys.stdout.write("\n")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, dest="socket_path")
    parser.add_argument(
        "command", choices=("health", "ready", "drain", "resume", "shutdown", "review"),
    )
    args = parser.parse_args()
    try:
        if args.command == "review":
            raise SystemExit(review(args.socket_path))
        if args.command in ("health", "ready"):
            value = request_json(
                args.socket_path, "GET", "/v1/health", None,
                timeout=5.0, max_request=0, max_response=MAX_CONTROL_RESPONSE,
            )
            validate_health(value, require_ready=args.command == "ready")
            sys.stdout.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
            return
        route = f"/v1/{args.command}"
        value = request_json(
            args.socket_path, "POST", route, {},
            timeout=60.0, max_request=MAX_CONTROL_RESPONSE, max_response=MAX_CONTROL_RESPONSE,
        )
        if args.command == "drain":
            validate_generation_ack(value, "drained")
        elif args.command == "resume":
            validate_generation_ack(value, "ready")
        elif value.get("stopping") is not True:
            raise ControlError("manager returned a malformed shutdown acknowledgement")
        sys.stdout.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    except (ControlError, OSError, http.client.HTTPException) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
