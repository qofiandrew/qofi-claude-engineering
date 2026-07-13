#!/usr/bin/env bash
# Explicit, evidence-bound recovery for retained swarm lifecycle locks.
#
# This command is intentionally separate from normal lifecycle paths. It never
# treats PID death as sufficient proof, never kills a session, and never infers
# a Codex workspace mutation. `audit` is read-only. `recover` requires the exact
# audit receipt, an explicit acknowledgement, quiescence, and (for a Codex
# workspace mutation) an operator-selected prepare/verify/release action.

set -euo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] \
   || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-recover: SWARM_HOME unset or wrong" >&2
  exit 1
fi

SCRIPT_FILE="$(/usr/bin/python3 -I -B - "$0" <<'PY'
import os,sys
print(os.path.realpath(sys.argv[1]))
PY
)"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_FILE")" && pwd -P)"
CONF="$SWARM_HOME/swarm.conf"
RUNTIME_BIN="${SWARM_CODEX_RUNTIME_BIN:-$SCRIPT_DIR/swarm-codex-runtime.sh}"

usage() {
  cat >&2 <<'EOF'
usage:
  swarm-recover.sh audit mutation [--operation <add|remove|sync|account|up> ...]
  swarm-recover.sh audit launch <name>
  swarm-recover.sh audit repo-lease </canonical/repo>

  swarm-recover.sh recover mutation --receipt <action-bound-sha256> --ack-reconciled \
    --operation <add|remove|sync|account|up> [--name <name>] \
    [--engine <claude|codex>] [--repo </canonical/repo>] \
    [--workspace-action <prepare|verify|release>]

  swarm-recover.sh recover launch <name> --receipt <sha256> --ack-reconciled
  swarm-recover.sh recover repo-lease </canonical/repo> \
    --receipt <sha256> --ack-reconciled

Pass the exact reconciliation arguments to both mutation audit and recovery.
Run `swarm-up.sh down` before mutation recovery, or
`swarm-up.sh down <name>` before launch recovery. Audit never changes state.
EOF
  exit 1
}

valid_name() {
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac
}

# _core inspect|remove mutation|launch [name] [expected-receipt] [reconciliation-json]
#
# The Python core opens every evidence file without following symlinks and
# hashes a canonical observation. In remove mode it recomputes that observation
# immediately before starting the shared exact exchange-release protocol. A
# changed config, owner, session/runtime boundary, or replacement lock
# invalidates the receipt and leaves the retained signal in place. If release
# is interrupted, the canonical name remains an authoritative release marker
# that this same recovery command can audit and finish.
_core() {
  /usr/bin/python3 -I -B - "$SCRIPT_DIR/atomic-directory-lock.py" "$@" <<'PY'
from __future__ import annotations

import ctypes
import datetime as dt
import errno
import hashlib
import json
import os
import pwd
import re
import secrets
import shutil
import stat
import subprocess
import sys
import uuid

MAX_CONF = 2 * 1024 * 1024
MAX_STATE = 2 * 1024 * 1024
NAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]*\Z")
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
ACCOUNT_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*\Z")
HASH_RE = re.compile(r"[0-9a-f]{64}\Z")
ATOMIC_LOCK_HELPER = sys.argv[1]


class Blocked(RuntimeError):
    pass


def blocked(message: str) -> None:
    raise Blocked(message)


def safe_lstat(path: str, label: str, *, kind: str, mode: int | None = None,
               owner: int | None = None) -> os.stat_result:
    try:
        info = os.lstat(path)
    except OSError as exc:
        blocked(f"{label} cannot be inspected: {exc}")
    if stat.S_ISLNK(info.st_mode):
        blocked(f"{label} is a symlink")
    if kind == "file" and not stat.S_ISREG(info.st_mode):
        blocked(f"{label} is not a regular file")
    if kind == "dir" and not stat.S_ISDIR(info.st_mode):
        blocked(f"{label} is not a directory")
    if mode is not None and stat.S_IMODE(info.st_mode) != mode:
        blocked(f"{label} mode is {stat.S_IMODE(info.st_mode):04o}, expected {mode:04o}")
    if owner is not None and info.st_uid != owner:
        blocked(f"{label} owner uid is {info.st_uid}, expected {owner}")
    return info


def identity(info: os.stat_result) -> list[int]:
    return [
        info.st_dev, info.st_ino, info.st_uid, info.st_gid,
        stat.S_IMODE(info.st_mode), info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    ]


def inode_shape(info: os.stat_result) -> list[int]:
    # rename(2) updates directory ctime even though it is the same audited
    # inode. Use the immutable identity/authority fields after exchange;
    # the full timestamp-bearing identity is still compared before rename.
    return [info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)]


def require_no_extended_acl(path: str, label: str) -> None:
    """Fail closed on a macOS extended ACL without following the final path."""
    if sys.platform != "darwin":
        return
    info = os.lstat(path)
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    if stat.S_ISDIR(info.st_mode):
        flags |= getattr(os, "O_DIRECTORY", 0)
    fd = os.open(path, flags)
    try:
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
                return
            blocked(f"{label} ACL cannot be inspected (errno {error})")
        try:
            blocked(f"{label} must not have an extended ACL")
        finally:
            free_acl(acl)
    finally:
        os.close(fd)


def stable_read(path: str, label: str, limit: int, *, mode: int | None = None,
                owner: int | None = None) -> tuple[bytes, os.stat_result]:
    before = safe_lstat(path, label, kind="file", mode=mode, owner=owner)
    if before.st_size > limit:
        blocked(f"{label} exceeds the {limit}-byte recovery bound")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        blocked(f"{label} cannot be opened safely: {exc}")
    try:
        opened = os.fstat(fd)
        if identity(opened) != identity(before):
            blocked(f"{label} changed while opening")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(65536, limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > limit:
                blocked(f"{label} exceeds the recovery bound")
        after = os.fstat(fd)
        if identity(after) != identity(opened):
            blocked(f"{label} changed while reading")
        return b"".join(chunks), opened
    finally:
        os.close(fd)


def pid_live(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except ProcessLookupError:
        return False
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            return False
        return True
    return True


def inspect_lock(path: str, uid: int, label: str) -> dict[str, object]:
    info = safe_lstat(path, label, kind="dir", mode=0o700, owner=uid)
    require_no_extended_acl(path, label)
    try:
        entries = sorted(os.listdir(path))
    except OSError as exc:
        blocked(f"{label} cannot be listed: {exc}")
    if entries != ["owner"]:
        blocked(f"{label} must contain exactly one regular owner file")
    raw, owner_info = stable_read(
        os.path.join(path, "owner"), f"{label}/owner", 32, mode=0o600, owner=uid,
    )
    require_no_extended_acl(os.path.join(path, "owner"), f"{label}/owner")
    try:
        text = raw.decode("ascii", "strict")
    except UnicodeDecodeError:
        blocked(f"{label}/owner is not ASCII")
    if not re.fullmatch(r"[1-9][0-9]*\n?", text):
        blocked(f"{label}/owner is not one positive PID")
    pid = int(text.strip())
    if pid_live(pid):
        blocked(f"{label} owner PID {pid} is live or cannot be disproved")
    return {
        "kind": "owner-lock",
        "path": path,
        "identity": identity(info),
        "owner_identity": identity(owner_info),
        "owner_sha256": hashlib.sha256(raw).hexdigest(),
        "owner_pid": pid,
        "owner_name": "owner",
        "owner_token": None,
    }


def inspect_repo_lease(path: str, repo: str, repo_info: os.stat_result,
                       expected_state_root: str, uid: int) -> dict[str, object]:
    label = f"repo lease for {repo}"
    info = safe_lstat(path, label, kind="dir", mode=0o700, owner=uid)
    require_no_extended_acl(path, label)
    try:
        entries = sorted(os.listdir(path))
    except OSError as exc:
        blocked(f"{label} cannot be listed: {exc}")
    if entries != ["owner.json"]:
        blocked(f"{label} must contain exactly owner.json")
    owner_path = os.path.join(path, "owner.json")
    raw, owner_info = stable_read(
        owner_path, f"{label}/owner.json", 64 * 1024, mode=0o600, owner=uid,
    )
    require_no_extended_acl(owner_path, f"{label}/owner.json")
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError):
        blocked(f"{label}/owner.json is malformed")
    keys = {
        "schema", "pid", "token", "repo_dev", "repo_ino", "repo_path",
        "swarm_name", "state_dir", "operation", "started_at",
    }
    if not isinstance(value, dict) or set(value) != keys:
        blocked(f"{label}/owner.json has the wrong exact key set")
    pid = value.get("pid")
    token = value.get("token")
    swarm_name = value.get("swarm_name")
    state_dir = value.get("state_dir")
    if value.get("schema") != "qofi-codex-repo-lease/v1":
        blocked(f"{label}/owner.json has the wrong schema")
    if type(pid) is not int or pid <= 0:
        blocked(f"{label}/owner.json has an unsafe PID")
    if not isinstance(token, str):
        blocked(f"{label}/owner.json has an unsafe token")
    try:
        parsed_token = uuid.UUID(token)
    except (ValueError, AttributeError):
        blocked(f"{label}/owner.json token is not a UUID")
    if str(parsed_token) != token or parsed_token.version != 4:
        blocked(f"{label}/owner.json token is not a canonical random UUID")
    if (type(value.get("repo_dev")) is not int or type(value.get("repo_ino")) is not int
            or value["repo_dev"] != repo_info.st_dev or value["repo_ino"] != repo_info.st_ino):
        blocked(f"{label}/owner.json repository identity does not match the open repo")
    if value.get("repo_path") != repo:
        blocked(f"{label}/owner.json repository path does not match config")
    if not isinstance(swarm_name, str) or not NAME_RE.fullmatch(swarm_name):
        blocked(f"{label}/owner.json has an unsafe swarm name")
    expected_state = os.path.join(expected_state_root, f"discord-{swarm_name}")
    if (not isinstance(state_dir, str) or not os.path.isabs(state_dir)
            or os.path.normpath(state_dir) != state_dir
            or os.path.realpath(state_dir) != state_dir or state_dir != expected_state):
        blocked(f"{label}/owner.json state directory is not the configured canonical state path")
    if value.get("operation") not in ("startup", "turn", "git"):
        blocked(f"{label}/owner.json has an unknown operation")
    if not timestamp(value.get("started_at")):
        blocked(f"{label}/owner.json has an invalid start time")
    if pid_live(pid):
        blocked(f"{label} owner PID {pid} is live or cannot be disproved")
    return {
        "path": path,
        "identity": identity(info),
        "owner_identity": identity(owner_info),
        "owner_sha256": hashlib.sha256(raw).hexdigest(),
        "owner_pid": pid,
        "owner_name": "owner.json",
        "owner_token": token,
        "repo_dev": repo_info.st_dev,
        "repo_ino": repo_info.st_ino,
        "repo_path": repo,
        "swarm_name": swarm_name,
        "operation": value["operation"],
        "state_dir": state_dir,
        "kind": "owner-lock",
    }


def inspect_release_marker(
    path: str, lock_name: str, owner_name: str, uid: int,
) -> dict[str, object]:
    label = f"repo release marker {path}"
    info = safe_lstat(path, label, kind="dir", mode=0o700, owner=uid)
    require_no_extended_acl(path, label)
    try:
        entries = sorted(os.listdir(path))
    except OSError as exc:
        blocked(f"{label} cannot be listed: {exc}")
    if entries != ["release.json"]:
        blocked(f"{label} must contain exactly release.json")
    marker_path = os.path.join(path, "release.json")
    raw, marker_info = stable_read(
        marker_path, f"{label}/release.json", 16 * 1024, mode=0o600, owner=uid,
    )
    require_no_extended_acl(marker_path, f"{label}/release.json")
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError):
        blocked(f"{label}/release.json is malformed")
    keys = {
        "schema", "phase", "lock_name", "old_lock_name", "old_lock_dev", "old_lock_ino",
        "owner_name", "owner_dev", "owner_ino", "owner_sha256", "token_sha256",
    }
    old_pattern = re.compile(rf"\.{re.escape(lock_name)}\.release\.[0-9a-f]{{24}}\Z")
    if (not isinstance(value, dict) or set(value) != keys
            or value.get("schema") != "qofi-lock-release/v1"
            or value.get("phase") != "exchanged" or value.get("lock_name") != lock_name
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
        blocked(f"{label}/release.json has unsafe exact evidence")
    return {
        "path": path,
        "identity": identity(info),
        "marker_identity": identity(marker_info),
        "marker_sha256": hashlib.sha256(raw).hexdigest(),
        "value": value,
    }


def matching_release_names(parent: str, lock_name: str) -> list[str]:
    try:
        names = os.listdir(parent)
    except OSError as exc:
        blocked(f"release-marker parent cannot be listed: {exc}")
    return sorted(
        name for name in names
        if re.fullmatch(rf"\.{re.escape(lock_name)}\.release\.[0-9a-f]{{24}}", name)
    )


def inspect_inert_release(path: str, lock_name: str, uid: int) -> dict[str, object]:
    info = safe_lstat(path, "finalized release marker", kind="dir", mode=0o700, owner=uid)
    require_no_extended_acl(path, "finalized release marker")
    entries = sorted(os.listdir(path))
    if not entries:
        return {"path": path, "identity": identity(info), "status": "empty"}
    if entries != ["release.json"]:
        blocked("finalized release marker has unsafe contents")
    raw, marker_info = stable_read(
        os.path.join(path, "release.json"), "finalized release marker/release.json",
        16 * 1024, mode=0o600, owner=uid,
    )
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError):
        blocked("finalized release marker JSON is malformed")
    if (not isinstance(value, dict) or value.get("schema") != "qofi-lock-release/v1"
            or value.get("phase") != "exchanged" or value.get("lock_name") != lock_name):
        blocked("finalized release marker JSON is not bound to its lock name")
    return {
        "path": path, "identity": identity(info), "status": "marker",
        "marker_identity": identity(marker_info),
        "marker_sha256": hashlib.sha256(raw).hexdigest(),
    }


def inspect_plain_lock_boundary(path: str, uid: int, label: str) -> dict[str, object]:
    """Inspect a PID-owner lock plus either phase of exact exchange release."""
    lock_name = os.path.basename(path)
    parent = os.path.dirname(path)
    try:
        canonical_entries = sorted(os.listdir(path))
    except OSError as exc:
        blocked(f"{label} cannot be listed: {exc}")
    release_names = matching_release_names(parent, lock_name)
    marker: dict[str, object]
    old: dict[str, object]
    if canonical_entries == ["owner"]:
        old = inspect_lock(path, uid, label)
        if not release_names:
            return old
        if len(release_names) != 1:
            blocked(f"{label} has ambiguous pre-exchange release markers")
        marker = inspect_release_marker(
            os.path.join(parent, release_names[0]), lock_name, "owner", uid,
        )
        phase = "pre-exchange"
    elif canonical_entries == ["release.json"]:
        marker = inspect_release_marker(path, lock_name, "owner", uid)
        value = marker["value"]
        old_name = str(value["old_lock_name"])
        if any(name != old_name for name in release_names):
            blocked(f"{label} has an unrelated active release marker")
        old_path = os.path.join(parent, old_name)
        if not os.path.lexists(old_path):
            old = {"status": "missing", "path": old_path}
        else:
            old_info = safe_lstat(
                old_path, f"old {label}", kind="dir", mode=0o700, owner=uid,
            )
            require_no_extended_acl(old_path, f"old {label}")
            entries = sorted(os.listdir(old_path))
            if entries == ["owner"]:
                old = inspect_lock(old_path, uid, f"old {label}")
            elif not entries:
                old = {"status": "empty", "path": old_path, "identity": identity(old_info)}
            else:
                blocked(f"old {label} has unsafe contents")
        phase = "exchanged"
    else:
        blocked(f"{label} is neither an owner lock nor an exact release marker")
    value = marker["value"]
    if old.get("status") not in ("missing", "empty"):
        if (old["identity"][0:2] != [value["old_lock_dev"], value["old_lock_ino"]]
                or old["owner_identity"][0:2] != [value["owner_dev"], value["owner_ino"]]
                or old["owner_sha256"] != value["owner_sha256"]
                or hashlib.sha256(b"-").hexdigest() != value["token_sha256"]):
            blocked(f"{label} release marker does not bind the exact old PID owner")
    elif old.get("status") == "empty" and (
        old["identity"][0:2] != [value["old_lock_dev"], value["old_lock_ino"]]
    ):
        blocked(f"empty old {label} inode is not marker-bound")
    return {
        "kind": "release-tombstone", "path": path, "phase": phase,
        "identity": marker["identity"] if phase == "exchanged" else old["identity"],
        "marker": marker, "old": old, "owner_name": "owner",
        "owner_pid": old.get("owner_pid"), "owner_token": None,
    }


def inspect_repo_release(
    canonical: str,
    repo: str,
    repo_info: os.stat_result,
    expected_state_root: str,
    uid: int,
    active_names: list[str],
) -> dict[str, object]:
    lock_name = os.path.basename(canonical)
    canonical_entries = sorted(os.listdir(canonical))
    release_names = [
        name for name in active_names
        if re.fullmatch(rf"\.{re.escape(lock_name)}\.release\.[0-9a-f]{{24}}", name)
    ]
    marker: dict[str, object]
    old: dict[str, object]
    phase: str
    if canonical_entries == ["owner.json"]:
        if len(release_names) != 1:
            blocked("pre-exchange repo release must have exactly one bound marker")
        old = inspect_repo_lease(canonical, repo, repo_info, expected_state_root, uid)
        marker = inspect_release_marker(
            os.path.join(os.path.dirname(canonical), release_names[0]), lock_name,
            "owner.json", uid,
        )
        phase = "pre-exchange"
    elif canonical_entries == ["release.json"]:
        marker = inspect_release_marker(canonical, lock_name, "owner.json", uid)
        marker_value = marker["value"]
        old_name = str(marker_value["old_lock_name"])
        unexpected = [name for name in release_names if name != old_name]
        if unexpected:
            blocked("repo release has an unrelated active exchange marker")
        old_path = os.path.join(os.path.dirname(canonical), old_name)
        if not os.path.lexists(old_path):
            old = {"status": "missing", "path": old_path}
        else:
            old_info = safe_lstat(
                old_path, "old repo lease during release", kind="dir", mode=0o700, owner=uid,
            )
            require_no_extended_acl(old_path, "old repo lease during release")
            old_entries = sorted(os.listdir(old_path))
            if old_entries == ["owner.json"]:
                old = inspect_repo_lease(old_path, repo, repo_info, expected_state_root, uid)
            elif not old_entries:
                old = {"status": "empty", "path": old_path, "identity": identity(old_info)}
            else:
                blocked("old repo lease during release has unsafe contents")
        phase = "exchanged"
    else:
        blocked("canonical repo lease is neither an owner lock nor an exact release marker")
    value = marker["value"]
    if old.get("status") not in ("missing", "empty"):
        if (old["identity"][0:2] != [value["old_lock_dev"], value["old_lock_ino"]]
                or old["owner_identity"][0:2] != [value["owner_dev"], value["owner_ino"]]
                or old["owner_sha256"] != value["owner_sha256"]
                or hashlib.sha256(str(old["owner_token"]).encode()).hexdigest()
                   != value["token_sha256"]):
            blocked("repo release marker does not bind the exact old owner lock")
    elif old.get("status") == "empty":
        if old["identity"][0:2] != [value["old_lock_dev"], value["old_lock_ino"]]:
            blocked("empty old repo lease inode is not marker-bound")
    return {
        "kind": "release-tombstone", "path": canonical, "phase": phase,
        "identity": marker["identity"] if phase == "exchanged" else old["identity"],
        "marker": marker, "old": old, "owner_name": "owner.json",
        "owner_pid": old.get("owner_pid"), "owner_token": old.get("owner_token"),
        "repo_dev": repo_info.st_dev, "repo_ino": repo_info.st_ino, "repo_path": repo,
        "swarm_name": old.get("swarm_name"), "operation": "release",
        "state_dir": old.get("state_dir"),
    }


def inspect_conf(path: str, uid: int) -> tuple[dict[str, object], list[dict[str, object]]]:
    raw, info = stable_read(path, "swarm.conf", MAX_CONF, owner=uid)
    require_no_extended_acl(path, "swarm.conf")
    if stat.S_IMODE(info.st_mode) & 0o022:
        blocked("swarm.conf is group/world writable")
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        blocked("swarm.conf is not valid UTF-8")
    rows: list[dict[str, object]] = []
    seen: set[str] = set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if any(ord(ch) < 32 or ord(ch) == 127 for ch in line):
            blocked(f"swarm.conf line {number} contains a control character")
        fields = line.split("|")
        fields += [""] * max(0, 7 - len(fields))
        name, repo, token, channel, guild, account, engine = (
            value.strip() for value in fields[:7]
        )
        engine = engine or "claude"
        if not NAME_RE.fullmatch(name):
            blocked(f"swarm.conf line {number} has an unsafe name")
        if name in seen:
            blocked(f"swarm.conf contains duplicate name {name}")
        seen.add(name)
        if not TOKEN_RE.fullmatch(token):
            blocked(f"swarm.conf row {name} has an unsafe token variable")
        if channel and not channel.isdigit():
            blocked(f"swarm.conf row {name} has a nonnumeric channel")
        if guild and not guild.isdigit():
            blocked(f"swarm.conf row {name} has a nonnumeric guild")
        if account and not ACCOUNT_RE.fullmatch(account):
            blocked(f"swarm.conf row {name} has an unsafe account label")
        if engine not in ("claude", "codex"):
            blocked(f"swarm.conf row {name} has unknown engine {engine}")
        if (not repo or not os.path.isabs(repo) or os.path.normpath(repo) != repo
                or any(ord(ch) < 32 or ord(ch) == 127 for ch in repo)):
            blocked(f"swarm.conf row {name} has an unsafe repository path")
        repo_evidence: dict[str, object]
        try:
            repo_info = os.lstat(repo)
        except FileNotFoundError:
            if engine == "codex":
                blocked(f"Codex repository is missing for {name}: {repo}")
            repo_evidence = {"status": "missing"}
        else:
            if stat.S_ISLNK(repo_info.st_mode):
                if engine == "codex":
                    blocked(f"Codex repository is a symlink for {name}: {repo}")
                repo_evidence = {"status": "symlink", "identity": identity(repo_info)}
            elif not stat.S_ISDIR(repo_info.st_mode):
                blocked(f"repository path is not a directory for {name}: {repo}")
            else:
                canonical = os.path.realpath(repo)
                if engine == "codex" and canonical != repo:
                    blocked(f"Codex repository is noncanonical for {name}: {repo}")
                repo_evidence = {
                    # Workspace prepare/release intentionally changes ownership,
                    # modes, and ctime across this exact tree. Bind the config
                    # row to canonical pathname plus immutable directory
                    # device/inode so that explicit reconciliation can finish
                    # without weakening replacement detection.
                    "status": "directory",
                    "device_inode": [repo_info.st_dev, repo_info.st_ino],
                    "canonical": canonical,
                }
        rows.append({
            "name": name, "repo": repo, "token": token, "channel": channel,
            "guild": guild, "account": account, "engine": engine,
            "line": number, "repo_evidence": repo_evidence,
        })
    return {
        "path": path,
        "identity": identity(info),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }, rows


def tmux_sessions() -> tuple[str, list[str]]:
    configured = os.environ.get("SWARM_TMUX_BIN", "tmux")
    if "/" in configured:
        if not os.path.isabs(configured):
            blocked("SWARM_TMUX_BIN must be a command name or absolute path")
        binary = configured
    else:
        binary = shutil.which(configured) or ""
    if not binary:
        blocked(f"tmux is unavailable: {configured}")
    try:
        result = subprocess.run(
            [binary, "list-sessions", "-F", "#{session_name}"],
            text=True, capture_output=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        blocked(f"tmux session inventory failed: {exc}")
    if result.returncode not in (0, 1):
        blocked(f"tmux session inventory failed with exit {result.returncode}")
    if len(result.stdout.encode("utf-8", "replace")) > 1024 * 1024:
        blocked("tmux session inventory exceeds the recovery bound")
    sessions = sorted({line for line in result.stdout.splitlines() if line})
    if any(any(ord(ch) < 32 or ord(ch) == 127 for ch in name) for name in sessions):
        blocked("tmux returned an unsafe session name")
    return os.path.realpath(binary), sessions


def timestamp(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def inspect_runtime_state(name: str, base_home: str, uid: int) -> dict[str, object]:
    codex = os.path.join(base_home, ".codex")
    channels = os.path.join(codex, "channels")
    state = os.path.join(channels, f"discord-{name}")
    for path, label in ((codex, "CODEX_HOME"), (channels, "Codex channels root"),
                        (state, f"Codex state for {name}")):
        if not os.path.lexists(path):
            return {"name": name, "status": "missing", "path": state}
        safe_lstat(path, label, kind="dir", mode=0o700, owner=uid)
    evidence: dict[str, object] = {
        "name": name, "status": "quiescent", "path": state,
        "state_identity": identity(os.lstat(state)),
    }
    runtime = os.path.join(state, "runtime.json")
    if os.path.lexists(runtime):
        raw, info = stable_read(runtime, f"runtime state for {name}", MAX_STATE,
                                mode=0o600, owner=uid)
        try:
            value = json.loads(raw.decode("utf-8", "strict"))
        except (UnicodeDecodeError, ValueError):
            blocked(f"runtime state for {name} is malformed")
        if (not isinstance(value, dict) or value.get("schema") != "codex-bridge-runtime/v1"
                or type(value.get("pid")) is not int or value["pid"] <= 0
                or not timestamp(value.get("started_at"))
                or not timestamp(value.get("updated_at"))
                or type(value.get("ready")) is not bool
                or type(value.get("active")) is not bool
                or type(value.get("queue_depth")) is not int
                or value["queue_depth"] < 0
                or value.get("backend") not in ("exec", "app-server")):
            blocked(f"runtime state for {name} has the wrong schema")
        child = value.get("child_pid")
        if child is not None and (type(child) is not int or child <= 0):
            blocked(f"runtime state for {name} has an unsafe child PID")
        pids = [value["pid"]] + ([child] if child is not None else [])
        live = [pid for pid in pids if pid_live(pid)]
        if live:
            blocked(f"Codex runtime for {name} still has live PID(s): {','.join(map(str, live))}")
        evidence["runtime"] = {
            "identity": identity(info), "sha256": hashlib.sha256(raw).hexdigest(),
            "pids": pids,
        }
    else:
        evidence["runtime"] = None
    daemon = os.path.join(state, "daemon.lock")
    if os.path.lexists(daemon):
        daemon_info = safe_lstat(
            daemon, f"daemon lock for {name}", kind="dir", mode=0o700, owner=uid,
        )
        try:
            daemon_entries = sorted(os.listdir(daemon))
        except OSError as exc:
            blocked(f"daemon lock for {name} cannot be listed: {exc}")
        if daemon_entries != ["owner.json"]:
            blocked(f"daemon lock for {name} has unexpected entries")
        owner_path = os.path.join(daemon, "owner.json")
        raw, owner_info = stable_read(
            owner_path, f"daemon owner for {name}", 64 * 1024, mode=0o600, owner=uid,
        )
        try:
            value = json.loads(raw.decode("utf-8", "strict"))
        except (UnicodeDecodeError, ValueError):
            blocked(f"daemon owner for {name} is malformed")
        pid = value.get("pid") if isinstance(value, dict) else None
        if (not isinstance(value, dict) or value.get("schema") != "codex-bridge-lock/v1"
                or type(pid) is not int or pid <= 0):
            blocked(f"daemon owner for {name} has the wrong schema")
        if pid_live(pid):
            blocked(f"Codex daemon lock for {name} still names live PID {pid}")
        evidence["daemon"] = {
            "identity": identity(daemon_info), "owner_identity": identity(owner_info),
            "owner_sha256": hashlib.sha256(raw).hexdigest(), "pid": pid,
        }
    else:
        evidence["daemon"] = None
    return evidence


def launch_inventory(root: str, uid: int) -> list[dict[str, object]]:
    if not os.path.lexists(root):
        return []
    safe_lstat(root, "launch-lock root", kind="dir", mode=0o700, owner=uid)
    require_no_extended_acl(root, "launch-lock root")
    try:
        names = sorted(os.listdir(root))
    except OSError as exc:
        blocked(f"launch-lock root cannot be listed: {exc}")
    result = []
    for name in names:
        released = re.fullmatch(r"\.([A-Za-z0-9_][A-Za-z0-9_-]*)\.released\.[0-9a-f]{24}", name)
        if released:
            inspect_inert_release(os.path.join(root, name), released.group(1), uid)
            continue
        if re.fullmatch(r"\.[A-Za-z0-9_][A-Za-z0-9_-]*\.release\.[0-9a-f]{24}", name):
            # Bound and reported with its canonical lock below.
            continue
        if not NAME_RE.fullmatch(name):
            blocked("launch-lock root contains an unsafe entry")
        result.append(inspect_plain_lock_boundary(
            os.path.join(root, name), uid, f"launch lock {name}",
        ))
    return result


def repo_lease_root_inventory(root: str, uid: int) -> dict[str, object]:
    if not os.path.lexists(root):
        return {"status": "missing", "path": root, "entries": []}
    info = safe_lstat(root, "repo-lease root", kind="dir", mode=0o700, owner=uid)
    require_no_extended_acl(root, "repo-lease root")
    try:
        names = sorted(os.listdir(root))
    except OSError as exc:
        blocked(f"repo-lease root cannot be listed: {exc}")
    active: list[str] = []
    inert: list[dict[str, object]] = []
    for name in names:
        released = re.fullmatch(r"\.([0-9]+-[0-9]+\.lock)\.released\.[0-9a-f]{24}", name)
        if released:
            inert.append(inspect_inert_release(os.path.join(root, name), released.group(1), uid))
            continue
        if (not re.fullmatch(r"[0-9]+-[0-9]+\.lock", name)
                and not re.fullmatch(r"\.[0-9]+-[0-9]+\.lock\.release\.[0-9a-f]{24}", name)):
            blocked("repo-lease root contains an unsafe entry")
        path = os.path.join(root, name)
        safe_lstat(path, f"repo lease {name}", kind="dir", mode=0o700, owner=uid)
        require_no_extended_acl(path, f"repo lease {name}")
        active.append(name)
    return {
        "status": "present", "path": root, "identity": identity(info),
        "entries": active, "inert_entries": inert,
    }


def reconciliation(value: str, scope: str) -> dict[str, object] | None:
    if not value:
        return None
    try:
        item = json.loads(value)
    except ValueError:
        blocked("reconciliation evidence is not valid JSON")
    if scope != "mutation":
        blocked("reconciliation evidence is valid only for mutation recovery")
    keys = {
        "operation", "name", "engine", "repo", "workspace_action", "journal_evidence",
    }
    if not isinstance(item, dict) or set(item) != keys:
        blocked("reconciliation evidence has the wrong exact key set")
    operation = item.get("operation")
    target_name = item.get("name")
    engine = item.get("engine")
    repo = item.get("repo")
    action = item.get("workspace_action")
    journal = item.get("journal_evidence")
    if not all(isinstance(part, str) for part in (operation, target_name, engine, repo, action)):
        blocked("reconciliation evidence contains a non-string field")
    if operation not in ("add", "remove", "sync", "account", "up"):
        blocked("reconciliation operation is invalid")
    if operation in ("add", "remove"):
        if not NAME_RE.fullmatch(target_name) or engine not in ("claude", "codex"):
            blocked("add/remove reconciliation target is invalid")
        if (not repo or not os.path.isabs(repo) or os.path.normpath(repo) != repo
                or any(ord(ch) < 32 or ord(ch) == 127 for ch in repo)):
            blocked("add/remove reconciliation repo is invalid")
        if engine == "claude" and action:
            blocked("Claude reconciliation must not contain a workspace action")
        if engine == "codex" and action not in ("prepare", "verify", "release"):
            blocked("Codex reconciliation requires an exact workspace action")
    elif operation in ("account", "up"):
        if not NAME_RE.fullmatch(target_name) or any((engine, repo, action)):
            blocked("account/up reconciliation has incompatible fields")
    elif operation == "sync" and any((target_name, engine, repo, action)):
        blocked("sync reconciliation has incompatible fields")
    if action == "release":
        evidence_keys = {"schema", "repo", "present", "journal_sha256"}
        if (not isinstance(journal, dict) or set(journal) != evidence_keys
                or journal.get("schema") != "qofi-codex-workspace-journal-evidence/v1"
                or journal.get("repo") != repo or journal.get("present") is not True
                or not isinstance(journal.get("journal_sha256"), str)
                or not HASH_RE.fullmatch(journal["journal_sha256"])):
            blocked("release reconciliation lacks exact root workspace-journal evidence")
    elif journal is not None:
        blocked("workspace-journal evidence is valid only for release")
    return item


def observe(scope: str, name: str, reconciliation_raw: str = "") -> tuple[dict[str, object], dict[str, object], list[dict[str, object]]]:
    uid = os.getuid()
    swarm_home = os.environ["SWARM_HOME"]
    if not os.path.isabs(swarm_home) or os.path.realpath(swarm_home) != swarm_home:
        blocked("SWARM_HOME must be an absolute canonical directory")
    safe_lstat(swarm_home, "SWARM_HOME", kind="dir", owner=uid)
    conf_path = os.path.join(swarm_home, "swarm.conf")
    conf, rows = inspect_conf(conf_path, uid)
    tmux_binary, sessions = tmux_sessions()

    try:
        account_home = os.path.realpath(pwd.getpwuid(uid).pw_dir)
    except KeyError:
        blocked("current uid has no account home")
    if os.environ.get("SWARM_RECOVERY_ALLOW_FAKE_HOME") == "1":
        # Test-only isolation hook. A lone environment flag must never redirect
        # production recovery away from the current account's real evidence.
        test_root = os.environ.get("SWARM_RECOVERY_TEST_ROOT", "")
        sentinel = os.path.join(test_root, ".swarm-recovery-test-fixture")
        account_home = os.path.realpath(os.environ.get("HOME", ""))
        if (not test_root or not os.path.isabs(test_root)
                or os.path.realpath(test_root) != test_root):
            blocked("fake HOME is available only inside an explicit canonical test root")
        root_info = safe_lstat(test_root, "recovery test root", kind="dir", mode=0o700, owner=uid)
        test_home_info = safe_lstat(
            account_home, "recovery test HOME", kind="dir", mode=0o700, owner=uid,
        )
        marker, _ = stable_read(
            sentinel, "recovery test sentinel", 128, mode=0o600, owner=uid,
        )
        if (marker != b"qofi-swarm-recovery-test-fixture/v1\n"
                or os.path.dirname(account_home) != test_root
                or os.path.dirname(swarm_home) != test_root
                or root_info.st_dev != test_home_info.st_dev):
            blocked("fake HOME test fixture is not an isolated sibling boundary")
        fake_home = True
    else:
        supplied_home = os.path.realpath(os.environ.get("HOME", ""))
        if supplied_home != account_home:
            blocked("HOME does not match the current account's canonical home")
        fake_home = False

    mutation_path = conf_path + ".mutation.lock"
    launch_root = conf_path + ".launch.locks"
    repo_lease_root = os.path.join(account_home, ".codex", "channels", "repo-locks")
    if scope == "mutation":
        lock = inspect_plain_lock_boundary(mutation_path, uid, "mutation lock")
        launch_locks = launch_inventory(launch_root, uid)
        if launch_locks:
            blocked("launch locks remain; recover each exact launch before mutation recovery")
        repo_leases = repo_lease_root_inventory(repo_lease_root, uid)
        if repo_leases["entries"]:
            blocked("repo leases remain; recover each exact dead repo lease before mutation recovery")
        fleet = [session for session in sessions if session.startswith("swarm-")]
        if fleet:
            blocked("fleet tmux sessions remain: " + ",".join(fleet))
        state_names = sorted({str(row["name"]) for row in rows})
    elif scope == "launch":
        if not NAME_RE.fullmatch(name):
            blocked("launch recovery name is unsafe")
        lock = inspect_plain_lock_boundary(
            os.path.join(launch_root, name), uid, f"launch lock {name}",
        )
        exact = f"swarm-{name}"
        if exact in sessions:
            blocked(f"tmux session {exact} still exists")
        launch_locks = []
        repo_leases = repo_lease_root_inventory(repo_lease_root, uid)
        state_names = [name]
    elif scope == "repo-lease":
        repo = name
        if (not os.path.isabs(repo) or os.path.normpath(repo) != repo
                or os.path.realpath(repo) != repo or not os.path.isdir(repo)
                or os.path.islink(repo)):
            blocked("repo-lease recovery target must be an existing canonical directory")
        repo_info = os.lstat(repo)
        base = f"{repo_info.st_dev}-{repo_info.st_ino}.lock"
        expected = os.path.join(repo_lease_root, base)
        root_evidence = repo_lease_root_inventory(repo_lease_root, uid)
        if base not in root_evidence["entries"]:
            blocked("the configured repository inode has no exact retained repo lease")
        exact_state_root = os.path.join(account_home, ".codex", "channels")
        canonical_entries = sorted(os.listdir(expected))
        release_names = [
            entry for entry in root_evidence["entries"]
            if re.fullmatch(rf"\.{re.escape(base)}\.release\.[0-9a-f]{{24}}", entry)
        ]
        if canonical_entries == ["owner.json"] and not release_names:
            lock = inspect_repo_lease(expected, repo, repo_info, exact_state_root, uid)
        else:
            lock = inspect_repo_release(
                expected, repo, repo_info, exact_state_root, uid,
                list(root_evidence["entries"]),
            )
        fleet = [session for session in sessions if session.startswith("swarm-")]
        if fleet:
            blocked("fleet tmux sessions remain: " + ",".join(fleet))
        launch_locks = []
        repo_leases = root_evidence
        owner_swarm = lock.get("swarm_name")
        state_names = sorted(
            {str(row["name"]) for row in rows}
            | ({str(owner_swarm)} if isinstance(owner_swarm, str) and owner_swarm else set())
        )
    else:
        blocked("scope must be mutation, launch, or repo-lease")

    runtime = [inspect_runtime_state(item, account_home, uid) for item in state_names]
    reconciliation_evidence = reconciliation(reconciliation_raw, scope) \
        if reconciliation_raw else None
    observation = {
        "schema": "swarm-recovery-receipt/v1",
        "scope": scope, "name": name if scope in ("launch", "repo-lease") else None,
        "reconciliation": reconciliation_evidence,
        "lock": lock, "config": conf, "rows": rows,
        "tmux_binary": tmux_binary, "sessions": sessions,
        "runtime": runtime, "launch_locks": launch_locks, "repo_leases": repo_leases,
        "account_home": account_home, "fake_home_test_hook": fake_home,
    }
    return observation, lock, rows


def receipt(observation: dict[str, object]) -> str:
    raw = json.dumps(
        observation, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
    ).encode("ascii")
    return hashlib.sha256(raw).hexdigest()


def report(observation: dict[str, object], rows: list[dict[str, object]], digest: str) -> None:
    lock = observation["lock"]
    print(f"SCOPE={observation['scope']}")
    if observation["scope"] == "launch":
        print(f"NAME={observation['name']}")
    elif observation["scope"] == "repo-lease":
        print(f"REPO={observation['name']}")
        print(f"REPO_ID={lock['repo_dev']}:{lock['repo_ino']}")
        print(f"SWARM_NAME={lock.get('swarm_name') or 'release-finalizing'}")
        print(f"LEASE_OPERATION={lock['operation']}")
        if isinstance(lock.get("owner_token"), str):
            print(f"OWNER_TOKEN_SHA256={hashlib.sha256(lock['owner_token'].encode()).hexdigest()}")
        else:
            print(f"OWNER_TOKEN_SHA256={lock['marker']['value']['token_sha256']}")
    print(f"LOCK={lock['path']}")
    print(f"LOCK_ID={lock['identity'][0]}:{lock['identity'][1]}")
    print(f"OWNER_PID={lock.get('owner_pid') if lock.get('owner_pid') is not None else 'removed'}")
    print("OWNER_STATE=dead" if lock.get("owner_pid") is not None else "OWNER_STATE=release-finalizing")
    print(f"CONF_SHA256={observation['config']['sha256']}")
    action = observation.get("reconciliation")
    if isinstance(action, dict):
        print(f"ACTION_OPERATION={action['operation']}")
        print(f"ACTION_NAME={action['name']}")
        print(f"ACTION_ENGINE={action['engine']}")
        print(f"ACTION_REPO={action['repo']}")
        print(f"ACTION_WORKSPACE={action['workspace_action']}")
        journal = action.get("journal_evidence")
        if isinstance(journal, dict):
            print(f"ACTION_JOURNAL_SHA256={journal['journal_sha256']}")
    print(f"TMUX_SESSIONS={json.dumps(observation['sessions'], separators=(',', ':'))}")
    for row in rows:
        print(f"ROW\t{row['name']}\t{row['engine']}\t{row['repo']}")
    for state in observation["runtime"]:
        print(f"RUNTIME\t{state['name']}\t{state['status']}")
    print(f"RECEIPT={digest}")
    print("RESULT=ready-for-explicit-reconciliation")


def remove_exact_lock(observation: dict[str, object], lock: dict[str, object]) -> None:
    token = str(lock["owner_token"]) if lock["owner_token"] is not None else "-"
    evidence = [
        str(lock["identity"][0]), str(lock["identity"][1]),
        str(lock["owner_identity"][0]), str(lock["owner_identity"][1]),
        str(lock["owner_sha256"]), token,
    ]
    try:
        result = subprocess.run(
            [
                "/usr/bin/python3", "-I", "-B", ATOMIC_LOCK_HELPER, "release",
                str(lock["path"]), str(lock["owner_name"]), *evidence,
            ],
            text=True, capture_output=True, timeout=10,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        blocked(f"exact exchange release could not be executed: {exc}")
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()[:500]
        blocked(f"exact exchange release refused; retained marker requires audit: {detail}")


def rename_exchange_fd(parent_fd: int, first: str, second: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renameatx_np if sys.platform == "darwin" else getattr(libc, "renameat2", None)
    if function is None:
        blocked("host has no atomic rename-exchange primitive")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_uint]
    function.restype = ctypes.c_int
    flag = 0x00000002
    ctypes.set_errno(0)
    if function(parent_fd, first.encode(), parent_fd, second.encode(), flag) != 0:
        error = ctypes.get_errno()
        blocked(f"release-marker exchange failed (errno {error})")


def rename_exclusive_fd(parent_fd: int, source: str, destination: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renameatx_np if sys.platform == "darwin" else getattr(libc, "renameat2", None)
    if function is None:
        blocked("host has no rename-no-replace primitive")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_uint]
    function.restype = ctypes.c_int
    flag = 0x00000004 if sys.platform == "darwin" else 0x00000001
    ctypes.set_errno(0)
    if function(parent_fd, source.encode(), parent_fd, destination.encode(), flag) != 0:
        error = ctypes.get_errno()
        blocked(f"release-marker finalization failed (errno {error})")


def remove_exact_release(lock: dict[str, object]) -> None:
    """Complete either phase of the helper's crash-safe exchange release."""
    path = str(lock["path"])
    parent, name = os.path.split(path)
    marker = lock["marker"]
    marker_value = marker["value"]
    old = lock["old"]
    old_name = str(marker_value["old_lock_name"])
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    pfd = os.open(parent, flags)
    finalized_name: str | None = None

    def verify_marker(entry: str, *, exchanged: bool) -> None:
        fd = os.open(entry, flags, dir_fd=pfd)
        try:
            current = os.fstat(fd)
            expected = marker["identity"]
            if ((inode_shape(current) if exchanged else identity(current))
                    != (expected[:5] if exchanged else expected)):
                blocked("release marker inode changed after receipt verification")
            if sorted(os.listdir(fd)) != ["release.json"]:
                blocked("release marker contents changed after receipt verification")
            marker_info = os.stat("release.json", dir_fd=fd, follow_symlinks=False)
            if identity(marker_info) != marker["marker_identity"]:
                blocked("release marker file changed after receipt verification")
            marker_fd = os.open(
                "release.json", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=fd,
            )
            try:
                opened = os.fstat(marker_fd)
                raw = os.read(marker_fd, 16 * 1024 + 1)
                after = os.fstat(marker_fd)
                if (identity(opened) != marker["marker_identity"]
                        or identity(after) != marker["marker_identity"]
                        or hashlib.sha256(raw).hexdigest() != marker["marker_sha256"]):
                    blocked("release marker evidence changed while reopening")
            finally:
                os.close(marker_fd)
        finally:
            os.close(fd)

    def verify_old(entry: str, *, exchanged: bool) -> int | None:
        status = old.get("status")
        if status == "missing":
            if os.path.lexists(os.path.join(parent, entry)):
                blocked("deleted old lock reappeared after receipt verification")
            return None
        fd = os.open(entry, flags, dir_fd=pfd)
        current = os.fstat(fd)
        expected_identity = old["identity"]
        if ((inode_shape(current) if exchanged else identity(current))
                != (expected_identity[:5] if exchanged else expected_identity)):
            os.close(fd)
            blocked("old lock inode changed after receipt verification")
        if status == "empty":
            if os.listdir(fd):
                os.close(fd)
                blocked("empty old lock gained contents")
            return fd
        owner_name = str(old["owner_name"])
        if sorted(os.listdir(fd)) != [owner_name]:
            os.close(fd)
            blocked("old lock owner contents changed")
        owner = os.stat(owner_name, dir_fd=fd, follow_symlinks=False)
        if identity(owner) != old["owner_identity"]:
            os.close(fd)
            blocked("old lock owner inode changed")
        owner_fd = os.open(
            owner_name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=fd,
        )
        try:
            opened = os.fstat(owner_fd)
            raw = os.read(owner_fd, 64 * 1024 + 1)
            after = os.fstat(owner_fd)
            if (identity(opened) != old["owner_identity"]
                    or identity(after) != old["owner_identity"]
                    or hashlib.sha256(raw).hexdigest() != old["owner_sha256"]):
                blocked("old lock owner evidence changed while reopening")
        finally:
            os.close(owner_fd)
        return fd

    try:
        if lock["phase"] == "pre-exchange":
            old_fd = verify_old(name, exchanged=False)
            if old_fd is not None:
                os.close(old_fd)
            verify_marker(old_name, exchanged=False)
            rename_exchange_fd(pfd, name, old_name)
            os.fsync(pfd)
        verify_marker(name, exchanged=True)
        old_fd = verify_old(old_name, exchanged=True)
        if old_fd is not None:
            try:
                if old.get("status") != "empty":
                    os.unlink(str(old["owner_name"]), dir_fd=old_fd)
                    os.fsync(old_fd)
            finally:
                os.close(old_fd)
            os.rmdir(old_name, dir_fd=pfd)
            os.fsync(pfd)
        finalized_name = f".{name}.released.{secrets.token_hex(12)}"
        rename_exclusive_fd(pfd, name, finalized_name)
        os.fsync(pfd)
        marker_fd = os.open(finalized_name, flags, dir_fd=pfd)
        try:
            if sorted(os.listdir(marker_fd)) != ["release.json"]:
                blocked("finalized release marker changed before cleanup")
            os.unlink("release.json", dir_fd=marker_fd)
            os.fsync(marker_fd)
        finally:
            os.close(marker_fd)
        os.rmdir(finalized_name, dir_fd=pfd)
        finalized_name = None
        os.fsync(pfd)
    finally:
        # A retained `.released.*` name is an inert, auditable cleanup artifact.
        os.close(pfd)


def main() -> None:
    if len(sys.argv) < 4:
        blocked("internal recovery invocation is incomplete")
    mode, scope = sys.argv[2:4]
    name = sys.argv[4] if len(sys.argv) >= 5 else ""
    expected = sys.argv[5] if len(sys.argv) >= 6 else ""
    reconciliation_raw = sys.argv[6] if len(sys.argv) >= 7 else ""
    observation, lock, rows = observe(scope, name, reconciliation_raw)
    digest = receipt(observation)
    if mode == "inspect":
        report(observation, rows, digest)
        return
    if mode != "remove" or not HASH_RE.fullmatch(expected):
        blocked("internal remove request has no valid receipt")
    if digest != expected:
        blocked(f"recovery receipt changed (current {digest}); rerun audit")
    if lock.get("kind") == "release-tombstone":
        remove_exact_release(lock)
    else:
        remove_exact_lock(observation, lock)
    report(observation, rows, digest)
    print("RECOVERED=exact-retained-lock-removed")


try:
    main()
except Blocked as exc:
    print(f"swarm-recover: BLOCKED: {exc}", file=sys.stderr)
    raise SystemExit(3)
except (OSError, ValueError) as exc:
    print(f"swarm-recover: BLOCKED: recovery evidence could not be proven: {exc}", file=sys.stderr)
    raise SystemExit(3)
PY
}

COMMAND="${1:-}"
SCOPE="${2:-}"
[ "$COMMAND" = audit ] || [ "$COMMAND" = recover ] || usage
[ "$SCOPE" = mutation ] || [ "$SCOPE" = launch ] || [ "$SCOPE" = repo-lease ] || usage
shift 2

NAME=""
if [ "$SCOPE" = launch ]; then
  NAME="${1:-}"
  valid_name "$NAME" || usage
  shift
elif [ "$SCOPE" = repo-lease ]; then
  NAME="${1:-}"
  [ -n "$NAME" ] || usage
  shift
fi

RECEIPT=""
ACK=0
OPERATION=""
TARGET_NAME=""
ENGINE=""
REPO=""
WORKSPACE_ACTION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --receipt) [ "$#" -ge 2 ] || usage; RECEIPT="$2"; shift 2 ;;
    --ack-reconciled) ACK=1; shift ;;
    --operation) [ "$#" -ge 2 ] || usage; OPERATION="$2"; shift 2 ;;
    --name) [ "$#" -ge 2 ] || usage; TARGET_NAME="$2"; shift 2 ;;
    --engine) [ "$#" -ge 2 ] || usage; ENGINE="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --workspace-action) [ "$#" -ge 2 ] || usage; WORKSPACE_ACTION="$2"; shift 2 ;;
    *) usage ;;
  esac
done

validate_mutation_reconciliation() {
  case "$OPERATION" in add|remove|sync|account|up) ;; *) usage ;; esac
  if [ -n "$TARGET_NAME" ]; then valid_name "$TARGET_NAME" || usage; fi
  case "$OPERATION" in
    add|remove)
      [ -n "$TARGET_NAME" ] && [ -n "$REPO" ] || usage
      case "$ENGINE" in claude|codex) ;; *) usage ;; esac
      case "$WORKSPACE_ACTION" in ''|prepare|verify|release) ;; *) usage ;; esac
      if [ "$ENGINE" = claude ] && [ -n "$WORKSPACE_ACTION" ]; then
        echo "swarm-recover: REFUSED — Claude add/remove cannot carry a Codex workspace action" >&2
        exit 2
      fi
      if [ "$ENGINE" = codex ] && [ -z "$WORKSPACE_ACTION" ]; then
        echo "swarm-recover: REFUSED — interrupted Codex add/remove requires an explicit workspace action" >&2
        exit 2
      fi
      ;;
    account|up)
      [ -n "$TARGET_NAME" ] || usage
      [ -z "$ENGINE$REPO$WORKSPACE_ACTION" ] || usage
      ;;
    sync) [ -z "$TARGET_NAME$ENGINE$REPO$WORKSPACE_ACTION" ] || usage ;;
  esac
}

root_journal_evidence() {
  local raw
  if ! raw="$("$RUNTIME_BIN" workspace-journal-evidence --repo "$REPO" 2>&1)"; then
    printf '%s\n' "$raw" >&2
    echo "swarm-recover: REFUSED — root workspace-journal evidence is unavailable" >&2
    return 3
  fi
  /usr/bin/python3 -I -B - "$REPO" "$raw" <<'PY'
import json,re,sys
repo,raw=sys.argv[1:3]
try: value=json.loads(raw)
except ValueError: raise SystemExit(3)
if (not isinstance(value,dict)
    or set(value)!={"schema","repo","present","journal_sha256"}
    or value.get("schema")!="qofi-codex-workspace-journal-evidence/v1"
    or value.get("repo")!=repo or value.get("present") is not True
    or not isinstance(value.get("journal_sha256"),str)
    or not re.fullmatch(r"[0-9a-f]{64}",value["journal_sha256"])):
    raise SystemExit(3)
print(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True))
PY
}

build_reconciliation() {
  local journal="${1:-}"
  /usr/bin/python3 -I -B - \
    "$OPERATION" "$TARGET_NAME" "$ENGINE" "$REPO" "$WORKSPACE_ACTION" "$journal" <<'PY'
import json,sys
operation,name,engine,repo,action,journal=sys.argv[1:7]
value={
  "operation":operation,"name":name,"engine":engine,"repo":repo,
  "workspace_action":action,
  "journal_evidence":json.loads(journal) if journal else None,
}
print(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True))
PY
}

prove_hidden_runtime_quiescent() {
  local proof
  if ! proof="$("$RUNTIME_BIN" quiescence-proof 2>&1)"; then
    printf '%s\n' "$proof" >&2
    echo "swarm-recover: REFUSED — hidden Codex runtime quiescence could not be proven; lock retained" >&2
    return 3
  fi
  if [ "$proof" != '{"schema":"qofi-codex-quiescence-proof/v1","status":"quiescent"}' ]; then
    echo "swarm-recover: REFUSED — hidden Codex runtime returned malformed quiescence proof; lock retained" >&2
    return 3
  fi
}

REFERENCE_AUDIT=""
validate_workspace_reference_action() {
  local codex_refs=0
  [ -n "$WORKSPACE_ACTION" ] || return 0
  while IFS="$(printf '\t')" read -r _tag _name _engine _repo; do
    [ "$_tag" = ROW ] || continue
    if [ "$_engine" = codex ] && [ "$_repo" = "$REPO" ]; then
      codex_refs=$((codex_refs + 1))
    fi
  done <<EOF
$REFERENCE_AUDIT
EOF
  case "$WORKSPACE_ACTION" in
    release)
      if [ "$codex_refs" -ne 0 ]; then
        echo "swarm-recover: REFUSED — release conflicts with $codex_refs configured Codex reference(s); lock retained" >&2
        return 3
      fi
      ;;
    prepare|verify)
      if [ "$codex_refs" -eq 0 ]; then
        echo "swarm-recover: REFUSED — $WORKSPACE_ACTION requires a current Codex reference; use release for an unregistered journal" >&2
        return 3
      fi
      ;;
  esac
}

RECONCILIATION=""
JOURNAL_EVIDENCE=""
if [ "$SCOPE" = mutation ] && [ -n "$OPERATION" ]; then
  validate_mutation_reconciliation
  if [ "$WORKSPACE_ACTION" = release ]; then
    JOURNAL_EVIDENCE="$(root_journal_evidence)" || exit $?
  fi
  RECONCILIATION="$(build_reconciliation "$JOURNAL_EVIDENCE")" || exit 3
elif [ "$SCOPE" = mutation ] && [ -n "$TARGET_NAME$ENGINE$REPO$WORKSPACE_ACTION" ]; then
  usage
elif [ "$SCOPE" != mutation ] && [ -n "$OPERATION$TARGET_NAME$ENGINE$REPO$WORKSPACE_ACTION" ]; then
  usage
fi

if [ "$COMMAND" = audit ]; then
  [ -z "$RECEIPT" ] && [ "$ACK" -eq 0 ] || usage
  if ! REFERENCE_AUDIT="$(_core inspect "$SCOPE" "$NAME" "" "$RECONCILIATION" 2>&1)"; then
    printf '%s\n' "$REFERENCE_AUDIT" >&2
    exit 3
  fi
  validate_workspace_reference_action || exit $?
  printf '%s\n' "$REFERENCE_AUDIT"
  exit 0
fi

case "$RECEIPT" in ''|*[!0-9a-f]*) usage ;; esac
[ "${#RECEIPT}" -eq 64 ] || usage
[ "$ACK" -eq 1 ] || {
  echo "swarm-recover: REFUSED — --ack-reconciled is required; no state changed" >&2
  exit 2
}

if [ "$SCOPE" = launch ]; then
  prove_hidden_runtime_quiescent || exit $?
  _core remove launch "$NAME" "$RECEIPT" ""
  exit $?
elif [ "$SCOPE" = repo-lease ]; then
  prove_hidden_runtime_quiescent || exit $?
  _core remove repo-lease "$NAME" "$RECEIPT" ""
  exit $?
fi
[ -n "$RECONCILIATION" ] || usage

# First action-bound receipt comparison. Everything through here is read-only.
if ! AUDIT="$(_core inspect mutation "" "" "$RECONCILIATION" 2>&1)"; then
  printf '%s\n' "$AUDIT" >&2
  exit 3
fi
CURRENT_RECEIPT="$(printf '%s\n' "$AUDIT" | /usr/bin/sed -n 's/^RECEIPT=//p')"
if [ "$CURRENT_RECEIPT" != "$RECEIPT" ]; then
  echo "swarm-recover: REFUSED — action-bound receipt mismatch (current $CURRENT_RECEIPT); no state changed" >&2
  exit 3
fi
REFERENCE_AUDIT="$AUDIT"
validate_workspace_reference_action || exit $?
printf '%s\n' "$AUDIT"

# Workspace changes happen only after both the receipt and acknowledgement
# have been proven. Release additionally CAS-binds the exact root journal.
case "$WORKSPACE_ACTION" in
  prepare) "$RUNTIME_BIN" prepare-workspace --repo "$REPO" ;;
  verify)  "$RUNTIME_BIN" verify --repo "$REPO" ;;
  release)
    JOURNAL_SHA="$(/usr/bin/python3 -I -B - "$JOURNAL_EVIDENCE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["journal_sha256"])
PY
)" || exit 3
    "$RUNTIME_BIN" release-workspace --repo "$REPO" \
      --expected-journal-sha256 "$JOURNAL_SHA"
    ;;
esac

# Every workspace currently referenced by a Codex row must independently pass
# the root-attested read-only verifier before the global signal can be removed.
VERIFIED_REPOS=""
while IFS="$(printf '\t')" read -r _tag _name _engine _repo; do
  [ "$_tag" = ROW ] || continue
  [ "$_engine" = codex ] || continue
  case "
$VERIFIED_REPOS
" in *"
$_repo
"*) continue ;; esac
  if ! [ "$WORKSPACE_ACTION" = verify ] || [ "$_repo" != "$REPO" ]; then
    "$RUNTIME_BIN" verify --repo "$_repo"
  fi
  VERIFIED_REPOS="${VERIFIED_REPOS}${_repo}
"
done <<EOF
$AUDIT
EOF

# The core recomputes the complete receipt after all explicit reconciliation.
# Any ABA, config edit, new session, heartbeat, or lock replacement preserves
# the retained signal and requires a fresh audit.
prove_hidden_runtime_quiescent || exit $?
_core remove mutation "" "$RECEIPT" "$RECONCILIATION"
