#!/usr/bin/python3 -I
"""Atomically publish a non-empty lock directory with rename-no-replace.

macOS is the production target. Linux renameat2 support keeps unprivileged
tests portable. No fallback to ordinary rename is allowed: replacing an empty
existing lock would violate exclusion.
"""

from __future__ import annotations

import ctypes
import datetime as dt
import errno
import hashlib
import json
import os
import re
import secrets
import stat
import sys
import uuid

sys.dont_write_bytecode = True

RELEASE_SCHEMA = "qofi-lock-release/v1"
HASH_RE = re.compile(r"[0-9a-f]{64}\Z")


class NoReleaseBoundary(RuntimeError):
    """The canonical name has no active exact-release marker."""


def stat_identity(info: os.stat_result) -> list[int]:
    return [
        info.st_dev, info.st_ino, info.st_uid, info.st_gid,
        stat.S_IMODE(info.st_mode), info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    ]


def inode_shape(info: os.stat_result) -> list[int]:
    return [
        info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode),
    ]


def die(message: str, code: int = 2) -> None:
    print(f"atomic-directory-lock: {message}", file=sys.stderr)
    raise SystemExit(code)


def rename_exclusive(parent_fd: int, source: str, destination: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    source_raw = source.encode("utf-8")
    destination_raw = destination.encode("utf-8")
    ctypes.set_errno(0)
    if sys.platform == "darwin":
        rename = libc.renameatx_np
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                           ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(parent_fd, source_raw, parent_fd, destination_raw, 0x00000004)
    elif hasattr(libc, "renameat2"):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                           ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(parent_fd, source_raw, parent_fd, destination_raw, 0x00000001)
    else:
        die("host has no rename-no-replace primitive", 70)
    if result == 0:
        return
    error = ctypes.get_errno()
    if error in (errno.EEXIST, errno.ENOTEMPTY):
        raise FileExistsError(error, os.strerror(error), destination)
    raise OSError(error, os.strerror(error), destination)


def rename_exchange(parent_fd: int, first: str, second: str) -> None:
    """Atomically swap two names so the canonical lock is never absent."""

    libc = ctypes.CDLL(None, use_errno=True)
    first_raw = first.encode("utf-8")
    second_raw = second.encode("utf-8")
    ctypes.set_errno(0)
    if sys.platform == "darwin":
        rename = libc.renameatx_np
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                           ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(parent_fd, first_raw, parent_fd, second_raw, 0x00000002)
    elif hasattr(libc, "renameat2"):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                           ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(parent_fd, first_raw, parent_fd, second_raw, 0x00000002)
    else:
        die("host has no atomic rename-exchange primitive", 70)
    if result == 0:
        return
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), f"{first}<->{second}")


def fd_has_extended_acl(fd: int) -> bool:
    if sys.platform != "darwin":
        return False
    libc = ctypes.CDLL(None, use_errno=True)
    get_acl = libc.acl_get_fd_np
    get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
    get_acl.restype = ctypes.c_void_p
    free_acl = libc.acl_free
    free_acl.argtypes = [ctypes.c_void_p]
    free_acl.restype = ctypes.c_int
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)  # ACL_TYPE_EXTENDED
    if not acl:
        error = ctypes.get_errno()
        if error in (0, errno.ENOENT):
            return False
        die(f"could not inspect lock-parent ACL: errno {error}")
    try:
        return True
    finally:
        free_acl(acl)


def validate_parent(parent_fd: int) -> None:
    parent_info = os.fstat(parent_fd)
    if (not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid != os.getuid()
            or parent_info.st_mode & 0o022 or fd_has_extended_acl(parent_fd)):
        die("lock parent is not an owner-held ACL-free non-group/world-writable directory")


def stable_read_at(
    directory_fd: int, name: str, *, limit: int, expected_mode: int = 0o600,
) -> tuple[bytes, os.stat_result]:
    before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
            or stat.S_IMODE(before.st_mode) != expected_mode or before.st_size > limit):
        die(f"release evidence file is unsafe: {name}")
    fd = os.open(
        name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd,
    )
    try:
        opened = os.fstat(fd)
        raw = b""
        while len(raw) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(raw)))
            if not chunk:
                break
            raw += chunk
        after = os.fstat(fd)
        if (stat_identity(opened) != stat_identity(before)
                or stat_identity(after) != stat_identity(opened) or len(raw) > limit
                or fd_has_extended_acl(fd)):
            die(f"release evidence file changed while reading: {name}")
        return raw, opened
    finally:
        os.close(fd)


def open_exact_directory(parent_fd: int, name: str, label: str) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        die(f"{label} is not an owner-held mode-0700 directory")
    fd = os.open(name, flags, dir_fd=parent_fd)
    opened = os.fstat(fd)
    if (stat_identity(opened) != stat_identity(info) or fd_has_extended_acl(fd)):
        os.close(fd)
        die(f"{label} changed while opening or has an extended ACL")
    return fd, opened


def parse_release_marker(
    parent_fd: int, entry: str, lock_name: str, owner_name: str,
) -> tuple[dict[str, object], dict[str, object]]:
    marker_fd, marker_info = open_exact_directory(parent_fd, entry, "release marker")
    try:
        if sorted(os.listdir(marker_fd)) != ["release.json"]:
            die("release marker must contain exactly release.json")
        raw, file_info = stable_read_at(marker_fd, "release.json", limit=16 * 1024)
    finally:
        os.close(marker_fd)
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError):
        die("release marker JSON is malformed")
    keys = {
        "schema", "phase", "lock_name", "old_lock_name", "old_lock_dev", "old_lock_ino",
        "owner_name", "owner_dev", "owner_ino", "owner_sha256", "token_sha256",
    }
    old_pattern = re.compile(rf"\.{re.escape(lock_name)}\.release\.[0-9a-f]{{24}}\Z")
    if (not isinstance(value, dict) or set(value) != keys
            or value.get("schema") != RELEASE_SCHEMA or value.get("phase") != "exchanged"
            or value.get("lock_name") != lock_name
            or not isinstance(value.get("old_lock_name"), str)
            or not old_pattern.fullmatch(value["old_lock_name"])
            or type(value.get("old_lock_dev")) is not int or value["old_lock_dev"] < 0
            or type(value.get("old_lock_ino")) is not int or value["old_lock_ino"] <= 0
            or value.get("owner_name") != owner_name
            or type(value.get("owner_dev")) is not int or value["owner_dev"] < 0
            or type(value.get("owner_ino")) is not int or value["owner_ino"] <= 0
            or not isinstance(value.get("owner_sha256"), str)
            or not HASH_RE.fullmatch(value["owner_sha256"])
            or not isinstance(value.get("token_sha256"), str)
            or not HASH_RE.fullmatch(value["token_sha256"])):
        die("release marker has unsafe or incomplete exact evidence")
    return value, {
        "entry": entry,
        "identity": stat_identity(marker_info),
        "file_identity": stat_identity(file_info),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False
    except OSError as exc:
        return exc.errno != errno.ESRCH


def validate_daemon_owner(value: object) -> tuple[int, str]:
    if (not isinstance(value, dict)
            or set(value) != {"schema", "pid", "token", "started_at"}
            or value.get("schema") != "codex-bridge-lock/v1"
            or type(value.get("pid")) is not int or value["pid"] <= 0
            or not isinstance(value.get("token"), str)
            or not isinstance(value.get("started_at"), str)):
        die("release marker old owner is not an exact Codex daemon owner")
    try:
        token = uuid.UUID(value["token"])
        dt.datetime.fromisoformat(value["started_at"].replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        die("release marker old daemon owner has an invalid token or timestamp")
    if str(token) != value["token"] or token.version != 4:
        die("release marker old daemon owner token is not canonical UUIDv4")
    return value["pid"], value["token"]


def inspect_old_release_lock(
    parent_fd: int,
    old_name: str,
    owner_name: str,
    marker: dict[str, object],
    policy: str,
) -> dict[str, object]:
    try:
        old_fd, old_info = open_exact_directory(parent_fd, old_name, "old release lock")
    except FileNotFoundError:
        return {"status": "missing", "entry": old_name, "owner_state": "removed"}
    try:
        entries = sorted(os.listdir(old_fd))
        if not entries:
            if [old_info.st_dev, old_info.st_ino] != [
                marker["old_lock_dev"], marker["old_lock_ino"],
            ]:
                die("empty old release lock is not marker-bound")
            return {
                "status": "empty", "entry": old_name,
                "identity": stat_identity(old_info), "owner_state": "removed",
            }
        if entries != [owner_name]:
            die("old release lock has unexpected contents")
        raw, owner_info = stable_read_at(old_fd, owner_name, limit=16 * 1024)
    finally:
        os.close(old_fd)
    if ([old_info.st_dev, old_info.st_ino]
            != [marker["old_lock_dev"], marker["old_lock_ino"]]
            or [owner_info.st_dev, owner_info.st_ino]
            != [marker["owner_dev"], marker["owner_ino"]]
            or hashlib.sha256(raw).hexdigest() != marker["owner_sha256"]):
        die("release marker does not bind the exact old owner lock")
    pid: int | None = None
    token = "-"
    if owner_name == "owner.json":
        try:
            value = json.loads(raw.decode("utf-8", "strict"))
        except (UnicodeDecodeError, ValueError):
            die("old release owner JSON is malformed")
        if policy == "codex-daemon":
            pid, token = validate_daemon_owner(value)
        elif isinstance(value, dict) and isinstance(value.get("token"), str):
            token = value["token"]
        else:
            die("old JSON release owner has no ownership token")
    if hashlib.sha256(token.encode("utf-8")).hexdigest() != marker["token_sha256"]:
        die("release marker ownership-token digest does not match the old owner")
    owner_state = "live" if pid is not None and pid_alive(pid) else "dead"
    return {
        "status": "owner", "entry": old_name, "identity": stat_identity(old_info),
        "owner_identity": stat_identity(owner_info),
        "owner_sha256": hashlib.sha256(raw).hexdigest(),
        "owner_state": owner_state, "owner_pid": pid,
    }


def inspect_release_boundary(
    path: str, owner_name: str, policy: str,
) -> tuple[dict[str, object], str]:
    if (not os.path.isabs(path) or os.path.normpath(path) != path
            or owner_name not in ("owner", "owner.json")
            or policy not in ("generic", "codex-daemon")):
        die("release inspection arguments are unsafe", 64)
    parent, name = os.path.split(path)
    if not name or not re.fullmatch(r"[A-Za-z0-9_.-]{1,255}", name):
        die("release inspection lock basename is unsafe", 64)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_fd = os.open(parent, flags)
    try:
        validate_parent(parent_fd)
        names = sorted(os.listdir(parent_fd))
        release_names = [
            item for item in names
            if re.fullmatch(rf"\.{re.escape(name)}\.release\.[0-9a-f]{{24}}", item)
        ]
        try:
            canonical_fd, canonical_info = open_exact_directory(
                parent_fd, name, "canonical release lock",
            )
        except FileNotFoundError:
            if release_names:
                die("active release artifact exists while the canonical lock is absent")
            raise NoReleaseBoundary()
        try:
            canonical_entries = sorted(os.listdir(canonical_fd))
        finally:
            os.close(canonical_fd)

        if canonical_entries == [owner_name]:
            if not release_names:
                raise NoReleaseBoundary()
            if len(release_names) != 1:
                die("pre-exchange release has ambiguous marker directories")
            marker_value, marker_record = parse_release_marker(
                parent_fd, release_names[0], name, owner_name,
            )
            if marker_value["old_lock_name"] != release_names[0]:
                die("pre-exchange marker is not bound to its own exchange name")
            phase = "pre-exchange"
            old = inspect_old_release_lock(
                parent_fd, name, owner_name, marker_value, policy,
            )
            if old["status"] != "owner":
                die("pre-exchange release no longer has its exact old owner")
        elif canonical_entries == ["release.json"]:
            marker_value, marker_record = parse_release_marker(parent_fd, name, name, owner_name)
            old_name = str(marker_value["old_lock_name"])
            if any(item != old_name for item in release_names):
                die("exchanged release has an unrelated active marker directory")
            phase = "exchanged"
            old = inspect_old_release_lock(
                parent_fd, old_name, owner_name, marker_value, policy,
            )
        else:
            if release_names:
                die("active release marker accompanies an unsafe canonical lock")
            raise NoReleaseBoundary()

        observation = {
            "schema": "qofi-lock-release-observation/v1", "path": path,
            "owner_name": owner_name, "policy": policy, "phase": phase,
            "canonical_identity": stat_identity(canonical_info),
            "marker": marker_record, "marker_value": marker_value, "old": old,
        }
        raw = json.dumps(
            observation, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        ).encode("ascii")
        return observation, hashlib.sha256(raw).hexdigest()
    finally:
        os.close(parent_fd)


def read_exact_owner(
    lock_fd: int,
    owner_name: str,
    expected: tuple[int, int, int, int],
    owner_hash: str,
    token: str,
) -> bytes:
    locked = os.fstat(lock_fd)
    if ((locked.st_dev, locked.st_ino) != expected[:2]
            or os.listdir(lock_fd) != [owner_name]):
        die("lock changed before exact release")
    owner = os.stat(owner_name, dir_fd=lock_fd, follow_symlinks=False)
    if (not stat.S_ISREG(owner.st_mode)
            or (owner.st_dev, owner.st_ino) != expected[2:]
            or owner.st_uid != os.getuid()
            or stat.S_IMODE(owner.st_mode) != 0o600
            or owner.st_size > 16 * 1024):
        die("owner inode changed before release")
    owner_fd = os.open(
        owner_name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=lock_fd,
    )
    try:
        opened = os.fstat(owner_fd)
        raw = os.read(owner_fd, 16 * 1024 + 1)
        after = os.fstat(owner_fd)
        if ((opened.st_dev, opened.st_ino) != expected[2:]
                or (after.st_dev, after.st_ino, after.st_size,
                    after.st_mtime_ns, after.st_ctime_ns) !=
                   (opened.st_dev, opened.st_ino, opened.st_size,
                    opened.st_mtime_ns, opened.st_ctime_ns)
                or len(raw) > 16 * 1024
                or hashlib.sha256(raw).hexdigest() != owner_hash):
            die("owner evidence changed before release")
    finally:
        os.close(owner_fd)
    if token != "-":
        try:
            value = json.loads(raw.decode("utf-8", "strict"))
        except (UnicodeDecodeError, ValueError):
            die("owner JSON changed before release")
        if not isinstance(value, dict) or value.get("token") != token:
            die("owner token changed before release")
    return raw


def remove_marker_directory(parent_fd: int, name: str) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    marker_fd = os.open(name, flags, dir_fd=parent_fd)
    try:
        if os.listdir(marker_fd) != ["release.json"]:
            die("release marker directory changed")
        os.unlink("release.json", dir_fd=marker_fd)
        os.fsync(marker_fd)
    finally:
        os.close(marker_fd)
    os.rmdir(name, dir_fd=parent_fd)


def verify_release_marker_at(
    parent_fd: int, entry: str, observation: dict[str, object], *, renamed: bool,
) -> int:
    marker = observation["marker"]
    marker_fd, marker_info = open_exact_directory(parent_fd, entry, "release marker")
    expected = marker["identity"]
    if ((inode_shape(marker_info) if renamed else stat_identity(marker_info))
            != (expected[:5] if renamed else expected)):
        os.close(marker_fd)
        die("release marker inode changed after receipt verification")
    try:
        if sorted(os.listdir(marker_fd)) != ["release.json"]:
            die("release marker contents changed after receipt verification")
        raw, file_info = stable_read_at(marker_fd, "release.json", limit=16 * 1024)
        if (stat_identity(file_info) != marker["file_identity"]
                or hashlib.sha256(raw).hexdigest() != marker["sha256"]):
            die("release marker file changed after receipt verification")
    except BaseException:
        os.close(marker_fd)
        raise
    return marker_fd


def verify_old_release_at(
    parent_fd: int,
    entry: str,
    observation: dict[str, object],
    *,
    renamed: bool,
    require_dead_daemon: bool,
) -> int | None:
    old = observation["old"]
    if old["status"] == "missing":
        try:
            os.stat(entry, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        die("deleted old release lock reappeared after receipt verification")
    old_fd, old_info = open_exact_directory(parent_fd, entry, "old release lock")
    expected = old["identity"]
    if ((inode_shape(old_info) if renamed else stat_identity(old_info))
            != (expected[:5] if renamed else expected)):
        os.close(old_fd)
        die("old release lock inode changed after receipt verification")
    if old["status"] == "empty":
        if os.listdir(old_fd):
            os.close(old_fd)
            die("empty old release lock gained contents")
        return old_fd
    owner_name = str(observation["owner_name"])
    if sorted(os.listdir(old_fd)) != [owner_name]:
        os.close(old_fd)
        die("old release owner contents changed after receipt verification")
    try:
        raw, owner_info = stable_read_at(old_fd, owner_name, limit=16 * 1024)
        if (stat_identity(owner_info) != old["owner_identity"]
                or hashlib.sha256(raw).hexdigest() != old["owner_sha256"]):
            die("old release owner changed after receipt verification")
        if require_dead_daemon:
            try:
                value = json.loads(raw.decode("utf-8", "strict"))
            except (UnicodeDecodeError, ValueError):
                die("old daemon owner became malformed before release completion")
            pid, _token = validate_daemon_owner(value)
            if pid_alive(pid):
                die(f"old daemon owner PID {pid} is live; release completion refused")
    except BaseException:
        os.close(old_fd)
        raise
    return old_fd


def complete_exact_release(
    path: str, owner_name: str, expected_receipt: str, policy: str,
) -> None:
    if not HASH_RE.fullmatch(expected_receipt):
        die("release completion receipt is unsafe", 64)
    observation, receipt = inspect_release_boundary(path, owner_name, policy)
    if receipt != expected_receipt:
        die("release boundary changed; obtain a fresh exact receipt")
    old = observation["old"]
    if policy == "codex-daemon" and old["owner_state"] == "live":
        die(f"old daemon owner PID {old['owner_pid']} is live; release completion refused")

    parent, name = os.path.split(path)
    old_name = str(observation["marker_value"]["old_lock_name"])
    released_name = f".{name}.released.{secrets.token_hex(12)}"
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_fd = os.open(parent, flags)
    exchanged_here = False
    old_mutated = old["status"] in ("empty", "missing")
    finalized = False
    marker_fd = -1
    old_fd = -1
    try:
        validate_parent(parent_fd)
        if observation["phase"] == "pre-exchange":
            old_fd = verify_old_release_at(
                parent_fd, name, observation, renamed=False,
                require_dead_daemon=policy == "codex-daemon",
            ) or -1
            if old_fd >= 0:
                os.close(old_fd)
                old_fd = -1
            marker_fd = verify_release_marker_at(
                parent_fd, old_name, observation, renamed=False,
            )
            os.close(marker_fd)
            marker_fd = -1
            rename_exchange(parent_fd, name, old_name)
            exchanged_here = True
            os.fsync(parent_fd)

        marker_fd = verify_release_marker_at(
            parent_fd, name, observation, renamed=exchanged_here,
        )
        old_fd = verify_old_release_at(
            parent_fd, old_name, observation, renamed=exchanged_here,
            require_dead_daemon=policy == "codex-daemon",
        ) or -1
        if old_fd >= 0:
            if old["status"] == "owner":
                old_mutated = True
                os.unlink(owner_name, dir_fd=old_fd)
                os.fsync(old_fd)
            os.close(old_fd)
            old_fd = -1
            os.rmdir(old_name, dir_fd=parent_fd)
            os.fsync(parent_fd)

        rename_exclusive(parent_fd, name, released_name)
        finalized = True
        os.fsync(parent_fd)
        os.close(marker_fd)
        marker_fd = -1
        remove_marker_directory(parent_fd, released_name)
        os.fsync(parent_fd)
    except BaseException:
        if exchanged_here and not old_mutated:
            try:
                if marker_fd >= 0:
                    os.close(marker_fd)
                    marker_fd = -1
                if old_fd >= 0:
                    os.close(old_fd)
                    old_fd = -1
                rename_exchange(parent_fd, name, old_name)
                exchanged_here = False
                os.fsync(parent_fd)
            except OSError as exc:
                print(
                    f"atomic-directory-lock: CRITICAL: interrupted release could not be "
                    f"restored to pre-exchange state: {exc}", file=sys.stderr,
                )
        raise
    finally:
        if marker_fd >= 0:
            os.close(marker_fd)
        if old_fd >= 0:
            os.close(old_fd)
        if finalized:
            try:
                remove_marker_directory(parent_fd, released_name)
            except OSError:
                pass
        os.close(parent_fd)


def inspect_release_command() -> None:
    if len(sys.argv) != 5:
        die("usage: atomic-directory-lock.py inspect-release PATH OWNER POLICY", 64)
    observation, receipt = inspect_release_boundary(sys.argv[2], sys.argv[3], sys.argv[4])
    old = observation["old"]
    detail = str(old.get("owner_pid") or "-")
    print(f"release|{old['owner_state']}|{detail}|{receipt}")


def recover_release_command() -> None:
    if len(sys.argv) != 6:
        die(
            "usage: atomic-directory-lock.py recover-release PATH OWNER RECEIPT POLICY", 64,
        )
    complete_exact_release(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])


def cleanup_finalized_command() -> None:
    if len(sys.argv) != 5:
        die("usage: atomic-directory-lock.py cleanup-finalized PATH OWNER POLICY", 64)
    path, owner_name, policy = sys.argv[2:]
    if (not os.path.isabs(path) or os.path.normpath(path) != path
            or owner_name not in ("owner", "owner.json")
            or policy not in ("generic", "codex-daemon")):
        die("finalized-release cleanup arguments are unsafe", 64)
    parent, name = os.path.split(path)
    if not name or not re.fullmatch(r"[A-Za-z0-9_.-]{1,255}", name):
        die("finalized-release lock basename is unsafe", 64)
    pattern = re.compile(rf"\.{re.escape(name)}\.released\.[0-9a-f]{{24}}\Z")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_fd = os.open(parent, flags)
    records: list[dict[str, object]] = []
    try:
        validate_parent(parent_fd)
        finalized = sorted(item for item in os.listdir(parent_fd) if pattern.fullmatch(item))
        if not finalized:
            raise NoReleaseBoundary()
        for entry in finalized:
            marker_fd, marker_info = open_exact_directory(
                parent_fd, entry, "finalized release marker",
            )
            try:
                entries = sorted(os.listdir(marker_fd))
                if not entries:
                    records.append({"entry": entry, "identity": stat_identity(marker_info)})
                    continue
                if entries != ["release.json"]:
                    die("finalized release marker has unsafe contents")
            finally:
                os.close(marker_fd)
            value, marker = parse_release_marker(parent_fd, entry, name, owner_name)
            if policy == "codex-daemon" and value["owner_name"] != "owner.json":
                die("finalized daemon release marker has the wrong owner kind")
            records.append({
                "entry": entry, "identity": stat_identity(marker_info), "marker": marker,
            })

        # Inspect every inert artifact before the first removal. Each reopen is
        # bound to the exact inode/file evidence captured above.
        for record in records:
            entry = str(record["entry"])
            marker_fd, marker_info = open_exact_directory(
                parent_fd, entry, "finalized release marker",
            )
            try:
                if stat_identity(marker_info) != record["identity"]:
                    die("finalized release marker changed before cleanup")
                marker = record.get("marker")
                if marker is None:
                    if os.listdir(marker_fd):
                        die("empty finalized release marker gained contents")
                else:
                    if sorted(os.listdir(marker_fd)) != ["release.json"]:
                        die("finalized release marker contents changed")
                    raw, file_info = stable_read_at(marker_fd, "release.json", limit=16 * 1024)
                    if (stat_identity(file_info) != marker["file_identity"]
                            or hashlib.sha256(raw).hexdigest() != marker["sha256"]):
                        die("finalized release marker evidence changed")
                    os.unlink("release.json", dir_fd=marker_fd)
                    os.fsync(marker_fd)
            finally:
                os.close(marker_fd)
            os.rmdir(entry, dir_fd=parent_fd)
            os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def release_exact() -> None:
    if len(sys.argv) != 10:
        die(
            "usage: atomic-directory-lock.py release PATH OWNER LOCK_DEV LOCK_INO "
            "OWNER_DEV OWNER_INO OWNER_SHA256 TOKEN",
            64,
        )
    _, _, path, owner_name, lock_dev, lock_ino, owner_dev, owner_ino, owner_hash, token = sys.argv
    if (not os.path.isabs(path) or os.path.normpath(path) != path
            or owner_name not in ("owner", "owner.json")
            or not re.fullmatch(r"[0-9a-f]{64}", owner_hash)
            or not token or len(token) > 256):
        die("release evidence is unsafe", 64)
    try:
        expected = (int(lock_dev), int(lock_ino), int(owner_dev), int(owner_ino))
    except ValueError:
        die("release inode evidence is unsafe", 64)
    parent, name = os.path.split(path)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_fd = os.open(parent, flags)
    validate_parent(parent_fd)
    exchange_name = f".{name}.release.{secrets.token_hex(12)}"
    released_name = f".{name}.released.{secrets.token_hex(12)}"
    marker_fd = -1
    exchanged = False
    old_mutated = False
    finalized = False
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (not stat.S_ISDIR(current.st_mode)
                or (current.st_dev, current.st_ino) != expected[:2]):
            die("lock inode changed before release")
        lock_fd = os.open(name, flags, dir_fd=parent_fd)
        try:
            read_exact_owner(lock_fd, owner_name, expected, owner_hash, token)
        finally:
            os.close(lock_fd)

        marker = {
            "schema": RELEASE_SCHEMA,
            "phase": "exchanged",
            "lock_name": name,
            "old_lock_name": exchange_name,
            "old_lock_dev": expected[0],
            "old_lock_ino": expected[1],
            "owner_name": owner_name,
            "owner_dev": expected[2],
            "owner_ino": expected[3],
            "owner_sha256": owner_hash,
            "token_sha256": hashlib.sha256(token.encode("utf-8")).hexdigest(),
        }
        marker_raw = (json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n").encode()
        os.mkdir(exchange_name, 0o700, dir_fd=parent_fd)
        marker_fd = os.open(exchange_name, flags, dir_fd=parent_fd)
        os.fchmod(marker_fd, 0o700)
        release_fd = os.open(
            "release.json",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=marker_fd,
        )
        try:
            offset = 0
            while offset < len(marker_raw):
                offset += os.write(release_fd, marker_raw[offset:])
            os.fchmod(release_fd, 0o600)
            os.fsync(release_fd)
        finally:
            os.close(release_fd)
        os.fsync(marker_fd)
        os.close(marker_fd)
        marker_fd = -1

        # The canonical name always denotes either the original lock or this
        # durable tombstone; an in-progress release never looks unlocked.
        rename_exchange(parent_fd, name, exchange_name)
        exchanged = True
        os.fsync(parent_fd)

        old_lock_fd = os.open(exchange_name, flags, dir_fd=parent_fd)
        try:
            read_exact_owner(old_lock_fd, owner_name, expected, owner_hash, token)
            old_mutated = True
            os.unlink(owner_name, dir_fd=old_lock_fd)
            os.fsync(old_lock_fd)
        finally:
            os.close(old_lock_fd)
        os.rmdir(exchange_name, dir_fd=parent_fd)
        os.fsync(parent_fd)

        # This is the release linearization point. A crash may leave only an
        # inert `.released.*` marker, never a hidden active lock.
        rename_exclusive(parent_fd, name, released_name)
        finalized = True
        os.fsync(parent_fd)
        remove_marker_directory(parent_fd, released_name)
        os.fsync(parent_fd)
    except BaseException:
        if exchanged and not old_mutated:
            try:
                rename_exchange(parent_fd, name, exchange_name)
                exchanged = False
                os.fsync(parent_fd)
                remove_marker_directory(parent_fd, exchange_name)
            except OSError as exc:
                print(
                    f"atomic-directory-lock: CRITICAL: release exchange could not be restored: {exc}",
                    file=sys.stderr,
                )
        raise
    finally:
        if marker_fd >= 0:
            os.close(marker_fd)
        if not exchanged and not finalized:
            try:
                remove_marker_directory(parent_fd, exchange_name)
            except OSError:
                pass
        if finalized:
            try:
                remove_marker_directory(parent_fd, released_name)
            except OSError:
                pass
        os.close(parent_fd)


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "cleanup-finalized":
        try:
            cleanup_finalized_command()
        except NoReleaseBoundary:
            raise SystemExit(4)
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "inspect-release":
        try:
            inspect_release_command()
        except NoReleaseBoundary:
            raise SystemExit(4)
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "recover-release":
        try:
            recover_release_command()
        except NoReleaseBoundary:
            die("there is no active exact-release boundary to recover")
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "release":
        release_exact()
        return
    if len(sys.argv) != 3:
        die("usage: atomic-directory-lock.py /absolute/lock owner|owner.json", 64)
    path, owner_name = sys.argv[1:]
    if (not os.path.isabs(path) or os.path.normpath(path) != path
            or owner_name not in ("owner", "owner.json")):
        die("lock path or owner name is unsafe", 64)
    content = sys.stdin.buffer.read(16 * 1024 + 1)
    if not content or len(content) > 16 * 1024:
        die("owner content is empty or exceeds 16KiB", 64)

    parent, name = os.path.split(path)
    if not name or not re.fullmatch(r"[A-Za-z0-9_.-]{1,255}", name):
        die("lock basename is unsafe", 64)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_fd = os.open(parent, flags)
    temporary = f".{name}.publish.{os.getpid()}.{secrets.token_hex(12)}"
    temp_fd = -1
    published = False
    try:
        validate_parent(parent_fd)
        os.mkdir(temporary, 0o700, dir_fd=parent_fd)
        temp_fd = os.open(temporary, flags, dir_fd=parent_fd)
        os.fchmod(temp_fd, 0o700)
        owner_fd = os.open(
            owner_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=temp_fd,
        )
        try:
            offset = 0
            while offset < len(content):
                offset += os.write(owner_fd, content[offset:])
            os.fchmod(owner_fd, 0o600)
            os.fsync(owner_fd)
        finally:
            os.close(owner_fd)
        os.fsync(temp_fd)
        rename_exclusive(parent_fd, temporary, name)
        published = True
        os.fsync(parent_fd)
    except FileExistsError:
        raise SystemExit(17)
    finally:
        if temp_fd >= 0:
            os.close(temp_fd)
        if not published:
            cleanup_fd = -1
            try:
                cleanup_fd = os.open(temporary, flags, dir_fd=parent_fd)
                os.unlink(owner_name, dir_fd=cleanup_fd)
            except OSError:
                pass
            finally:
                if cleanup_fd >= 0:
                    os.close(cleanup_fd)
            try:
                os.rmdir(temporary, dir_fd=parent_fd)
            except OSError:
                pass
        os.close(parent_fd)


if __name__ == "__main__":
    main()
