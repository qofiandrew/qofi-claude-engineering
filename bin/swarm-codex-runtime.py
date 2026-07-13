#!/usr/bin/python3 -I
"""Install, verify, log in, prepare, and remove the macOS Codex service runtime."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import grp
import hashlib
import json
import os
import pwd
import re
import selectors
import secrets
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import NoReturn

sys.dont_write_bytecode = True

SCHEMA = "qofi-codex-runtime/v2"
ATTESTATION = "/private/etc/qofi-codex-runtime.json"
RUNNER = "/usr/local/libexec/qofi-codex-runner"
LIFECYCLE = "/usr/local/libexec/qofi-codex-runtime"
MANAGER_LAUNCHER = "/usr/local/libexec/qofi-codex-manager-launcher"
MANAGER_BUNDLE = "/usr/local/libexec/qofi-codex-app-server-manager.mjs"
FABLE_REVIEWER = "/usr/local/libexec/qofi-fable-reviewer-mcp.py"
FABLE_DOCTRINE = "/usr/local/libexec/qofi-fable-reviewer-doctrine.md"
FABLE_SCHEMA = "/usr/local/libexec/qofi-adversarial-review-output.schema.json"
MANAGER_AUTHORITY = "/private/etc/qofi-codex-manager.json"
MANAGER_ADMISSION = "/private/var/db/qofi-codex-manager-admission.json"
MANAGER_LAUNCHER_LOCK = "/private/var/db/qofi-codex-manager-launcher.lock"
MANAGER_AUTHORITY_SCHEMA = "qofi-codex-manager-authority/v1"
MANAGER_ADMISSION_SCHEMA = "qofi-codex-manager-admission/v1"
TOOLCHAIN = "/usr/local/libexec/qofi-codex-toolchain"
SUDOERS = "/private/etc/sudoers.d/qofi-codex-runtime"
LOCK = "/private/var/run/qofi-codex-runner.lock"
WORKSPACE_REGISTRY = "/private/var/db/qofi-codex-runtime-workspaces.json"
WORKSPACE_SCHEMA = "qofi-codex-workspaces/v3"
WORKSPACE_JOURNAL_EVIDENCE_SCHEMA = "qofi-codex-workspace-journal-evidence/v1"
QUIESCENCE_PROOF_SCHEMA = "qofi-codex-quiescence-proof/v1"
DEFAULT_USER = "_qofi_codex"
DEFAULT_GROUP = "_qofi_codex_shared"
DEFAULT_HOME = "/Users/_qofi_codex"
MACOS_RUNTIME_INFRASTRUCTURE = "/usr/sbin/distnoted"
RUNTIME_USER_REALNAME = "Qofi Codex Runtime"
RUNTIME_GROUP_REALNAME = "Qofi Codex shared workspace"
SUPPORTED_PNPM_VERSION = "9.12.3"
SUPPORTED_PNPM_INTEGRITY = (
    "sha512.cce0f9de9c5a7c95bef944169cc5dfe8741abfb145078c0d508b868056848a87"
    "c81e626246cb60967cbd7fd29a6c062ef73ff840d96b3c86c40ac92cf4a813ee"
)
MAX_TREE_ENTRIES = 150_000
MAX_HELPER_OUTPUT = 16 * 1024
MAX_PROJECT_PACKAGE_JSON = 1024 * 1024
MAX_AUTH_JSON = 1024 * 1024
MAX_MANAGER_BUNDLE_BYTES = 2 * 1024 * 1024
MAX_REVIEWER_DOCTRINE_BYTES = 256 * 1024
MAX_REVIEWER_CONFIG_BYTES = 64 * 1024
HELPER_TIMEOUT = 10.0
RUNTIME_BOOTSTRAP_PROOF_ATTEMPTS = 100
RUNTIME_BOOTSTRAP_PROOF_INTERVAL = 0.05
# `launchctl asuser` adopts a bootstrap/audit context but deliberately does not
# change credentials. It must therefore run as root on current macOS, followed
# by this fixed isolated-system-Python trampoline which drops credentials before
# the requested executable is reached. Keep byte-identical with qofi-codex-runner.
RUNTIME_CONTEXT_TRAMPOLINE = r'''import os
import pwd
import sys

def refuse(reason):
    sys.stderr.write("qofi runtime credential trampoline refused: " + reason + "\n")
    raise SystemExit(126)

if len(sys.argv) < 6:
    refuse("argument shape")
name, uid_text, gid_text, mask_text = sys.argv[1:5]
argv = sys.argv[5:]
if not uid_text.isdecimal() or not gid_text.isdecimal():
    refuse("numeric identity")
uid, gid = int(uid_text), int(gid_text)
if uid <= 0 or gid <= 0 or mask_text not in ("077", "002"):
    refuse("identity or umask")
if (not argv or not os.path.isabs(argv[0]) or os.path.normpath(argv[0]) != argv[0]
        or any("\0" in value for value in argv)):
    refuse("executable argv")
try:
    by_name = pwd.getpwnam(name)
    by_uid = pwd.getpwuid(uid)
except KeyError:
    refuse("directory identity")
if (by_name.pw_name != name or by_name.pw_uid != uid or by_name.pw_gid != gid
        or by_uid.pw_name != name or by_uid.pw_uid != uid or by_uid.pw_gid != gid):
    refuse("directory identity")
try:
    os.initgroups(name, gid)
    os.setgid(gid)
    os.setuid(uid)
except OSError:
    refuse("credential drop")
if ((os.getuid(), os.geteuid(), os.getgid(), os.getegid()) != (uid, uid, gid, gid)
        or 0 in os.getgroups()):
    refuse("credential proof")
os.umask(int(mask_text, 8))
try:
    os.execve(argv[0], argv, dict(os.environ))
except OSError:
    refuse("exec")'''
# Production authority is always uid 0. Tests may replace this module-local
# constant only after importing the source into an isolated process.
ROOT_AUTHORITY_UID = 0
ROOT_AUTHORITY_GID = 0
LEGACY_EXACT_KEYS = {
    "schema", "operator_uid", "runtime_uid", "runtime_user",
    "runtime_gid", "runtime_group", "runtime_home", "codex_home",
    "runner_path", "runner_sha256", "node_path", "node_sha256",
    "codex_script", "codex_script_sha256", "launchd_canary_name",
    "launchd_canary_sha256",
}
EXACT_KEYS = LEGACY_EXACT_KEYS | {
    "fable_reviewer_path", "fable_reviewer_sha256",
    "fable_doctrine_path", "fable_doctrine_sha256",
    "fable_schema_path", "fable_schema_sha256",
    "fable_reviewer_config_sha256", "codex_config_sha256",
}
MANAGER_AUTHORITY_KEYS = {
    "schema", "operator_uid", "operator_user", "operator_home",
    "node_path", "node_sha256", "manager_bundle_path",
    "manager_bundle_sha256", "manager_launcher_path",
    "manager_launcher_sha256", "manager_python_path",
    "manager_python_sha256", "manager_state_dir", "swarm_home",
    "manager_environment_sha256",
}
MANAGER_ADMISSION_KEYS = {
    "schema", "nonce", "operator_uid", "launcher_pid", "launcher_started",
    "manager_pid", "manager_started", "node_path", "node_sha256",
    "manager_bundle_path", "manager_bundle_sha256", "manager_launcher_path",
    "manager_launcher_sha256", "manager_python_path", "manager_python_sha256",
    "manager_state_dir", "swarm_home", "manager_environment_sha256",
}
MANAGER_HEALTH_KEYS = {
    "schema", "managerVersion", "protocolVersion", "cliVersion", "generation",
    "registeredSwarmCount", "status", "phase", "upstreamState", "upstreamReady",
}
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]{0,63}\Z")
PROFILE_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}\Z")
DEFAULT_PROFILE = "default"
HASH_RE = re.compile(r"[0-9a-f]{64}\Z")
CODEX_CONFIG_TEMPLATE = b'''# Managed by swarm-codex-runtime.py. Local edits are replaced.
[mcp_servers.fable_reviewer]
command = "/usr/bin/sudo"
args = ["-n", "-H", "-u", "#__QOFI_OPERATOR_UID__", "--", "/usr/bin/python3", "-I", "-B", "/usr/local/libexec/qofi-fable-reviewer-mcp.py"]
enabled = true
required = true
startup_timeout_sec = 10
tool_timeout_sec = 4300
default_tools_approval_mode = "approve"
enabled_tools = ["adversarial_review"]

[mcp_servers.fable_reviewer.tools.adversarial_review]
approval_mode = "approve"
'''
CODEX_CONFIG_OPERATOR_UID = b"__QOFI_OPERATOR_UID__"
OPERATOR_DIRS = {".git", ".codex", ".claude", ".agents"}
OPERATOR_FILES = {
    "AGENTS.md", "CLAUDE.md", "TEAM_LEAD.md", "ESCALATION.md",
    "CONVERSATION.md", "EVALUATION.md", "SURFACING.md", "MEMORY.md",
    "READINESS_BAR.md", "CPO_BUS_PROTOCOL.md", ".gitleaks.toml",
}
PROVIDER_DIRS = {".aws", ".azure", ".gcloud", ".kube", ".ssh", ".gnupg"}
# Claude owns the complete contents of this subtree, including worktree-local
# `.git` pointer files.  Codex may protect the directory entry itself, but the
# privileged workspace provisioner must never traverse, journal, chmod, or
# reject Claude's worktrees as nested repositories.
OPAQUE_OPERATOR_SUBTREES = {os.path.join(".claude", "worktrees")}
PERSISTENT_RUNTIME_TRAVERSAL_PERMISSIONS = (
    "search,readattr,readextattr,readsecurity"
)
ENV_EXAMPLE_RE = re.compile(r"\.env\.(?:example|sample|template)(?:\.[A-Za-z0-9_-]+)?\Z", re.I)
SECRET_DATA_RE = re.compile(
    r"(?:credential|credentials|secret|secrets|service[-_]?account|private[-_]?key|auth)"
    r"[^/]*\.(?:json|ya?ml|toml|ini|cfg|conf|txt)\Z",
    re.I,
)
ALLOWED_IMPLICIT_RUNTIME_GROUPS = {"everyone", "localaccounts", "_lpoperator"}
_ACL_API: tuple[object, object, object, object] | None = None


def die(message: str, code: int = 2) -> NoReturn:
    print(f"swarm-codex-runtime: {message}", file=sys.stderr)
    raise SystemExit(code)


def run(command: list[str], *, check: bool = True, capture: bool = False,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command, check=check, text=True, capture_output=capture,
            env=env or {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
            },
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = ""
        if isinstance(exc, subprocess.CalledProcessError):
            detail = (exc.stderr or exc.stdout or "").strip()
        die(f"command failed: {' '.join(command)}{': ' + detail if detail else ''}")


def terminate_process_group(process: subprocess.Popen[bytes], grace: float = 0.75) -> None:
    """Terminate a bounded helper without leaving descendants behind."""

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    # A leader can exit while a descendant remains in the process group. Send
    # KILL to the group even after the leader has been reaped.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        die("could not reap a privileged lifecycle helper")


def run_as_operator_bounded(
    operator: pwd.struct_passwd,
    command: list[str],
    *,
    cwd: str,
    label: str,
) -> str:
    """Run mutable discovery code only after dropping every root credential."""

    def drop() -> None:
        if os.geteuid() == 0:
            os.initgroups(operator.pw_name, operator.pw_gid)
            os.setgid(operator.pw_gid)
            os.setuid(operator.pw_uid)
        elif os.geteuid() != operator.pw_uid or os.getuid() != operator.pw_uid:
            raise PermissionError("resolver caller is neither root nor the attested operator")
        os.umask(0o077)

    environment = {
        "HOME": operator.pw_dir,
        "USER": operator.pw_name,
        "LOGNAME": operator.pw_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "PYTHONNOUSERSITE": "1",
    }
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=cwd,
            env=environment,
            preexec_fn=drop,
            start_new_session=True,
        )
    except OSError as exc:
        die(f"could not start {label} as the operator: {exc}")
    assert process.stdout is not None
    os.set_blocking(process.stdout.fileno(), False)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + HELPER_TIMEOUT
    failure = ""
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = f"{label} timed out"
                break
            for key, _ in selector.select(min(remaining, 0.1)):
                try:
                    chunk = os.read(key.fd, 4096)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output.extend(chunk)
                if len(output) > MAX_HELPER_OUTPUT:
                    failure = f"{label} exceeded the bounded output cap"
                    break
            if failure:
                break
            if process.poll() is not None and not selector.get_map():
                break
    finally:
        selector.close()
        process.stdout.close()
    if failure:
        terminate_process_group(process)
        die(failure)
    try:
        returncode = process.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        terminate_process_group(process)
        die(f"{label} timed out")
    try:
        text = output.decode("utf-8", "strict")
    except UnicodeDecodeError:
        die(f"{label} emitted non-UTF-8 output")
    if returncode != 0:
        detail = text.strip().replace("\n", " ")[:512]
        die(f"{label} failed{': ' + detail if detail else ''}")
    return text.replace("\r\n", "\n").replace("\r", "\n")


def run_as_operator_capture_bytes(
    operator: pwd.struct_passwd,
    command: list[str],
    *,
    cwd: str,
    label: str,
    max_stdout: int,
    max_stderr: int = MAX_HELPER_OUTPUT,
    timeout: float = HELPER_TIMEOUT,
) -> bytes:
    """Capture one binary artifact after an exact operator credential drop.

    Stdout is the artifact channel and stderr is a separately bounded
    diagnostic channel. Keeping both pipes nonblocking avoids a helper which
    fills stderr from deadlocking root while root waits for bundle bytes.
    """

    if max_stdout < 1 or max_stderr < 1 or timeout <= 0:
        die(f"invalid internal bounds for {label}")

    def drop() -> None:
        if os.geteuid() == 0:
            os.initgroups(operator.pw_name, operator.pw_gid)
            os.setgid(operator.pw_gid)
            os.setuid(operator.pw_uid)
        elif os.geteuid() != operator.pw_uid or os.getuid() != operator.pw_uid:
            raise PermissionError("builder caller is neither root nor the attested operator")
        if ((os.getuid(), os.geteuid(), os.getgid(), os.getegid())
                != (operator.pw_uid, operator.pw_uid, operator.pw_gid, operator.pw_gid)
                or 0 in os.getgroups()):
            raise PermissionError("builder credential drop could not be proven")
        os.umask(0o077)

    environment = {
        "HOME": operator.pw_dir,
        "USER": operator.pw_name,
        "LOGNAME": operator.pw_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            env=environment,
            preexec_fn=drop,
            start_new_session=True,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        die(f"could not start {label} as the operator: {exc}")
    assert process.stdout is not None and process.stderr is not None
    streams = {
        process.stdout: ("stdout", bytearray(), max_stdout),
        process.stderr: ("stderr", bytearray(), max_stderr),
    }
    selector = selectors.DefaultSelector()
    deadline = time.monotonic() + timeout
    failure = ""
    unexpected: BaseException | None = None
    try:
        for stream in streams:
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = f"{label} timed out"
                break
            for key, _ in selector.select(min(remaining, 0.1)):
                try:
                    chunk = os.read(key.fd, 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                channel, output, maximum = streams[key.fileobj]
                output.extend(chunk)
                if len(output) > maximum:
                    failure = f"{label} exceeded the bounded {channel} cap"
                    break
            if failure:
                break
    except BaseException as exc:
        unexpected = exc
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()
    if unexpected is not None:
        terminate_process_group(process)
        raise unexpected
    if failure:
        terminate_process_group(process)
        die(failure)
    try:
        returncode = process.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        terminate_process_group(process)
        die(f"{label} timed out")
    stderr = bytes(streams[process.stderr][1])
    if returncode != 0:
        detail = stderr.decode("utf-8", "replace").strip().replace("\n", " ")[:512]
        die(f"{label} failed{': ' + detail if detail else ''}")
    return bytes(streams[process.stdout][1])


def require_macos() -> None:
    if sys.platform != "darwin":
        die("the dedicated Codex runtime installer currently supports macOS only")


def require_root() -> None:
    if os.geteuid() != 0:
        die("this command requires root; use bin/swarm-codex-runtime.sh")


def require_fixed_reviewer_authority() -> None:
    """Bind the complete fixed reviewer surface used after installation."""

    validate_root_authority_file(
        FABLE_REVIEWER, "fixed Fable reviewer shim", executable=True, exact_mode=0o755,
        max_bytes=2 * 1024 * 1024,
    )
    validate_root_authority_file(
        FABLE_DOCTRINE, "fixed Fable reviewer doctrine", exact_mode=0o644,
        max_bytes=MAX_REVIEWER_DOCTRINE_BYTES,
    )
    validate_root_authority_file(
        FABLE_SCHEMA, "fixed adversarial review schema", exact_mode=0o644,
        max_bytes=MAX_REVIEWER_DOCTRINE_BYTES,
    )


def require_fixed_lifecycle(*, include_reviewer: bool = True) -> None:
    """Bind the fixed lifecycle and, normally, its installed companions.

    A privileged install upgrading a legacy v2 attestation must first enter via
    the already-root-owned lifecycle before the Fable companions exist.  That
    one caller sets ``include_reviewer=False``; every post-install mutation
    retains the complete proof.
    """

    if os.path.realpath(sys.argv[0]) != LIFECYCLE:
        die("post-install root lifecycle commands must execute the fixed root-owned helper")
    validate_root_authority_file(
        LIFECYCLE, "fixed lifecycle helper", executable=True, exact_mode=0o755,
        max_bytes=2 * 1024 * 1024,
    )
    if include_reviewer:
        require_fixed_reviewer_authority()


def validate_runtime_home_target(home: str, operator_home: str, repo: str, swarm_home: str) -> str:
    if not os.path.isabs(home) or os.path.normpath(home) != home:
        die("runtime home must be an absolute normalized path")
    if os.path.lexists(home) and (os.path.islink(home) or os.path.realpath(home) != home):
        die("runtime home must not contain symlink indirection")
    roots = [operator_home, repo, swarm_home, "/tmp", "/private/tmp", "/var/tmp", "/var/folders"]
    for root in roots:
        if not os.path.exists(root):
            continue
        canonical = os.path.realpath(root)
        if os.path.commonpath([canonical, home]) in (canonical, home):
            die(f"runtime home must not overlap operator/workspace/host/temp root: {canonical}")
    parent = os.path.dirname(home)
    parent_info = os.lstat(parent)
    if (not stat.S_ISDIR(parent_info.st_mode) or stat.S_ISLNK(parent_info.st_mode)
            or parent_info.st_uid != ROOT_AUTHORITY_UID or parent_info.st_mode & 0o022):
        die("runtime home parent must be a root-controlled real directory")
    return home


def process_executable_path(pid: int) -> str | None:
    if sys.platform != "darwin" or pid <= 0:
        return None
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidpath = libproc.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    length = proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        return None
    try:
        return buffer.value.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None


def process_arguments(pid: int) -> list[str] | None:
    """Read one bounded initial argv vector with macOS KERN_PROCARGS2."""

    if sys.platform != "darwin" or pid <= 1:
        return None
    libc = ctypes.CDLL(None, use_errno=True)
    sysctl = libc.sysctl
    sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
    ]
    sysctl.restype = ctypes.c_int
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2, pid
    size = ctypes.c_size_t(0)
    if sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    if not 8 <= size.value <= 256 * 1024:
        return None
    buffer = ctypes.create_string_buffer(size.value)
    if sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return None
    raw = bytes(buffer.raw[:size.value])
    width = ctypes.sizeof(ctypes.c_int)
    if len(raw) < width:
        return None
    argc = int.from_bytes(raw[:width], byteorder=sys.byteorder, signed=True)
    if not 1 <= argc <= 64:
        return None
    offset = width
    executable_end = raw.find(b"\0", offset)
    if executable_end <= offset:
        return None
    offset = executable_end + 1
    while offset < len(raw) and raw[offset] == 0:
        offset += 1
    result: list[str] = []
    try:
        for _ in range(argc):
            end = raw.find(b"\0", offset)
            if end < offset:
                return None
            result.append(raw[offset:end].decode("utf-8", "strict"))
            offset = end + 1
    except UnicodeDecodeError:
        return None
    return result


PROCESS_SNAPSHOT_FIELDS = [
    "pid=", "ppid=", "pgid=", "sess=", "uid=", "ruid=", "svuid=",
    "gid=", "rgid=", "svgid=", "lstart=",
]


def parse_process_snapshot(line: str) -> dict[str, int | str] | None:
    fields = line.split()
    if len(fields) != 15 or not all(field.isdigit() for field in fields[:10]):
        return None
    values = list(map(int, fields[:10]))
    return {
        "pid": values[0], "ppid": values[1], "pgid": values[2], "session": values[3],
        "uid": values[4], "ruid": values[5], "svuid": values[6],
        "gid": values[7], "rgid": values[8], "svgid": values[9],
        "started": " ".join(fields[10:]),
    }


def process_snapshots(uid: int) -> list[dict[str, int | str]]:
    output = run(
        ["/bin/ps", "-axo", ",".join(PROCESS_SNAPSHOT_FIELDS)], capture=True,
    ).stdout
    if len(output.encode("utf-8", "replace")) > 1024 * 1024:
        die("runtime process snapshot exceeded the bound")
    result: list[dict[str, int | str]] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        snapshot = parse_process_snapshot(line)
        if snapshot is None:
            die("runtime process snapshot was malformed")
        if uid in (snapshot["uid"], snapshot["ruid"], snapshot["svuid"]):
            result.append(snapshot)
    return result


def process_snapshot(pid: int) -> dict[str, int | str] | None:
    try:
        observed = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", ",".join(PROCESS_SNAPSHOT_FIELDS)],
            text=True, capture_output=True, timeout=3,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError):
        return None
    lines = [line for line in observed.stdout.splitlines() if line.strip()]
    return parse_process_snapshot(lines[0]) if observed.returncode == 0 and len(lines) == 1 else None


def exact_process_command(pid: int) -> str | None:
    try:
        observed = subprocess.run(
            ["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
            text=True, capture_output=True, timeout=3,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return observed.stdout.strip() if observed.returncode == 0 else None


def allowed_runtime_infrastructure_pid(
    snapshots: list[dict[str, int | str]], uid: int, gid: int,
) -> int | None:
    """Return the one stable PID-1/SIP distnoted agent, never a payload process."""

    if sys.platform != "darwin" or uid <= 0 or gid <= 0:
        return None
    candidates = [
        item for item in snapshots
        if item["pid"] > 1
        and item["ppid"] == 1
        and item["pgid"] == item["pid"]
        and item["session"] == 0
        and item["uid"] == item["ruid"] == item["svuid"] == uid
        and item["gid"] == item["rgid"] == item["svgid"] == gid
        and process_executable_path(int(item["pid"])) == MACOS_RUNTIME_INFRASTRUCTURE
    ]
    if len(candidates) != 1:
        return None
    before = candidates[0]
    pid = int(before["pid"])
    info = validate_root_authority_file(
        MACOS_RUNTIME_INFRASTRUCTURE,
        "macOS runtime infrastructure",
        executable=True,
        exact_mode=0o755,
        max_bytes=16 * 1024 * 1024,
    )
    if (os.path.realpath(MACOS_RUNTIME_INFRASTRUCTURE) != MACOS_RUNTIME_INFRASTRUCTURE
            or info.st_uid != 0 or info.st_gid != 0 or info.st_nlink != 1
            or not getattr(info, "st_flags", 0) & 0x00080000):
        die("macOS runtime infrastructure authority changed")
    if exact_process_command(pid) != f"{MACOS_RUNTIME_INFRASTRUCTURE} agent":
        return None
    after = process_snapshot(pid)
    if (after != before or process_executable_path(pid) != MACOS_RUNTIME_INFRASTRUCTURE
            or exact_process_command(pid) != f"{MACOS_RUNTIME_INFRASTRUCTURE} agent"):
        return None
    return pid


def service_pids(uid: int, gid: int) -> list[int]:
    snapshots = process_snapshots(uid)
    allowed = allowed_runtime_infrastructure_pid(snapshots, uid, gid)
    return [int(item["pid"]) for item in snapshots if item["pid"] != allowed]


def identity_authority(
    operator: pwd.struct_passwd,
    runtime: pwd.struct_passwd,
    shared: grp.struct_group,
) -> dict[str, object]:
    return {
        "operator_uid": operator.pw_uid,
        "runtime_uid": runtime.pw_uid,
        "runtime_user": runtime.pw_name,
        "runtime_gid": shared.gr_gid,
        "runtime_group": shared.gr_name,
        "runtime_home": runtime.pw_dir,
    }


def exact_runtime_identity(
    authority: dict[str, object], *, require_ds: bool = True,
) -> tuple[pwd.struct_passwd, pwd.struct_passwd, grp.struct_group]:
    """Prove every numeric identity maps back to the same attested record."""

    try:
        operator_uid = authority["operator_uid"]
        runtime_uid = authority["runtime_uid"]
        runtime_gid = authority["runtime_gid"]
        runtime_user = authority["runtime_user"]
        runtime_group = authority["runtime_group"]
        runtime_home = authority["runtime_home"]
    except KeyError as exc:
        die(f"runtime identity authority is incomplete: {exc}")
    if (type(operator_uid) is not int or operator_uid <= 0
            or type(runtime_uid) is not int or runtime_uid <= 0
            or runtime_uid == operator_uid
            or type(runtime_gid) is not int or runtime_gid <= 0
            or not isinstance(runtime_user, str) or not NAME_RE.fullmatch(runtime_user)
            or not isinstance(runtime_group, str) or not NAME_RE.fullmatch(runtime_group)
            or not isinstance(runtime_home, str)):
        die("runtime identity authority has invalid uid/name/home/gid fields")
    try:
        operator = pwd.getpwuid(operator_uid)
        operator_by_name = pwd.getpwnam(operator.pw_name)
        runtime = pwd.getpwnam(runtime_user)
        runtime_by_uid = pwd.getpwuid(runtime_uid)
        shared = grp.getgrnam(runtime_group)
        shared_by_gid = grp.getgrgid(runtime_gid)
    except KeyError as exc:
        die(f"attested runtime identity no longer exists bidirectionally: {exc}")
    if (operator_by_name.pw_uid != operator_uid
            or runtime.pw_uid != runtime_uid
            or runtime_by_uid.pw_name != runtime_user
            or runtime_by_uid.pw_uid != runtime_uid
            or runtime.pw_dir != runtime_home
            or runtime_by_uid.pw_dir != runtime_home
            or runtime.pw_gid != runtime_gid
            or runtime_by_uid.pw_gid != runtime_gid
            or runtime.pw_shell != "/usr/bin/false"
            or runtime_by_uid.pw_shell != "/usr/bin/false"
            or shared.gr_gid != runtime_gid
            or shared_by_gid.gr_name != runtime_group
            or shared_by_gid.gr_gid != runtime_gid):
        die("attested uid/name/home/gid does not map bidirectionally to one service identity")
    explicit_members = set(shared.gr_mem)
    expected_members = {operator.pw_name, runtime_user}
    if explicit_members != expected_members:
        die("shared runtime group has missing or unexpected explicit members")
    try:
        runtime_groups = set(os.getgrouplist(runtime_user, runtime.pw_gid))
        operator_groups = set(os.getgrouplist(operator.pw_name, operator.pw_gid))
    except OSError as exc:
        die(f"could not resolve exact runtime group membership: {exc}")
    try:
        runtime_group_names = {grp.getgrgid(gid).gr_name for gid in runtime_groups}
    except KeyError as exc:
        die(f"runtime account has an unresolvable supplementary gid: {exc}")
    if runtime_group_names - ({runtime_group} | ALLOWED_IMPLICIT_RUNTIME_GROUPS):
        die("runtime account has an unexpected or privileged supplementary group")
    if runtime_gid not in operator_groups:
        die("operator is not in the attested shared runtime group")
    if require_ds and sys.platform == "darwin":
        expected_numeric = (
            ("UniqueID", runtime_uid), ("PrimaryGroupID", runtime_gid),
        )
        for field, expected in expected_numeric:
            if ds_numeric_attribute("Users", runtime_user, field) != expected:
                die(f"Directory Services runtime {field} drift")
        if ds_boolean_attribute("Users", runtime_user, "IsHidden") is not True:
            die("Directory Services runtime IsHidden drift")
        expected_strings = (
            ("NFSHomeDirectory", runtime_home),
            ("UserShell", "/usr/bin/false"),
            ("RealName", RUNTIME_USER_REALNAME),
            ("Password", "*"),
        )
        for field, expected in expected_strings:
            if ds_string_attribute("Users", runtime_user, field) != expected:
                die(f"Directory Services runtime {field} drift")
        if ds_string_attribute("Users", runtime_user, "AuthenticationAuthority") is not None:
            die("runtime account must not have an AuthenticationAuthority")
        if ds_numeric_attribute("Groups", runtime_group, "PrimaryGroupID") != runtime_gid:
            die("Directory Services shared group gid drift")
        if ds_string_attribute("Groups", runtime_group, "RealName") != RUNTIME_GROUP_REALNAME:
            die("Directory Services shared group marker drift")
        if set(ds_values_attribute("Groups", runtime_group, "GroupMembership")) != expected_members:
            die("Directory Services shared group has missing or unexpected members")
        if ds_values_attribute("Groups", runtime_group, "NestedGroups"):
            die("Directory Services shared group must not contain nested groups")
    return operator, runtime, shared


def quiesce_service_uid(authority: dict[str, object]) -> None:
    uid = int(authority["runtime_uid"])
    for _ in range(40):
        exact_runtime_identity(authority)
        gid = int(authority["runtime_gid"])
        pids = service_pids(uid, gid)
        if not pids:
            return
        for pid in pids:
            exact_runtime_identity(authority, require_ds=False)
            try:
                os.kill(pid, signal.SIGSTOP)
            except ProcessLookupError:
                pass
        for pid in service_pids(uid, gid):
            exact_runtime_identity(authority, require_ds=False)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(0.05)
    die("dedicated runtime uid has a persistent respawner; refusing lifecycle mutation")


def acquire_lifecycle_lock(authority: dict[str, object] | None) -> int:
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != ROOT_AUTHORITY_UID
            or stat.S_IMODE(info.st_mode) != 0o600 or fd_has_extended_acl(fd)):
        os.close(fd)
        die("global runner lock must be root-owned mode 0600")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        die("a Codex child is active; retry lifecycle mutation after the turn completes")
    if authority is not None:
        quiesce_service_uid(authority)
    return fd


def release_lifecycle_lock(fd: int) -> None:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


def acquire_manager_mutation_lock(timeout: float = 45.0) -> int:
    """Exclude manager startup before taking the global hidden-runner lock."""

    try:
        fd = os.open(
            MANAGER_LAUNCHER_LOCK,
            os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
    except OSError as exc:
        die(f"could not bind manager lifecycle lock: {exc}")
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != ROOT_AUTHORITY_UID
                or stat.S_IMODE(info.st_mode) != 0o600 or fd_has_extended_acl(fd)):
            die("manager lifecycle lock must be root-owned mode 0600")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    die("Codex App Server manager is active; shut it down before lifecycle mutation")
                time.sleep(0.05)
            except OSError as exc:
                die(f"could not acquire manager lifecycle lock: {exc}")
        try:
            named = os.lstat(MANAGER_LAUNCHER_LOCK)
        except OSError as exc:
            die(f"could not rebind manager lifecycle lock: {exc}")
        if _manager_admission_identity(named) != _manager_admission_identity(os.fstat(fd)):
            die("manager lifecycle lock was replaced while acquiring it")
        return fd
    except BaseException:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
        raise


def acquire_manager_mutation_locks(
    authority: dict[str, object] | None,
) -> tuple[int, int]:
    manager_fd = acquire_manager_mutation_lock()
    try:
        runner_fd = acquire_lifecycle_lock(authority)
    except BaseException:
        try:
            fcntl.flock(manager_fd, fcntl.LOCK_UN)
        finally:
            os.close(manager_fd)
        raise
    return manager_fd, runner_fd


def release_manager_mutation_locks(manager_fd: int, runner_fd: int) -> None:
    try:
        release_lifecycle_lock(runner_fd)
    finally:
        try:
            fcntl.flock(manager_fd, fcntl.LOCK_UN)
        finally:
            os.close(manager_fd)


def canonical_dir(path: str, label: str) -> str:
    if not os.path.isabs(path):
        die(f"{label} must be absolute")
    normalized = os.path.normpath(path)
    if normalized != path or not os.path.isdir(path) or os.path.islink(path):
        die(f"{label} must be a real canonical directory: {path}")
    canonical = os.path.realpath(path)
    if canonical != path:
        die(f"{label} must not contain symlink indirection: {path}")
    return canonical


class WorkspaceRootMismatch(RuntimeError):
    pass


class AttrList(ctypes.Structure):
    _fields_ = [
        ("bitmapcount", ctypes.c_ushort),
        ("reserved", ctypes.c_ushort),
        ("commonattr", ctypes.c_uint32),
        ("volattr", ctypes.c_uint32),
        ("dirattr", ctypes.c_uint32),
        ("fileattr", ctypes.c_uint32),
        ("forkattr", ctypes.c_uint32),
    ]


def workspace_volume_uuid_fd(fd: int) -> str:
    """Return the stable filesystem UUID for a descriptor-bound workspace.

    Darwin's st_dev is a mount-session identifier and can change across a
    reboot even when an APFS file keeps the same inode.  ATTR_VOL_UUID is the
    persistent volume identity needed by recovery journals.
    """

    attr_vol_uuid = 0x00040000
    attributes = AttrList(5, 0, 0, attr_vol_uuid, 0, 0, 0)
    output = ctypes.create_string_buffer(64)
    libc = ctypes.CDLL(None, use_errno=True)
    fgetattrlist = libc.fgetattrlist
    fgetattrlist.argtypes = [
        ctypes.c_int, ctypes.POINTER(AttrList), ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_uint32,
    ]
    fgetattrlist.restype = ctypes.c_int
    ctypes.set_errno(0)
    if fgetattrlist(fd, ctypes.byref(attributes), output, len(output), 0) != 0:
        die(f"could not bind workspace volume identity: errno {ctypes.get_errno()}")
    returned_size = struct.unpack_from("=I", output.raw)[0]
    if returned_size != 20:
        die("workspace volume identity returned an unexpected size")
    return str(uuid.UUID(bytes=output.raw[4:20]))


def open_workspace_root_fd(
    repo: str,
    *,
    expected_identity: tuple[int, int] | None = None,
) -> tuple[str, int, os.stat_result]:
    """Open one nofollow workspace root and bind all later work to its inode."""

    if not os.path.isabs(repo) or os.path.normpath(repo) != repo:
        raise WorkspaceRootMismatch("workspace path is not absolute and normalized")
    try:
        before = os.lstat(repo)
    except FileNotFoundError as exc:
        raise WorkspaceRootMismatch("workspace is absent") from exc
    if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or os.path.realpath(repo) != repo):
        raise WorkspaceRootMismatch("workspace is not a canonical real directory")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(repo, flags)
    except OSError as exc:
        raise WorkspaceRootMismatch(f"workspace changed before open: {exc}") from exc
    opened = os.fstat(fd)
    identity = (opened.st_dev, opened.st_ino)
    if (not stat.S_ISDIR(opened.st_mode)
            or identity != (before.st_dev, before.st_ino)
            or (expected_identity is not None and identity != expected_identity)):
        os.close(fd)
        raise WorkspaceRootMismatch("workspace root identity changed before mutation")
    try:
        after = os.lstat(repo)
    except FileNotFoundError:
        after = None
    if after is None or (after.st_dev, after.st_ino) != identity:
        # The bound fd is safe, but lifecycle operations are path-scoped. Do
        # not mutate an inode that has already been detached from that path.
        os.close(fd)
        raise WorkspaceRootMismatch("workspace root was replaced while binding")
    return repo, fd, opened


def workspace_volume_uuid_for_path(
    repo: str,
    expected_identity: tuple[int, int],
) -> str:
    try:
        _canonical, fd, _info = open_workspace_root_fd(
            repo, expected_identity=expected_identity,
        )
    except WorkspaceRootMismatch as exc:
        die(str(exc))
    try:
        return workspace_volume_uuid_fd(fd)
    finally:
        os.close(fd)


def sha256(path: str) -> str:
    before = os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_size > 512 * 1024 * 1024):
        die(f"refusing to hash unsafe/oversized authority file: {path}")
    digest = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        identity = (
            opened.st_dev, opened.st_ino, opened.st_size,
            opened.st_mtime_ns, opened.st_ctime_ns,
        )
        if identity != (
            before.st_dev, before.st_ino, before.st_size,
            before.st_mtime_ns, before.st_ctime_ns,
        ):
            die(f"authority file changed while opening: {path}")
        while chunk := os.read(fd, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(fd)
        if (after.st_dev, after.st_ino, after.st_size,
                after.st_mtime_ns, after.st_ctime_ns) != identity:
            die(f"authority file changed while hashing: {path}")
    finally:
        os.close(fd)
    return digest.hexdigest()


def _authority_owner(uid: int) -> bool:
    # Production accepts only uid 0.  The second value is an explicit
    # unprivileged-test seam documented beside ROOT_AUTHORITY_UID.
    return uid in (0, ROOT_AUTHORITY_UID)


def _authority_path(path: str, label: str) -> str:
    if (not os.path.isabs(path) or os.path.normpath(path) != path
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in path)):
        die(f"{label} path must be absolute and normalized")
    return path


def _open_root_authority_directory(
    path: str,
    label: str,
    *,
    create: bool = False,
) -> int:
    """Open an authority directory through an ACL-free trusted chain.

    The production chain is checked from ``/`` down.  When tests replace the
    root-authority uid with their unprivileged uid, ancestors above the direct
    fixture directory retain the ownership/mode proof while ACL enforcement
    begins at the fixture directory itself.  This keeps the production policy
    exact without treating a developer's stock macOS home ACL as root state.
    """

    target = _authority_path(path, label)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open("/", flags)
    except OSError as exc:
        die(f"could not open the root authority chain for {label}: {exc}")
    current = "/"
    parts = target.split("/")[1:]
    try:
        for index in range(len(parts) + 1):
            info = os.fstat(fd)
            enforce_acl = ROOT_AUTHORITY_UID == 0 or current == target
            if (not stat.S_ISDIR(info.st_mode) or not _authority_owner(info.st_uid)
                    or info.st_mode & 0o022
                    or (enforce_acl and fd_has_extended_acl(fd))):
                die(f"{label} authority directory is not ACL-free root controlled: {current}")
            if index == len(parts):
                return fd

            part = parts[index]
            if not part or part in (".", ".."):
                die(f"{label} authority path has an invalid component")
            try:
                next_fd = os.open(part, flags, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    die(f"{label} authority directory is absent: {os.path.join(current, part)}")
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                    next_fd = os.open(part, flags, dir_fd=fd)
                    os.fchown(next_fd, ROOT_AUTHORITY_UID, ROOT_AUTHORITY_GID)
                    os.fchmod(next_fd, 0o755)
                    strip_extended_acl_fd(next_fd, f"created {label} authority directory")
                except OSError as exc:
                    die(f"could not create the root authority directory for {label}: {exc}")
            except OSError as exc:
                die(f"could not traverse the root authority directory for {label}: {exc}")
            os.close(fd)
            fd = next_fd
            current = os.path.join(current, part)
    except BaseException:
        os.close(fd)
        raise


def ensure_root_authority_directory(path: str, label: str) -> None:
    fd = _open_root_authority_directory(path, label, create=True)
    os.close(fd)


def validate_root_authority_file(
    path: str,
    label: str,
    *,
    executable: bool = False,
    exact_mode: int | None = None,
    max_bytes: int | None = None,
) -> os.stat_result:
    """Bind one installed root authority file to its safe parent chain."""

    path = _authority_path(path, label)
    parent_fd = _open_root_authority_directory(os.path.dirname(path), label)
    try:
        name = os.path.basename(path)
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        try:
            opened = os.fstat(fd)
            identity = (
                opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid,
                opened.st_gid, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns,
            )
            if identity != (
                before.st_dev, before.st_ino, before.st_mode, before.st_uid,
                before.st_gid, before.st_size, before.st_mtime_ns, before.st_ctime_ns,
            ):
                die(f"{label} authority changed while opening: {path}")
            mode = stat.S_IMODE(opened.st_mode)
            if (not stat.S_ISREG(opened.st_mode) or not _authority_owner(opened.st_uid)
                    or mode & 0o022 or fd_has_extended_acl(fd)
                    or (executable and not mode & 0o111)
                    or (exact_mode is not None and mode != exact_mode)
                    or (max_bytes is not None and opened.st_size > max_bytes)):
                die(f"{label} is not an ACL-free root authority file: {path}")
            return opened
        finally:
            os.close(fd)
    except (FileNotFoundError, OSError) as exc:
        die(f"could not bind {label} root authority file {path}: {exc}")
    finally:
        os.close(parent_fd)


def validate_root_authority_tree(root: str, label: str) -> None:
    """Reject ACL, ownership, mode, symlink, and special-file drift in a tree."""

    root = _authority_path(root, label)
    _parent_fd = _open_root_authority_directory(os.path.dirname(root), label)
    os.close(_parent_fd)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        root_fd = os.open(root, flags)
    except OSError as exc:
        die(f"could not open {label} authority tree: {exc}")
    count = 0
    try:
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
        ):
            count += len(dirs) + len(files)
            if count > MAX_TREE_ENTRIES:
                die(f"{label} authority tree exceeds the bounded entry count")
            directory = os.fstat(dir_fd)
            if (not stat.S_ISDIR(directory.st_mode)
                    or not _authority_owner(directory.st_uid)
                    or directory.st_mode & 0o022 or fd_has_extended_acl(dir_fd)):
                die(f"{label} authority directory drift: {current}")
            for name in dirs + files:
                before = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
                entry_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                if stat.S_ISDIR(before.st_mode):
                    entry_flags |= getattr(os, "O_DIRECTORY", 0)
                elif stat.S_ISREG(before.st_mode):
                    entry_flags |= os.O_NONBLOCK
                else:
                    die(f"{label} authority tree contains a symlink or special file: {current}/{name}")
                entry_fd = os.open(name, entry_flags, dir_fd=dir_fd)
                try:
                    opened = os.fstat(entry_fd)
                    if ((opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid,
                         opened.st_gid, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
                            != (before.st_dev, before.st_ino, before.st_mode, before.st_uid,
                                before.st_gid, before.st_size, before.st_mtime_ns,
                                before.st_ctime_ns)
                            or not _authority_owner(opened.st_uid)
                            or opened.st_mode & 0o022 or fd_has_extended_acl(entry_fd)):
                        die(f"{label} authority entry drift: {current}/{name}")
                finally:
                    os.close(entry_fd)
    finally:
        os.close(root_fd)


def atomic_write(path: str, content: str, mode: int) -> None:
    parent = os.path.dirname(path)
    if mode & 0o022:
        die(f"root authority file mode is group/world writable: {path}")
    ensure_root_authority_directory(parent, "atomic-write parent")
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchown(handle.fileno(), ROOT_AUTHORITY_UID, ROOT_AUTHORITY_GID)
            os.fchmod(handle.fileno(), mode)
            strip_extended_acl_fd(handle.fileno(), "staged root authority file")
            staged = os.fstat(handle.fileno())
            if (not stat.S_ISREG(staged.st_mode)
                    or not _authority_owner(staged.st_uid)
                    or stat.S_IMODE(staged.st_mode) != mode
                    or fd_has_extended_acl(handle.fileno())):
                die(f"could not harden staged root authority file: {path}")
        os.replace(temporary, path)
        validate_root_authority_file(path, "installed atomic authority", exact_mode=mode)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def transaction_backup(path: str) -> str | None:
    if not os.path.lexists(path):
        return None
    validate_root_authority_file(path, "transaction authority")
    backup = path + f".old.{os.getpid()}"
    if os.path.lexists(backup):
        die(f"stale authority transaction backup exists: {backup}")
    os.link(path, backup, follow_symlinks=False)
    validate_root_authority_file(backup, "transaction authority backup")
    return backup


def transaction_restore(path: str, backup: str | None) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        info = None
    if info is not None:
        validate_root_authority_file(path, "transaction replacement authority")
        os.unlink(path)
    if backup is not None and os.path.lexists(backup):
        validate_root_authority_file(backup, "transaction restore authority")
        os.rename(backup, path)
        validate_root_authority_file(path, "restored transaction authority")


def transaction_discard(backup: str | None) -> None:
    if backup is not None:
        try:
            os.unlink(backup)
        except FileNotFoundError:
            pass


def operator_record(explicit: str | None) -> pwd.struct_passwd:
    name = explicit or os.environ.get("SUDO_USER", "")
    if not name or name == "root":
        die("could not identify the non-root operator; pass --operator-user")
    try:
        record = pwd.getpwnam(name)
    except KeyError:
        die(f"operator account does not exist: {name}")
    if record.pw_uid == 0 or not NAME_RE.fullmatch(record.pw_name):
        die("operator account must have a valid non-root local username")
    return record


def ds_record(kind: str, name: str) -> bool:
    result = subprocess.run(
        ["/usr/bin/dscl", ".", "-read", f"/{kind}/{name}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )
    return result.returncode == 0


def ds_numeric_attribute(kind: str, name: str, field: str) -> int | None:
    result = run(
        ["/usr/bin/dscl", ".", "-read", f"/{kind}/{name}", field],
        check=False, capture=True,
    )
    combined = (result.stdout + result.stderr).strip()
    if result.returncode != 0 or combined == f"No such key: {field}":
        return None
    fields = result.stdout.strip().split()
    if len(fields) != 2 or fields[0].rstrip(":") != field or not fields[1].isdigit():
        die(f"existing Directory Services {kind}/{name} has malformed {field}")
    return int(fields[1])


def ds_boolean_attribute(kind: str, name: str, field: str) -> bool | None:
    """Read one Directory Services boolean without assuming numeric rendering.

    macOS normalizes a value written as ``1`` to ``YES`` for native boolean
    attributes such as ``IsHidden`` and may render its key as
    ``dsAttrTypeNative:IsHidden``. Accept only those exact native/direct keys
    and true forms (plus their exact false counterparts); every other present
    shape remains a fail-closed malformed record.
    """

    result = run(
        ["/usr/bin/dscl", ".", "-read", f"/{kind}/{name}", field],
        check=False, capture=True,
    )
    combined = (result.stdout + result.stderr).strip()
    if result.returncode != 0 or combined == f"No such key: {field}":
        return None
    fields = result.stdout.strip().split()
    rendered_key = fields[0].rstrip(":") if fields else ""
    if (len(fields) != 2
            or rendered_key not in (field, f"dsAttrTypeNative:{field}")):
        die(f"existing Directory Services {kind}/{name} has malformed {field}")
    if fields[1] in ("1", "YES"):
        return True
    if fields[1] in ("0", "NO"):
        return False
    die(f"existing Directory Services {kind}/{name} has malformed {field}")


def ds_string_attribute(kind: str, name: str, field: str) -> str | None:
    result = run(
        ["/usr/bin/dscl", ".", "-read", f"/{kind}/{name}", field],
        check=False, capture=True,
    )
    combined = (result.stdout + result.stderr).strip()
    if result.returncode != 0 or combined == f"No such key: {field}":
        return None
    prefix = f"{field}:"
    text = result.stdout.strip()
    if not text.startswith(prefix):
        die(f"existing Directory Services {kind}/{name} has malformed {field}")
    return text[len(prefix):].strip()


def ds_values_attribute(kind: str, name: str, field: str) -> list[str]:
    result = run(
        ["/usr/bin/dscl", ".", "-read", f"/{kind}/{name}", field],
        check=False, capture=True,
    )
    combined = (result.stdout + result.stderr).strip()
    if result.returncode != 0 or combined == f"No such key: {field}":
        return []
    lines = result.stdout.splitlines()
    if not lines or not lines[0].startswith(f"{field}:"):
        die(f"existing Directory Services {kind}/{name} has malformed {field}")
    values = lines[0].split(":", 1)[1].split()
    for line in lines[1:]:
        values.extend(line.split())
    if any(not value or any(ord(ch) < 32 or ord(ch) == 127 for ch in value) for value in values):
        die(f"existing Directory Services {kind}/{name} has unsafe {field}")
    return values


def next_id(kind: str, field: str, floor: int = 501) -> int:
    output = run(["/usr/bin/dscl", ".", "-list", f"/{kind}", field], capture=True).stdout
    used = {int(line.split()[-1]) for line in output.splitlines()
            if line.split() and line.split()[-1].isdigit()}
    candidate = max([floor - 1, *[value for value in used if value < 60_000]]) + 1
    while candidate in used:
        candidate += 1
    if candidate >= 60_000:
        die(f"could not allocate a bounded {field}")
    return candidate


def ensure_group(name: str) -> grp.struct_group:
    if not NAME_RE.fullmatch(name):
        die("runtime group name is invalid")
    exists = ds_record("Groups", name)
    if exists and ds_string_attribute("Groups", name, "RealName") != RUNTIME_GROUP_REALNAME:
        die(
            f"refusing to adopt unmanaged pre-existing group {name}; remove/rename it or "
            "recover the original Qofi authority explicitly"
        )
    gid = ds_numeric_attribute("Groups", name, "PrimaryGroupID") if exists else None
    if gid is None:
        gid = next_id("Groups", "PrimaryGroupID")
    path = f"/Groups/{name}"
    run(["/usr/bin/dscl", ".", "-create", path])
    run(["/usr/bin/dscl", ".", "-create", path, "RealName", RUNTIME_GROUP_REALNAME])
    run(["/usr/bin/dscl", ".", "-create", path, "PrimaryGroupID", str(gid)])
    run(["/usr/bin/dscacheutil", "-flushcache"], check=False)
    try:
        record = grp.getgrnam(name)
    except KeyError:
        die(f"group directory cache did not resolve {name}; retry after dscacheutil -flushcache")
    if record.gr_gid != gid or record.gr_gid <= 0:
        die("runtime group directory record does not match its reconciled gid")
    return record


def ensure_user(name: str, home: str, primary_gid: int) -> pwd.struct_passwd:
    if not NAME_RE.fullmatch(name):
        die("runtime user name is invalid")
    exists = ds_record("Users", name)
    if exists and ds_string_attribute("Users", name, "RealName") != RUNTIME_USER_REALNAME:
        die(
            f"refusing to adopt unmanaged pre-existing user {name}; remove/rename it or "
            "recover the original Qofi authority explicitly"
        )
    uid = ds_numeric_attribute("Users", name, "UniqueID") if exists else None
    if uid is None:
        uid = next_id("Users", "UniqueID")
    if uid == 0:
        die("runtime account uid must be non-root")
    path = f"/Users/{name}"
    run(["/usr/bin/dscl", ".", "-create", path])
    # Establish the Qofi marker before the remaining fields so interrupted
    # creation is distinguishable from an unrelated pre-existing account.
    run(["/usr/bin/dscl", ".", "-create", path, "RealName", RUNTIME_USER_REALNAME])
    for key, value in (
        ("UniqueID", str(uid)), ("PrimaryGroupID", str(primary_gid)),
        ("NFSHomeDirectory", home), ("UserShell", "/usr/bin/false"),
        ("IsHidden", "1"),
        ("Password", "*"),
    ):
        run(["/usr/bin/dscl", ".", "-create", path, key, value])
    run(["/usr/bin/dscacheutil", "-flushcache"], check=False)
    try:
        record = pwd.getpwnam(name)
    except KeyError:
        die(f"user directory cache did not resolve {name}; retry after dscacheutil -flushcache")
    if (record.pw_uid != uid or record.pw_uid <= 0 or record.pw_dir != home
            or record.pw_shell != "/usr/bin/false" or record.pw_gid != primary_gid):
        die("existing runtime account does not match requested home/shell/shared primary group")
    if ds_boolean_attribute("Users", name, "IsHidden") is not True:
        die("runtime account is not marked hidden after Directory Services reconciliation")
    return record


def add_group_member(group: str, user: str) -> None:
    run(["/usr/sbin/dseditgroup", "-o", "edit", "-a", user, "-t", "user", group])
    run(["/usr/bin/dscacheutil", "-flushcache"], check=False)


def remove_group_member(group: str, user: str) -> None:
    run(
        ["/usr/sbin/dseditgroup", "-o", "edit", "-d", user, "-t", "user", group],
        check=False,
    )
    run(["/usr/bin/dscacheutil", "-flushcache"], check=False)


def rollback_directory_services(
    *,
    operator: pwd.struct_passwd,
    runtime_user: str,
    runtime_group: str,
    runtime_home: str,
    runtime: pwd.struct_passwd | None,
    user_created: bool,
    group_created: bool,
    home_existed: bool,
    operator_member_added: bool,
    runtime_member_added: bool,
    prior_runtime_primary_gid: int | None,
) -> None:
    """Undo only Directory Services state proven to be created by this transaction."""

    if runtime is not None:
        shared = grp.getgrnam(runtime_group)
        authority = identity_authority(operator, runtime, shared)
        # If exact identity cannot be re-proven, retain the marked records for
        # recovery. Deleting an account while an unquiesced numeric UID may
        # still own a process would create a dangerous orphan/reuse window.
        quiesce_service_uid(authority)
    run(
        ["/bin/launchctl", "bootout", f"user/{runtime.pw_uid}"],
        check=False,
    ) if runtime is not None else None
    # Membership edits are independent of user-record creation. In a recovery
    # install the user may be newly created while the marked shared group
    # predates it; deleting the user must not leave either added member behind.
    if ds_record("Groups", runtime_group):
        if operator_member_added:
            remove_group_member(runtime_group, operator.pw_name)
        if runtime_member_added:
            remove_group_member(runtime_group, runtime_user)
        remaining = set(ds_values_attribute("Groups", runtime_group, "GroupMembership"))
        if ((operator_member_added and operator.pw_name in remaining)
                or (runtime_member_added and runtime_user in remaining)):
            die("shared runtime group membership rollback was incomplete")
    if not user_created and ds_record("Users", runtime_user):
        user_path = f"/Users/{runtime_user}"
        if prior_runtime_primary_gid is None:
            run(["/usr/bin/dscl", ".", "-delete", user_path, "PrimaryGroupID"], check=False)
        else:
            run([
                "/usr/bin/dscl", ".", "-create", user_path,
                "PrimaryGroupID", str(prior_runtime_primary_gid),
            ])
        if ds_numeric_attribute("Users", runtime_user, "PrimaryGroupID") != prior_runtime_primary_gid:
            die("runtime user primary gid rollback was incomplete")
    if user_created and ds_record("Users", runtime_user):
        if ds_string_attribute("Users", runtime_user, "RealName") != RUNTIME_USER_REALNAME:
            die("new runtime user lost its Qofi marker during rollback")
        uid = ds_numeric_attribute("Users", runtime_user, "UniqueID")
        if runtime is not None and uid != runtime.pw_uid:
            die("new runtime user uid changed during rollback")
        run(["/usr/bin/dscl", ".", "-delete", f"/Users/{runtime_user}"])
    if user_created and not home_existed and os.path.lexists(runtime_home):
        info = os.lstat(runtime_home)
        expected_uid = runtime.pw_uid if runtime is not None else None
        if (expected_uid is None or not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != expected_uid or os.path.realpath(runtime_home) != runtime_home):
            die("new runtime home is unsafe to remove during rollback")
        shutil.rmtree(runtime_home)
    if group_created and ds_record("Groups", runtime_group):
        if ds_string_attribute("Groups", runtime_group, "RealName") != RUNTIME_GROUP_REALNAME:
            die("new runtime group lost its Qofi marker during rollback")
        run(["/usr/bin/dscl", ".", "-delete", f"/Groups/{runtime_group}"])
    run(["/usr/bin/dscacheutil", "-flushcache"], check=False)


def acl_entries(path: str) -> list[str]:
    result = run(["/bin/ls", "-lde", path], capture=True)
    return [
        line.strip() for line in result.stdout.splitlines()[1:]
        if re.match(r"\s*\d+:\s", line)
    ]


def reset_runtime_acl(path: str, operator_name: str | None = None) -> None:
    cleared = run(["/bin/chmod", "-N", path], check=False, capture=True)
    if cleared.returncode != 0:
        die(f"could not clear inherited/unrelated ACLs on {path}: {cleared.stderr.strip()}")
    expected: list[str] = []
    if operator_name is not None:
        rule = f"user:{operator_name} allow search,readattr,readextattr,readsecurity"
        added = run(["/bin/chmod", "+a", rule, path], check=False, capture=True)
        if added.returncode != 0:
            die(f"could not grant exact operator metadata ACL on {path}: {added.stderr.strip()}")
        expected = [f"0: {rule}"]
    observed = acl_entries(path)
    if observed != expected:
        die(f"runtime ACL reset did not produce the exact allowlist on {path}: {observed}")


def verify_runtime_acl(path: str, operator_name: str | None = None) -> None:
    expected = [] if operator_name is None else [
        f"0: user:{operator_name} allow search,readattr,readextattr,readsecurity",
    ]
    observed = acl_entries(path)
    if observed != expected:
        die(f"runtime path has an unexpected ACL: {path}: {observed}")


def cleanup_persistent_runtime_traversal_acls(
    operator: pwd.struct_passwd,
    runtime_user: str,
) -> None:
    """Remove the daemon-shared traversal ACEs at global root uninstall only.

    Individual Discord daemons deliberately leave these three ancestors in
    place because sibling daemons use the same hidden runtime identity.  The
    root lifecycle lock and service-uid quiescence make uninstall the one safe
    owner for their removal.  Refuse foreign, broader, inherited, or duplicate
    entries and remove only the exact Qofi ACE; never use ``chmod -N`` here.
    """

    if not NAME_RE.fullmatch(runtime_user):
        die("attested runtime user is unsafe for shared ACL cleanup")
    home = operator.pw_dir
    if (not os.path.isabs(home) or os.path.normpath(home) != home or home == "/"
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in home)):
        die("operator home is unsafe for shared ACL cleanup")
    paths = [home, os.path.join(home, ".codex"), os.path.join(home, ".codex", "channels")]
    expected = (
        f"user:{runtime_user} allow {PERSISTENT_RUNTIME_TRAVERSAL_PERMISSIONS}"
    )
    expected_listing = [f"0: {expected}"]
    opened: list[tuple[str, int, tuple[int, int]]] = []

    def assert_bound(path: str, fd: int, identity: tuple[int, int]) -> None:
        try:
            current = os.lstat(path)
        except FileNotFoundError:
            die(f"shared runtime ACL path disappeared during cleanup: {path}")
        bound = os.fstat(fd)
        if (not stat.S_ISDIR(current.st_mode) or stat.S_ISLNK(current.st_mode)
                or (current.st_dev, current.st_ino) != identity
                or (bound.st_dev, bound.st_ino) != identity
                or os.path.realpath(path) != path):
            die(f"shared runtime ACL path changed during cleanup: {path}")

    try:
        for index, path in enumerate(paths):
            try:
                before = os.lstat(path)
            except FileNotFoundError:
                # A never-launched installation need not have created the
                # operator Codex hierarchy.  The home itself must still exist.
                if index == 0:
                    die("operator home is absent during shared ACL cleanup")
                continue
            if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode)
                    or before.st_uid not in (ROOT_AUTHORITY_UID, operator.pw_uid)
                    or before.st_mode & 0o022 or os.path.realpath(path) != path):
                die(f"shared runtime ACL path is not an owner-controlled real directory: {path}")
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(path, flags)
            identity = (before.st_dev, before.st_ino)
            opened.append((path, fd, identity))
            assert_bound(path, fd, identity)

        # Inspect the complete shared plan before the first ACL mutation.  A
        # failure therefore preserves every sibling traversal grant intact.
        for path, fd, identity in opened:
            assert_bound(path, fd, identity)
            observed = acl_entries(path)
            if observed not in ([], expected_listing):
                die(f"shared runtime ACL has an unexpected entry; nothing was removed: {path}: {observed}")

        # Remove children first so the runtime identity retains traversal to a
        # later ancestor until that ancestor's own ACE is removed.
        for path, fd, identity in reversed(opened):
            assert_bound(path, fd, identity)
            observed = acl_entries(path)
            if observed == expected_listing:
                # ``-h`` prevents a last-instant pathname swap to a symlink
                # from redirecting this root operation onto its target.
                removed = run(["/bin/chmod", "-h", "-a", expected, path],
                              check=False, capture=True)
                if removed.returncode != 0:
                    die(f"could not remove exact shared runtime ACL on {path}: {removed.stderr.strip()}")
            elif observed:
                die(f"shared runtime ACL changed before removal: {path}: {observed}")
            assert_bound(path, fd, identity)
            remaining = acl_entries(path)
            if remaining:
                die(f"shared runtime ACL cleanup did not leave an empty ACL on {path}: {remaining}")
    finally:
        for _path, fd, _identity in opened:
            os.close(fd)


def profile_codex_home(runtime_home: str, profile: str) -> str:
    """Derive a profile CODEX_HOME; callers can never provide its path."""

    if not isinstance(profile, str) or not PROFILE_RE.fullmatch(profile):
        die("Codex profile handle must match [a-z][a-z0-9_-]{0,31}")
    if profile == DEFAULT_PROFILE:
        return os.path.join(runtime_home, ".codex")
    return os.path.join(runtime_home, ".codex-profiles", profile)


def rendered_codex_config(operator_uid: int) -> bytes:
    if type(operator_uid) is not int or operator_uid <= 0:
        die("Codex config renderer requires a non-root operator uid")
    if CODEX_CONFIG_TEMPLATE.count(CODEX_CONFIG_OPERATOR_UID) != 1:
        die("embedded Codex config template has an invalid placeholder count")
    return CODEX_CONFIG_TEMPLATE.replace(
        CODEX_CONFIG_OPERATOR_UID, str(operator_uid).encode("ascii"),
    )


def validate_codex_config_template_source(swarm_home: str, operator_uid: int) -> None:
    source = os.path.join(swarm_home, "templates", "_base", "codex", "config.toml.template")
    fd = open_trusted_source(source, operator_uid, "Codex config template")
    try:
        info = os.fstat(fd)
        if info.st_size != len(CODEX_CONFIG_TEMPLATE):
            die("Codex config template source has unexpected bytes")
        observed = os.read(fd, len(CODEX_CONFIG_TEMPLATE) + 1)
        after = os.fstat(fd)
        if (observed != CODEX_CONFIG_TEMPLATE
                or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
                    after.st_ctime_ns)
                != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                    info.st_ctime_ns)):
            die("Codex config template source differs from the fixed renderer")
    finally:
        os.close(fd)


def _runtime_config_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
        info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    )


def _runtime_config_directory_identity(info: os.stat_result) -> tuple[int, ...]:
    return info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid


def verify_codex_config_render_hash(operator_uid: int, expected_sha256: object) -> None:
    """Bind the public deterministic render without reading private runtime state."""

    digest = hashlib.sha256(rendered_codex_config(operator_uid)).hexdigest()
    if (not isinstance(expected_sha256, str)
            or not HASH_RE.fullmatch(expected_sha256)
            or digest != expected_sha256):
        die("attested Codex config hash differs from the fixed renderer")


def verify_runtime_codex_config_metadata(
    record: pwd.struct_passwd,
    profile: str = DEFAULT_PROFILE,
) -> None:
    """Verify operator-visible config metadata without opening private bytes.

    The operator ACL intentionally grants search/read-attribute access only.
    Exact bytes and ACL absence are verified later by the fixed root runner.
    """

    codex_home = profile_codex_home(record.pw_dir, profile)
    config = os.path.join(codex_home, "config.toml")
    try:
        parent_before = os.lstat(codex_home)
        config_before = os.lstat(config)
        config_after = os.lstat(config)
        parent_after = os.lstat(codex_home)
    except OSError as exc:
        die(f"could not inspect dedicated Codex config metadata: {exc}")
    if (_runtime_config_identity(parent_after) != _runtime_config_identity(parent_before)
            or _runtime_config_identity(config_after) != _runtime_config_identity(config_before)
            or not stat.S_ISDIR(parent_before.st_mode)
            or stat.S_ISLNK(parent_before.st_mode)
            or parent_before.st_uid != record.pw_uid
            or parent_before.st_gid != record.pw_gid
            or stat.S_IMODE(parent_before.st_mode) != 0o700
            or not stat.S_ISREG(config_before.st_mode)
            or stat.S_ISLNK(config_before.st_mode)
            or config_before.st_uid != record.pw_uid
            or config_before.st_gid != record.pw_gid
            or config_before.st_nlink != 1
            or config_before.st_dev != parent_before.st_dev
            or stat.S_IMODE(config_before.st_mode) != 0o600):
        die("dedicated Codex config metadata is not exact or stable")


def verify_runtime_codex_config(
    record: pwd.struct_passwd,
    operator_uid: int,
    profile: str = DEFAULT_PROFILE,
    *,
    expected_sha256: str | None = None,
) -> None:
    codex_home = profile_codex_home(record.pw_dir, profile)
    expected = rendered_codex_config(operator_uid)
    if expected_sha256 is not None:
        verify_codex_config_render_hash(operator_uid, expected_sha256)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_before = os.lstat(codex_home)
        parent_fd = os.open(codex_home, flags)
    except OSError as exc:
        die(f"could not bind dedicated Codex home config: {exc}")
    config_fd = -1
    try:
        parent_opened = os.fstat(parent_fd)
        if (_runtime_config_identity(parent_opened) != _runtime_config_identity(parent_before)
                or not stat.S_ISDIR(parent_opened.st_mode)
                or parent_opened.st_uid != record.pw_uid
                or parent_opened.st_gid != record.pw_gid
                or stat.S_IMODE(parent_opened.st_mode) != 0o700):
            die("dedicated Codex home changed while binding config")
        before = os.stat("config.toml", dir_fd=parent_fd, follow_symlinks=False)
        config_fd = os.open(
            "config.toml",
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        opened = os.fstat(config_fd)
        parent_after = os.lstat(codex_home)
        observed = os.read(config_fd, len(expected) + 1)
        final = os.fstat(config_fd)
        if (_runtime_config_identity(opened) != _runtime_config_identity(before)
                or _runtime_config_identity(final) != _runtime_config_identity(before)
                or _runtime_config_identity(parent_after) != _runtime_config_identity(parent_before)
                or not stat.S_ISREG(opened.st_mode) or stat.S_ISLNK(opened.st_mode)
                or opened.st_uid != record.pw_uid or opened.st_gid != record.pw_gid
                or opened.st_nlink != 1 or opened.st_dev != parent_opened.st_dev
                or stat.S_IMODE(opened.st_mode) != 0o600
                or fd_has_extended_acl(config_fd) or observed != expected):
            die("dedicated Codex config is not the exact runtime-owned mode 0600 render")
    except FileNotFoundError:
        die("dedicated Codex config is absent; rerun install")
    except OSError as exc:
        die(f"could not verify dedicated Codex config: {exc}")
    finally:
        if config_fd >= 0:
            os.close(config_fd)
        os.close(parent_fd)


def render_runtime_codex_config(
    record: pwd.struct_passwd,
    operator_uid: int,
    profile: str = DEFAULT_PROFILE,
) -> None:
    codex_home = profile_codex_home(record.pw_dir, profile)
    expected = rendered_codex_config(operator_uid)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_before = os.lstat(codex_home)
        parent_fd = os.open(codex_home, flags)
    except OSError as exc:
        die(f"could not bind dedicated Codex home for config render: {exc}")
    temporary = f".config.toml.tmp.{os.getpid()}.{secrets.token_hex(6)}"
    temporary_fd = -1
    try:
        parent_opened = os.fstat(parent_fd)
        if (_runtime_config_identity(parent_opened) != _runtime_config_identity(parent_before)
                or not stat.S_ISDIR(parent_opened.st_mode)
                or parent_opened.st_uid != record.pw_uid
                or parent_opened.st_gid != record.pw_gid
                or stat.S_IMODE(parent_opened.st_mode) != 0o700):
            die("dedicated Codex home is unsafe for config render")
        try:
            current = os.stat("config.toml", dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None and (
            not stat.S_ISREG(current.st_mode) or stat.S_ISLNK(current.st_mode)
            or current.st_uid != record.pw_uid or current.st_gid != record.pw_gid
            or current.st_nlink != 1 or current.st_dev != parent_opened.st_dev
        ):
            die("existing dedicated Codex config is not a replaceable runtime-owned file")
        temporary_fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent_fd,
        )
        os.fchown(temporary_fd, record.pw_uid, record.pw_gid)
        os.fchmod(temporary_fd, 0o600)
        strip_extended_acl_fd(temporary_fd, "staged dedicated Codex config")
        view = memoryview(expected)
        while view:
            written = os.write(temporary_fd, view)
            if written <= 0:
                die("could not write staged dedicated Codex config")
            view = view[written:]
        os.fsync(temporary_fd)
        staged = os.fstat(temporary_fd)
        if (not stat.S_ISREG(staged.st_mode) or staged.st_uid != record.pw_uid
                or staged.st_gid != record.pw_gid or staged.st_nlink != 1
                or staged.st_dev != parent_opened.st_dev
                or stat.S_IMODE(staged.st_mode) != 0o600
                or staged.st_size != len(expected) or fd_has_extended_acl(temporary_fd)):
            die("staged dedicated Codex config hardening failed")
        os.close(temporary_fd)
        temporary_fd = -1
        parent_after = os.lstat(codex_home)
        if (_runtime_config_directory_identity(parent_after)
                != _runtime_config_directory_identity(parent_before)):
            die("dedicated Codex home changed before config publication")
        os.replace(
            temporary, "config.toml", src_dir_fd=parent_fd, dst_dir_fd=parent_fd,
        )
        os.fsync(parent_fd)
    except OSError as exc:
        die(f"could not render dedicated Codex config: {exc}")
    finally:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        os.close(parent_fd)
    verify_runtime_codex_config(record, operator_uid, profile)


def secure_runtime_home(
    record: pwd.struct_passwd,
    operator: pwd.struct_passwd,
    profile: str = DEFAULT_PROFILE,
    *,
    render_config: bool = True,
) -> None:
    home = record.pw_dir
    if not os.path.lexists(home):
        os.mkdir(home, 0o700)
        os.chown(home, record.pw_uid, record.pw_gid)
    home_info = os.lstat(home)
    if (not stat.S_ISDIR(home_info.st_mode) or stat.S_ISLNK(home_info.st_mode)
            or home_info.st_uid != record.pw_uid):
        die("existing runtime home is not a real runtime-owned directory")
    os.chmod(home, 0o700)
    relatives = [".tmp"]
    if profile == DEFAULT_PROFILE:
        relatives.append(".codex")
    else:
        relatives.extend((".codex-profiles", f".codex-profiles/{profile}"))
    # Validate the handle before using it as a relative directory component.
    selected_codex_home = profile_codex_home(home, profile)
    for relative in relatives:
        path = os.path.join(home, relative)
        if not os.path.lexists(path):
            os.mkdir(path, 0o700)
            os.chown(path, record.pw_uid, record.pw_gid)
        info = os.lstat(path)
        if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != record.pw_uid or info.st_gid != record.pw_gid):
            die(f"existing runtime path is not a real runtime-owned directory: {path}")
        os.chmod(path, 0o700)
    validate_runtime_keychain_storage(record)
    # Remove inherited/unrelated ACLs first. The operator daemon may inspect
    # ownership/mode metadata but never auth contents.
    acl_paths = [home, os.path.join(home, ".tmp"), selected_codex_home]
    if profile != DEFAULT_PROFILE:
        acl_paths.append(os.path.join(home, ".codex-profiles"))
    for path in acl_paths:
        reset_runtime_acl(path, operator.pw_name)
    if render_config:
        render_runtime_codex_config(record, operator.pw_uid, profile)
    auth = os.path.join(selected_codex_home, "auth.json")
    if os.path.lexists(auth):
        fd = open_dedicated_auth(
            auth,
            record,
            profile=profile,
            missing_error="existing runtime auth.json disappeared while securing it",
            require_hardened_mode=False,
        )
        try:
            os.fchmod(fd, 0o600)
            strip_extended_acl_fd(fd, "existing dedicated auth.json")
            hardened = os.fstat(fd)
            if (stat.S_IMODE(hardened.st_mode) != 0o600
                    or fd_has_extended_acl(fd)):
                die("existing runtime auth.json could not be hardened")
        finally:
            os.close(fd)


def secure_existing_profile_homes(
    record: pwd.struct_passwd, operator: pwd.struct_passwd, *,
    render_config: bool = True,
) -> None:
    profiles = os.path.join(record.pw_dir, ".codex-profiles")
    try:
        before = os.lstat(profiles)
    except FileNotFoundError:
        return
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(profiles, flags)
    except OSError as exc:
        die(f"could not bind existing Codex profiles home: {exc}")
    handles: list[str] = []
    try:
        opened = os.fstat(fd)
        if (_runtime_config_identity(opened) != _runtime_config_identity(before)
                or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != record.pw_uid
                or opened.st_gid != record.pw_gid or stat.S_IMODE(opened.st_mode) != 0o700):
            die("existing Codex profiles home is unsafe")
        with os.scandir(fd) as iterator:
            for entry in iterator:
                if not PROFILE_RE.fullmatch(entry.name) or entry.name == DEFAULT_PROFILE:
                    die("existing Codex profiles home contains an invalid handle")
                info = entry.stat(follow_symlinks=False)
                if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                        or info.st_uid != record.pw_uid or info.st_gid != record.pw_gid
                        or info.st_dev != opened.st_dev
                        or stat.S_IMODE(info.st_mode) != 0o700):
                    die(f"existing Codex profile home is unsafe: {entry.name}")
                handles.append(entry.name)
        if len(handles) > 256:
            die("existing Codex profile count exceeds the managed bound")
    finally:
        os.close(fd)
    for handle in sorted(handles):
        secure_runtime_home(
            record, operator, handle, render_config=render_config,
        )


def render_all_runtime_codex_configs_transactionally(
    record: pwd.struct_passwd, operator: pwd.struct_passwd,
) -> None:
    """Render default and existing named homes as one rollback-capable update."""

    profiles = [DEFAULT_PROFILE]
    profiles_root = os.path.join(record.pw_dir, ".codex-profiles")
    if os.path.lexists(profiles_root):
        with os.scandir(profiles_root) as iterator:
            profiles.extend(sorted(entry.name for entry in iterator))
    changed: list[tuple[str, str | None, tuple[int, ...] | None]] = []
    try:
        for profile in profiles:
            # Reuse the handle validation before deriving any path.
            codex_home = profile_codex_home(record.pw_dir, profile)
            config = os.path.join(codex_home, "config.toml")
            backup: str | None = None
            original_identity: tuple[int, ...] | None = None
            try:
                info = os.lstat(config)
            except FileNotFoundError:
                pass
            else:
                home_info = os.lstat(codex_home)
                if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                        or info.st_uid != record.pw_uid or info.st_gid != record.pw_gid
                        or info.st_nlink != 1 or info.st_dev != home_info.st_dev):
                    die("existing dedicated Codex config is unsafe for transactional render")
                backup = os.path.join(
                    codex_home, f".config.toml.rollback.{os.getpid()}.{secrets.token_hex(6)}",
                )
                if os.path.lexists(backup):
                    die("stale dedicated Codex config rollback path exists")
                os.rename(config, backup)
                original_identity = _runtime_config_identity(os.lstat(backup))
            changed.append((config, backup, original_identity))
            render_runtime_codex_config(record, operator.pw_uid, profile)
    except BaseException:
        rollback_errors: list[str] = []
        for config, backup, original_identity in reversed(changed):
            try:
                if os.path.lexists(config):
                    current = os.lstat(config)
                    if (not stat.S_ISREG(current.st_mode) or stat.S_ISLNK(current.st_mode)
                            or current.st_uid != record.pw_uid or current.st_nlink != 1):
                        raise RuntimeError(f"rendered config changed before rollback: {config}")
                    os.unlink(config)
                if backup is not None:
                    saved = os.lstat(backup)
                    if (_runtime_config_identity(saved) != original_identity
                            or not stat.S_ISREG(saved.st_mode)):
                        raise RuntimeError(f"saved config changed before rollback: {backup}")
                    os.rename(backup, config)
            except BaseException as exc:
                rollback_errors.append(str(exc))
        if rollback_errors:
            die("Codex config render rollback was incomplete: " + "; ".join(rollback_errors))
        raise
    for _config, backup, original_identity in changed:
        if backup is None:
            continue
        saved = os.lstat(backup)
        if _runtime_config_identity(saved) != original_identity:
            die("saved Codex config changed before transaction commit")
        os.unlink(backup)


def runtime_environment(record: pwd.struct_passwd, codex_home: str) -> dict[str, str]:
    return {
        "HOME": record.pw_dir, "CODEX_HOME": codex_home,
        "PATH": f"{TOOLCHAIN}/bin:{TOOLCHAIN}:/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": record.pw_name, "LOGNAME": record.pw_name,
        "TMPDIR": os.path.join(record.pw_dir, ".tmp"), "LANG": "C", "LC_ALL": "C",
    }


def runtime_context_command(
    record: pwd.struct_passwd,
    command: list[str],
    *,
    umask: int,
) -> list[str]:
    if (not NAME_RE.fullmatch(record.pw_name) or record.pw_uid <= 0 or record.pw_gid <= 0
            or umask not in (0o077, 0o002) or not command
            or any(not isinstance(value, str) or "\0" in value for value in command)
            or not os.path.isabs(command[0]) or os.path.normpath(command[0]) != command[0]):
        die("refusing an unsafe hidden-runtime context command")
    return [
        "/bin/launchctl", "asuser", str(record.pw_uid),
        "/usr/bin/python3", "-I", "-S", "-c", RUNTIME_CONTEXT_TRAMPOLINE,
        record.pw_name, str(record.pw_uid), str(record.pw_gid), f"{umask:03o}",
        *command,
    ]


def run_as_runtime(
    record: pwd.struct_passwd,
    command: list[str],
    *,
    capture: bool = False,
    codex_home: str | None = None,
) -> subprocess.CompletedProcess[str]:
    invocation = runtime_context_command(record, command, umask=0o077)

    try:
        return subprocess.run(
            invocation,
            env=runtime_environment(
                record,
                os.path.join(record.pw_dir, ".codex") if codex_home is None else codex_home,
            ),
            cwd=record.pw_dir,
            text=True, capture_output=capture,
        )
    except OSError as exc:
        die(f"could not enter the hidden runtime account bootstrap: {exc}")


def validate_runtime_keychain_storage(record: pwd.struct_passwd) -> None:
    """Validate only the opaque Security.framework storage boundary.

    macOS may create per-user Local Items metadata beneath Library/Keychains
    even when the user's keychain search list is empty. Never enumerate or
    mutate that opaque state; search-list isolation is proved separately.
    """

    directory_flags = (
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        home_fd = os.open(record.pw_dir, directory_flags)
    except OSError as exc:
        die(f"could not bind runtime home for keychain validation: {exc}")
    try:
        home_info = os.fstat(home_fd)
        if (not stat.S_ISDIR(home_info.st_mode) or home_info.st_uid != record.pw_uid
                or stat.S_IMODE(home_info.st_mode) != 0o700):
            die("runtime home is unsafe for keychain storage")
        try:
            library_before = os.stat("Library", dir_fd=home_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if (not stat.S_ISDIR(library_before.st_mode) or stat.S_ISLNK(library_before.st_mode)
                or library_before.st_dev != home_info.st_dev
                or library_before.st_uid != record.pw_uid
                or stat.S_IMODE(library_before.st_mode) & 0o700 != 0o700
                or library_before.st_mode & 0o022):
            die("runtime Library must be a real non-writable runtime-owned directory")
        library_fd = os.open("Library", directory_flags, dir_fd=home_fd)
        try:
            library_opened = os.fstat(library_fd)
            if ((library_opened.st_dev, library_opened.st_ino, library_opened.st_mode,
                 library_opened.st_uid, library_opened.st_gid)
                    != (library_before.st_dev, library_before.st_ino, library_before.st_mode,
                        library_before.st_uid, library_before.st_gid)
                    or fd_has_extended_acl(library_fd)):
                die("runtime Library changed while opening or has an extended ACL")
            try:
                keychains_before = os.stat(
                    "Keychains", dir_fd=library_fd, follow_symlinks=False,
                )
            except FileNotFoundError:
                return
            mode = stat.S_IMODE(keychains_before.st_mode)
            if (not stat.S_ISDIR(keychains_before.st_mode)
                    or stat.S_ISLNK(keychains_before.st_mode)
                    or keychains_before.st_dev != home_info.st_dev
                    or keychains_before.st_uid != record.pw_uid
                    or keychains_before.st_gid != record.pw_gid
                    or mode & 0o700 != 0o700 or mode & 0o066):
                die("runtime Library/Keychains storage boundary is unsafe")
            keychains_fd = os.open("Keychains", directory_flags, dir_fd=library_fd)
            try:
                keychains_opened = os.fstat(keychains_fd)
                if ((keychains_opened.st_dev, keychains_opened.st_ino,
                     keychains_opened.st_mode, keychains_opened.st_uid, keychains_opened.st_gid)
                        != (keychains_before.st_dev, keychains_before.st_ino,
                            keychains_before.st_mode, keychains_before.st_uid,
                            keychains_before.st_gid)
                        or fd_has_extended_acl(keychains_fd)):
                    die("runtime Library/Keychains changed while opening or has an extended ACL")
            finally:
                os.close(keychains_fd)
        finally:
            os.close(library_fd)
    except OSError as exc:
        die(f"could not validate runtime keychain storage boundary: {exc}")
    finally:
        os.close(home_fd)


def clear_runtime_keychain_search(record: pwd.struct_passwd) -> None:
    cleared = run_as_runtime(record, ["/usr/bin/security", "list-keychains", "-d", "user", "-s"], capture=True)
    if cleared.returncode != 0:
        die(f"could not clear runtime keychain search list: {cleared.stderr.strip()}")


def verify_runtime_keychain_search_empty(record: pwd.struct_passwd) -> None:
    observed = run_as_runtime(record, ["/usr/bin/security", "list-keychains", "-d", "user"], capture=True)
    if observed.returncode != 0 or observed.stdout.strip():
        die("runtime user keychain search list is not provably empty")


def establish_empty_keychain_search(record: pwd.struct_passwd) -> None:
    clear_runtime_keychain_search(record)
    verify_runtime_keychain_search_empty(record)
    validate_runtime_keychain_storage(record)


def ensure_runtime_bootstrap(record: pwd.struct_passwd) -> None:
    bootstrap = run(
        ["/bin/launchctl", "bootstrap", f"user/{record.pw_uid}"],
        check=False, capture=True,
    )
    # Existing domains return nonzero on some macOS releases. More importantly,
    # `launchctl bootstrap user/<uid>` can return while launchd is still importing
    # that user domain; an immediate `asuser` then transiently fails to obtain the
    # user context. Retry only the fixed, read-only identity proof for a short,
    # bounded readiness window. The proof remains authoritative; bootstrap output
    # is setup/diagnostic evidence only.
    proof: subprocess.CompletedProcess[str] | None = None
    for attempt in range(RUNTIME_BOOTSTRAP_PROOF_ATTEMPTS):
        proof = run_as_runtime(record, ["/usr/bin/id", "-u"], capture=True)
        if proof.returncode == 0 and proof.stdout.strip() == str(record.pw_uid):
            return
        if attempt + 1 < RUNTIME_BOOTSTRAP_PROOF_ATTEMPTS:
            time.sleep(RUNTIME_BOOTSTRAP_PROOF_INTERVAL)

    assert proof is not None

    def bounded_detail(result: subprocess.CompletedProcess[str]) -> str:
        raw = result.stderr or result.stdout or ""
        printable = "".join(
            character if 32 <= ord(character) < 127 else " " for character in raw
        )
        return " ".join(printable.split())[:512]

    proof_detail = bounded_detail(proof)
    bootstrap_detail = bounded_detail(bootstrap)
    diagnostics = [f"asuser proof exit {proof.returncode}"]
    if proof_detail:
        diagnostics[-1] += f": {proof_detail}"
    if bootstrap.returncode != 0 or bootstrap_detail:
        setup = f"bootstrap exit {bootstrap.returncode}"
        if bootstrap_detail:
            setup += f": {bootstrap_detail}"
        diagnostics.append(setup)
    die("hidden service-user bootstrap/asuser proof failed: " + "; ".join(diagnostics))


def resolve_operator_codex(operator: pwd.struct_passwd, repo: str, swarm_home: str) -> tuple[str, str]:
    resolver_path = os.path.join(swarm_home, "bin", "trusted-cli.py")
    # The repository resolver is intentionally never imported or executed by
    # uid 0. Its tiny tab-delimited result is treated as untrusted data and the
    # returned paths are re-opened component-by-component below.
    validate_source(resolver_path, operator.pw_uid, "trusted CLI resolver")
    output = run_as_operator_bounded(
        operator,
        ["/usr/bin/python3", "-I", "-B", resolver_path, "exec-plan", "codex"],
        cwd=repo,
        label="operator Codex resolver",
    )
    lines = output.splitlines()
    if len(lines) != 1:
        die("operator Codex resolver must emit exactly one line")
    fields = lines[0].split("\t")
    if (len(fields) != 2 or any(not field or "\x00" in field for field in fields)
            or any(not os.path.isabs(field) or os.path.normpath(field) != field for field in fields)):
        die("Codex installation must resolve to Node plus one codex.js prefix")
    executable, script = map(os.path.realpath, fields)
    # Retain live descriptors through both validations so a rename race cannot
    # turn the resolver result into a different root-read source later.
    node_fd = open_trusted_source(executable, operator.pw_uid, "resolved Node")
    script_fd = open_trusted_source(script, operator.pw_uid, "resolved Codex script")
    os.close(node_fd)
    os.close(script_fd)
    return executable, script


def resolve_operator_bun(operator: pwd.struct_passwd) -> str:
    candidates = (
        os.path.join(operator.pw_dir, ".local", "bin", "bun"),
        os.path.join(operator.pw_dir, ".bun", "bin", "bun"),
        "/opt/homebrew/bin/bun", "/usr/local/bin/bun",
    )
    for candidate in candidates:
        if os.path.lexists(candidate):
            canonical = os.path.realpath(candidate)
            try:
                validate_source(canonical, operator.pw_uid, "Bun", executable=True)
            except SystemExit:
                continue
            return canonical
    die("could not resolve a trusted operator Bun executable for root installation")


def requested_pnpm_version(repo: str) -> str | None:
    """Return the exact pinned pnpm version required by this workspace."""

    package_path = os.path.join(repo, "package.json")
    package: dict[str, object] | None = None
    try:
        before = os.lstat(package_path)
    except FileNotFoundError:
        before = None
    if before is not None:
        if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
                or before.st_size < 2 or before.st_size > MAX_PROJECT_PACKAGE_JSON):
            die("project package.json must be a bounded real regular file for pnpm provisioning")
        fd = os.open(
            package_path,
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            opened = os.fstat(fd)
            identity = (
                opened.st_dev, opened.st_ino, opened.st_uid, opened.st_gid,
                opened.st_mode, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns,
            )
            if identity != (
                before.st_dev, before.st_ino, before.st_uid, before.st_gid,
                before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns,
            ):
                die("project package.json changed while resolving pnpm")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(fd, min(64 * 1024, MAX_PROJECT_PACKAGE_JSON + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > MAX_PROJECT_PACKAGE_JSON:
                    die("project package.json exceeded the pnpm provisioning bound")
            after = os.fstat(fd)
            if identity != (
                after.st_dev, after.st_ino, after.st_uid, after.st_gid,
                after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns,
            ) or total != opened.st_size:
                die("project package.json changed while resolving pnpm")
            raw = b"".join(chunks)
        finally:
            os.close(fd)
        try:
            value = json.loads(raw.decode("utf-8", "strict"))
        except (UnicodeDecodeError, ValueError) as exc:
            die(f"project package.json is invalid while resolving pnpm: {exc}")
        if not isinstance(value, dict):
            die("project package.json must contain an object while resolving pnpm")
        package = value

    declared = package.get("packageManager") if package is not None else None
    declared_pnpm = isinstance(declared, str) and declared.lower().startswith("pnpm@")
    scripts_use_pnpm = False
    if package is not None:
        scripts = package.get("scripts")
        if isinstance(scripts, dict):
            scripts_use_pnpm = any(
                isinstance(command, str)
                and re.search(r"(?:^|[\s;&|()])pnpm(?:$|[\s;&|()])", command)
                for command in scripts.values()
            )
    needs_pnpm = (
        os.path.lexists(os.path.join(repo, "pnpm-lock.yaml"))
        or declared_pnpm
        or scripts_use_pnpm
    )
    if not needs_pnpm:
        return None
    if not isinstance(declared, str):
        die("pnpm projects must pin an exact packageManager such as pnpm@9.12.3")
    plain = f"pnpm@{SUPPORTED_PNPM_VERSION}"
    with_integrity = f"{plain}+{SUPPORTED_PNPM_INTEGRITY}"
    if declared not in (plain, with_integrity):
        die(
            f"pnpm projects must pin the audited global runtime version "
            f"{plain} with no suffix or its exact audited sha512 integrity"
        )
    return SUPPORTED_PNPM_VERSION


def existing_pnpm_plan() -> tuple[str, str] | None:
    """Preserve the one global audited pnpm package across repo installs."""

    source = os.path.join(TOOLCHAIN, "pnpm")
    if not os.path.lexists(source):
        return None
    validate_root_authority_tree(source, "installed pnpm package")
    manifest_path = os.path.join(source, "package.json")
    info = validate_root_authority_file(
        manifest_path, "installed pnpm manifest", max_bytes=MAX_PROJECT_PACKAGE_JSON,
    )
    if info.st_size < 2:
        die("installed pnpm manifest is empty")
    try:
        manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        die(f"installed pnpm manifest is invalid: {exc}")
    if (not isinstance(manifest, dict) or manifest.get("name") != "pnpm"
            or manifest.get("version") != SUPPORTED_PNPM_VERSION
            or not isinstance(manifest.get("bin"), dict)
            or manifest["bin"].get("pnpm") != "bin/pnpm.cjs"):
        die("installed global pnpm package is outside the audited runtime version")
    validate_pnpm_corepack_record(source, ROOT_AUTHORITY_UID)
    return source, SUPPORTED_PNPM_VERSION


def validate_pnpm_corepack_record(source: str, operator_uid: int) -> None:
    """Require Corepack's exact package locator and registry integrity record."""

    path = os.path.join(source, ".corepack")
    fd = -1
    try:
        fd = open_trusted_source(path, operator_uid, "cached pnpm Corepack record")
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_size < 2 or info.st_size > 4096):
            die("cached pnpm Corepack record is unsafe")
        raw = os.read(fd, 4097)
        record = json.loads(raw.decode("utf-8", "strict"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        die(f"cached pnpm Corepack record is invalid: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)
    if (not isinstance(record, dict)
            or record.get("locator") != {
                "name": "pnpm", "reference": SUPPORTED_PNPM_VERSION,
            }
            or record.get("bin") != {
                "pnpm": "./bin/pnpm.cjs", "pnpx": "./bin/pnpx.cjs",
            }
            or record.get("hash") != SUPPORTED_PNPM_INTEGRITY):
        die("cached pnpm Corepack record differs from the audited package integrity")


def resolve_operator_pnpm(
    operator: pwd.struct_passwd,
    repo: str,
) -> tuple[str, str] | None:
    """Resolve one exact, already-cached Corepack pnpm package without network."""

    version = requested_pnpm_version(repo)
    if version is None:
        return None
    source = os.path.join(
        operator.pw_dir, ".cache", "node", "corepack", "v1", "pnpm", version,
    )
    try:
        package_fd = open_trusted_source(
            source, operator.pw_uid, "cached pnpm package", directory=True,
        )
    except (FileNotFoundError, NotADirectoryError):
        existing = existing_pnpm_plan()
        if existing is not None:
            return existing
        die(
            f"pnpm@{version} is not present in the operator's trusted Corepack cache; "
            f"run `corepack pnpm@{version} --version` as {operator.pw_name}, then retry install"
        )
    try:
        manifest_fd = os.open(
            "package.json",
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=package_fd,
        )
        try:
            info = os.fstat(manifest_fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_size < 2
                    or info.st_size > MAX_PROJECT_PACKAGE_JSON):
                die("cached pnpm package has an invalid manifest")
            raw = os.read(manifest_fd, MAX_PROJECT_PACKAGE_JSON + 1)
        finally:
            os.close(manifest_fd)
    finally:
        os.close(package_fd)
    try:
        manifest = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as exc:
        die(f"cached pnpm package manifest is invalid: {exc}")
    if (not isinstance(manifest, dict) or manifest.get("name") != "pnpm"
            or manifest.get("version") != version
            or not isinstance(manifest.get("bin"), dict)
            or manifest["bin"].get("pnpm") != "bin/pnpm.cjs"):
        die(f"cached pnpm package does not exactly provide pnpm@{version}")
    validate_pnpm_corepack_record(source, operator.pw_uid)
    cli = os.path.join(source, "bin", "pnpm.cjs")
    cli_fd = open_trusted_source(cli, operator.pw_uid, "cached pnpm entrypoint")
    os.close(cli_fd)
    return source, version


def validate_source(path: str, operator_uid: int, label: str, executable: bool = False) -> None:
    info = os.lstat(path)
    if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid not in (ROOT_AUTHORITY_UID, operator_uid) or info.st_mode & 0o022):
        die(f"{label} source is not an operator/root-controlled regular file: {path}")
    if executable and not info.st_mode & 0o111:
        die(f"{label} source is not executable")


def open_trusted_source(path: str, operator_uid: int, label: str,
                        *, directory: bool = False) -> int:
    if (not os.path.isabs(path) or os.path.normpath(path) != path
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in path)):
        die(f"{label} source path is not absolute and normalized")
    directory_flags = (
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    fd = os.open("/", directory_flags)
    try:
        parts = path.split("/")[1:]
        if not parts or any(not part or part in (".", "..") for part in parts):
            die(f"{label} source path has an invalid component")
        for index, part in enumerate(parts):
            last = index == len(parts) - 1
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            if not last or directory:
                flags |= getattr(os, "O_DIRECTORY", 0)
            else:
                flags |= os.O_NONBLOCK
            next_fd = os.open(part, flags, dir_fd=fd)
            info = os.fstat(next_fd)
            if info.st_uid not in (0, ROOT_AUTHORITY_UID, operator_uid) or info.st_mode & 0o022:
                os.close(next_fd)
                die(f"{label} source component is not operator/root controlled: {part}")
            if not last and not stat.S_ISDIR(info.st_mode):
                os.close(next_fd)
                die(f"{label} source parent is not a directory: {part}")
            os.close(fd)
            fd = next_fd
        final = os.fstat(fd)
        expected = stat.S_ISDIR(final.st_mode) if directory else stat.S_ISREG(final.st_mode)
        if not expected:
            die(f"{label} source has the wrong file type")
        return fd
    except BaseException:
        os.close(fd)
        raise


def copy_trusted_file_fd(source_fd: int, destination: str, operator_uid: int,
                         label: str, *, max_bytes: int = 512 * 1024 * 1024) -> None:
    opened = os.fstat(source_fd)
    identity = (
        opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns,
    )
    if (not stat.S_ISREG(opened.st_mode)
            or opened.st_uid not in (0, ROOT_AUTHORITY_UID, operator_uid)
            or opened.st_mode & 0o022 or opened.st_size > max_bytes):
        die(f"unsafe/oversized toolchain source file: {label}")
    destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        copied = 0
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            if copied > max_bytes:
                die(f"toolchain source exceeded bound while copying: {label}")
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
        after = os.fstat(source_fd)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
                after.st_ctime_ns) != identity:
            die(f"toolchain source changed while copying: {label}")
        os.fsync(destination_fd)
        os.fchmod(destination_fd, stat.S_IMODE(opened.st_mode) & ~0o022)
        strip_extended_acl_fd(destination_fd, f"copied toolchain file {label}")
        if fd_has_extended_acl(destination_fd):
            die(f"copied toolchain file retained an extended ACL: {label}")
    finally:
        os.close(destination_fd)


def copy_trusted_file(source: str, destination: str, operator_uid: int,
                      *, max_bytes: int = 512 * 1024 * 1024) -> None:
    source_fd = open_trusted_source(source, operator_uid, "toolchain file")
    try:
        copy_trusted_file_fd(source_fd, destination, operator_uid, source,
                             max_bytes=max_bytes)
    finally:
        os.close(source_fd)


def copy_trusted_tree_fd(source_fd: int, destination: str, operator_uid: int,
                         label: str, budget: list[int]) -> None:
    before = os.fstat(source_fd)
    if (not stat.S_ISDIR(before.st_mode)
            or before.st_uid not in (0, ROOT_AUTHORITY_UID, operator_uid)
            or before.st_mode & 0o022):
        die(f"unsafe toolchain source directory: {label}")
    os.mkdir(destination, 0o700)
    names = sorted(os.listdir(source_fd))
    for name in names:
        if name in (".", "..") or "/" in name or "\0" in name:
            die("invalid toolchain tree entry")
        budget[0] += 1
        if budget[0] > MAX_TREE_ENTRIES:
            die("toolchain source exceeds the bounded entry count")
        entry = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        child_label = os.path.join(label, name)
        destination_path = os.path.join(destination, name)
        if stat.S_ISLNK(entry.st_mode):
            die(f"toolchain source contains a symlink: {child_label}")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        if stat.S_ISDIR(entry.st_mode):
            flags |= getattr(os, "O_DIRECTORY", 0)
        elif stat.S_ISREG(entry.st_mode):
            flags |= os.O_NONBLOCK
        else:
            die(f"toolchain source contains a special file: {child_label}")
        child_fd = os.open(name, flags, dir_fd=source_fd)
        try:
            opened = os.fstat(child_fd)
            if (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_size,
                    opened.st_mtime_ns, opened.st_ctime_ns) != (
                entry.st_dev, entry.st_ino, entry.st_mode, entry.st_size, entry.st_mtime_ns,
                entry.st_ctime_ns,
            ):
                die(f"toolchain source changed while opening: {child_label}")
            if stat.S_ISDIR(opened.st_mode):
                copy_trusted_tree_fd(
                    child_fd, destination_path, operator_uid, child_label, budget,
                )
            elif stat.S_ISREG(opened.st_mode):
                copy_trusted_file_fd(
                    child_fd, destination_path, operator_uid, child_label,
                )
        finally:
            os.close(child_fd)
    after = os.fstat(source_fd)
    if (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_ctime_ns) != (
        before.st_dev, before.st_ino, before.st_mtime_ns, before.st_ctime_ns,
    ):
        die(f"toolchain source directory changed while copying: {label}")


def copy_trusted_tree(source: str, destination: str, operator_uid: int,
                      budget: list[int] | None = None) -> None:
    budget = budget if budget is not None else [0]
    source_fd = open_trusted_source(source, operator_uid, "toolchain directory", directory=True)
    try:
        copy_trusted_tree_fd(source_fd, destination, operator_uid, source, budget)
    finally:
        os.close(source_fd)


def root_control_tree(root: str) -> None:
    def harden(path: str, required: int) -> None:
        before = os.lstat(path)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        if stat.S_ISDIR(before.st_mode):
            flags |= getattr(os, "O_DIRECTORY", 0)
        elif stat.S_ISREG(before.st_mode):
            flags |= os.O_NONBLOCK
        else:
            die(f"Codex package contains a symlink or special file: {path}")
        fd = os.open(path, flags)
        try:
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_size,
                    opened.st_mtime_ns, opened.st_ctime_ns) != (
                before.st_dev, before.st_ino, before.st_mode, before.st_size,
                before.st_mtime_ns, before.st_ctime_ns,
            ):
                die(f"Codex package changed while hardening: {path}")
            os.fchown(fd, ROOT_AUTHORITY_UID, ROOT_AUTHORITY_GID)
            os.fchmod(fd, (stat.S_IMODE(opened.st_mode) | required) & ~0o022)
            strip_extended_acl_fd(fd, f"installed Codex package entry {path}")
            hardened = os.fstat(fd)
            if (not _authority_owner(hardened.st_uid)
                    or hardened.st_mode & 0o022 or fd_has_extended_acl(fd)):
                die(f"Codex package entry did not become ACL-free root authority: {path}")
        finally:
            os.close(fd)

    count = 0
    for current, dirs, files in os.walk(root, followlinks=False):
        count += len(dirs) + len(files)
        if count > MAX_TREE_ENTRIES:
            die("Codex package exceeds the bounded install tree")
        if os.path.islink(current):
            die(f"Codex package contains a symlinked directory: {current}")
        harden(current, 0o555)
        for name in dirs + files:
            path = os.path.join(current, name)
            info = os.lstat(path)
            required = 0o555 if stat.S_ISDIR(info.st_mode) else 0o444
            harden(path, required)
    validate_root_authority_tree(root, "staged Codex toolchain")


def write_tool_wrapper(path: str, cli_relative: str) -> None:
    node = os.path.join(TOOLCHAIN, "node")
    cli = os.path.join(TOOLCHAIN, cli_relative)
    content = f'#!/bin/sh\nexec "{node}" "{cli}" "$@"\n'.encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o500)
    try:
        view = memoryview(content)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fsync(fd)
        strip_extended_acl_fd(fd, f"staged {os.path.basename(path)} wrapper")
        if fd_has_extended_acl(fd):
            die(f"staged wrapper retained an extended ACL: {path}")
    finally:
        os.close(fd)


def install_toolchain(
    node_source: str,
    script_source: str,
    bun_source: str,
    operator_uid: int,
    runtime: pwd.struct_passwd,
    pnpm_source: str | None = None,
    pnpm_version: str | None = None,
) -> tuple[str, str, str | None]:
    if (pnpm_source is None) != (pnpm_version is None):
        die("pnpm toolchain source and version must be supplied together")
    if pnpm_version is not None and pnpm_version != SUPPORTED_PNPM_VERSION:
        die(f"only pnpm@{SUPPORTED_PNPM_VERSION} may enter the global root toolchain")
    if pnpm_source is None:
        existing_pnpm = existing_pnpm_plan()
        if existing_pnpm is not None:
            pnpm_source, pnpm_version = existing_pnpm
    validate_source(node_source, operator_uid, "Node", executable=True)
    validate_source(script_source, operator_uid, "Codex script")
    package_source = os.path.dirname(os.path.dirname(script_source))
    if script_source != os.path.join(package_source, "bin", "codex.js"):
        die("resolved Codex script is not the expected <package>/bin/codex.js")
    if not os.path.isfile(os.path.join(package_source, "package.json")):
        die("resolved Codex package is incomplete")
    node_prefix = os.path.dirname(os.path.dirname(node_source))
    npm_source = os.path.join(node_prefix, "lib", "node_modules", "npm")
    if (not os.path.isfile(os.path.join(npm_source, "bin", "npm-cli.js"))
            or not os.path.isfile(os.path.join(npm_source, "bin", "npx-cli.js"))):
        die("resolved Node installation does not include the required npm/npx baseline")
    parent = os.path.dirname(TOOLCHAIN)
    ensure_root_authority_directory(parent, "Codex toolchain parent")
    stage = tempfile.mkdtemp(prefix=".qofi-codex-toolchain.", dir=parent)
    try:
        stage_fd = os.open(
            stage,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            os.fchown(stage_fd, ROOT_AUTHORITY_UID, ROOT_AUTHORITY_GID)
            os.fchmod(stage_fd, 0o755)
            strip_extended_acl_fd(stage_fd, "staged Codex toolchain root")
        finally:
            os.close(stage_fd)
        node_target = os.path.join(stage, "node")
        bin_target = os.path.join(stage, "bin")
        package_target = os.path.join(stage, "codex")
        npm_target = os.path.join(stage, "npm")
        pnpm_target = os.path.join(stage, "pnpm")
        os.mkdir(bin_target, 0o755)
        budget = [0]
        copy_trusted_file(node_source, node_target, operator_uid)
        copy_trusted_file(bun_source, os.path.join(bin_target, "bun"), operator_uid)
        copy_trusted_tree(package_source, package_target, operator_uid, budget)
        copy_trusted_tree(npm_source, npm_target, operator_uid, budget)
        write_tool_wrapper(os.path.join(bin_target, "npm"), "npm/bin/npm-cli.js")
        write_tool_wrapper(os.path.join(bin_target, "npx"), "npm/bin/npx-cli.js")
        if pnpm_source is not None:
            copy_trusted_tree(pnpm_source, pnpm_target, operator_uid, budget)
            write_tool_wrapper(os.path.join(bin_target, "pnpm"), "pnpm/bin/pnpm.cjs")
        root_control_tree(stage)
        os.chmod(node_target, 0o755)
        staged_bun = os.path.join(bin_target, "bun")
        staged_script = os.path.join(package_target, "bin", "codex.js")
        os.chmod(staged_bun, 0o755)
        os.chmod(os.path.join(bin_target, "npm"), 0o755)
        os.chmod(os.path.join(bin_target, "npx"), 0o755)
        if pnpm_source is not None:
            os.chmod(os.path.join(bin_target, "pnpm"), 0o755)
        validate_root_authority_tree(stage, "staged Codex toolchain")
        version_run = run_as_runtime(runtime, [node_target, staged_script, "--version"], capture=True)
        if version_run.returncode != 0:
            die(f"service-uid staged Codex version probe failed: {version_run.stderr.strip()}")
        version = version_run.stdout.strip()
        if not re.fullmatch(r"(?:codex-cli|codex) 0\.144\.[1-9][0-9]*(?:[-+][0-9A-Za-z.-]+)?", version):
            die(f"staged Codex version is outside the audited 0.144.x line: {version}")
        bun_run = run_as_runtime(runtime, [staged_bun, "--version"], capture=True)
        if bun_run.returncode != 0:
            die(f"service-uid staged Bun version probe failed: {bun_run.stderr.strip()}")
        bun_version = bun_run.stdout.strip()
        bun_match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?", bun_version)
        if not bun_match or tuple(map(int, bun_match.groups())) < (1, 3, 0):
            die(f"staged Bun >=1.3.0 is required (found: {bun_version})")
        for name, cli in (("npm", "npm-cli.js"), ("npx", "npx-cli.js")):
            probe = run_as_runtime(
                runtime,
                [node_target, os.path.join(npm_target, "bin", cli), "--version"],
                capture=True,
            )
            if probe.returncode != 0 or not re.fullmatch(
                r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", probe.stdout.strip(),
            ):
                die(f"service-uid staged {name} version probe failed: "
                    f"{(probe.stderr or probe.stdout).strip()}")
        if pnpm_source is not None and pnpm_version is not None:
            pnpm_probe = run_as_runtime(
                runtime,
                [node_target, os.path.join(pnpm_target, "bin", "pnpm.cjs"), "--version"],
                capture=True,
            )
            if pnpm_probe.returncode != 0 or pnpm_probe.stdout.strip() != pnpm_version:
                die(f"service-uid staged pnpm version probe failed: "
                    f"{(pnpm_probe.stderr or pnpm_probe.stdout).strip()}")
        old = TOOLCHAIN + f".old.{os.getpid()}"
        if os.path.lexists(old):
            die(f"stale toolchain transaction path exists: {old}")
        if os.path.lexists(TOOLCHAIN):
            validate_root_authority_tree(TOOLCHAIN, "existing Codex toolchain")
            os.rename(TOOLCHAIN, old)
        try:
            os.rename(stage, TOOLCHAIN)
        except BaseException:
            if os.path.lexists(old) and not os.path.lexists(TOOLCHAIN):
                os.rename(old, TOOLCHAIN)
            raise
        stage = ""
        try:
            validate_root_authority_tree(TOOLCHAIN, "installed Codex toolchain")
            for name in ("npm", "npx"):
                probe = run_as_runtime(
                    runtime, [os.path.join(TOOLCHAIN, "bin", name), "--version"],
                    capture=True,
                )
                if probe.returncode != 0:
                    die(f"installed {name} wrapper failed its service-uid probe: "
                        f"{(probe.stderr or probe.stdout).strip()}")
            if pnpm_source is not None and pnpm_version is not None:
                probe = run_as_runtime(
                    runtime, [os.path.join(TOOLCHAIN, "bin", "pnpm"), "--version"],
                    capture=True,
                )
                if probe.returncode != 0 or probe.stdout.strip() != pnpm_version:
                    die(f"installed pnpm wrapper failed its service-uid probe: "
                        f"{(probe.stderr or probe.stdout).strip()}")
        except BaseException:
            if os.path.isdir(TOOLCHAIN):
                shutil.rmtree(TOOLCHAIN)
            if os.path.lexists(old):
                os.rename(old, TOOLCHAIN)
            raise
    finally:
        if stage and os.path.lexists(stage):
            shutil.rmtree(stage)
    node = os.path.join(TOOLCHAIN, "node")
    script = os.path.join(TOOLCHAIN, "codex", "bin", "codex.js")
    return node, script, old if os.path.lexists(old) else None


def install_root_program(
    source: str,
    target: str,
    operator_uid: int,
    label: str,
    *,
    exact_mode: int = 0o755,
    executable: bool = True,
    max_bytes: int = 2 * 1024 * 1024,
) -> str | None:
    if exact_mode not in (0o644, 0o755) or executable != bool(exact_mode & 0o111):
        die(f"invalid fixed-file publication mode for {label}")
    ensure_root_authority_directory(os.path.dirname(target), f"{label} parent")
    temporary = target + f".tmp.{os.getpid()}"
    backup = target + f".old.{os.getpid()}"
    if os.path.lexists(temporary) or os.path.lexists(backup):
        die(f"stale {label} transaction path exists")
    copy_trusted_file(source, temporary, operator_uid, max_bytes=max_bytes)
    temporary_fd = os.open(
        temporary, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fchown(temporary_fd, ROOT_AUTHORITY_UID, ROOT_AUTHORITY_GID)
        os.fchmod(temporary_fd, exact_mode)
        strip_extended_acl_fd(temporary_fd, f"staged {label}")
    finally:
        os.close(temporary_fd)
    staged = validate_root_authority_file(
        temporary, f"staged {label}", executable=executable, exact_mode=exact_mode,
        max_bytes=max_bytes,
    )
    staged_identity = (staged.st_dev, staged.st_ino)
    parent_fd = _open_root_authority_directory(os.path.dirname(target), f"{label} parent")
    backed_up = False
    published = False
    try:
        if os.path.lexists(target):
            validate_root_authority_file(
                target, f"existing {label}", executable=executable, exact_mode=exact_mode,
                max_bytes=max_bytes,
            )
            os.rename(target, backup)
            backed_up = True
        os.rename(temporary, target)
        published = True
        os.fsync(parent_fd)
        installed = validate_root_authority_file(
            target, f"installed {label}", executable=executable, exact_mode=exact_mode,
            max_bytes=max_bytes,
        )
        if (installed.st_dev, installed.st_ino) != staged_identity:
            die(f"installed {label} identity changed during publication")
    except BaseException:
        if published and os.path.lexists(target):
            current = os.lstat(target)
            if (current.st_dev, current.st_ino) != staged_identity:
                die(f"installed {label} changed before rollback")
            os.unlink(target)
        if backed_up and not os.path.lexists(target):
            os.rename(backup, target)
        os.fsync(parent_fd)
        raise
    finally:
        os.close(parent_fd)
        if os.path.lexists(temporary):
            current = os.lstat(temporary)
            if (current.st_dev, current.st_ino) != staged_identity:
                die(f"staged {label} changed before cleanup")
            os.unlink(temporary)
    return backup if backed_up else None


def install_root_program_bytes(content: bytes, target: str, label: str) -> str | None:
    """Publish captured bytes without reopening an operator-writable pathname."""

    if not isinstance(content, bytes) or not 1 <= len(content) <= MAX_MANAGER_BUNDLE_BYTES:
        die(f"captured {label} has an invalid size")
    ensure_root_authority_directory(os.path.dirname(target), f"{label} parent")
    temporary = target + f".tmp.{os.getpid()}"
    backup = target + f".old.{os.getpid()}"
    if os.path.lexists(temporary) or os.path.lexists(backup):
        die(f"stale {label} transaction path exists")
    fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    staged_identity: tuple[int, int] | None = None
    try:
        os.fchown(fd, ROOT_AUTHORITY_UID, ROOT_AUTHORITY_GID)
        os.fchmod(fd, 0o600)
        strip_extended_acl_fd(fd, f"staged {label}")
        view = memoryview(content)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                die(f"could not write staged {label}")
            view = view[written:]
        os.fsync(fd)
        os.fchmod(fd, 0o755)
        os.fsync(fd)
        opened = os.fstat(fd)
        if (not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != ROOT_AUTHORITY_UID
                or opened.st_gid != ROOT_AUTHORITY_GID
                or stat.S_IMODE(opened.st_mode) != 0o755
                or opened.st_size != len(content)
                or fd_has_extended_acl(fd)):
            die(f"staged {label} hardening failed")
        staged_identity = (opened.st_dev, opened.st_ino)
    except BaseException:
        os.close(fd)
        try:
            info = os.lstat(temporary)
            if staged_identity is None or (info.st_dev, info.st_ino) == staged_identity:
                os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    else:
        os.close(fd)

    try:
        validate_root_authority_file(
            temporary, f"staged {label}", executable=True, exact_mode=0o755,
            max_bytes=MAX_MANAGER_BUNDLE_BYTES,
        )
    except BaseException:
        if os.path.lexists(temporary):
            current = os.lstat(temporary)
            if (current.st_dev, current.st_ino) == staged_identity:
                os.unlink(temporary)
        raise
    parent_fd = _open_root_authority_directory(os.path.dirname(target), f"{label} parent")
    backed_up = False
    published = False
    try:
        if os.path.lexists(target):
            validate_root_authority_file(
                target, f"existing {label}", executable=True, exact_mode=0o755,
                max_bytes=MAX_MANAGER_BUNDLE_BYTES,
            )
            os.rename(target, backup)
            backed_up = True
        os.rename(temporary, target)
        published = True
        os.fsync(parent_fd)
        installed = validate_root_authority_file(
            target, f"installed {label}", executable=True, exact_mode=0o755,
            max_bytes=MAX_MANAGER_BUNDLE_BYTES,
        )
        if (installed.st_dev, installed.st_ino) != staged_identity:
            die(f"installed {label} identity changed during publication")
    except BaseException:
        if published and os.path.lexists(target):
            current = os.lstat(target)
            if (current.st_dev, current.st_ino) != staged_identity:
                die(f"installed {label} changed before rollback")
            os.unlink(target)
        if backed_up and not os.path.lexists(target):
            os.rename(backup, target)
        os.fsync(parent_fd)
        raise
    finally:
        os.close(parent_fd)
        if os.path.lexists(temporary):
            current = os.lstat(temporary)
            if (current.st_dev, current.st_ino) != staged_identity:
                die(f"staged {label} changed before cleanup")
            os.unlink(temporary)
    return backup if backed_up else None


def install_runner(source: str, operator_uid: int) -> str | None:
    return install_root_program(source, RUNNER, operator_uid, "runner")


def install_lifecycle(source: str, operator_uid: int) -> str | None:
    return install_root_program(source, LIFECYCLE, operator_uid, "lifecycle helper")


def install_root_data(
    source: str, target: str, operator_uid: int, label: str, *, max_bytes: int,
) -> str | None:
    return install_root_program(
        source, target, operator_uid, label,
        exact_mode=0o644, executable=False, max_bytes=max_bytes,
    )


def trusted_source_sha256(
    path: str, operator_uid: int, label: str, *, max_bytes: int,
) -> str:
    fd = open_trusted_source(path, operator_uid, label)
    digest = hashlib.sha256()
    try:
        before = os.fstat(fd)
        if not 1 <= before.st_size <= max_bytes:
            die(f"{label} source has an invalid size")
        while True:
            chunk = os.read(fd, 64 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(fd)
        if ((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
             after.st_ctime_ns)
                != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                    before.st_ctime_ns)):
            die(f"{label} source changed while hashing")
    finally:
        os.close(fd)
    return digest.hexdigest()


def manager_state_dir(operator: pwd.struct_passwd) -> str:
    return os.path.join(operator.pw_dir, ".codex", "app-server-manager")


def manager_environment(operator: pwd.struct_passwd) -> dict[str, str]:
    return {
        "HOME": operator.pw_dir,
        "USER": operator.pw_name,
        "LOGNAME": operator.pw_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
    }


def manager_environment_sha256(operator: pwd.struct_passwd) -> str:
    rendered = json.dumps(
        manager_environment(operator), sort_keys=True, separators=(",", ":"),
        ensure_ascii=True,
    )
    return hashlib.sha256(rendered.encode("ascii")).hexdigest()


def ensure_manager_state_dir(operator: pwd.struct_passwd) -> str:
    """Create one ACL-free operator-private manager state directory by fd."""

    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    home_fd = os.open(operator.pw_dir, flags)
    try:
        home_info = os.fstat(home_fd)
        if (not stat.S_ISDIR(home_info.st_mode) or home_info.st_uid != operator.pw_uid
                or home_info.st_mode & 0o022):
            die("operator home is unsafe for manager state")
        try:
            os.mkdir(".codex", 0o700, dir_fd=home_fd)
            created_codex = True
        except FileExistsError:
            created_codex = False
        codex_fd = os.open(".codex", flags, dir_fd=home_fd)
        try:
            if created_codex:
                os.fchown(codex_fd, operator.pw_uid, operator.pw_gid)
                os.fchmod(codex_fd, 0o700)
                strip_extended_acl_fd(codex_fd, "operator Codex home")
            codex_info = os.fstat(codex_fd)
            if (not stat.S_ISDIR(codex_info.st_mode)
                    or codex_info.st_uid != operator.pw_uid
                    or stat.S_IMODE(codex_info.st_mode) != 0o700):
                die("operator .codex must be an owner mode-0700 real directory")
            try:
                os.mkdir("app-server-manager", 0o700, dir_fd=codex_fd)
            except FileExistsError:
                pass
            state_fd = os.open("app-server-manager", flags, dir_fd=codex_fd)
            try:
                state_info = os.fstat(state_fd)
                if (not stat.S_ISDIR(state_info.st_mode)
                        or state_info.st_uid not in (ROOT_AUTHORITY_UID, operator.pw_uid)):
                    die("manager state path is not a safe real directory")
                os.fchown(state_fd, operator.pw_uid, operator.pw_gid)
                os.fchmod(state_fd, 0o700)
                strip_extended_acl_fd(state_fd, "manager state directory")
                hardened = os.fstat(state_fd)
                if (hardened.st_uid != operator.pw_uid
                        or stat.S_IMODE(hardened.st_mode) != 0o700
                        or fd_has_extended_acl(state_fd)):
                    die("manager state directory hardening failed")
            finally:
                os.close(state_fd)
        finally:
            os.close(codex_fd)
    finally:
        os.close(home_fd)
    selected = manager_state_dir(operator)
    if os.path.realpath(selected) != selected:
        die("manager state directory is not canonical")
    return selected


def build_manager_bundle(swarm_home: str, operator: pwd.struct_passwd, bun: str) -> bytes:
    """Bundle after credential drop and return bytes over a bounded pipe only."""

    source = os.path.join(swarm_home, "codex-bridge", "app-server-manager.ts")
    validate_source(source, operator.pw_uid, "App Server manager source")
    output = run_as_operator_capture_bytes(
        operator,
        [
            bun,
            "--no-env-file", "--config=/dev/null", "--no-install",
            "--no-addons", "--no-macros",
            "build", source, "--target=node", "--format=esm",
        ],
        cwd=swarm_home,
        label="single-file App Server manager bundle",
        max_stdout=MAX_MANAGER_BUNDLE_BYTES,
    )
    if not 1024 <= len(output) <= MAX_MANAGER_BUNDLE_BYTES:
        die("generated App Server manager bundle has an invalid size")
    return output


def write_manager_authority(operator: pwd.struct_passwd, node: str, swarm_home: str) -> None:
    state_dir = ensure_manager_state_dir(operator)
    manager_python = process_executable_path(os.getpid())
    if manager_python is None:
        die("could not resolve the fixed lifecycle Python executable")
    manager_python = os.path.realpath(manager_python)
    validate_root_authority_file(
        manager_python, "manager Python executable", executable=True,
        max_bytes=512 * 1024 * 1024,
    )
    value = {
        "schema": MANAGER_AUTHORITY_SCHEMA,
        "operator_uid": operator.pw_uid,
        "operator_user": operator.pw_name,
        "operator_home": operator.pw_dir,
        "node_path": node,
        "node_sha256": sha256(node),
        "manager_bundle_path": MANAGER_BUNDLE,
        "manager_bundle_sha256": sha256(MANAGER_BUNDLE),
        "manager_launcher_path": MANAGER_LAUNCHER,
        "manager_launcher_sha256": sha256(MANAGER_LAUNCHER),
        "manager_python_path": manager_python,
        "manager_python_sha256": sha256(manager_python),
        "manager_state_dir": state_dir,
        "swarm_home": swarm_home,
        "manager_environment_sha256": manager_environment_sha256(operator),
    }
    if set(value) != MANAGER_AUTHORITY_KEYS:
        die("internal manager authority schema mismatch")
    atomic_write(
        MANAGER_AUTHORITY,
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        0o644,
    )


def load_manager_authority() -> dict[str, object]:
    info = validate_root_authority_file(
        MANAGER_AUTHORITY, "manager authority", exact_mode=0o644, max_bytes=16 * 1024,
    )
    fd = os.open(MANAGER_AUTHORITY, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns,
                opened.st_ctime_ns) != (
            info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
        ):
            die("manager authority changed while opening")
        raw = os.read(fd, 16 * 1024 + 1)
    finally:
        os.close(fd)
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as exc:
        die(f"manager authority is invalid JSON: {exc}")
    if (not isinstance(value, dict) or set(value) != MANAGER_AUTHORITY_KEYS
            or value.get("schema") != MANAGER_AUTHORITY_SCHEMA):
        die("manager authority does not exactly match v1")
    return value


def validate_manager_authority(operator: pwd.struct_passwd, runtime_authority: dict[str, object]) -> dict[str, object]:
    value = load_manager_authority()
    state_dir = manager_state_dir(operator)
    if (value.get("operator_uid") != operator.pw_uid
            or value.get("operator_user") != operator.pw_name
            or value.get("operator_home") != operator.pw_dir
            or value.get("node_path") != runtime_authority.get("node_path")
            or value.get("node_sha256") != runtime_authority.get("node_sha256")
            or value.get("manager_bundle_path") != MANAGER_BUNDLE
            or value.get("manager_launcher_path") != MANAGER_LAUNCHER
            or value.get("manager_state_dir") != state_dir
            or value.get("manager_environment_sha256")
            != manager_environment_sha256(operator)):
        die("manager authority differs from the runtime/operator contract")
    swarm_home = value.get("swarm_home")
    if (not isinstance(swarm_home, str) or not os.path.isabs(swarm_home)
            or os.path.normpath(swarm_home) != swarm_home
            or os.path.realpath(swarm_home) != swarm_home):
        die("manager authority swarm home is not canonical")
    for path_key, hash_key, executable in (
        ("node_path", "node_sha256", True),
        ("manager_bundle_path", "manager_bundle_sha256", False),
        ("manager_launcher_path", "manager_launcher_sha256", True),
        ("manager_python_path", "manager_python_sha256", True),
    ):
        path = str(value[path_key])
        expected = value[hash_key]
        if not isinstance(expected, str) or not HASH_RE.fullmatch(expected):
            die(f"manager authority {hash_key} is invalid")
        maximum = (
            512 * 1024 * 1024
            if path_key in ("node_path", "manager_python_path")
            else 2 * 1024 * 1024
        )
        validate_root_authority_file(
            path, f"manager {path_key}", executable=executable,
            max_bytes=maximum,
        )
        if sha256(path) != expected:
            die(f"manager root authority drift: {path_key}")
    state_fd = os.open(
        state_dir,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        state_info = os.fstat(state_fd)
        if (not stat.S_ISDIR(state_info.st_mode) or state_info.st_uid != operator.pw_uid
                or stat.S_IMODE(state_info.st_mode) != 0o700
                or fd_has_extended_acl(state_fd)):
            die("manager state directory authority changed")
    finally:
        os.close(state_fd)
    swarm_fd = os.open(
        swarm_home,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        swarm_info = os.fstat(swarm_fd)
        if (not stat.S_ISDIR(swarm_info.st_mode)
                or swarm_info.st_uid not in (ROOT_AUTHORITY_UID, operator.pw_uid)
                or swarm_info.st_mode & 0o022 or fd_has_extended_acl(swarm_fd)):
            die("manager swarm home authority changed")
    finally:
        os.close(swarm_fd)
    return value


def _manager_admission_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
        info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    )


def load_manager_admission() -> tuple[dict[str, object], tuple[int, ...]]:
    info = validate_root_authority_file(
        MANAGER_ADMISSION, "manager recovery admission",
        exact_mode=0o600, max_bytes=16 * 1024,
    )
    try:
        fd = os.open(MANAGER_ADMISSION, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        die(f"could not open manager recovery admission: {exc}")
    try:
        opened = os.fstat(fd)
        if _manager_admission_identity(opened) != _manager_admission_identity(info):
            die("manager recovery admission changed while opening")
        raw = os.read(fd, 16 * 1024 + 1)
        after = os.fstat(fd)
        if _manager_admission_identity(after) != _manager_admission_identity(opened):
            die("manager recovery admission changed while reading")
    except OSError as exc:
        die(f"could not read manager recovery admission: {exc}")
    finally:
        os.close(fd)
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as exc:
        die(f"manager recovery admission is invalid JSON: {exc}")
    if (not isinstance(value, dict) or set(value) != MANAGER_ADMISSION_KEYS
            or value.get("schema") != MANAGER_ADMISSION_SCHEMA):
        die("manager recovery admission does not exactly match v1")
    return value, _manager_admission_identity(opened)


def validate_manager_recovery_processes(
    authority: dict[str, object],
    admission: dict[str, object],
    operator: pwd.struct_passwd,
) -> tuple[dict[str, int | str], dict[str, int | str]]:
    shared = MANAGER_ADMISSION_KEYS - {
        "schema", "nonce", "launcher_pid", "launcher_started",
        "manager_pid", "manager_started",
    }
    if (not isinstance(admission.get("nonce"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", str(admission["nonce"]))
            or admission.get("operator_uid") != operator.pw_uid
            or any(admission.get(key) != authority.get(key) for key in shared)):
        die("manager recovery admission differs from root authority")
    launcher_pid = admission.get("launcher_pid")
    manager_pid = admission.get("manager_pid")
    launcher_started = admission.get("launcher_started")
    manager_started = admission.get("manager_started")
    if (type(launcher_pid) is not int or launcher_pid <= 1
            or type(manager_pid) is not int or manager_pid <= 1
            or not isinstance(launcher_started, str) or not launcher_started
            or not isinstance(manager_started, str) or not manager_started):
        die("manager recovery admission has invalid process identities")
    launcher = process_snapshot(launcher_pid)
    manager = process_snapshot(manager_pid)
    if (launcher is None or manager is None
            or launcher["uid"] != ROOT_AUTHORITY_UID
            or launcher["ruid"] != ROOT_AUTHORITY_UID
            or launcher["svuid"] != ROOT_AUTHORITY_UID
            or launcher["gid"] != ROOT_AUTHORITY_GID
            or launcher["rgid"] != ROOT_AUTHORITY_GID
            or launcher["svgid"] != ROOT_AUTHORITY_GID
            or launcher["started"] != launcher_started
            or manager["uid"] != operator.pw_uid
            or manager["ruid"] != operator.pw_uid
            or manager["svuid"] != operator.pw_uid
            or manager["gid"] != operator.pw_gid
            or manager["rgid"] != operator.pw_gid
            or manager["svgid"] != operator.pw_gid
            or manager["ppid"] != launcher_pid
            or manager["pgid"] != manager_pid
            or manager["started"] != manager_started):
        die("manager recovery process identities differ from admission")
    if (process_executable_path(launcher_pid) != authority["manager_python_path"]
            or process_executable_path(manager_pid) != authority["node_path"]):
        die("manager recovery executable identity differs from authority")
    launcher_args = process_arguments(launcher_pid)
    if launcher_args != [
        str(authority["manager_python_path"]), "-I",
        str(authority["manager_launcher_path"]),
    ]:
        die("manager recovery launcher argv differs from authority")
    expected_manager_args = [
        str(authority["node_path"]), "--disable-sigusr1",
        str(authority["manager_bundle_path"]),
        "--state-dir", str(authority["manager_state_dir"]),
        "--swarm-home", str(authority["swarm_home"]),
    ]
    if process_arguments(manager_pid) != expected_manager_args:
        die("manager recovery manager argv differs from authority")
    return launcher, manager


def _manager_socket_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
        info.st_mtime_ns, info.st_ctime_ns,
    )


def query_stopped_manager_recovery_health(
    authority: dict[str, object], operator: pwd.struct_passwd, expected_peer_pid: int,
) -> dict[str, object]:
    path = os.path.join(str(authority["manager_state_dir"]), "control.sock")
    try:
        before = os.lstat(path)
    except OSError as exc:
        die(f"could not bind manager recovery control endpoint: {exc}")
    if (not stat.S_ISSOCK(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != operator.pw_uid or stat.S_IMODE(before.st_mode) != 0o600
            or path_has_extended_acl(path)):
        die("manager recovery control endpoint is not owner-private")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5.0)
    try:
        client.connect(path)
        after_connect = os.lstat(path)
        if _manager_socket_identity(after_connect) != _manager_socket_identity(before):
            die("manager recovery control endpoint changed while connecting")
        raw_peer = client.getsockopt(0, 0x002, 4)  # SOL_LOCAL, LOCAL_PEERPID
        if len(raw_peer) != 4 or struct.unpack("=i", raw_peer)[0] != expected_peer_pid:
            die("manager recovery control peer is not the admitted manager")
        client.sendall(
            b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\n"
            b"Accept: application/json\r\nConnection: close\r\n\r\n"
        )
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = client.recv(4096)
            if not chunk:
                die("manager recovery health response ended before headers")
            response.extend(chunk)
            if len(response) > 16 * 1024:
                die("manager recovery health headers exceeded the bound")
        header_raw, body = bytes(response).split(b"\r\n\r\n", 1)
        try:
            lines = header_raw.decode("ascii", "strict").split("\r\n")
        except UnicodeDecodeError:
            die("manager recovery health headers are not ASCII")
        if not lines or not re.fullmatch(r"HTTP/1\.[01] 200(?: .*)?", lines[0]):
            die("manager recovery health endpoint did not return HTTP 200")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            if ":" not in line:
                die("manager recovery health response has a malformed header")
            name, value = line.split(":", 1)
            name = name.strip().lower()
            if not name or name in headers:
                die("manager recovery health response has duplicate headers")
            headers[name] = value.strip()
        length = headers.get("content-length", "")
        if (headers.get("content-type", "").split(";", 1)[0].strip() != "application/json"
                or not length.isdecimal() or not 1 <= int(length) <= 64 * 1024):
            die("manager recovery health response metadata is invalid")
        expected_length = int(length)
        while len(body) < expected_length:
            chunk = client.recv(min(4096, expected_length - len(body)))
            if not chunk:
                die("manager recovery health response ended before its body")
            body += chunk
        if len(body) != expected_length:
            die("manager recovery health response exceeded its declared length")
        try:
            value = json.loads(body.decode("utf-8", "strict"))
        except (UnicodeDecodeError, ValueError) as exc:
            die(f"manager recovery health response is invalid JSON: {exc}")
    except OSError as exc:
        die(f"could not query manager recovery health: {exc}")
    finally:
        client.close()
    try:
        after = os.lstat(path)
    except OSError as exc:
        die(f"could not rebind manager recovery control endpoint: {exc}")
    if _manager_socket_identity(after) != _manager_socket_identity(before):
        die("manager recovery control endpoint changed after response")
    if (not isinstance(value, dict) or set(value) != MANAGER_HEALTH_KEYS
            or value.get("schema") != "qofi-codex-app-server-manager/v1"
            or value.get("managerVersion") != "0.1.0"
            or value.get("protocolVersion") != "0.144.1"
            or value.get("cliVersion") != "0.144.1"
            or type(value.get("generation")) is not int or int(value["generation"]) <= 0
            or type(value.get("registeredSwarmCount")) is not int
            or value.get("registeredSwarmCount") != 0
            or value.get("status") != "ambiguous"
            or value.get("phase") != "ambiguous"
            or value.get("upstreamState") != "ambiguous"
            or value.get("upstreamReady") is not False):
        die("manager recovery health is not an exact stopped zero-registration ambiguity")
    return value


def open_manager_recovery_launcher_lock() -> tuple[int, tuple[int, ...]]:
    """Bind the root launcher's existing singleton lock without replacing it."""

    try:
        before = os.lstat(MANAGER_LAUNCHER_LOCK)
        fd = os.open(
            MANAGER_LAUNCHER_LOCK,
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as exc:
        die(f"could not bind manager recovery launcher lock: {exc}")
    try:
        opened = os.fstat(fd)
        identity = _manager_admission_identity(opened)
        if (identity != _manager_admission_identity(before)
                or not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != ROOT_AUTHORITY_UID
                or stat.S_IMODE(opened.st_mode) != 0o600
                or fd_has_extended_acl(fd)):
            die("manager recovery launcher lock authority changed")
        return fd, identity
    except OSError as exc:
        os.close(fd)
        die(f"could not validate manager recovery launcher lock: {exc}")
    except BaseException:
        os.close(fd)
        raise


def acquire_manager_recovery_runner_lock(timeout: float = 35.0) -> int:
    """Freeze upstream creation before the final logical health proof."""

    try:
        fd = os.open(
            LOCK, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600,
        )
    except OSError as exc:
        die(f"could not bind manager recovery runner lock: {exc}")
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != ROOT_AUTHORITY_UID
                or stat.S_IMODE(info.st_mode) != 0o600 or fd_has_extended_acl(fd)):
            die("manager recovery runner lock authority changed")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    die("manager recovery runner did not reach quiescence")
                time.sleep(0.05)
            except OSError as exc:
                die(f"could not inspect manager recovery runner lock: {exc}")
        try:
            named = os.lstat(LOCK)
        except OSError as exc:
            die(f"could not rebind manager recovery runner lock: {exc}")
        if _manager_admission_identity(named) != _manager_admission_identity(os.fstat(fd)):
            die("manager recovery runner lock was replaced while acquiring it")
        return fd
    except BaseException:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
        raise


def wait_for_manager_recovery_quiescence(
    runtime_authority: dict[str, object],
    admission_identity: tuple[int, ...],
    launcher: dict[str, int | str],
    manager: dict[str, int | str],
    launcher_lock_fd: int,
    launcher_lock_identity: tuple[int, ...],
    runner_lock_fd: int,
) -> None:
    deadline = time.monotonic() + 45.0
    while time.monotonic() < deadline:
        try:
            current = os.lstat(MANAGER_ADMISSION)
        except FileNotFoundError:
            pass
        except OSError as exc:
            die(f"could not rebind manager admission during recovery: {exc}")
        else:
            if _manager_admission_identity(current) != admission_identity:
                die("manager admission was replaced during recovery")
        try:
            fcntl.flock(launcher_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            launcher_lock_acquired = True
        except BlockingIOError:
            launcher_lock_acquired = False
        except OSError as exc:
            die(f"could not inspect manager launcher lock during recovery: {exc}")
        if launcher_lock_acquired:
            try:
                current_lock = os.lstat(MANAGER_LAUNCHER_LOCK)
            except OSError as exc:
                die(f"could not rebind manager launcher lock during recovery: {exc}")
            if (_manager_admission_identity(current_lock) != launcher_lock_identity
                    or _manager_admission_identity(os.fstat(launcher_lock_fd))
                    != launcher_lock_identity):
                die("manager recovery launcher lock was replaced")
            # The launcher may still be visible briefly as a zombie after its
            # flock is released. Lock ownership is the stronger supervisor
            # boundary. Re-sample the child and admission under our newly held
            # lock; the attested launcher removes both before it returns.
            manager_after_lock = process_snapshot(int(manager["pid"]))
            try:
                admission_after_lock = os.lstat(MANAGER_ADMISSION)
            except FileNotFoundError:
                admission_after_lock = None
            except OSError as exc:
                die(f"could not rebind manager admission after launcher exit: {exc}")
            if admission_after_lock is not None:
                if _manager_admission_identity(admission_after_lock) != admission_identity:
                    die("manager admission was replaced during recovery")
                die("manager launcher lock released before admission cleanup")
            if manager_after_lock is not None and manager_after_lock == manager:
                die("manager launcher lock released before child cleanup")
            break
        time.sleep(0.05)
    else:
        die("admitted manager did not complete supervised recovery")

    try:
        info = os.fstat(runner_lock_fd)
    except OSError as exc:
        die(f"could not revalidate held manager recovery runner lock: {exc}")
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != ROOT_AUTHORITY_UID
            or stat.S_IMODE(info.st_mode) != 0o600 or fd_has_extended_acl(runner_lock_fd)):
        die("manager recovery runner lock changed while held")
    quiesce_service_uid(runtime_authority)
    _, runtime, _ = exact_runtime_identity(runtime_authority)
    if service_pids(runtime.pw_uid, int(runtime_authority["runtime_gid"])):
        die("manager recovery did not quiesce the dedicated runtime uid")


def validate_sudo_publish_authority() -> None:
    """Prove the complete root execution boundary before granting NOPASSWD."""

    validate_root_authority_file(
        RUNNER, "sudo target runner", executable=True, exact_mode=0o755,
        max_bytes=2 * 1024 * 1024,
    )
    validate_root_authority_file(
        LIFECYCLE, "fixed lifecycle helper", executable=True, exact_mode=0o755,
        max_bytes=2 * 1024 * 1024,
    )
    validate_root_authority_tree(TOOLCHAIN, "installed Codex toolchain")
    authority = load_attestation()
    if (authority.get("runner_path") != RUNNER
            or authority.get("node_path") != os.path.join(TOOLCHAIN, "node")
            or authority.get("codex_script")
            != os.path.join(TOOLCHAIN, "codex", "bin", "codex.js")
            or authority.get("runner_sha256") != sha256(RUNNER)
            or authority.get("node_sha256") != sha256(str(authority["node_path"]))
            or authority.get("codex_script_sha256")
            != sha256(str(authority["codex_script"]))
            or authority.get("fable_reviewer_path") != FABLE_REVIEWER
            or authority.get("fable_reviewer_sha256") != sha256(FABLE_REVIEWER)
            or authority.get("fable_doctrine_path") != FABLE_DOCTRINE
            or authority.get("fable_doctrine_sha256") != sha256(FABLE_DOCTRINE)
            or authority.get("fable_schema_path") != FABLE_SCHEMA
            or authority.get("fable_schema_sha256") != sha256(FABLE_SCHEMA)
            or authority.get("codex_config_sha256")
            != hashlib.sha256(
                rendered_codex_config(int(authority["operator_uid"])),
            ).hexdigest()):
        die("refusing sudoers publication because root execution authority is inconsistent")
    operator = pwd.getpwuid(int(authority["operator_uid"]))
    validate_manager_authority(operator, authority)


def install_sudoers(
    operator: pwd.struct_passwd, runtime: pwd.struct_passwd | None = None,
) -> None:
    validate_sudo_publish_authority()
    if runtime is None:
        authority = load_attestation()
        runtime = pwd.getpwnam(str(authority["runtime_user"]))
    content = (
        "# managed by swarm-codex-runtime.sh; runner validates every argument and attested hash\n"
        f"{operator.pw_name} ALL=(root) NOPASSWD: {RUNNER} *\n"
        f'{operator.pw_name} ALL=(root) NOPASSWD: {MANAGER_LAUNCHER} ""\n'
        f"{runtime.pw_name} ALL=(#{operator.pw_uid}) NOPASSWD: "
        f"/usr/bin/python3 -I -B {FABLE_REVIEWER}\n"
    )
    parent = os.path.dirname(SUDOERS)
    ensure_root_authority_directory(parent, "sudoers parent")
    temporary = SUDOERS + f".tmp.{os.getpid()}"
    atomic_write(temporary, content, 0o440)
    run(["/usr/sbin/visudo", "-cf", temporary])
    os.replace(temporary, SUDOERS)
    os.chown(SUDOERS, ROOT_AUTHORITY_UID, ROOT_AUTHORITY_GID)
    os.chmod(SUDOERS, 0o440)
    validate_root_authority_file(SUDOERS, "installed sudoers rule", exact_mode=0o440)


def prove_runner_sudo_precommit(operator: pwd.struct_passwd) -> None:
    output = run_as_operator_bounded(
        operator,
        ["/usr/bin/sudo", "-n", "--", RUNNER, "--verify-install"],
        cwd=operator.pw_dir,
        label="precommit fixed runner/sudoers proof",
    )
    if output.strip() != "qofi-codex-runner: OK v2 authority/hash/account contract":
        die("precommit fixed runner/sudoers proof returned unexpected output")
    prove_fable_reviewer_sudo_lane(operator, "precommit")


def prove_runner_sudo_verify(
    operator: pwd.struct_passwd, profile: str = DEFAULT_PROFILE,
) -> None:
    if not PROFILE_RE.fullmatch(profile):
        die("Codex profile handle must match [a-z][a-z0-9_-]{0,31}")
    command = [
        "/usr/bin/sudo", "-n", "--", RUNNER, "--verify",
        *([] if profile == DEFAULT_PROFILE else ["--profile", profile]),
    ]
    proof = subprocess.run(
        command,
        text=True, capture_output=True,
        env={"HOME": operator.pw_dir, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )
    if proof.returncode != 0:
        die(f"root runner/sudoers verification failed: {(proof.stderr or proof.stdout).strip()}")
    expected = "qofi-codex-runner: OK v2 authority/hash/account contract\n"
    if proof.stdout != expected or proof.stderr:
        die("root runner/sudoers verification returned unexpected output")


def prove_fable_reviewer_sudo_lane(
    operator: pwd.struct_passwd, phase: str,
) -> None:
    output = run_as_operator_bounded(
        operator,
        ["/usr/bin/sudo", "-n", "--", RUNNER, "--verify-fable-reviewer"],
        cwd=operator.pw_dir,
        label=f"{phase} service-uid Fable MCP/sudoers proof",
    )
    if output.strip() != "qofi-codex-runner: OK service-uid/operator Fable MCP contract":
        die(f"{phase} service-uid Fable MCP/sudoers proof returned unexpected output")


def set_operator_canary(operator_uid: int, existing_name: str | None = None) -> tuple[str, str]:
    suffix = secrets.token_hex(8).upper()
    name = existing_name or f"QOFI_CODEX_RUNTIME_CANARY_{suffix}"
    secret = secrets.token_urlsafe(32)
    run(["/bin/launchctl", "asuser", str(operator_uid), "/bin/launchctl", "setenv", name, secret])
    observed = run(
        ["/bin/launchctl", "asuser", str(operator_uid), "/bin/launchctl", "getenv", name],
        capture=True,
    ).stdout.strip()
    if observed != secret:
        die("could not establish the operator launchd isolation canary")
    return name, hashlib.sha256(secret.encode()).hexdigest()


def load_attestation(*, require_root_owner: bool = True) -> dict[str, object]:
    if require_root_owner:
        info = validate_root_authority_file(
            ATTESTATION, "runtime attestation", exact_mode=0o644, max_bytes=16 * 1024,
        )
    else:
        info = os.lstat(ATTESTATION)
    if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_mode & 0o022
            or (require_root_owner and not _authority_owner(info.st_uid))
            or not 2 <= info.st_size <= 16 * 1024):
        die("runtime attestation is not a bounded root-owned regular file")
    fd = os.open(ATTESTATION, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns,
                opened.st_ctime_ns) != (
            info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
        ) or fd_has_extended_acl(fd):
            die("runtime attestation changed while opening")
        raw = os.read(fd, 16 * 1024 + 1)
    finally:
        os.close(fd)
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as exc:
        die(f"runtime attestation is invalid JSON: {exc}")
    if (not isinstance(value, dict) or set(value) not in (EXACT_KEYS, LEGACY_EXACT_KEYS)
            or value.get("schema") != SCHEMA):
        die("runtime attestation does not exactly match qofi-codex-runtime/v2")
    return value


def write_attestation(operator: pwd.struct_passwd, runtime: pwd.struct_passwd,
                      shared: grp.struct_group, node: str, script: str,
                      canary_name: str, canary_hash: str, swarm_home: str) -> None:
    value = {
        "schema": SCHEMA,
        "operator_uid": operator.pw_uid,
        "runtime_uid": runtime.pw_uid,
        "runtime_user": runtime.pw_name,
        "runtime_gid": shared.gr_gid,
        "runtime_group": shared.gr_name,
        "runtime_home": runtime.pw_dir,
        "codex_home": os.path.join(runtime.pw_dir, ".codex"),
        "runner_path": RUNNER,
        "runner_sha256": sha256(RUNNER),
        "node_path": node,
        "node_sha256": sha256(node),
        "codex_script": script,
        "codex_script_sha256": sha256(script),
        "fable_reviewer_path": FABLE_REVIEWER,
        "fable_reviewer_sha256": sha256(FABLE_REVIEWER),
        "fable_doctrine_path": FABLE_DOCTRINE,
        "fable_doctrine_sha256": sha256(FABLE_DOCTRINE),
        "fable_schema_path": FABLE_SCHEMA,
        "fable_schema_sha256": sha256(FABLE_SCHEMA),
        "fable_reviewer_config_sha256": trusted_source_sha256(
            os.path.join(swarm_home, "fable-reviewer.json"),
            operator.pw_uid, "Fable reviewer policy", max_bytes=MAX_REVIEWER_CONFIG_BYTES,
        ),
        "codex_config_sha256": hashlib.sha256(
            rendered_codex_config(operator.pw_uid),
        ).hexdigest(),
        "launchd_canary_name": canary_name,
        "launchd_canary_sha256": canary_hash,
    }
    atomic_write(ATTESTATION, json.dumps(value, indent=2, sort_keys=True) + "\n", 0o644)


def sensitive_path(rel: str) -> bool:
    normalized = rel.replace(os.sep, "/")
    if normalized == ".claude/worktrees" or normalized.startswith(".claude/worktrees/"):
        return True
    name = normalized.rsplit("/", 1)[-1].lower()
    env_example = bool(ENV_EXAMPLE_RE.fullmatch(name))
    if (
        name == ".env"
        or (name.startswith(".env.") and not env_example)
        or name.endswith(".env")
        or name in {
            "tokens.env", ".npmrc", ".pypirc", ".netrc", ".git-credentials",
            "id_rsa", "id_ed25519",
        }
        or name.endswith((".pem", ".key", ".p12", ".pfx"))
        or re.match(r"settings\.local(?:\.|$)", name, re.I)
        or bool(SECRET_DATA_RE.search(name))
    ):
        return True
    return any(part.lower() in PROVIDER_DIRS for part in normalized.split("/"))


def operator_owned(rel: str) -> bool:
    first = rel.split(os.sep, 1)[0]
    return (
        first in OPERATOR_DIRS or rel in OPERATOR_FILES
        or first.startswith(".swarm-") or sensitive_path(rel)
    )


def package_dependency_path(rel: str) -> bool:
    """Return whether a workspace path is inside a node_modules domain."""

    return "node_modules" in rel.replace(os.sep, "/").split("/")


def fd_has_extended_acl(fd: int) -> bool:
    if sys.platform != "darwin":
        return False
    global _ACL_API
    if _ACL_API is None:
        libc = ctypes.CDLL(None, use_errno=True)
        get_acl = libc.acl_get_fd_np
        get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
        get_acl.restype = ctypes.c_void_p
        free_acl = libc.acl_free
        free_acl.argtypes = [ctypes.c_void_p]
        free_acl.restype = ctypes.c_int
        init_acl = libc.acl_init
        init_acl.argtypes = [ctypes.c_int]
        init_acl.restype = ctypes.c_void_p
        set_acl = libc.acl_set_fd_np
        set_acl.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        set_acl.restype = ctypes.c_int
        _ACL_API = (get_acl, free_acl, init_acl, set_acl)
    get_acl, free_acl, _init_acl, _set_acl = _ACL_API
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)  # ACL_TYPE_EXTENDED
    if not acl:
        error = ctypes.get_errno()
        if error in (0, errno.ENOENT):
            return False
        die(f"could not inspect extended ACL: errno {error}")
    try:
        return True
    finally:
        free_acl(acl)


def path_has_extended_acl(path: str) -> bool:
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
        die(f"could not inspect path extended ACL: errno {error}")
    try:
        return True
    finally:
        free_acl(acl)


def strip_extended_acl_fd(fd: int, label: str) -> None:
    """Remove an inherited macOS ACL from the already-open authority inode."""

    if sys.platform != "darwin" or not fd_has_extended_acl(fd):
        return
    assert _ACL_API is not None
    _get_acl, free_acl, init_acl, set_acl = _ACL_API
    ctypes.set_errno(0)
    empty = init_acl(0)
    if not empty:
        die(f"could not allocate an empty ACL for {label}: errno {ctypes.get_errno()}")
    try:
        ctypes.set_errno(0)
        if set_acl(fd, empty, 0x00000100) != 0:  # ACL_TYPE_EXTENDED
            die(f"could not strip inherited ACL from {label}: errno {ctypes.get_errno()}")
    finally:
        free_acl(empty)
    if fd_has_extended_acl(fd):
        die(f"extended ACL remained after hardening {label}")


def assert_single_link_regular_file(
    info: os.stat_result,
    rel: str,
    *,
    expected_dev: int | None = None,
    expected_uid: int | None = None,
    allowed_uids: set[int] | None = None,
    proven_dependency_hardlinks: dict[tuple[int, int], int] | None = None,
    hardlink_owner_uid: int | None = None,
) -> bool:
    """Validate a regular inode and identify a proven dependency hard link.

    A hard link inside the workspace can name an operator file outside the
    workspace (or alias one file across sensitive/ordinary policy tiers).
    Mutating that inode would extend the hidden runtime group's authority past
    the descriptor-bound repository boundary, while merely reading the in-repo
    name could bypass the path-based sandbox.  A complete preflight may prove
    the narrow exception: every alias is present in node_modules, the observed
    alias count exactly equals st_nlink, and the inode remains operator-owned,
    runtime-readable, and immutable to group/everyone.  Those inodes are never
    chmodded, chgrped, or journaled.  Return True for that exception.
    """

    if not stat.S_ISREG(info.st_mode):
        die(f"workspace contains unsupported special file: {rel}")
    if expected_dev is not None and info.st_dev != expected_dev:
        die(f"workspace crosses a filesystem boundary: {rel}")
    if expected_uid is not None and info.st_uid != expected_uid:
        die(f"workspace path is not owned by the attested operator: {rel}")
    if allowed_uids is not None and info.st_uid not in allowed_uids:
        die(f"workspace path has an unrecognized owner uid: {rel}")
    if stat.S_IMODE(info.st_mode) & 0o7000:
        die(f"workspace regular file has unsafe set-id/sticky mode bits: {rel}")
    if info.st_nlink == 1:
        return False
    identity = (info.st_dev, info.st_ino)
    if (proven_dependency_hardlinks is None
            or proven_dependency_hardlinks.get(identity) != info.st_nlink
            or not package_dependency_path(rel)
            or sensitive_path(rel)
            or operator_owned(rel)):
        die(f"workspace contains a hard-linked regular file: {rel}")
    if hardlink_owner_uid is None or info.st_uid != hardlink_owner_uid:
        die(f"workspace package hard link has the wrong owner: {rel}")
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o022:
        die(f"workspace package hard link is group/world writable: {rel}")
    if not mode & 0o004 or (mode & 0o100 and not mode & 0o001):
        die(f"workspace package hard link is not runtime-readable/executable: {rel}")
    return True


def assert_workspace_inode_boundary_fd(
    root_fd: int,
    *,
    expected_uid: int | None = None,
    allowed_uids: set[int] | None = None,
) -> dict[tuple[int, int], int]:
    """Preflight the complete managed tree before any privileged mutation."""

    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
    root = os.fstat(root_fd)
    expected_dev = root.st_dev
    seen_dirs: set[tuple[int, int]] = set()
    regular_aliases: dict[tuple[int, int], list[tuple[str, os.stat_result]]] = {}
    count = 0
    for current, dirs, files, dir_fd in os.fwalk(
        ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
    ):
        rel_dir = "" if current == "." else current.removeprefix("./")
        count += len(dirs) + len(files)
        if count > MAX_TREE_ENTRIES:
            die(f"workspace exceeds the {MAX_TREE_ENTRIES}-entry security scan bound")
        info = os.fstat(dir_fd)
        identity = (info.st_dev, info.st_ino)
        if info.st_dev != expected_dev:
            die(f"workspace crosses a filesystem boundary: {rel_dir or '.'}")
        if identity in seen_dirs:
            die(f"workspace contains a duplicate directory inode: {rel_dir or '.'}")
        seen_dirs.add(identity)
        if expected_uid is not None and info.st_uid != expected_uid:
            die(f"workspace path is not owned by the attested operator: {rel_dir or '.'}")
        if allowed_uids is not None and info.st_uid not in allowed_uids:
            die(f"workspace path has an unrecognized owner uid: {rel_dir or '.'}")
        # setgid is the managed shared-directory marker. setuid/sticky directory
        # bits are never required and can carry surprising host semantics.
        if stat.S_IMODE(info.st_mode) & 0o5000:
            die(f"workspace directory has unsafe set-id/sticky mode bits: {rel_dir or '.'}")

        opaque = detach_opaque_operator_subtrees(rel_dir, dirs, files, dir_fd)
        try:
            for opaque_rel, fd in opaque:
                item = os.fstat(fd)
                opaque_identity = (item.st_dev, item.st_ino)
                if item.st_dev != expected_dev:
                    die(f"workspace crosses a filesystem boundary: {opaque_rel}")
                if opaque_identity in seen_dirs:
                    die(f"workspace contains a duplicate directory inode: {opaque_rel}")
                seen_dirs.add(opaque_identity)
                if expected_uid is not None and item.st_uid != expected_uid:
                    die(f"workspace path is not owned by the attested operator: {opaque_rel}")
                if allowed_uids is not None and item.st_uid not in allowed_uids:
                    die(f"workspace path has an unrecognized owner uid: {opaque_rel}")
                if stat.S_IMODE(item.st_mode) & 0o5000:
                    die(f"workspace directory has unsafe set-id/sticky mode bits: {opaque_rel}")
        finally:
            for _opaque_rel, fd in opaque:
                os.close(fd)

        for name in files:
            rel = os.path.join(rel_dir, name) if rel_dir else name
            try:
                fd = os.open(name, flags, dir_fd=dir_fd)
            except OSError as exc:
                if exc.errno in (errno.ELOOP, errno.ENOENT):
                    continue
                raise
            try:
                item = os.fstat(fd)
                if not stat.S_ISREG(item.st_mode):
                    die(f"workspace contains unsupported special file: {rel}")
                if item.st_dev != expected_dev:
                    die(f"workspace crosses a filesystem boundary: {rel}")
                if expected_uid is not None and item.st_uid != expected_uid:
                    die(f"workspace path is not owned by the attested operator: {rel}")
                if allowed_uids is not None and item.st_uid not in allowed_uids:
                    die(f"workspace path has an unrecognized owner uid: {rel}")
                if stat.S_IMODE(item.st_mode) & 0o7000:
                    die(f"workspace regular file has unsafe set-id/sticky mode bits: {rel}")
                identity = (item.st_dev, item.st_ino)
                regular_aliases.setdefault(identity, []).append((rel, item))
                if item.st_nlink != 1 and fd_has_extended_acl(fd):
                    die(f"workspace package hard link has an extended ACL: {rel}")
            finally:
                os.close(fd)

    proven: dict[tuple[int, int], int] = {}
    for identity, aliases in regular_aliases.items():
        link_counts = {item.st_nlink for _rel, item in aliases}
        if link_counts == {1} and len(aliases) == 1:
            continue
        first_rel = aliases[0][0]
        if (len(link_counts) != 1
                or next(iter(link_counts), 0) != len(aliases)
                or any(not package_dependency_path(rel)
                       or sensitive_path(rel) or operator_owned(rel)
                       for rel, _item in aliases)):
            die(f"workspace contains a hard-linked regular file outside a closed "
                f"node_modules alias set: {first_rel}")
        link_count = next(iter(link_counts))
        for rel, item in aliases:
            # The workspace root owner is the only identity allowed to own a
            # dependency-cache alias.  Later prepare/verify calls additionally
            # bind this to the attested operator before any mutation.
            assert_single_link_regular_file(
                item, rel,
                expected_dev=expected_dev,
                expected_uid=expected_uid,
                allowed_uids=allowed_uids,
                proven_dependency_hardlinks={identity: link_count},
                hardlink_owner_uid=root.st_uid,
            )
        proven[identity] = link_count
    return proven


def detach_opaque_operator_subtrees(
    rel_dir: str,
    dirs: list[str],
    files: list[str],
    dir_fd: int,
) -> list[tuple[str, int]]:
    """Open and prune host-owned subtrees that Codex must never traverse.

    `os.fwalk(..., topdown=True)` lets callers remove a directory from `dirs`
    before descent.  Return descriptor-bound directory entries so each caller
    can inspect, protect, verify, journal, or release only the opaque root
    without trusting a pathname or touching any Claude worktree contents.
    """

    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    opened: list[tuple[str, int]] = []
    for opaque in OPAQUE_OPERATOR_SUBTREES:
        parent, name = os.path.split(opaque)
        if parent != rel_dir:
            continue
        if name in files:
            die(f"opaque operator subtree must be a real directory: {opaque}")
        if name not in dirs:
            continue
        try:
            fd = os.open(name, flags, dir_fd=dir_fd)
        except OSError as exc:
            die(f"opaque operator subtree must remain a real directory: {opaque} ({exc})")
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or fd_has_extended_acl(fd):
            os.close(fd)
            die(f"opaque operator subtree is unsafe: {opaque}")
        dirs.remove(name)
        opened.append((opaque, fd))
    return opened


def assert_workspace_no_acls_or_nested_git_fd(
    root_fd: int,
    *,
    expected_uid: int | None = None,
    allowed_uids: set[int] | None = None,
) -> dict[tuple[int, int], int]:
    proven_dependency_hardlinks = assert_workspace_inode_boundary_fd(
        root_fd, expected_uid=expected_uid, allowed_uids=allowed_uids,
    )
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    root_info = os.fstat(root_fd)
    expected_dev = root_info.st_dev
    count = 0
    for current, dirs, files, dir_fd in os.fwalk(
        ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
    ):
        rel_dir = "" if current == "." else current.removeprefix("./")
        count += len(dirs) + len(files)
        if count > MAX_TREE_ENTRIES:
            die(f"workspace exceeds the {MAX_TREE_ENTRIES}-entry security scan bound")
        opaque = detach_opaque_operator_subtrees(rel_dir, dirs, files, dir_fd)
        for _rel, fd in opaque:
            os.close(fd)
        outside_root_git = not (rel_dir == ".git" or rel_dir.startswith(".git/"))
        if ((rel_dir == "" and ".git" in files)
                or (rel_dir != "" and outside_root_git
                    and (".git" in dirs or ".git" in files))):
            die("nested repositories, submodules, and .git pointer files are unsupported")
        if rel_dir == "" and ".git" in dirs:
            try:
                git_fd = os.open(".git", flags, dir_fd=dir_fd)
            except OSError as exc:
                die(f"workspace .git must be a real in-repo directory before mutation: {exc}")
            os.close(git_fd)
        if fd_has_extended_acl(dir_fd):
            die(f"workspace has a pre-existing ACL; remove it before prepare-workspace: {rel_dir or '.'}")
        for name in files:
            rel = os.path.join(rel_dir, name) if rel_dir else name
            try:
                fd = os.open(
                    name, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=dir_fd,
                )
            except OSError as exc:
                if exc.errno in (errno.ELOOP, errno.ENOENT):
                    continue
                raise
            try:
                assert_single_link_regular_file(
                    os.fstat(fd), rel,
                    expected_dev=expected_dev, expected_uid=expected_uid,
                    allowed_uids=allowed_uids,
                    proven_dependency_hardlinks=proven_dependency_hardlinks,
                    hardlink_owner_uid=root_info.st_uid,
                )
                if fd_has_extended_acl(fd):
                    die(f"workspace has a pre-existing ACL; remove it before prepare-workspace: {rel}")
            finally:
                os.close(fd)
    return proven_dependency_hardlinks


def assert_workspace_no_acls_or_nested_git(repo: str) -> None:
    try:
        _, root_fd, _ = open_workspace_root_fd(repo)
    except WorkspaceRootMismatch as exc:
        die(str(exc))
    try:
        assert_workspace_no_acls_or_nested_git_fd(root_fd)
    finally:
        os.close(root_fd)


def prepare_git_readonly(root_fd: int, operator: pwd.struct_passwd,
                         shared: grp.struct_group) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        git_fd = os.open(".git", flags, dir_fd=root_fd)
    except FileNotFoundError:
        return
    except OSError as exc:
        die(f"workspace .git must be a real in-repo directory: {exc}")
    try:
        workspace_dev = os.fstat(root_fd).st_dev
        count = 0
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=git_fd,
        ):
            rel_dir = ".git" if current == "." else os.path.join(".git", current.removeprefix("./"))
            count += len(dirs) + len(files)
            if count > MAX_TREE_ENTRIES:
                die(f"workspace .git exceeds the {MAX_TREE_ENTRIES}-entry permission bound")
            info = os.fstat(dir_fd)
            if not stat.S_ISDIR(info.st_mode):
                die(f"workspace .git contains a non-directory component: {rel_dir}")
            if info.st_dev != workspace_dev or info.st_uid != operator.pw_uid:
                die(f"workspace .git leaves the operator-owned filesystem boundary: {rel_dir}")
            if fd_has_extended_acl(dir_fd):
                die(f"workspace .git directory has an unexpected ACL: {rel_dir}")
            os.fchown(dir_fd, operator.pw_uid, shared.gr_gid)
            # setgid makes future operator-created refs/objects inherit the
            # shared runtime group while Git metadata remains group-read-only.
            os.fchmod(dir_fd, 0o2750)
            for name in dirs:
                try:
                    child_fd = os.open(name, flags, dir_fd=dir_fd)
                except OSError as exc:
                    die(f"workspace .git contains a symlink/special directory: "
                        f"{os.path.join(rel_dir, name)} ({exc})")
                os.close(child_fd)
            for name in files:
                rel = os.path.join(rel_dir, name)
                if rel == os.path.join(".git", "objects", "info", "alternates"):
                    die("workspace .git object alternates are unsupported")
                try:
                    file_fd = os.open(
                        name, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=dir_fd,
                    )
                except OSError as exc:
                    die(f"workspace .git contains a symlink/special file: {rel} ({exc})")
                try:
                    file_info = os.fstat(file_fd)
                    assert_single_link_regular_file(
                        file_info, rel,
                        expected_dev=workspace_dev, expected_uid=operator.pw_uid,
                    )
                    if fd_has_extended_acl(file_fd):
                        die(f"workspace .git file has an unexpected ACL: {rel}")
                    os.fchown(file_fd, operator.pw_uid, shared.gr_gid)
                    os.fchmod(file_fd, 0o750 if file_info.st_mode & 0o100 else 0o640)
                finally:
                    os.close(file_fd)
    finally:
        os.close(git_fd)


def verify_git_readonly(root_fd: int, operator: pwd.struct_passwd,
                        shared: grp.struct_group) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        git_fd = os.open(".git", flags, dir_fd=root_fd)
    except FileNotFoundError:
        return
    except OSError as exc:
        die(f"workspace .git must remain a real in-repo directory: {exc}")
    try:
        workspace_dev = os.fstat(root_fd).st_dev
        count = 0
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=git_fd,
        ):
            rel_dir = ".git" if current == "." else os.path.join(".git", current.removeprefix("./"))
            count += len(dirs) + len(files)
            if count > MAX_TREE_ENTRIES:
                die(f"workspace .git exceeds the {MAX_TREE_ENTRIES}-entry verification bound")
            info = os.fstat(dir_fd)
            mode = stat.S_IMODE(info.st_mode)
            if info.st_dev != workspace_dev or info.st_uid != operator.pw_uid:
                die(f"workspace .git leaves the operator-owned filesystem boundary: {rel_dir}")
            if fd_has_extended_acl(dir_fd):
                die(f"workspace .git directory has an unexpected ACL: {rel_dir}")
            # macOS preserves the parent gid but does not propagate setgid to
            # newly created child directories. Require setgid on the .git
            # root and the complete service-read/no-write invariant below it.
            required = 0o2750 if rel_dir == ".git" else 0o0750
            if (info.st_uid != operator.pw_uid or info.st_gid != shared.gr_gid
                    or mode & required != required or mode & 0o022):
                die(f"workspace .git directory permission drift: {rel_dir}")
            for name in dirs:
                try:
                    child_fd = os.open(name, flags, dir_fd=dir_fd)
                except OSError as exc:
                    die(f"workspace .git contains a symlink/special directory: "
                        f"{os.path.join(rel_dir, name)} ({exc})")
                os.close(child_fd)
            for name in files:
                rel = os.path.join(rel_dir, name)
                if rel == os.path.join(".git", "objects", "info", "alternates"):
                    die("workspace .git object alternates are unsupported")
                try:
                    file_fd = os.open(
                        name, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=dir_fd,
                    )
                except OSError as exc:
                    die(f"workspace .git contains a symlink/special file: {rel} ({exc})")
                try:
                    file_info = os.fstat(file_fd)
                    mode = stat.S_IMODE(file_info.st_mode)
                    assert_single_link_regular_file(
                        file_info, rel,
                        expected_dev=workspace_dev, expected_uid=operator.pw_uid,
                    )
                    if fd_has_extended_acl(file_fd):
                        die(f"workspace .git file has an unexpected ACL: {rel}")
                    group_exec = bool(mode & 0o010)
                    owner_exec = bool(mode & 0o100)
                    if (file_info.st_uid != operator.pw_uid
                            or file_info.st_gid != shared.gr_gid
                            or mode & 0o440 != 0o440 or mode & 0o022
                            or group_exec != owner_exec):
                        die(f"workspace .git file permission drift: {rel}")
                finally:
                    os.close(file_fd)
    finally:
        os.close(git_fd)


def prepare_workspace(
    repo: str,
    operator: pwd.struct_passwd,
    shared: grp.struct_group,
    *,
    expected_identity: tuple[int, int] | None = None,
    runtime_uid: int | None = None,
) -> None:
    try:
        repo, root_fd, root_info = open_workspace_root_fd(
            repo, expected_identity=expected_identity,
        )
    except WorkspaceRootMismatch as exc:
        die(str(exc))
    try:
        # Scan and mutate through this same identity-checked descriptor.
        managed_uids = {operator.pw_uid}
        if runtime_uid is not None:
            managed_uids.add(runtime_uid)
        proven_dependency_hardlinks = assert_workspace_no_acls_or_nested_git_fd(
            root_fd, allowed_uids=managed_uids,
        )
        if root_info.st_uid != operator.pw_uid:
            die("workspace root must be owned by the attested operator")
        count = 0
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
        ):
            rel_dir = "" if current == "." else current.removeprefix("./")
            opaque = detach_opaque_operator_subtrees(rel_dir, dirs, files, dir_fd)
            try:
                for opaque_rel, fd in opaque:
                    info = os.fstat(fd)
                    if info.st_uid != operator.pw_uid:
                        die(f"opaque operator subtree has wrong uid: {opaque_rel}")
                    os.fchown(fd, operator.pw_uid, operator.pw_gid)
                    os.fchmod(fd, 0o700)
            finally:
                for _opaque_rel, fd in opaque:
                    os.close(fd)
            if not rel_dir:
                dirs[:] = [name for name in dirs if name != ".git"]
            count += len(dirs) + len(files)
            if count > MAX_TREE_ENTRIES:
                die(f"workspace exceeds the {MAX_TREE_ENTRIES}-entry permission bound")
            current_info = os.fstat(dir_fd)
            if fd_has_extended_acl(dir_fd):
                die(f"workspace directory has an unexpected ACL: {rel_dir or '.'}")
            mode = stat.S_IMODE(current_info.st_mode) & 0o777
            if rel_dir and sensitive_path(rel_dir):
                os.fchown(dir_fd, operator.pw_uid, operator.pw_gid)
                os.fchmod(dir_fd, 0o700)
            elif rel_dir and operator_owned(rel_dir):
                os.fchown(dir_fd, -1, shared.gr_gid)
                os.fchmod(dir_fd, (mode | 0o050) & ~0o022)
            else:
                os.fchown(dir_fd, -1, shared.gr_gid)
                os.fchmod(dir_fd, (mode | 0o2770) & ~0o002)
            for name in files:
                rel_file = os.path.join(rel_dir, name) if rel_dir else name
                try:
                    file_fd = os.open(
                        name, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=dir_fd,
                    )
                except OSError as exc:
                    if exc.errno in (errno.ELOOP, errno.ENOENT):
                        continue
                    raise
                try:
                    file_info = os.fstat(file_fd)
                    immutable_dependency_hardlink = assert_single_link_regular_file(
                        file_info, rel_file,
                        expected_dev=root_info.st_dev, allowed_uids=managed_uids,
                        proven_dependency_hardlinks=proven_dependency_hardlinks,
                        hardlink_owner_uid=operator.pw_uid,
                    )
                    if fd_has_extended_acl(file_fd):
                        die(f"workspace file has an unexpected ACL: {rel_file}")
                    if immutable_dependency_hardlink:
                        continue
                    if sensitive_path(rel_file):
                        os.fchown(file_fd, operator.pw_uid, operator.pw_gid)
                        os.fchmod(file_fd, 0o700 if file_info.st_mode & 0o100 else 0o600)
                    elif operator_owned(rel_file):
                        os.fchown(file_fd, -1, shared.gr_gid)
                        required = 0o040 | (0o010 if file_info.st_mode & 0o100 else 0)
                        os.fchmod(file_fd, ((stat.S_IMODE(file_info.st_mode) & 0o777) | required) & ~0o022)
                    else:
                        os.fchown(file_fd, -1, shared.gr_gid)
                        ordinary_mode = stat.S_IMODE(file_info.st_mode) & 0o777
                        group_exec = 0o010 if ordinary_mode & 0o100 else 0
                        os.fchmod(file_fd, (ordinary_mode | 0o660 | group_exec) & ~0o002)
                finally:
                    os.close(file_fd)

        prepare_git_readonly(root_fd, operator, shared)
    finally:
        os.close(root_fd)


def verify_workspace(
    repo: str,
    operator: pwd.struct_passwd,
    shared: grp.struct_group,
    *,
    expected_identity: tuple[int, int] | None = None,
    runtime_uid: int | None = None,
) -> None:
    try:
        repo, root_fd, root = open_workspace_root_fd(
            repo, expected_identity=expected_identity,
        )
    except WorkspaceRootMismatch as exc:
        die(str(exc))
    try:
        managed_uids = {operator.pw_uid}
        if runtime_uid is not None:
            managed_uids.add(runtime_uid)
        proven_dependency_hardlinks = assert_workspace_no_acls_or_nested_git_fd(
            root_fd, allowed_uids=managed_uids,
        )
        if fd_has_extended_acl(root_fd):
            die("workspace root has an unexpected ACL")
        if (root.st_uid != operator.pw_uid or root.st_gid != shared.gr_gid
                or root.st_mode & 0o2070 != 0o2070 or root.st_mode & 0o002):
            die("workspace root is not operator-owned/shared-group-rwx/setgid")
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
        ):
            rel_dir = "" if current == "." else current.removeprefix("./")
            opaque = detach_opaque_operator_subtrees(rel_dir, dirs, files, dir_fd)
            try:
                for opaque_rel, fd in opaque:
                    info = os.fstat(fd)
                    if (info.st_dev != root.st_dev
                            or info.st_uid != operator.pw_uid or info.st_gid != operator.pw_gid
                            or stat.S_IMODE(info.st_mode) != 0o700):
                        die(f"opaque operator subtree permission drift: {opaque_rel}")
            finally:
                for _opaque_rel, fd in opaque:
                    os.close(fd)
            if not rel_dir:
                dirs[:] = [name for name in dirs if name != ".git"]
            entries = [(name, True) for name in dirs] + [(name, False) for name in files]
            for name, is_dir in entries:
                rel = os.path.join(rel_dir, name) if rel_dir else name
                try:
                    before = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
                except FileNotFoundError:
                    # Operator-owned workspaces can change while they are
                    # being verified. An entry that has disappeared cannot
                    # extend the runtime account's authority.
                    continue
                # os.fwalk intentionally places a symlink-to-directory in
                # ``dirs`` even when follow_symlinks=False. On macOS,
                # O_DIRECTORY|O_NOFOLLOW then reports ENOTDIR rather than
                # ELOOP. Symlinks carry no permission metadata for us to
                # reconcile; the runtime boundary independently lstat-scans
                # them and Seatbelt constrains target resolution.
                if stat.S_ISLNK(before.st_mode):
                    try:
                        after = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    if ((after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
                            or not stat.S_ISLNK(after.st_mode)):
                        die(f"workspace symlink changed during verification: {rel}")
                    continue
                if is_dir:
                    if not stat.S_ISDIR(before.st_mode):
                        die(f"workspace path changed type during verification: {rel}")
                elif not stat.S_ISREG(before.st_mode):
                    die(f"workspace contains unsupported special file: {rel}")
                entry_flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
                if is_dir:
                    entry_flags |= getattr(os, "O_DIRECTORY", 0)
                try:
                    fd = os.open(name, entry_flags, dir_fd=dir_fd)
                except OSError as exc:
                    die(f"workspace path changed while opening during verification: {rel} ({exc})")
                try:
                    info = os.fstat(fd)
                    if ((info.st_dev, info.st_ino) != (before.st_dev, before.st_ino)
                            or stat.S_ISDIR(info.st_mode) != is_dir
                            or (not is_dir and not stat.S_ISREG(info.st_mode))):
                        die(f"workspace path changed while opening during verification: {rel}")
                    if info.st_dev != root.st_dev:
                        die(f"workspace crosses a filesystem boundary: {rel}")
                    if info.st_uid not in managed_uids:
                        die(f"workspace path has an unrecognized owner uid: {rel}")
                    immutable_dependency_hardlink = False
                    if not is_dir:
                        immutable_dependency_hardlink = assert_single_link_regular_file(
                            info, rel,
                            expected_dev=root.st_dev, allowed_uids=managed_uids,
                            proven_dependency_hardlinks=proven_dependency_hardlinks,
                            hardlink_owner_uid=operator.pw_uid,
                        )
                    if fd_has_extended_acl(fd):
                        die(f"workspace path has an unexpected ACL: {rel}")
                    if immutable_dependency_hardlink:
                        continue
                    if sensitive_path(rel):
                        expected = 0o700 if stat.S_ISDIR(info.st_mode) or info.st_mode & 0o100 else 0o600
                        if info.st_uid != operator.pw_uid or stat.S_IMODE(info.st_mode) != expected:
                            die(f"workspace sensitive-path permission drift: {rel}")
                        continue
                    if operator_owned(rel):
                        needed = 0o040 if stat.S_ISREG(info.st_mode) else 0o050
                        forbidden = 0o020
                        if info.st_uid != operator.pw_uid:
                            die(f"workspace operator-owned path has wrong uid: {rel}")
                    else:
                        needed = (0o060 | (0o010 if info.st_mode & 0o100 else 0)) \
                            if stat.S_ISREG(info.st_mode) else 0o2070
                        forbidden = 0
                    if (info.st_gid != shared.gr_gid or info.st_mode & needed != needed
                            or info.st_mode & 0o002 or info.st_mode & forbidden):
                        die(f"workspace shared-group permission drift: {rel}")
                finally:
                    os.close(fd)
        verify_git_readonly(root_fd, operator, shared)
    finally:
        os.close(root_fd)


def workspace_registry() -> dict[str, dict[str, object]]:
    try:
        info = os.lstat(WORKSPACE_REGISTRY)
    except FileNotFoundError:
        return {}
    info = validate_root_authority_file(
        WORKSPACE_REGISTRY, "workspace registry", exact_mode=0o600,
        max_bytes=64 * 1024 * 1024,
    )
    fd = os.open(WORKSPACE_REGISTRY, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns,
                opened.st_ctime_ns) != (
            info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
        ) or fd_has_extended_acl(fd):
            die("workspace registry changed while opening")
        raw = os.read(fd, 64 * 1024 * 1024 + 1)
    finally:
        os.close(fd)
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as exc:
        die(f"workspace registry is unreadable: {exc}")
    if (not isinstance(value, dict) or set(value) != {"schema", "workspaces"}
            or value["schema"] not in (
                "qofi-codex-workspaces/v1", "qofi-codex-workspaces/v2", WORKSPACE_SCHEMA,
            )
            or not isinstance(value["workspaces"], dict)
            or not all(isinstance(path, str) and os.path.isabs(path)
                       and isinstance(journal, dict) for path, journal in value["workspaces"].items())
            or len(value["workspaces"]) > 1024):
        die("workspace registry has the wrong schema")
    if value["schema"] == "qofi-codex-workspaces/v1":
        # A v1 journal has no inode binding and must never be replayed. Convert
        # it in memory to conservative-release records. The next lifecycle
        # write persists v2.
        converted: dict[str, dict[str, object]] = {}
        for path, entries in value["workspaces"].items():
            if (os.path.normpath(path) != path or path == "/" or not isinstance(entries, dict)
                    or len(entries) > MAX_TREE_ENTRIES + 1):
                die("legacy workspace registry contains an unsafe workspace path")
            for rel in entries:
                if (not isinstance(rel, str)
                        or (rel and (os.path.isabs(rel) or os.path.normpath(rel) != rel
                                     or rel.startswith("../") or rel == ".."))):
                    die("legacy workspace registry contains an unsafe relative path")
            identity = [0, 0]
            try:
                root = os.lstat(path)
                if stat.S_ISDIR(root.st_mode) and not stat.S_ISLNK(root.st_mode):
                    identity = [root.st_dev, root.st_ino]
            except FileNotFoundError:
                pass
            converted[path] = {
                "root": identity,
                "volume": None,
                "phase": "legacy",
                "entries": {
                    rel: {"before": None, "managed": None}
                    for rel in entries if isinstance(rel, str)
                },
            }
        return converted
    result: dict[str, dict[str, object]] = {}
    for path, source_journal in value["workspaces"].items():
        journal = dict(source_journal)
        if value["schema"] == "qofi-codex-workspaces/v2":
            journal["volume"] = None
        if (os.path.normpath(path) != path or path == "/"
                or set(journal) != {"root", "volume", "phase", "entries"}
                or journal["phase"] not in ("preparing", "prepared", "legacy")
                or not isinstance(journal["root"], list) or len(journal["root"]) != 2
                or any(type(item) is not int or item < 0 for item in journal["root"])
                or (journal["volume"] is not None
                    and (not isinstance(journal["volume"], str)
                         or not re.fullmatch(
                             r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",
                             journal["volume"],
                         )))
                or not isinstance(journal["entries"], dict)
                or len(journal["entries"]) > MAX_TREE_ENTRIES + 1):
            die("workspace registry contains an unsafe workspace journal")
        entries = journal["entries"]
        for rel, record in entries.items():
            if (not isinstance(rel, str)
                    or (rel and (os.path.isabs(rel) or os.path.normpath(rel) != rel
                                 or rel.startswith("../") or rel == ".."))
                    or not isinstance(record, dict) or set(record) != {"before", "managed"}):
                die("workspace registry contains an invalid path record")
            for saved in (record["before"], record["managed"]):
                if saved is None:
                    continue
                if (not isinstance(saved, list) or len(saved) != 6
                        or any(type(item) is not int or item < 0 for item in saved[:3])
                        or int(saved[2]) > 0o7777 or saved[3] not in ("d", "f")
                        or any(type(item) is not int or item < 0 for item in saved[4:])):
                    die("workspace registry contains an invalid inode-bound metadata record")
        root_record = entries.get("")
        root_saved = root_record.get("managed") or root_record.get("before") \
            if isinstance(root_record, dict) else None
        if ((journal["phase"] != "legacy" and not isinstance(root_saved, list))
                or (isinstance(root_saved, list) and root_saved[3] != "d")):
            die("workspace registry root metadata must describe a directory")
        result[path] = journal
    return result


def workspace_journal_sha256(journal: dict[str, object]) -> str:
    """Stable digest used to bind privileged recovery to one exact journal."""
    raw = json.dumps(
        journal, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
    ).encode("ascii")
    return hashlib.sha256(raw).hexdigest()


def capture_workspace_metadata(
    repo: str,
    *,
    expected_identity: tuple[int, int] | None = None,
) -> tuple[str, dict[str, list[object]]]:
    entries: dict[str, list[object]] = {}
    try:
        canonical, root_fd, _ = open_workspace_root_fd(
            repo, expected_identity=expected_identity,
        )
    except WorkspaceRootMismatch as exc:
        die(str(exc))
    try:
        proven_dependency_hardlinks = assert_workspace_inode_boundary_fd(root_fd)
        root_info = os.fstat(root_fd)
        root_dev = root_info.st_dev
        count = 0
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
        ):
            rel_dir = "" if current == "." else current.removeprefix("./")
            count += len(dirs) + len(files)
            if count > MAX_TREE_ENTRIES:
                die(f"workspace exceeds the {MAX_TREE_ENTRIES}-entry journal bound")
            opaque = detach_opaque_operator_subtrees(rel_dir, dirs, files, dir_fd)
            info = os.fstat(dir_fd)
            entries[rel_dir] = [
                info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), "d", info.st_dev, info.st_ino,
            ]
            try:
                for opaque_rel, fd in opaque:
                    item = os.fstat(fd)
                    entries[opaque_rel] = [
                        item.st_uid, item.st_gid, stat.S_IMODE(item.st_mode), "d",
                        item.st_dev, item.st_ino,
                    ]
            finally:
                for _opaque_rel, fd in opaque:
                    os.close(fd)
            for name in files:
                rel = os.path.join(rel_dir, name) if rel_dir else name
                try:
                    fd = os.open(
                        name, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=dir_fd,
                    )
                except OSError as exc:
                    if exc.errno in (errno.ELOOP, errno.ENOENT):
                        continue
                    raise
                try:
                    item = os.fstat(fd)
                    immutable_dependency_hardlink = assert_single_link_regular_file(
                        item, rel,
                        expected_dev=root_dev,
                        proven_dependency_hardlinks=proven_dependency_hardlinks,
                        hardlink_owner_uid=root_info.st_uid,
                    )
                    if immutable_dependency_hardlink:
                        continue
                    entries[rel] = [
                        item.st_uid, item.st_gid, stat.S_IMODE(item.st_mode), "f",
                        item.st_dev, item.st_ino,
                    ]
                finally:
                    os.close(fd)
    finally:
        os.close(root_fd)
    return canonical, entries


def write_workspace_registry(registry: dict[str, dict[str, object]]) -> None:
    atomic_write(WORKSPACE_REGISTRY, json.dumps({
        "schema": WORKSPACE_SCHEMA, "workspaces": registry,
    }, indent=2, sort_keys=True) + "\n", 0o600)


def reconcile_workspace_journal_identity(
    journal: dict[str, object],
    current_root: list[int],
    current_volume: str,
    current_root_metadata: list[object],
) -> bool:
    """Rebind a journal after a mount-session device number changes.

    New journals use volume UUID plus inode as their durable identity.  A v2
    journal has no volume UUID, so its one-time upgrade additionally requires
    the complete root metadata and inode to match, with only st_dev differing.
    """

    old_root = journal.get("root")
    old_volume = journal.get("volume")
    records = journal.get("entries")
    if (not isinstance(old_root, list) or len(old_root) != 2
            or not isinstance(records, dict)):
        return False
    old_dev, old_inode = map(int, old_root)
    new_dev, new_inode = current_root
    if old_inode != new_inode:
        return False
    if old_volume is not None and old_volume != current_volume:
        return False
    if old_dev != new_dev and old_volume is None:
        root_record = records.get("")
        root_saved = root_record.get("managed") or root_record.get("before") \
            if isinstance(root_record, dict) else None
        if (not isinstance(root_saved, list) or len(root_saved) != 6
                or root_saved[3] != "d"
                or [*root_saved[:4], root_saved[5]]
                != [*current_root_metadata[:4], current_root_metadata[5]]):
            return False
    if old_dev != new_dev:
        for record in records.values():
            if not isinstance(record, dict):
                return False
            for key in ("before", "managed"):
                saved = record.get(key)
                if saved is None:
                    continue
                if not isinstance(saved, list) or len(saved) != 6 or saved[4] != old_dev:
                    return False
        for record in records.values():
            assert isinstance(record, dict)
            for key in ("before", "managed"):
                saved = record.get(key)
                if isinstance(saved, list):
                    saved[4] = new_dev
        journal["root"] = current_root
    journal["volume"] = current_volume
    return True


def snapshot_workspace(
    repo: str,
    *,
    expected_identity: tuple[int, int] | None = None,
) -> None:
    registry = workspace_registry()
    canonical, entries = capture_workspace_metadata(
        repo, expected_identity=expected_identity,
    )
    current_root = [int(entries[""][4]), int(entries[""][5])]
    current_volume = workspace_volume_uuid_for_path(canonical, tuple(current_root))
    journal = registry.get(canonical)
    if journal is None:
        journal = {
            "root": current_root,
            "volume": current_volume,
            "phase": "preparing",
            "entries": {
                rel: {"before": saved, "managed": None}
                for rel, saved in entries.items()
            },
        }
        registry[canonical] = journal
    else:
        if not reconcile_workspace_journal_identity(
            journal, current_root, current_volume, entries[""],
        ):
            die("registered workspace root was replaced; release it before preparing this path")
        journal["phase"] = "preparing"
        records = journal["entries"]
        assert isinstance(records, dict)
        for rel, saved in entries.items():
            records.setdefault(rel, {"before": saved, "managed": None})
    write_workspace_registry(registry)


def finalize_workspace_snapshot(
    repo: str,
    *,
    expected_identity: tuple[int, int] | None = None,
) -> None:
    registry = workspace_registry()
    canonical, entries = capture_workspace_metadata(
        repo, expected_identity=expected_identity,
    )
    journal = registry.get(canonical)
    if journal is None:
        die("workspace journal disappeared before finalization")
    current_root = [int(entries[""][4]), int(entries[""][5])]
    current_volume = workspace_volume_uuid_for_path(canonical, tuple(current_root))
    if not reconcile_workspace_journal_identity(
        journal, current_root, current_volume, entries[""],
    ):
        die("workspace root changed during preparation")
    records = journal["entries"]
    assert isinstance(records, dict)
    for rel, saved in entries.items():
        record = records.setdefault(rel, {"before": None, "managed": None})
        assert isinstance(record, dict)
        record["managed"] = saved
    journal["phase"] = "prepared"
    write_workspace_registry(registry)


def cleanup_workspace(repo: str, operator: pwd.struct_passwd,
                      snapshot: dict[str, object] | dict[str, list[object]]) -> str:
    if "entries" in snapshot and "root" in snapshot:
        journal = snapshot
        journal_root = journal.get("root")
        if (not isinstance(journal_root, list) or len(journal_root) != 2
                or any(type(item) is not int for item in journal_root)):
            die("workspace cleanup received an invalid root identity")
        if journal_root == [0, 0]:
            return "replaced"
        expected_identity = None
    else:
        expected_identity = None
        journal = {}
    try:
        _, root_fd, root_info = open_workspace_root_fd(
            repo, expected_identity=expected_identity,
        )
    except WorkspaceRootMismatch as exc:
        return "absent" if "absent" in str(exc) else "replaced"
    if "entries" in snapshot and "root" in snapshot:
        current_root = [root_info.st_dev, root_info.st_ino]
        current_metadata: list[object] = [
            root_info.st_uid, root_info.st_gid, stat.S_IMODE(root_info.st_mode),
            "d", root_info.st_dev, root_info.st_ino,
        ]
        if not reconcile_workspace_journal_identity(
            journal, current_root, workspace_volume_uuid_fd(root_fd), current_metadata,
        ):
            os.close(root_fd)
            return "replaced"
    if "entries" not in snapshot or "root" not in snapshot:
        # In-memory compatibility for an interrupted pre-v2 transaction. Bind
        # saved records to the descriptor we actually opened.
        old = snapshot
        journal = {
            "root": [root_info.st_dev, root_info.st_ino],
            "phase": "legacy",
            "entries": {
                rel: {
                    "before": ([*saved, 0, 0] if len(saved) == 4 else saved),
                    "managed": None,
                }
                for rel, saved in old.items()
            },
        }
    records = journal.get("entries")
    if not isinstance(records, dict):
        os.close(root_fd)
        die("workspace cleanup received an invalid journal")

    def release_fd(fd: int, rel: str, kind: str) -> None:
        info = os.fstat(fd)
        if kind == "d" and not stat.S_ISDIR(info.st_mode):
            return
        if kind == "f" and not stat.S_ISREG(info.st_mode):
            return
        if kind == "f" and assert_single_link_regular_file(
            info, rel,
            expected_dev=root_info.st_dev,
            proven_dependency_hardlinks=proven_dependency_hardlinks,
            hardlink_owner_uid=operator.pw_uid,
        ):
            return
        current = [
            info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), kind,
            info.st_dev, info.st_ino,
        ]
        record = records.get(rel)
        before = record.get("before") if isinstance(record, dict) else None
        managed = record.get("managed") if isinstance(record, dict) else None
        # Saved metadata is eligible only when both identity and the complete
        # managed metadata are unchanged. Any chmod/chown/replacement selects
        # current owner bits and can therefore never reopen a tightened mode.
        if (isinstance(before, list) and len(before) == 6
                and isinstance(managed, list) and managed == current
                and before[3] == kind
                and before[4:] == current[4:]):
            owner_mode = int(before[2]) & 0o700
        else:
            owner_mode = stat.S_IMODE(info.st_mode) & 0o700
        os.fchown(fd, operator.pw_uid, operator.pw_gid)
        os.fchmod(fd, owner_mode)

    try:
        # Release is privileged too: a mount or hard link introduced after
        # preparation must not redirect chown/chmod outside the journaled tree.
        proven_dependency_hardlinks = assert_workspace_inode_boundary_fd(root_fd)
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
        ):
            rel_dir = "" if current == "." else current.removeprefix("./")
            opaque = detach_opaque_operator_subtrees(rel_dir, dirs, files, dir_fd)
            for name in files:
                rel = os.path.join(rel_dir, name) if rel_dir else name
                try:
                    fd = os.open(
                        name, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=dir_fd,
                    )
                except OSError as exc:
                    if exc.errno in (errno.ELOOP, errno.ENOENT):
                        continue
                    raise
                try:
                    info = os.fstat(fd)
                    if stat.S_ISREG(info.st_mode):
                        release_fd(fd, rel, "f")
                finally:
                    os.close(fd)
            try:
                for opaque_rel, fd in opaque:
                    release_fd(fd, opaque_rel, "d")
            finally:
                for _opaque_rel, fd in opaque:
                    os.close(fd)
            release_fd(dir_fd, rel_dir, "d")
    finally:
        os.close(root_fd)
    return "released"


def expected_prepared_metadata(
    rel: str,
    saved: list[object],
    operator: pwd.struct_passwd,
    shared: grp.struct_group,
) -> tuple[int, int, int, str]:
    uid, _gid, mode = map(int, saved[:3])
    mode &= 0o777
    kind = str(saved[3])
    if rel == ".git" or rel.startswith(f".git{os.sep}"):
        return (
            operator.pw_uid,
            shared.gr_gid,
            0o2750 if kind == "d" else (0o750 if mode & 0o100 else 0o640),
            kind,
        )
    if rel and sensitive_path(rel):
        return operator.pw_uid, operator.pw_gid, (0o700 if kind == "d" or mode & 0o100 else 0o600), kind
    if rel and operator_owned(rel):
        if kind == "d":
            prepared_mode = (mode | 0o050) & ~0o022
        else:
            prepared_mode = (mode | 0o040 | (0o010 if mode & 0o100 else 0)) & ~0o022
        return uid, shared.gr_gid, prepared_mode, kind
    if kind == "d":
        prepared_mode = (mode | 0o2770) & ~0o002
    else:
        prepared_mode = (mode | 0o660 | (0o010 if mode & 0o100 else 0)) & ~0o002
    return uid, shared.gr_gid, prepared_mode, kind


def rollback_workspace(
    repo: str,
    operator: pwd.struct_passwd,
    shared: grp.struct_group,
    before: dict[str, list[object]],
) -> str:
    """Restore only unchanged inodes still carrying our exact prepared metadata."""

    root_before = before.get("")
    if not root_before or len(root_before) != 6:
        return "replaced"
    try:
        _, root_fd, root_info = open_workspace_root_fd(
            repo, expected_identity=(int(root_before[4]), int(root_before[5])),
        )
    except WorkspaceRootMismatch as exc:
        return "absent-or-replaced" if "absent" in str(exc) else "replaced"

    def rollback_fd(fd: int, rel: str, kind: str) -> None:
        info = os.fstat(fd)
        if kind == "f" and assert_single_link_regular_file(
            info, rel,
            expected_dev=root_info.st_dev,
            proven_dependency_hardlinks=proven_dependency_hardlinks,
            hardlink_owner_uid=operator.pw_uid,
        ):
            return
        saved = before.get(rel)
        if saved and len(saved) == 6 and saved[3] == kind and saved[4:] == [info.st_dev, info.st_ino]:
            expected = expected_prepared_metadata(rel, saved, operator, shared)
            current = (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), kind)
            if current == expected:
                os.fchown(fd, int(saved[0]), int(saved[1]))
                os.fchmod(fd, int(saved[2]))
                return
        os.fchown(fd, operator.pw_uid, operator.pw_gid)
        os.fchmod(fd, stat.S_IMODE(info.st_mode) & 0o700)

    try:
        proven_dependency_hardlinks = assert_workspace_inode_boundary_fd(root_fd)
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
        ):
            rel_dir = "" if current == "." else current.removeprefix("./")
            opaque = detach_opaque_operator_subtrees(rel_dir, dirs, files, dir_fd)
            for name in files:
                rel = os.path.join(rel_dir, name) if rel_dir else name
                try:
                    fd = os.open(
                        name, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=dir_fd,
                    )
                except OSError as exc:
                    if exc.errno in (errno.ELOOP, errno.ENOENT, errno.ENXIO):
                        continue
                    raise
                try:
                    if stat.S_ISREG(os.fstat(fd).st_mode):
                        rollback_fd(fd, rel, "f")
                finally:
                    os.close(fd)
            try:
                for opaque_rel, fd in opaque:
                    rollback_fd(fd, opaque_rel, "d")
            finally:
                for _opaque_rel, fd in opaque:
                    os.close(fd)
            rollback_fd(dir_fd, rel_dir, "d")
    finally:
        os.close(root_fd)
    return "rolled-back"


def unregister_workspace(repo: str) -> bool:
    registry = workspace_registry()
    if repo not in registry:
        return False
    del registry[repo]
    if registry:
        write_workspace_registry(registry)
    else:
        try:
            os.unlink(WORKSPACE_REGISTRY)
        except FileNotFoundError:
            pass
    return True


def _dedicated_auth_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
        info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    )


def open_dedicated_auth(
    auth: str,
    runtime: pwd.struct_passwd,
    *,
    profile: str = DEFAULT_PROFILE,
    missing_error: str,
    require_hardened_mode: bool,
) -> int:
    """Root-only descriptor binding for isolated provider-auth hardening."""

    before = dedicated_auth_info(
        auth,
        runtime,
        profile=profile,
        missing_error=missing_error,
        require_hardened_mode=require_hardened_mode,
    )
    parent = os.path.dirname(auth)
    parent_before = os.lstat(parent)
    parent_flags = (
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        parent_fd = os.open(parent, parent_flags)
    except OSError as exc:
        die(f"dedicated auth.json parent changed while opening: {exc}")
    try:
        parent_opened = os.fstat(parent_fd)
        if (_dedicated_auth_identity(parent_opened)
                != _dedicated_auth_identity(parent_before)):
            die("dedicated auth.json parent changed while opening")
        try:
            rebound = os.stat("auth.json", dir_fd=parent_fd, follow_symlinks=False)
            fd = os.open(
                "auth.json",
                os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_fd,
            )
        except OSError as exc:
            die(f"dedicated auth.json changed while opening: {exc}")
        try:
            opened = os.fstat(fd)
            parent_after = os.lstat(parent)
            if (_dedicated_auth_identity(rebound) != _dedicated_auth_identity(before)
                    or _dedicated_auth_identity(opened) != _dedicated_auth_identity(before)
                    or _dedicated_auth_identity(parent_after)
                    != _dedicated_auth_identity(parent_before)
                    or (require_hardened_mode and fd_has_extended_acl(fd))):
                die("dedicated auth.json changed while opening or has an unexpected ACL")
        except BaseException:
            os.close(fd)
            raise
        return fd
    finally:
        os.close(parent_fd)


def dedicated_auth_info(
    auth: str,
    runtime: pwd.struct_passwd,
    *,
    profile: str = DEFAULT_PROFILE,
    missing_error: str,
    require_hardened_mode: bool,
) -> os.stat_result:
    """Operator-safe auth metadata proof; never opens or reads the credential."""

    codex_home = profile_codex_home(runtime.pw_dir, profile)
    expected = os.path.join(codex_home, "auth.json")
    if auth != expected or not os.path.isabs(auth) or os.path.normpath(auth) != auth:
        die("dedicated auth.json path is outside the runtime account home")
    try:
        os.lstat(auth)
    except FileNotFoundError:
        die(missing_error)
    except OSError as exc:
        die(f"could not inspect dedicated auth.json: {exc}")
    profile_components = [codex_home]
    if profile != DEFAULT_PROFILE:
        profile_components.insert(0, os.path.join(runtime.pw_dir, ".codex-profiles"))
    for component in profile_components:
        try:
            component_info = os.lstat(component)
        except OSError as exc:
            die(f"could not inspect dedicated profile home: {exc}")
        if (not stat.S_ISDIR(component_info.st_mode)
                or stat.S_ISLNK(component_info.st_mode)
                or component_info.st_uid != runtime.pw_uid
                or component_info.st_gid != runtime.pw_gid
                or stat.S_IMODE(component_info.st_mode) != 0o700):
            die("dedicated profile home is not runtime-owned real mode 0700")
    parent = os.path.dirname(auth)
    try:
        parent_before = os.lstat(parent)
        before = os.lstat(auth)
    except FileNotFoundError:
        die(missing_error)
    except OSError as exc:
        die(f"could not inspect dedicated auth.json: {exc}")
    if (not stat.S_ISDIR(parent_before.st_mode) or stat.S_ISLNK(parent_before.st_mode)
            or parent_before.st_uid != runtime.pw_uid
            or stat.S_IMODE(parent_before.st_mode) != 0o700):
        die("dedicated auth.json parent is not runtime-owned mode 0700")
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != runtime.pw_uid or before.st_gid != runtime.pw_gid
            or before.st_nlink != 1 or not 2 <= before.st_size <= MAX_AUTH_JSON
            or before.st_dev != parent_before.st_dev):
        die("dedicated auth.json is not a runtime-owned regular file")
    if require_hardened_mode and stat.S_IMODE(before.st_mode) != 0o600:
        die("dedicated auth.json is not runtime-owned mode 0600")
    try:
        after = os.lstat(auth)
        parent_after = os.lstat(parent)
    except OSError as exc:
        die(f"dedicated auth.json changed while inspecting metadata: {exc}")
    if (_dedicated_auth_identity(after) != _dedicated_auth_identity(before)
            or _dedicated_auth_identity(parent_after)
            != _dedicated_auth_identity(parent_before)):
        die("dedicated auth.json changed while inspecting metadata")
    return after


def verify_authority(
    repo: str | None, profile: str = DEFAULT_PROFILE,
) -> None:
    value = load_attestation()
    if set(value) != EXACT_KEYS:
        die("runtime attestation predates Fable reviewer authority; rerun install")
    if value["runner_path"] != RUNNER:
        die("attested runner path is not fixed")
    if (value["node_path"] != os.path.join(TOOLCHAIN, "node")
            or value["codex_script"] != os.path.join(TOOLCHAIN, "codex", "bin", "codex.js")):
        die("attested Node/Codex paths are outside the fixed root toolchain")
    for path_key, hash_key in (
        ("runner_path", "runner_sha256"), ("node_path", "node_sha256"),
        ("codex_script", "codex_script_sha256"),
        ("fable_reviewer_path", "fable_reviewer_sha256"),
        ("fable_doctrine_path", "fable_doctrine_sha256"),
        ("fable_schema_path", "fable_schema_sha256"),
    ):
        path = str(value[path_key])
        info = os.lstat(path)
        if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != ROOT_AUTHORITY_UID or info.st_mode & 0o022
                or sha256(path) != value[hash_key]):
            die(f"root authority drift: {path_key}")
    try:
        lifecycle_info = os.lstat(LIFECYCLE)
    except FileNotFoundError:
        die("fixed root lifecycle helper is absent; rerun install")
    if (not stat.S_ISREG(lifecycle_info.st_mode) or stat.S_ISLNK(lifecycle_info.st_mode)
            or lifecycle_info.st_uid != ROOT_AUTHORITY_UID or lifecycle_info.st_mode & 0o022
            or not lifecycle_info.st_mode & 0o111):
        die("fixed root lifecycle helper is absent or unsafe")
    validate_root_authority_file(
        FABLE_REVIEWER, "fixed Fable reviewer shim", executable=True,
        exact_mode=0o755, max_bytes=2 * 1024 * 1024,
    )
    validate_root_authority_file(
        FABLE_DOCTRINE, "fixed Fable reviewer doctrine",
        exact_mode=0o644, max_bytes=MAX_REVIEWER_DOCTRINE_BYTES,
    )
    validate_root_authority_file(
        FABLE_SCHEMA, "fixed adversarial review schema",
        exact_mode=0o644, max_bytes=MAX_REVIEWER_DOCTRINE_BYTES,
    )
    operator = pwd.getpwuid(int(value["operator_uid"]))
    if os.geteuid() != operator.pw_uid or os.getuid() != operator.pw_uid:
        die("verify must run directly as the attested operator (do not sudo verify)")
    exact_operator, runtime, shared = exact_runtime_identity(value)
    if exact_operator.pw_uid != operator.pw_uid:
        die("attested operator identity changed during verification")
    if not os.path.lexists(MANAGER_AUTHORITY):
        die("manager authority is absent; installation is incomplete — rerun install")
    manager_authority = validate_manager_authority(operator, value)
    if value["codex_home"] != os.path.join(runtime.pw_dir, ".codex"):
        die("attested codex_home is not the default runtime profile home")
    codex_home = profile_codex_home(str(value["runtime_home"]), profile)
    auth = os.path.join(codex_home, "auth.json")
    dedicated_auth_info(
        auth,
        runtime,
        profile=profile,
        missing_error=(
            "dedicated auth.json is absent; run bin/swarm-codex-runtime.sh login"
            + ("" if profile == DEFAULT_PROFILE else f" --profile {profile}")
            + ", then retry verify"
        ),
        require_hardened_mode=True,
    )
    # The operator has search/read-attribute ACLs, never read access to the
    # hidden user's private config.  Bind stable metadata and the deterministic
    # render here; the fixed root runner below proves exact private bytes/mode/
    # ACL as part of its complete runtime authority check.
    verify_runtime_codex_config_metadata(runtime, profile)
    verify_codex_config_render_hash(operator.pw_uid, value["codex_config_sha256"])
    runtime_paths = [
        str(value["runtime_home"]), codex_home,
        os.path.join(str(value["runtime_home"]), ".tmp"),
    ]
    if profile != DEFAULT_PROFILE:
        runtime_paths.append(os.path.join(str(value["runtime_home"]), ".codex-profiles"))
    for path in runtime_paths:
        verify_runtime_acl(path, operator.pw_name)
    verify_runtime_acl(auth)
    observed = run(
        ["/bin/launchctl", "asuser", str(operator.pw_uid), "/bin/launchctl",
         "getenv", str(value["launchd_canary_name"])],
        capture=True, check=False,
    ).stdout.strip()
    if hashlib.sha256(observed.encode()).hexdigest() != value["launchd_canary_sha256"]:
        die("operator launchd canary is absent or changed; rerun install to refresh it")
    prove_runner_sudo_verify(operator, profile)
    prove_fable_reviewer_sudo_lane(operator, "verify")
    bootstrap = subprocess.run(
        ["/usr/bin/sudo", "-n", "--", RUNNER,
         *([] if profile == DEFAULT_PROFILE else ["--profile", profile]),
         "--parent-pid", str(os.getpid()), "--", "--version"],
        text=True, capture_output=True,
        env={"HOME": operator.pw_dir, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )
    if (bootstrap.returncode != 0
            or not re.fullmatch(r"(?:codex-cli|codex) 0\.144\.[1-9][0-9]*(?:[-+][0-9A-Za-z.-]+)?",
                                bootstrap.stdout.strip())):
        die(f"exact hidden-account runner/bootstrap proof failed: {(bootstrap.stderr or bootstrap.stdout).strip()}")
    login_status = subprocess.run(
        ["/usr/bin/sudo", "-n", "--", RUNNER,
         *([] if profile == DEFAULT_PROFILE else ["--profile", profile]),
         "--parent-pid", str(os.getpid()), "--",
         "login",
         "-c", 'forced_login_method="chatgpt"',
         "-c", 'cli_auth_credentials_store="file"',
         "status"],
        text=True, capture_output=True,
        env={"HOME": operator.pw_dir, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )
    login_output = (login_status.stdout + login_status.stderr).strip()
    if login_status.returncode != 0 or login_output != "Logged in using ChatGPT":
        die(f"dedicated runner login status is not exact ChatGPT auth: {login_output}")
    bun = os.path.join(TOOLCHAIN, "bin", "bun")
    bun_info = os.lstat(bun)
    if (not stat.S_ISREG(bun_info.st_mode) or stat.S_ISLNK(bun_info.st_mode)
            or bun_info.st_uid != ROOT_AUTHORITY_UID or bun_info.st_mode & 0o022
            or not bun_info.st_mode & 0o111):
        die("root-installed Bun authority is absent or unsafe")
    pnpm_wrapper = os.path.join(TOOLCHAIN, "bin", "pnpm")
    pnpm_installed = os.path.lexists(pnpm_wrapper)
    required_pnpm_version = requested_pnpm_version(repo) if repo else None
    if required_pnpm_version is not None and not pnpm_installed:
        die(f"root-installed pnpm@{required_pnpm_version} is absent; rerun install")
    tool_names = ["bun", "node", "npm", "npx"]
    if pnpm_installed:
        tool_names.append("pnpm")
    tool_probe = subprocess.run(
        ["/usr/bin/sudo", "-n", "--", RUNNER, "--check-tools",
         *([] if profile == DEFAULT_PROFILE else ["--profile", profile]), "--parent-pid",
         str(os.getpid()), "--", *tool_names],
        text=True, capture_output=True,
        env={"HOME": operator.pw_dir, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )
    expected_tool_rows = [
        f"bun\t{bun}",
        f"node\t{os.path.join(TOOLCHAIN, 'node')}",
        f"npm\t{os.path.join(TOOLCHAIN, 'bin', 'npm')}",
        f"npx\t{os.path.join(TOOLCHAIN, 'bin', 'npx')}",
    ]
    if pnpm_installed:
        expected_tool_rows.append(f"pnpm\t{pnpm_wrapper}")
    expected_tools = "\n".join(expected_tool_rows)
    if tool_probe.returncode != 0 or tool_probe.stdout.strip() != expected_tools:
        die(f"service-uid root toolchain probe failed: "
            f"{(tool_probe.stderr or tool_probe.stdout).strip()}")
    for name, cli in (("npm", "npm-cli.js"), ("npx", "npx-cli.js")):
        wrapper = os.path.join(TOOLCHAIN, "bin", name)
        expected = (
            f'#!/bin/sh\nexec "{os.path.join(TOOLCHAIN, "node")}" '
            f'"{os.path.join(TOOLCHAIN, "npm", "bin", cli)}" "$@"\n'
        )
        info = os.lstat(wrapper)
        if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != ROOT_AUTHORITY_UID or info.st_mode & 0o022
                or not info.st_mode & 0o111
                or info.st_size != len(expected.encode())
                or Path(wrapper).read_text(encoding="utf-8") != expected):
            die(f"root-installed {name} wrapper authority is absent or changed")
    if pnpm_installed:
        expected = (
            f'#!/bin/sh\nexec "{os.path.join(TOOLCHAIN, "node")}" '
            f'"{os.path.join(TOOLCHAIN, "pnpm", "bin", "pnpm.cjs")}" "$@"\n'
        )
        info = os.lstat(pnpm_wrapper)
        if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != ROOT_AUTHORITY_UID or info.st_mode & 0o022
                or not info.st_mode & 0o111
                or info.st_size != len(expected.encode())
                or Path(pnpm_wrapper).read_text(encoding="utf-8") != expected):
            die("root-installed pnpm wrapper authority is absent or changed")
    if repo:
        swarm_home = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
        if manager_authority.get("swarm_home") != swarm_home:
            die("installed manager swarm home differs from the current trusted source")
        source_lifecycle = os.path.join(swarm_home, "bin", "swarm-codex-runtime.py")
        source_runner = os.path.join(swarm_home, "bin", "qofi-codex-runner")
        source_manager_launcher = os.path.join(swarm_home, "bin", "qofi-codex-manager-launcher")
        source_fable_reviewer = os.path.join(swarm_home, "bin", "qofi-fable-reviewer-mcp.py")
        source_fable_doctrine = os.path.join(
            swarm_home, "templates", "_base", "codex", "fable-reviewer-doctrine.md",
        )
        source_fable_schema = os.path.join(
            swarm_home, "templates", "_base", "codex", "adversarial-review-output.schema.json",
        )
        validate_codex_config_template_source(swarm_home, operator.pw_uid)
        validate_source(source_lifecycle, operator.pw_uid, "repository lifecycle helper")
        validate_source(source_runner, operator.pw_uid, "repository runner")
        validate_source(
            source_manager_launcher, operator.pw_uid, "repository manager launcher",
            executable=True,
        )
        source_node, source_script = resolve_operator_codex(operator, repo, swarm_home)
        source_bun = resolve_operator_bun(operator)
        source_pairs = [
            (LIFECYCLE, source_lifecycle, "lifecycle helper"),
            (RUNNER, source_runner, "runner"),
            (MANAGER_LAUNCHER, source_manager_launcher, "manager launcher"),
            (FABLE_REVIEWER, source_fable_reviewer, "Fable reviewer shim"),
            (FABLE_DOCTRINE, source_fable_doctrine, "Fable reviewer doctrine"),
            (FABLE_SCHEMA, source_fable_schema, "adversarial review schema"),
            (str(value["node_path"]), source_node, "Node"),
            (str(value["codex_script"]), source_script, "Codex script"),
            (bun, source_bun, "Bun"),
        ]
        pnpm_plan = resolve_operator_pnpm(operator, repo)
        if pnpm_plan is not None:
            source_pnpm, source_pnpm_version = pnpm_plan
            if required_pnpm_version != source_pnpm_version:
                die("project pnpm pin changed during verification")
            source_pairs.extend((
                (os.path.join(TOOLCHAIN, "pnpm", "package.json"),
                 os.path.join(source_pnpm, "package.json"), "pnpm manifest"),
                (os.path.join(TOOLCHAIN, "pnpm", "bin", "pnpm.cjs"),
                 os.path.join(source_pnpm, "bin", "pnpm.cjs"), "pnpm entrypoint"),
            ))
        for installed, source, label in source_pairs:
            if sha256(installed) != sha256(source):
                die(f"installed {label} differs from the currently trusted operator source; rerun install")
        if trusted_source_sha256(
            os.path.join(swarm_home, "fable-reviewer.json"),
            operator.pw_uid, "Fable reviewer policy", max_bytes=MAX_REVIEWER_CONFIG_BYTES,
        ) != value["fable_reviewer_config_sha256"]:
            die("Fable reviewer policy differs from installed authority; rerun install")
        verify_workspace(repo, operator, shared, runtime_uid=runtime.pw_uid)
    print("swarm-codex-runtime: OK v2 runner/account/group/toolchain/auth/canary contract")


def command_install(args: argparse.Namespace, swarm_home: str) -> None:
    require_macos(); require_root()
    if os.path.lexists(ATTESTATION):
        # A legacy v2 authority predates the Fable companions this transaction
        # is responsible for publishing.  Bind only the immutable root entry
        # point here; the locked attestation check below keeps current expanded
        # authorities strict, and all ordinary lifecycle commands require the
        # complete companion proof.
        require_fixed_lifecycle(include_reviewer=False)
    operator = operator_record(args.operator_user)
    repo = canonical_dir(args.repo, "workspace")
    validate_runtime_home_target(args.runtime_home, operator.pw_dir, repo, swarm_home)
    initial_pnpm_version = requested_pnpm_version(repo)
    tool_backup: str | None = None
    lifecycle_backup: str | None = None
    runner_backup: str | None = None
    manager_launcher_backup: str | None = None
    manager_bundle_backup: str | None = None
    fable_reviewer_backup: str | None = None
    fable_doctrine_backup: str | None = None
    fable_schema_backup: str | None = None
    manager_authority_backup: str | None = None
    attestation_backup: str | None = None
    sudoers_backup: str | None = None
    registry_backup: str | None = None
    workspace_before: dict[str, list[object]] | None = None
    tool_installed = False
    lifecycle_installed = False
    runner_installed = False
    manager_launcher_installed = False
    manager_bundle_installed = False
    fable_reviewer_installed = False
    fable_doctrine_installed = False
    fable_schema_installed = False
    manager_authority_changed = False
    attestation_changed = False
    sudoers_changed = False
    registry_changed = False
    workspace_mutated = False
    committed = False
    existing_name: str | None = None
    new_canary_name: str | None = None
    runtime: pwd.struct_passwd | None = None
    group_existed = False
    user_existed = False
    home_existed = os.path.lexists(args.runtime_home)
    operator_was_member = False
    runtime_was_member = False
    operator_member_added = False
    runtime_member_added = False
    prior_runtime_primary_gid: int | None = None
    directory_services_started = False
    # Lock order is the same as manager startup: launcher singleton first,
    # global hidden-runner lock second. No new manager can publish admission
    # while this transaction replaces its launcher, bundle, or authority.
    manager_lock_fd, lock_fd = acquire_manager_mutation_locks(None)
    try:
        if os.path.lexists(MANAGER_ADMISSION):
            validate_root_authority_file(
                MANAGER_ADMISSION, "active manager admission",
                exact_mode=0o600, max_bytes=16 * 1024,
            )
            die("Codex App Server manager is active or left an admission record; shut it down before install")
        # Package-manager source/pin errors are immutable host preflight, not a
        # reason to touch Directory Services. Resolve them before quiescing or
        # reconciling the hidden account, then repeat immediately before copy.
        preflight_pnpm_plan = resolve_operator_pnpm(operator, repo)
        if preflight_pnpm_plan is None:
            preflight_pnpm_plan = existing_pnpm_plan()
        existing: dict[str, object] | None = None
        if os.path.lexists(ATTESTATION):
            # Existing authority is an identity constraint, never repair input.
            # Refuse malformed/mismatched state before touching Directory Services.
            existing = load_attestation()
            if set(existing) == EXACT_KEYS:
                require_fixed_reviewer_authority()
            try:
                existing_runtime_uid = int(existing["runtime_uid"])
                existing_runtime_gid = int(existing["runtime_gid"])
            except (TypeError, ValueError):
                die("existing attestation has non-numeric runtime identity")
            if (type(existing["operator_uid"]) is not int
                    or existing["operator_uid"] != operator.pw_uid
                    or existing["runtime_user"] != args.runtime_user
                    or existing["runtime_group"] != args.runtime_group
                    or existing["runtime_home"] != args.runtime_home
                    or existing_runtime_uid <= 0 or existing_runtime_gid <= 0):
                die(
                    "existing attestation identity differs from requested operator/runtime "
                    "user/group/home; uninstall or pass the original identity explicitly"
                )
            existing_name = str(existing["launchd_canary_name"])
            quiesce_service_uid(existing)
        validate_codex_config_template_source(swarm_home, operator.pw_uid)
        validate_source(
            os.path.join(swarm_home, "bin", "qofi-fable-reviewer-mcp.py"),
            operator.pw_uid, "Fable reviewer shim", executable=True,
        )
        validate_source(
            os.path.join(
                swarm_home, "templates", "_base", "codex", "fable-reviewer-doctrine.md",
            ),
            operator.pw_uid, "Fable reviewer doctrine",
        )
        validate_source(
            os.path.join(
                swarm_home, "templates", "_base", "codex",
                "adversarial-review-output.schema.json",
            ),
            operator.pw_uid, "adversarial review schema",
        )
        trusted_source_sha256(
            os.path.join(swarm_home, "fable-reviewer.json"),
            operator.pw_uid, "Fable reviewer policy", max_bytes=MAX_REVIEWER_CONFIG_BYTES,
        )
        group_existed = ds_record("Groups", args.runtime_group)
        user_existed = ds_record("Users", args.runtime_user)
        if group_existed:
            if ds_string_attribute("Groups", args.runtime_group, "RealName") != RUNTIME_GROUP_REALNAME:
                die("refusing to mutate an unmanaged pre-existing runtime group")
            prior_members = set(ds_values_attribute("Groups", args.runtime_group, "GroupMembership"))
            unexpected = prior_members - {operator.pw_name, args.runtime_user}
            if unexpected:
                die("refusing install because the managed shared group has unexpected members")
            operator_was_member = operator.pw_name in prior_members
            runtime_was_member = args.runtime_user in prior_members
        if (user_existed
                and ds_string_attribute("Users", args.runtime_user, "RealName") != RUNTIME_USER_REALNAME):
            die("refusing to mutate an unmanaged pre-existing runtime user")
        if user_existed:
            prior_runtime_primary_gid = ds_numeric_attribute(
                "Users", args.runtime_user, "PrimaryGroupID",
            )
        directory_services_started = True
        shared = ensure_group(args.runtime_group)
        runtime = ensure_user(args.runtime_user, args.runtime_home, shared.gr_gid)
        if runtime.pw_uid == operator.pw_uid:
            die("runtime account must be distinct from the operator")
        if existing is not None and (
            runtime.pw_uid != existing_runtime_uid or shared.gr_gid != existing_runtime_gid
        ):
            die("Directory Services runtime uid/gid differs from the existing attestation")
        add_group_member(shared.gr_name, operator.pw_name)
        operator_member_added = not operator_was_member
        add_group_member(shared.gr_name, runtime.pw_name)
        runtime_member_added = not runtime_was_member
        installed_identity = identity_authority(operator, runtime, shared)
        exact_runtime_identity(installed_identity)
        quiesce_service_uid(installed_identity)
        ensure_runtime_bootstrap(runtime)
        secure_runtime_home(runtime, operator, render_config=False)
        secure_existing_profile_homes(runtime, operator, render_config=False)
        establish_empty_keychain_search(runtime)
        node_source, script_source = resolve_operator_codex(operator, repo, swarm_home)
        bun_source = resolve_operator_bun(operator)
        if requested_pnpm_version(repo) != initial_pnpm_version:
            die("project pnpm pin changed during dedicated-runtime installation")
        pnpm_plan = resolve_operator_pnpm(operator, repo)
        if pnpm_plan is None:
            pnpm_plan = existing_pnpm_plan()
        if ((pnpm_plan is None) != (preflight_pnpm_plan is None)
                or (pnpm_plan is not None and preflight_pnpm_plan is not None
                    and (pnpm_plan[1] != preflight_pnpm_plan[1]
                         or os.path.realpath(pnpm_plan[0])
                         != os.path.realpath(preflight_pnpm_plan[0])))):
            die("global pnpm source/version changed during dedicated-runtime installation")
        pnpm_source, pnpm_version = pnpm_plan if pnpm_plan is not None else (None, None)
        node, script, tool_backup = install_toolchain(
            node_source, script_source, bun_source, operator.pw_uid, runtime,
            pnpm_source, pnpm_version,
        )
        tool_installed = True
        lifecycle_backup = install_lifecycle(
            os.path.join(swarm_home, "bin", "swarm-codex-runtime.py"), operator.pw_uid,
        )
        lifecycle_installed = True
        runner_backup = install_runner(
            os.path.join(swarm_home, "bin", "qofi-codex-runner"), operator.pw_uid,
        )
        runner_installed = True
        fable_reviewer_backup = install_root_program(
            os.path.join(swarm_home, "bin", "qofi-fable-reviewer-mcp.py"),
            FABLE_REVIEWER, operator.pw_uid, "Fable reviewer shim",
        )
        fable_reviewer_installed = True
        fable_doctrine_backup = install_root_data(
            os.path.join(
                swarm_home, "templates", "_base", "codex", "fable-reviewer-doctrine.md",
            ),
            FABLE_DOCTRINE, operator.pw_uid, "Fable reviewer doctrine",
            max_bytes=MAX_REVIEWER_DOCTRINE_BYTES,
        )
        fable_doctrine_installed = True
        fable_schema_backup = install_root_data(
            os.path.join(
                swarm_home, "templates", "_base", "codex",
                "adversarial-review-output.schema.json",
            ),
            FABLE_SCHEMA, operator.pw_uid, "adversarial review schema",
            max_bytes=MAX_REVIEWER_DOCTRINE_BYTES,
        )
        fable_schema_installed = True
        manager_output = build_manager_bundle(
            swarm_home, operator, os.path.join(TOOLCHAIN, "bin", "bun"),
        )
        manager_bundle_backup = install_root_program_bytes(
            manager_output, MANAGER_BUNDLE, "App Server manager bundle",
        )
        manager_bundle_installed = True
        manager_launcher_backup = install_root_program(
            os.path.join(swarm_home, "bin", "qofi-codex-manager-launcher"),
            MANAGER_LAUNCHER, operator.pw_uid, "App Server manager launcher",
        )
        manager_launcher_installed = True
        canary_name, canary_hash = set_operator_canary(operator.pw_uid)
        new_canary_name = canary_name
        attestation_backup = transaction_backup(ATTESTATION)
        attestation_changed = True
        write_attestation(
            operator, runtime, shared, node, script, canary_name, canary_hash, swarm_home,
        )
        manager_authority_backup = transaction_backup(MANAGER_AUTHORITY)
        manager_authority_changed = True
        write_manager_authority(operator, node, swarm_home)
        sudoers_backup = transaction_backup(SUDOERS)
        sudoers_changed = True
        install_sudoers(operator, runtime)
        prove_runner_sudo_precommit(operator)
        _, workspace_before = capture_workspace_metadata(repo)
        workspace_identity = (
            int(workspace_before[""][4]), int(workspace_before[""][5]),
        )
        registry_backup = transaction_backup(WORKSPACE_REGISTRY)
        registry_changed = True
        snapshot_workspace(repo, expected_identity=workspace_identity)
        workspace_mutated = True
        prepare_workspace(
            repo, operator, shared, expected_identity=workspace_identity,
            runtime_uid=runtime.pw_uid,
        )
        verify_workspace(
            repo, operator, shared, expected_identity=workspace_identity,
            runtime_uid=runtime.pw_uid,
        )
        finalize_workspace_snapshot(repo, expected_identity=workspace_identity)
        render_all_runtime_codex_configs_transactionally(runtime, operator)
        committed = True
        if existing_name and existing_name != canary_name:
            run(["/bin/launchctl", "asuser", str(operator.pw_uid), "/bin/launchctl",
                 "unsetenv", existing_name], check=False)
    finally:
        try:
            if committed:
                for backup in (
                    tool_backup, lifecycle_backup, runner_backup,
                    manager_launcher_backup, manager_bundle_backup,
                    fable_reviewer_backup, fable_doctrine_backup,
                    fable_schema_backup,
                ):
                    if backup and os.path.lexists(backup):
                        if os.path.isdir(backup):
                            shutil.rmtree(backup)
                        else:
                            os.unlink(backup)
                for backup in (
                    attestation_backup, manager_authority_backup,
                    sudoers_backup, registry_backup,
                ):
                    transaction_discard(backup)
            else:
                rollback_errors: list[str] = []

                def rollback_step(label: str, action: object) -> None:
                    try:
                        action()  # type: ignore[operator]
                    except BaseException as exc:
                        rollback_errors.append(f"{label}: {exc}")

                if workspace_mutated and workspace_before is not None:
                    rollback_step(
                        "workspace metadata",
                        lambda: rollback_workspace(repo, operator, shared, workspace_before),
                    )
                if registry_changed:
                    rollback_step(
                        "workspace registry",
                        lambda: transaction_restore(WORKSPACE_REGISTRY, registry_backup),
                    )
                if sudoers_changed:
                    rollback_step(
                        "sudoers authority", lambda: transaction_restore(SUDOERS, sudoers_backup),
                    )
                if manager_authority_changed:
                    rollback_step(
                        "manager authority",
                        lambda: transaction_restore(MANAGER_AUTHORITY, manager_authority_backup),
                    )
                if attestation_changed:
                    rollback_step(
                        "runtime attestation",
                        lambda: transaction_restore(ATTESTATION, attestation_backup),
                    )
                if new_canary_name:
                    rollback_step(
                        "operator canary",
                        lambda: run(
                            ["/bin/launchctl", "asuser", str(operator.pw_uid),
                             "/bin/launchctl", "unsetenv", new_canary_name],
                            check=False,
                        ),
                    )

                def restore_runner() -> None:
                    if os.path.isdir(RUNNER) or os.path.islink(RUNNER):
                        die("installed runner changed type during rollback")
                    try:
                        os.unlink(RUNNER)
                    except FileNotFoundError:
                        pass
                    if runner_backup and os.path.lexists(runner_backup):
                        os.rename(runner_backup, RUNNER)

                def restore_lifecycle() -> None:
                    if os.path.isdir(LIFECYCLE) or os.path.islink(LIFECYCLE):
                        die("installed lifecycle helper changed type during rollback")
                    try:
                        os.unlink(LIFECYCLE)
                    except FileNotFoundError:
                        pass
                    if lifecycle_backup and os.path.lexists(lifecycle_backup):
                        os.rename(lifecycle_backup, LIFECYCLE)

                def restore_root_program(path: str, backup: str | None, label: str) -> None:
                    if os.path.isdir(path) or os.path.islink(path):
                        die(f"installed {label} changed type during rollback")
                    try:
                        os.unlink(path)
                    except FileNotFoundError:
                        pass
                    if backup and os.path.lexists(backup):
                        os.rename(backup, path)

                def restore_toolchain() -> None:
                    if os.path.isdir(TOOLCHAIN) and not os.path.islink(TOOLCHAIN):
                        shutil.rmtree(TOOLCHAIN)
                    elif os.path.lexists(TOOLCHAIN):
                        die("installed toolchain changed type during rollback")
                    if tool_backup and os.path.lexists(tool_backup):
                        os.rename(tool_backup, TOOLCHAIN)
                ds_recovery_required = False
                if directory_services_started and existing is None:
                    before_ds_errors = len(rollback_errors)
                    rollback_step(
                        "Directory Services",
                        lambda: rollback_directory_services(
                            operator=operator,
                            runtime_user=args.runtime_user,
                            runtime_group=args.runtime_group,
                            runtime_home=args.runtime_home,
                            runtime=runtime,
                            user_created=not user_existed,
                            group_created=not group_existed,
                            home_existed=home_existed,
                            operator_member_added=operator_member_added,
                            runtime_member_added=runtime_member_added,
                            prior_runtime_primary_gid=prior_runtime_primary_gid,
                        ),
                    )
                    ds_recovery_required = len(rollback_errors) != before_ds_errors
                if runner_installed:
                    rollback_step("runner", restore_runner)
                if manager_launcher_installed:
                    rollback_step(
                        "manager launcher",
                        lambda: restore_root_program(
                            MANAGER_LAUNCHER, manager_launcher_backup, "manager launcher",
                        ),
                    )
                if manager_bundle_installed:
                    rollback_step(
                        "manager bundle",
                        lambda: restore_root_program(
                            MANAGER_BUNDLE, manager_bundle_backup, "manager bundle",
                        ),
                    )
                if fable_reviewer_installed:
                    rollback_step(
                        "Fable reviewer shim",
                        lambda: restore_root_program(
                            FABLE_REVIEWER, fable_reviewer_backup, "Fable reviewer shim",
                        ),
                    )
                if fable_doctrine_installed:
                    rollback_step(
                        "Fable reviewer doctrine",
                        lambda: restore_root_program(
                            FABLE_DOCTRINE, fable_doctrine_backup, "Fable reviewer doctrine",
                        ),
                    )
                if fable_schema_installed:
                    rollback_step(
                        "adversarial review schema",
                        lambda: restore_root_program(
                            FABLE_SCHEMA, fable_schema_backup, "adversarial review schema",
                        ),
                    )
                if lifecycle_installed and not ds_recovery_required:
                    rollback_step("lifecycle helper", restore_lifecycle)
                if tool_installed:
                    rollback_step("toolchain", restore_toolchain)
                if rollback_errors:
                    die("install failed and rollback was incomplete: " + "; ".join(rollback_errors))
        finally:
            release_manager_mutation_locks(manager_lock_fd, lock_fd)
    print("swarm-codex-runtime: install complete (idempotent root authority + workspace permissions)")
    assert runtime is not None
    auth = os.path.join(runtime.pw_dir, ".codex", "auth.json")
    if not os.path.isfile(auth) or os.path.islink(auth):
        print("NEXT (required 1/2): bin/swarm-codex-runtime.sh login")
        print(f"THEN (required 2/2): bin/swarm-codex-runtime.sh verify --repo {repo}")
    else:
        print("Next step (copy the command only):")
        print(f"  bin/swarm-codex-runtime.sh verify --repo {repo}")


def command_refresh_lifecycle(swarm_home: str) -> None:
    """Explicit bootstrap escape hatch for a fixed-helper self-update bug.

    Normal post-install mutations execute only the root-owned fixed lifecycle.
    If that exact helper cannot reach its own transactional update path, the
    operator may explicitly authorize this one-file refresh with their normal
    sudo password. The refreshed fixed helper must then perform a normal
    idempotent install, which updates the runner and attestation atomically.
    """

    require_macos(); require_root()
    source = os.path.join(swarm_home, "bin", "swarm-codex-runtime.py")
    if os.path.realpath(__file__) != source:
        die("refresh-lifecycle must execute the canonical repository lifecycle source")
    authority = load_attestation()
    operator, _runtime, _shared = exact_runtime_identity(authority)
    sudo_uid = os.environ.get("SUDO_UID", "")
    if not sudo_uid.isdigit() or int(sudo_uid) != operator.pw_uid:
        die("refresh-lifecycle must be explicitly sudo-authorized by the attested operator")
    validate_source(source, operator.pw_uid, "lifecycle refresh source", executable=True)
    lock_fd = acquire_lifecycle_lock(authority)
    backup_path = LIFECYCLE + f".old.{os.getpid()}"
    try:
        try:
            backup = install_lifecycle(source, operator.pw_uid)
            if sha256(LIFECYCLE) != sha256(source):
                die("refreshed fixed lifecycle differs from the authorized source")
        except BaseException:
            if os.path.lexists(backup_path):
                validate_root_authority_file(
                    backup_path, "lifecycle refresh rollback", executable=True,
                    exact_mode=0o755, max_bytes=2 * 1024 * 1024,
                )
                if os.path.lexists(LIFECYCLE):
                    validate_root_authority_file(
                        LIFECYCLE, "failed lifecycle refresh", executable=True,
                        exact_mode=0o755, max_bytes=2 * 1024 * 1024,
                    )
                    os.unlink(LIFECYCLE)
                os.rename(backup_path, LIFECYCLE)
            raise
        if backup:
            validate_root_authority_file(
                backup, "superseded lifecycle helper", executable=True,
                exact_mode=0o755, max_bytes=2 * 1024 * 1024,
            )
            os.unlink(backup)
    finally:
        release_lifecycle_lock(lock_fd)
    print("swarm-codex-runtime: fixed lifecycle refreshed")


def command_login(args: argparse.Namespace | None = None) -> None:
    require_macos(); require_root(); require_fixed_lifecycle()
    profile = DEFAULT_PROFILE if args is None else args.profile
    value = load_attestation()
    operator, runtime, _ = exact_runtime_identity(value)
    if value["codex_home"] != profile_codex_home(runtime.pw_dir, DEFAULT_PROFILE):
        die("attested codex_home is not the default runtime profile home")
    codex_home = profile_codex_home(runtime.pw_dir, profile)
    lock_fd = acquire_lifecycle_lock(value)
    try:
        secure_runtime_home(runtime, operator, profile)
        ensure_runtime_bootstrap(runtime)
        establish_empty_keychain_search(runtime)
        login_method = [
            "-c", 'forced_login_method="chatgpt"',
            "-c", 'cli_auth_credentials_store="file"',
        ]
        login_command = [
            str(value["node_path"]), str(value["codex_script"]), "login", *login_method,
        ]
        if profile == DEFAULT_PROFILE:
            result = run_as_runtime(runtime, login_command)
        else:
            result = run_as_runtime(runtime, login_command, codex_home=codex_home)
        quiesce_service_uid(value)
        if result.returncode != 0:
            die(f"dedicated Codex login failed (exit {result.returncode})")
        auth = os.path.join(codex_home, "auth.json")
        auth_fd = open_dedicated_auth(
            auth,
            runtime,
            profile=profile,
            missing_error=(
                "Codex login exited successfully but did not create the dedicated auth.json"
            ),
            require_hardened_mode=False,
        )
        try:
            os.fchmod(auth_fd, 0o600)
            strip_extended_acl_fd(auth_fd, "new dedicated auth.json")
            hardened = os.fstat(auth_fd)
            if (stat.S_IMODE(hardened.st_mode) != 0o600
                    or fd_has_extended_acl(auth_fd)):
                die("Codex login auth.json could not be hardened")
        finally:
            os.close(auth_fd)
        status_command = [
            str(value["node_path"]), str(value["codex_script"]),
            "login", *login_method, "status",
        ]
        if profile == DEFAULT_PROFILE:
            status = run_as_runtime(runtime, status_command, capture=True)
        else:
            status = run_as_runtime(
                runtime, status_command, capture=True, codex_home=codex_home,
            )
        quiesce_service_uid(value)
        login_output = (status.stdout + status.stderr).strip()
        if status.returncode != 0 or login_output != "Logged in using ChatGPT":
            die(f"dedicated login is not exact ChatGPT auth: {login_output}")
        verify_runtime_keychain_search_empty(runtime)
        validate_runtime_keychain_storage(runtime)
        final_auth_fd = open_dedicated_auth(
            auth,
            runtime,
            profile=profile,
            missing_error="dedicated auth.json disappeared after login-status verification",
            require_hardened_mode=True,
        )
        os.close(final_auth_fd)
    finally:
        release_lifecycle_lock(lock_fd)
    label = "" if profile == DEFAULT_PROFILE else f" for profile {profile}"
    verify_selector = "" if profile == DEFAULT_PROFILE else f" --profile {profile}"
    print(
        f"swarm-codex-runtime: dedicated ChatGPT login stored{label}; "
        f"run verify{verify_selector}"
    )


def command_prepare(args: argparse.Namespace) -> None:
    require_macos(); require_root(); require_fixed_lifecycle()
    value = load_attestation()
    operator, runtime, shared = exact_runtime_identity(value)
    lock_fd = acquire_lifecycle_lock(value)
    registry_backup: str | None = None
    registry_changed = False
    workspace_mutated = False
    committed = False
    before: dict[str, list[object]] | None = None
    canonical = ""
    try:
        canonical, before = capture_workspace_metadata(args.repo)
        workspace_identity = (int(before[""][4]), int(before[""][5]))
        registry_backup = transaction_backup(WORKSPACE_REGISTRY)
        registry_changed = True
        snapshot_workspace(args.repo, expected_identity=workspace_identity)
        workspace_mutated = True
        prepare_workspace(
            args.repo,
            operator,
            shared,
            expected_identity=workspace_identity,
            runtime_uid=runtime.pw_uid,
        )
        verify_workspace(
            args.repo,
            operator,
            shared,
            expected_identity=workspace_identity,
            runtime_uid=runtime.pw_uid,
        )
        finalize_workspace_snapshot(
            canonical, expected_identity=workspace_identity,
        )
        committed = True
    finally:
        try:
            if committed:
                transaction_discard(registry_backup)
            else:
                rollback_errors: list[str] = []
                if workspace_mutated and before is not None:
                    try:
                        rollback_workspace(
                            canonical,
                            operator,
                            shared,
                            before,
                        )
                    except BaseException as exc:
                        rollback_errors.append(f"workspace metadata: {exc}")
                if registry_changed:
                    try:
                        transaction_restore(WORKSPACE_REGISTRY, registry_backup)
                    except BaseException as exc:
                        rollback_errors.append(f"workspace registry: {exc}")
                if rollback_errors:
                    die("prepare-workspace failed and rollback was incomplete: "
                        + "; ".join(rollback_errors))
        finally:
            release_lifecycle_lock(lock_fd)
    print(f"swarm-codex-runtime: workspace prepared: {canonical}")


def command_release(args: argparse.Namespace) -> None:
    require_macos(); require_root(); require_fixed_lifecycle()
    value = load_attestation()
    operator, _, _ = exact_runtime_identity(value)
    if (not os.path.isabs(args.repo) or os.path.normpath(args.repo) != args.repo
            or args.repo == "/" or any(ord(ch) < 32 or ord(ch) == 127 for ch in args.repo)):
        die("release-workspace repo must be an absolute normalized path")
    lock_fd = acquire_lifecycle_lock(value)
    try:
        # Read the recovery journal only after serialization. A pre-lock
        # "not registered" result could race a concurrent prepare and let a
        # caller remove the last logical lease while service access remained.
        journal = workspace_registry().get(args.repo)
        expected_journal_sha256 = getattr(args, "expected_journal_sha256", None)
        if expected_journal_sha256 is not None:
            if (not HASH_RE.fullmatch(expected_journal_sha256)
                    or journal is None
                    or workspace_journal_sha256(journal) != expected_journal_sha256):
                die("workspace journal changed after recovery audit; no authority was released")
        if journal is None:
            print(f"swarm-codex-runtime: workspace is not registered: {args.repo}")
            return
        outcome = cleanup_workspace(args.repo, operator, journal)
        if outcome != "released":
            # Missing is not proof of deletion: the prepared inode may have
            # been renamed elsewhere. Replacement likewise proves only that
            # another inode now occupies the registered pathname. Retain the
            # inode-bound recovery journal and all runtime authority until the
            # original workspace is restored at this path and can be revoked.
            die(
                f"workspace root is {outcome}; service access may remain on a moved inode. "
                "The workspace journal was retained; restore the original workspace at "
                "the registered path and retry release-workspace"
            )
        if not unregister_workspace(args.repo):
            die("workspace registration disappeared during release")
    finally:
        release_lifecycle_lock(lock_fd)
    print(f"swarm-codex-runtime: service access released: {args.repo}")


def command_workspace_journal_evidence(args: argparse.Namespace) -> None:
    """Emit bounded root-attested evidence without exposing journal contents."""
    require_macos(); require_root(); require_fixed_lifecycle()
    value = load_attestation()
    exact_runtime_identity(value)
    if (not os.path.isabs(args.repo) or os.path.normpath(args.repo) != args.repo
            or args.repo == "/" or any(ord(ch) < 32 or ord(ch) == 127 for ch in args.repo)):
        die("workspace-journal-evidence repo must be an absolute normalized path")
    journal = workspace_registry().get(args.repo)
    evidence = {
        "schema": WORKSPACE_JOURNAL_EVIDENCE_SCHEMA,
        "repo": args.repo,
        "present": journal is not None,
        "journal_sha256": workspace_journal_sha256(journal) if journal is not None else None,
    }
    print(json.dumps(evidence, sort_keys=True, separators=(",", ":"), ensure_ascii=True))


def command_recover_manager(args: argparse.Namespace) -> None:
    require_macos(); require_root(); require_fixed_lifecycle()
    swarm_home = canonical_dir(args.swarm_home, "SWARM_HOME")
    runtime_authority = load_attestation()
    operator, _runtime, _shared = exact_runtime_identity(runtime_authority)
    authority = validate_manager_authority(operator, runtime_authority)
    if authority.get("swarm_home") != swarm_home:
        die("manager recovery source differs from root manager authority")
    sudo_uid = os.environ.get("SUDO_UID", "")
    if not sudo_uid.isdecimal() or int(sudo_uid) != operator.pw_uid:
        die("manager recovery SUDO_UID differs from the attested operator")

    admission, admission_identity = load_manager_admission()
    launcher, manager = validate_manager_recovery_processes(authority, admission, operator)
    manager_pid = int(admission["manager_pid"])
    query_stopped_manager_recovery_health(authority, operator, manager_pid)
    launcher_lock_fd, launcher_lock_identity = open_manager_recovery_launcher_lock()
    runner_lock_fd: int | None = None
    try:
        try:
            fcntl.flock(launcher_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        except OSError as exc:
            die(f"could not inspect admitted manager launcher lock: {exc}")
        else:
            fcntl.flock(launcher_lock_fd, fcntl.LOCK_UN)
            die("admitted manager launcher does not hold its singleton lock")

        # Rebind root admission, exact processes, socket inode, peer pid, and
        # health once more immediately before signaling the admitted launcher.
        admission_again, identity_again = load_manager_admission()
        if admission_again != admission or identity_again != admission_identity:
            die("manager recovery admission changed before termination")
        launcher_again, manager_again = validate_manager_recovery_processes(
            authority, admission_again, operator,
        )
        if launcher_again != launcher or manager_again != manager:
            die("manager recovery process identity changed before termination")

        # Freeze the root-runner singleton before the final logical-state
        # observation. A concurrent resume may enter manager code, but it
        # cannot create a replacement upstream or admit a registration while
        # this lock remains held through launcher reap and UID quiescence.
        runner_lock_fd = acquire_manager_recovery_runner_lock()
        query_stopped_manager_recovery_health(authority, operator, manager_pid)

        # The bounded health exchange is deliberately last among socket
        # observations, but it may consume its five-second timeout. Rebind the
        # root record and both process objects again after it so the signal is
        # never authorized by a pre-query PID snapshot.
        admission_final, identity_final = load_manager_admission()
        if admission_final != admission or identity_final != admission_identity:
            die("manager recovery admission changed after the health proof")
        launcher_final, manager_final = validate_manager_recovery_processes(
            authority, admission_final, operator,
        )
        if launcher_final != launcher or manager_final != manager:
            die("manager recovery process identity changed after the health proof")
        try:
            fcntl.flock(launcher_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        except OSError as exc:
            die(f"could not recheck manager launcher lock after health: {exc}")
        else:
            fcntl.flock(launcher_lock_fd, fcntl.LOCK_UN)
            die("manager launcher exited after the health proof")
        try:
            os.kill(int(admission["launcher_pid"]), signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError as exc:
            die(f"could not signal admitted manager launcher: {exc}")
        wait_for_manager_recovery_quiescence(
            runtime_authority, admission_identity, launcher, manager,
            launcher_lock_fd, launcher_lock_identity, runner_lock_fd,
        )
    finally:
        try:
            fcntl.flock(launcher_lock_fd, fcntl.LOCK_UN)
        finally:
            try:
                os.close(launcher_lock_fd)
            finally:
                if runner_lock_fd is not None:
                    try:
                        fcntl.flock(runner_lock_fd, fcntl.LOCK_UN)
                    finally:
                        os.close(runner_lock_fd)
    print("swarm-codex-runtime: stopped zero-registration manager recovered")


def command_quiescence_proof() -> None:
    """Stop orphaned service-UID processes under the fixed global runner lock."""
    require_macos(); require_root(); require_fixed_lifecycle()
    value = load_attestation()
    lock_fd = acquire_lifecycle_lock(value)
    try:
        _, runtime, _ = exact_runtime_identity(value)
        remaining = service_pids(runtime.pw_uid, runtime.pw_gid)
        if remaining:
            die("dedicated runtime uid is not quiescent after bounded termination")
    finally:
        release_lifecycle_lock(lock_fd)
    print(json.dumps(
        {"schema": QUIESCENCE_PROOF_SCHEMA, "status": "quiescent"},
        sort_keys=True, separators=(",", ":"), ensure_ascii=True,
    ))


def command_uninstall(args: argparse.Namespace) -> None:
    require_macos(); require_root(); require_fixed_lifecycle()
    try:
        value = load_attestation()
    except (OSError, SystemExit, ValueError) as exc:
        die(
            "cannot safely uninstall without the complete valid root attestation; no state was "
            "changed. Repair with `install --repo /absolute/workspace` using the original "
            f"runtime identity, then retry uninstall ({exc})"
        )
    operator, _runtime, _shared = exact_runtime_identity(value)
    validate_manager_authority(operator, value)
    runtime_uid = int(value["runtime_uid"])
    runtime_user = str(value["runtime_user"])
    runtime_group = str(value["runtime_group"])
    runtime_home = str(value["runtime_home"])
    if (not os.path.isabs(runtime_home) or os.path.normpath(runtime_home) != runtime_home
            or runtime_home == "/" or runtime_home == operator.pw_dir
            or os.path.commonpath([runtime_home, operator.pw_dir]) in (runtime_home, operator.pw_dir)):
        die("attested runtime home is unsafe for uninstall recovery")
    try:
        runtime_record = pwd.getpwnam(runtime_user)
    except KeyError:
        runtime_record = None
    if runtime_record is not None and (
        runtime_record.pw_uid != runtime_uid or runtime_record.pw_dir != runtime_home
    ):
        die("runtime account no longer matches the attested uid/home; no state was changed")

    def unlink_authority_file(path: str) -> None:
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            return
        if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != ROOT_AUTHORITY_UID):
            die(f"authority path changed type/owner during uninstall: {path}")
        os.unlink(path)

    manager_lock_fd, lock_fd = acquire_manager_mutation_locks(value)
    try:
        # Rebind every authority observation after both locks. A concurrent
        # install may have completed before this transaction acquired them,
        # but no manager start or manager-file mutation can now interleave.
        locked_value = load_attestation()
        if locked_value != value:
            die("runtime authority changed while uninstall acquired its locks")
        locked_operator, _locked_runtime, _locked_shared = exact_runtime_identity(
            locked_value,
        )
        if locked_operator.pw_uid != operator.pw_uid:
            die("runtime operator changed while uninstall acquired its locks")
        validate_manager_authority(locked_operator, locked_value)
        if os.path.lexists(MANAGER_ADMISSION):
            validate_root_authority_file(
                MANAGER_ADMISSION, "active manager admission",
                exact_mode=0o600, max_bytes=16 * 1024,
            )
            die(
                "cannot uninstall while the Codex App Server manager admission "
                "is present; shut it down first"
            )
        for repo, snapshot in workspace_registry().items():
            outcome = cleanup_workspace(repo, operator, snapshot)
            if outcome != "released":
                die(
                    f"cannot uninstall: registered workspace root is {outcome} at {repo}; "
                    "service access may remain on a moved inode. Root authority and the "
                    "workspace journal were retained; restore the original workspace at "
                    "its registered path and retry uninstall"
                )

        run(["/bin/launchctl", "asuser", str(operator.pw_uid), "/bin/launchctl", "unsetenv",
             str(value["launchd_canary_name"])], check=False)
        canary = run(
            ["/bin/launchctl", "asuser", str(operator.pw_uid), "/bin/launchctl", "getenv",
             str(value["launchd_canary_name"])],
            check=False, capture=True,
        )
        if canary.stdout.strip():
            die("operator launchd canary could not be removed; authority remains for retry")
        run(["/bin/launchctl", "bootout", f"user/{runtime_uid}"], check=False)

        # This is a global authority teardown, not a per-daemon shutdown.  The
        # lifecycle lock has quiesced the shared service uid, so no sibling can
        # still need the persistent operator-home traversal ACEs.
        cleanup_persistent_runtime_traversal_acls(operator, runtime_user)

        if args.remove_account:
            if os.path.lexists(runtime_home):
                home_info = os.lstat(runtime_home)
                if (not stat.S_ISDIR(home_info.st_mode) or stat.S_ISLNK(home_info.st_mode)
                        or home_info.st_uid != runtime_uid or os.path.realpath(runtime_home) != runtime_home):
                    die("runtime home is unsafe to remove; root authority remains for recovery")
        elif not ds_record("Users", runtime_user) or not ds_record("Groups", runtime_group):
            die("retained runtime account/group disappeared during uninstall")

        unlink_authority_file(WORKSPACE_REGISTRY)
        if os.path.lexists(TOOLCHAIN):
            tool_info = os.lstat(TOOLCHAIN)
            if (not stat.S_ISDIR(tool_info.st_mode) or stat.S_ISLNK(tool_info.st_mode)
                    or tool_info.st_uid != ROOT_AUTHORITY_UID):
                die("root toolchain changed type/owner during uninstall")
            shutil.rmtree(TOOLCHAIN)
        unlink_authority_file(RUNNER)
        unlink_authority_file(FABLE_REVIEWER)
        unlink_authority_file(FABLE_DOCTRINE)
        unlink_authority_file(FABLE_SCHEMA)
        unlink_authority_file(SUDOERS)
        unlink_authority_file(MANAGER_BUNDLE)
        unlink_authority_file(MANAGER_LAUNCHER)
        unlink_authority_file(MANAGER_AUTHORITY)
        # The attestation is the recovery journal and remains until every
        # other stateful authority is gone. Keep the executable lifecycle
        # helper through this unlink so a failure remains retryable without
        # ever re-entering mutable repository Python as root.
        unlink_authority_file(ATTESTATION)
        if args.remove_account:
            # Once the recovery journal is gone, leave the fixed helper until
            # account deletion is complete. A partial DS failure can then be
            # recovered by running install through that immutable helper,
            # reconstructing authority, and retrying uninstall.
            if os.path.lexists(runtime_home):
                shutil.rmtree(runtime_home)
            if ds_record("Users", runtime_user):
                run(["/usr/bin/dscl", ".", "-delete", f"/Users/{runtime_user}"])
            if ds_record("Groups", runtime_group):
                run(["/usr/bin/dscl", ".", "-delete", f"/Groups/{runtime_group}"])
            if (ds_record("Users", runtime_user) or ds_record("Groups", runtime_group)
                    or os.path.lexists(runtime_home)):
                die(
                    "service account/group/home removal was incomplete; the fixed lifecycle "
                    "helper remains. Rerun install to reconstruct authority, then retry uninstall"
                )
        unlink_authority_file(LIFECYCLE)
        if any(os.path.lexists(path) for path in (
            WORKSPACE_REGISTRY, TOOLCHAIN, RUNNER, LIFECYCLE, SUDOERS, ATTESTATION,
            MANAGER_BUNDLE, MANAGER_LAUNCHER, MANAGER_AUTHORITY, MANAGER_ADMISSION,
            FABLE_REVIEWER, FABLE_DOCTRINE,
            FABLE_SCHEMA,
        )):
            die("uninstall postcondition failed; an authority path remains")
    finally:
        release_manager_mutation_locks(manager_lock_fd, lock_fd)
    print("swarm-codex-runtime: root runner/attestation/sudoers/toolchain removed"
          + ("; service account/group removed" if args.remove_account else "; account/group retained"))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Manage the root-attested dedicated macOS Codex runtime",
    )
    sub = result.add_subparsers(dest="command", required=True)
    install = sub.add_parser("install", help="idempotently install authority and prepare one workspace")
    install.add_argument("--repo", required=True)
    install.add_argument("--swarm-home", required=True, help=argparse.SUPPRESS)
    install.add_argument("--operator-user")
    install.add_argument("--runtime-user", default=DEFAULT_USER)
    install.add_argument("--runtime-group", default=DEFAULT_GROUP)
    install.add_argument("--runtime-home", default=DEFAULT_HOME)
    login = sub.add_parser("login", help="perform interactive ChatGPT login as the service account")
    login.add_argument("--profile", default=DEFAULT_PROFILE, metavar="HANDLE")
    refresh = sub.add_parser(
        "refresh-lifecycle",
        help="explicitly refresh a fixed helper that cannot self-update",
    )
    refresh.add_argument("--swarm-home", required=True, help=argparse.SUPPRESS)
    verify = sub.add_parser("verify", help="verify installed authority and optional workspace")
    verify.add_argument("--repo")
    verify.add_argument("--profile", default=DEFAULT_PROFILE, metavar="HANDLE")
    prepare = sub.add_parser("prepare-workspace", help="apply shared-group collaboration modes")
    prepare.add_argument("--repo", required=True)
    release = sub.add_parser("release-workspace", help="revoke service access without uninstalling")
    release.add_argument("--repo", required=True)
    release.add_argument("--expected-journal-sha256", help=argparse.SUPPRESS)
    evidence = sub.add_parser(
        "workspace-journal-evidence",
        help="emit a root-attested digest for one workspace recovery journal",
    )
    evidence.add_argument("--repo", required=True)
    sub.add_parser(
        "quiescence-proof",
        help="stop orphaned service processes and prove the dedicated uid quiescent",
    )
    recover_manager = sub.add_parser(
        "recover-manager",
        help="root-verify and retire a stopped zero-registration manager ambiguity",
    )
    recover_manager.add_argument("--swarm-home", required=True, help=argparse.SUPPRESS)
    uninstall = sub.add_parser("uninstall", help="remove root authority; retain account by default")
    uninstall.add_argument("--remove-account", action="store_true")
    return result


def main() -> None:
    # Root-created authority/lock modes must not depend on the sudo caller.
    os.umask(0o077)
    args = parser().parse_args()
    if args.command == "install":
        swarm_home = canonical_dir(args.swarm_home, "SWARM_HOME")
        command_install(args, swarm_home)
    elif args.command == "refresh-lifecycle":
        swarm_home = canonical_dir(args.swarm_home, "SWARM_HOME")
        command_refresh_lifecycle(swarm_home)
    elif args.command == "login":
        command_login(args)
    elif args.command == "verify":
        require_macos()
        verify_authority(args.repo, args.profile)
    elif args.command == "prepare-workspace":
        command_prepare(args)
    elif args.command == "release-workspace":
        command_release(args)
    elif args.command == "workspace-journal-evidence":
        command_workspace_journal_evidence(args)
    elif args.command == "recover-manager":
        command_recover_manager(args)
    elif args.command == "quiescence-proof":
        command_quiescence_proof()
    elif args.command == "uninstall":
        command_uninstall(args)


if __name__ == "__main__":
    main()
