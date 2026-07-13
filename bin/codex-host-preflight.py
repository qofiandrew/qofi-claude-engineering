#!/usr/bin/env python3
"""Fail-closed host preflight for the unattended Codex lane."""

from __future__ import annotations

import os
import contextlib
import ctypes
import errno
import pwd
import grp
import re
import importlib.util
import json
import hashlib
import io
import selectors
import signal
import stat
import subprocess
import shutil
import sys
import tempfile
import time
from typing import NamedTuple, NoReturn, Optional
from pathlib import Path

OUTPUT_LIMIT = 8 * 1024
PROBE_TIMEOUT = 10.0
MIN_VERSION = (0, 144, 1)
MAX_VERSION = (0, 145, 0)
ATTESTATION_PATH = "/private/etc/qofi-codex-runtime.json"
ATTESTATION_SCHEMA = "qofi-codex-runtime/v2"
RUNNER_PATH = "/usr/local/libexec/qofi-codex-runner"
ROOT_TOOLCHAIN = "/usr/local/libexec/qofi-codex-toolchain"
FABLE_REVIEWER_PATH = "/usr/local/libexec/qofi-fable-reviewer-mcp.py"
FABLE_DOCTRINE_PATH = "/usr/local/libexec/qofi-fable-reviewer-doctrine.md"
FABLE_SCHEMA_PATH = "/usr/local/libexec/qofi-adversarial-review-output.schema.json"
SUPPORTED_PNPM_VERSION = "9.12.3"
SUPPORTED_PNPM_INTEGRITY = (
    "sha512.cce0f9de9c5a7c95bef944169cc5dfe8741abfb145078c0d508b868056848a87"
    "c81e626246cb60967cbd7fd29a6c062ef73ff840d96b3c86c40ac92cf4a813ee"
)
MAX_PROJECT_MANIFEST = 1024 * 1024
MAX_AUTH_JSON = 1024 * 1024
MAX_WORKSPACE_ENTRIES = 150_000
ALLOWED_IMPLICIT_RUNTIME_GROUPS = {"everyone", "localaccounts", "_lpoperator"}
_ACL_API: tuple[object, object] | None = None


class OperatorReviewAuthAttestation(NamedTuple):
    account_home: str
    codex_home: str
    auth_path: str
    home_identity: tuple[int, int, int, int, int]
    codex_home_identity: tuple[int, int, int, int, int]
    auth_identity: tuple[int, int, int, int, int, int, int, int]


def fail(message: str) -> NoReturn:
    print(f"codex host preflight: {message}", file=sys.stderr)
    raise SystemExit(2)


def validate_dedicated_auth_metadata(
    auth: str,
    runtime_uid: int,
    runtime_gid: int,
) -> os.stat_result:
    """Operator-safe auth proof; metadata only, never credential contents."""

    try:
        info = os.lstat(auth)
    except FileNotFoundError:
        fail(
            "dedicated ChatGPT auth is not initialized; run "
            "bin/swarm-codex-runtime.sh login, then retry"
        )
    except OSError as exc:
        fail(f"could not inspect dedicated Codex auth.json: {exc}")
    if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != runtime_uid or info.st_gid != runtime_gid
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
            or not 2 <= info.st_size <= MAX_AUTH_JSON):
        fail("dedicated Codex auth.json must be runtime-owned mode 0600")
    return info


def inside(root: str, candidate: str) -> bool:
    try:
        return os.path.commonpath([root, candidate]) == root
    except ValueError:
        return False


def clean_path(value: str, label: str) -> str:
    if not value or not os.path.isabs(value) or os.path.normpath(value) != value:
        fail(f"{label} must be an absolute normalized path")
    if any(ord(ch) < 32 or ord(ch) == 127 or ch == "|" for ch in value):
        fail(f"{label} contains an unsafe character")
    return value


def safe_dir_chain(
    path: str,
    *,
    exact_private_from: Optional[str] = None,
    owner_uid: Optional[int] = None,
) -> None:
    uid = os.getuid() if owner_uid is None else owner_uid
    current = os.path.sep
    for part in path.split(os.path.sep)[1:]:
        current = os.path.join(current, part)
        try:
            info = os.lstat(current)
        except OSError as exc:
            fail(f"unsafe install/auth path {current}: {exc}")
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail(f"unsafe path component is not a real directory: {current}")
        if info.st_uid not in (0, uid) or info.st_mode & 0o022:
            fail(f"unsafe writable/wrong-owner path component: {current}")
        if (exact_private_from and current != exact_private_from
                and inside(exact_private_from, current) and stat.S_IMODE(info.st_mode) != 0o700):
            fail(f"private auth path component must be 0700: {current}; run: chmod 700 {current}")


def is_execute_only_macos_sudo(
    requested: str,
    canonical: str,
    info: os.stat_result,
) -> bool:
    """Recognize only Apple's exact unreadable, sealed-system sudo shape."""

    return (
        sys.platform == "darwin"
        and requested == canonical == "/usr/bin/sudo"
        and stat.S_ISREG(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and info.st_uid == 0
        and info.st_gid == 0
        and stat.S_IMODE(info.st_mode) == 0o4511
        and info.st_nlink == 1
        and 0 < info.st_size <= 16 * 1024 * 1024
    )


def safe_executable(
    requested: str,
    label: str,
    forbidden: list[str],
    *,
    owner_uid: Optional[int] = None,
) -> str:
    requested = clean_path(requested, label)
    uid = os.getuid() if owner_uid is None else owner_uid
    safe_dir_chain(os.path.dirname(requested), owner_uid=uid)
    try:
        link_info = os.lstat(requested)
    except OSError as exc:
        fail(f"{label} is missing: {exc}")
    if link_info.st_uid not in (0, uid):
        fail(f"{label} link/file has the wrong owner")
    canonical = os.path.realpath(requested)
    if ":" in canonical:
        fail(f"{label} path cannot be represented safely in pinned PATH")
    safe_dir_chain(os.path.dirname(canonical), owner_uid=uid)
    try:
        info = os.lstat(canonical)
    except OSError as exc:
        fail(f"{label} canonical target is missing: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(f"{label} canonical target must be a regular non-symlink file")
    if info.st_uid not in (0, uid) or info.st_mode & 0o022 or not info.st_mode & 0o111:
        fail(f"{label} canonical target has unsafe ownership/mode or is not executable")
    for root in forbidden:
        if inside(root, canonical):
            fail(f"{label} must live outside {root}")

    # A trusted wrapper may be a script, but its interpreter must itself be an
    # absolute trusted executable. `/usr/bin/env ...` would re-open ambient PATH.
    try:
        handle = open(canonical, "rb")
    except PermissionError:
        # Current macOS deliberately ships the exact SIP-controlled sudo binary
        # as root:wheel 04511: executable/set-id but unreadable to the operator.
        # This exception is intentionally path-, platform-, owner-, mode-, link-
        # and size-bound. It must never make an unreadable operator wrapper (or
        # any caller-selected executable) eligible without shebang inspection.
        if not is_execute_only_macos_sudo(requested, canonical, info):
            fail(f"{label} is unreadable, so its interpreter cannot be verified")
        return canonical
    except OSError as exc:
        fail(f"could not inspect {label} interpreter: {exc}")
    with handle:
        first = handle.readline(512)
    if first.startswith(b"#!"):
        try:
            interpreter = first[2:].decode("utf-8", "strict").strip().split()[0]
        except (UnicodeDecodeError, IndexError):
            fail(f"{label} has an invalid shebang")
        if not os.path.isabs(interpreter) or os.path.basename(interpreter) == "env":
            fail(f"{label} script must use an absolute non-env interpreter")
        safe_executable(interpreter, f"{label} interpreter", forbidden, owner_uid=uid)
    return canonical


def safe_regular(
    requested: str,
    label: str,
    forbidden: list[str],
    *,
    owner_uid: Optional[int] = None,
) -> str:
    uid = os.getuid() if owner_uid is None else owner_uid
    requested = clean_path(requested, label)
    canonical = os.path.realpath(requested)
    safe_dir_chain(os.path.dirname(canonical), owner_uid=uid)
    try:
        info = os.lstat(canonical)
    except OSError as exc:
        fail(f"{label} is missing: {exc}")
    if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid not in (0, uid) or info.st_mode & 0o022):
        fail(f"{label} must be an owner-controlled canonical regular file")
    for root in forbidden:
        if inside(root, canonical):
            fail(f"{label} must live outside {root}")
    if ":" in canonical:
        fail(f"{label} path cannot be represented safely in pinned PATH")
    return canonical


def bounded_file_sha256(path: str, limit: int = 512 * 1024 * 1024) -> str:
    before = os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_size > limit):
        fail(f"authority source is unsafe or oversized: {path}")
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
            fail(f"authority source changed while opening: {path}")
        while chunk := os.read(fd, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(fd)
        if (after.st_dev, after.st_ino, after.st_size,
                after.st_mtime_ns, after.st_ctime_ns) != identity:
            fail(f"authority source changed while hashing: {path}")
    finally:
        os.close(fd)
    return digest.hexdigest()


def verify_current_runner_source(swarm_home: str, operator_uid: int, expected_hash: str) -> str:
    source = os.path.join(swarm_home, "bin", "qofi-codex-runner")
    if os.path.realpath(source) != source:
        fail("repository runner source must not contain symlink indirection")
    safe_dir_chain(os.path.dirname(source), owner_uid=operator_uid)
    try:
        info = os.lstat(source)
    except OSError as exc:
        fail(f"repository runner source is missing: {exc}")
    if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid not in (0, operator_uid) or info.st_mode & 0o022
            or not info.st_mode & 0o111
            or bounded_file_sha256(source, 4 * 1024 * 1024) != expected_hash):
        fail("installed runner differs from the current trusted repository source; rerun runtime install")
    return source


def optional_tool_dir(
    path: str,
    *,
    workspace: str | None = None,
    owner_uid: Optional[int] = None,
) -> str | None:
    if not os.path.isdir(path) or os.path.islink(path):
        return None
    canonical = os.path.realpath(path)
    if canonical != os.path.normpath(path):
        return None
    info = os.lstat(canonical)
    uid = os.getuid() if owner_uid is None else owner_uid
    if info.st_uid not in (0, uid) or info.st_mode & 0o022:
        return None
    if workspace and not inside(workspace, canonical):
        return None
    if ":" in canonical or any(ord(ch) < 32 or ord(ch) == 127 for ch in canonical):
        return None
    return canonical


def bounded_probe(binary: str, args: list[str], env: dict[str, str], label: str) -> str:
    try:
        proc = subprocess.Popen(
            [binary, *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
    except OSError as exc:
        fail(f"could not start {label}: {exc}")
    assert proc.stdout is not None
    os.set_blocking(proc.stdout.fileno(), False)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    chunks: list[bytes] = []
    total = 0
    deadline = time.monotonic() + PROBE_TIMEOUT
    reason = ""
    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            reason = f"{label} timed out after {int(PROBE_TIMEOUT)}s"
            break
        for key, _ in selector.select(min(remaining, 0.25)):
            try:
                chunk = os.read(key.fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            total += len(chunk)
            if total > OUTPUT_LIMIT:
                reason = f"{label} exceeded the {OUTPUT_LIMIT}-byte output cap"
                break
            chunks.append(chunk)
        if reason:
            break
        if proc.poll() is not None and not selector.get_map():
            break
    if reason:
        terminate_probe_group(proc)
        selector.close()
        fail(reason)
    try:
        rc = proc.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        terminate_probe_group(proc)
        selector.close()
        fail(f"{label} timed out after {int(PROBE_TIMEOUT)}s")
    selector.close()
    try:
        output = b"".join(chunks).decode("utf-8", "strict")
    except UnicodeDecodeError:
        fail(f"{label} emitted non-UTF-8 output")
    if rc != 0:
        fail(f"{label} exited nonzero ({rc})")
    return output.replace("\r\n", "\n").replace("\r", "\n")


def terminate_probe_group(proc: subprocess.Popen[bytes], grace: float = 0.5) -> None:
    """Give a probe a bounded TERM cleanup window, then kill its process group."""

    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    # The leader may exit before a descendant; target the group regardless.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        fail("probe process group could not be reaped")


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
        _ACL_API = (get_acl, free_acl)
    get_acl, free_acl = _ACL_API
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)
    if not acl:
        error = ctypes.get_errno()
        if error in (0, errno.ENOENT):
            return False
        fail(f"could not inspect workspace ACL: errno {error}")
    try:
        return True
    finally:
        free_acl(acl)


def _directory_identity(info: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        info.st_dev, info.st_ino, info.st_uid, info.st_gid,
        stat.S_IMODE(info.st_mode),
    )


def _auth_identity(info: os.stat_result) -> tuple[int, int, int, int, int, int, int, int]:
    return (
        info.st_dev, info.st_ino, info.st_uid, info.st_gid,
        stat.S_IMODE(info.st_mode), info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    )


def attest_operator_review_auth(
    account_home: str,
    codex_home: str,
) -> OperatorReviewAuthAttestation:
    """Bind the compatibility reviewer to one private current-user auth file."""

    uid = os.getuid()
    if (not os.path.isabs(account_home) or os.path.normpath(account_home) != account_home
            or os.path.realpath(account_home) != account_home
            or codex_home != os.path.join(account_home, ".codex")
            or os.path.realpath(codex_home) != codex_home):
        fail("operator review auth paths must be canonical beneath the account home")

    # Keep the ordinary root-to-home ownership/mode proof, then strengthen the
    # credential-bearing portion of that chain with fd-bound ACL checks.
    safe_dir_chain(codex_home, exact_private_from=account_home, owner_uid=uid)
    directory_flags = (
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    directory_identities: list[tuple[int, int, int, int, int]] = []
    for path, exact_mode in ((account_home, None), (codex_home, 0o700)):
        before = os.lstat(path)
        if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode)
                or before.st_uid != uid or before.st_mode & 0o022
                or (exact_mode is not None and stat.S_IMODE(before.st_mode) != exact_mode)):
            fail(f"operator review auth parent is not current-user private: {path}")
        fd = os.open(path, directory_flags)
        try:
            opened = os.fstat(fd)
            if _directory_identity(opened) != _directory_identity(before):
                fail(f"operator review auth parent changed while opening: {path}")
            # A stock macOS account home can carry the deny-only
            # ``group:everyone deny delete`` ACL.  It does not grant traversal
            # through the separately opened, current-user-owned mode-0700
            # .codex directory.  The credential-bearing .codex/auth.json
            # boundary itself must remain completely ACL-free.
            if path == codex_home and fd_has_extended_acl(fd):
                fail(f"operator review auth parent has an extended ACL: {path}")
            directory_identities.append(_directory_identity(opened))
        finally:
            os.close(fd)

    auth_path = os.path.join(codex_home, "auth.json")
    before = os.lstat(auth_path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != uid or stat.S_IMODE(before.st_mode) != 0o600
            or not 2 <= before.st_size <= 1024 * 1024
            or os.path.realpath(auth_path) != auth_path):
        fail("operator review auth.json must be a canonical current-user regular mode 0600 file bounded to 1 MiB")
    auth_fd = os.open(auth_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(auth_fd)
        if (_auth_identity(opened) != _auth_identity(before) or fd_has_extended_acl(auth_fd)):
            fail("operator review auth.json changed while opening or has an extended ACL")
        auth_identity = _auth_identity(opened)
    finally:
        os.close(auth_fd)

    return OperatorReviewAuthAttestation(
        account_home=account_home,
        codex_home=codex_home,
        auth_path=auth_path,
        home_identity=directory_identities[0],
        codex_home_identity=directory_identities[1],
        auth_identity=auth_identity,
    )


def revalidate_operator_review_auth(attestation: OperatorReviewAuthAttestation) -> None:
    """Refuse an auth/parent replacement across the subscription-status probe."""

    if attest_operator_review_auth(
        attestation.account_home, attestation.codex_home,
    ) != attestation:
        fail("operator review auth boundary changed during preflight")


def assert_workspace_acl_git_boundary(repo: str) -> None:
    """Repeat prepare-time ACL/nested-repository checks before every launch."""

    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    root_fd = os.open(repo, flags)
    try:
        count = 0
        for current, dirs, files, dir_fd in os.fwalk(
            ".", topdown=True, follow_symlinks=False, dir_fd=root_fd,
        ):
            rel_dir = "" if current == "." else current.removeprefix("./")
            outside_root_git = not (rel_dir == ".git" or rel_dir.startswith(".git/"))
            if ((rel_dir == "" and ".git" in files)
                    or (rel_dir and outside_root_git and (".git" in dirs or ".git" in files))):
                fail("workspace gained a nested repository, submodule, or .git pointer")
            if rel_dir == "" and ".git" in dirs:
                try:
                    git_fd = os.open(".git", flags, dir_fd=dir_fd)
                except OSError as exc:
                    fail(f"workspace root .git is no longer a real directory: {exc}")
                os.close(git_fd)
            count += len(dirs) + len(files)
            if count > MAX_WORKSPACE_ENTRIES:
                fail("workspace exceeds the bounded launch-time security scan")
            if fd_has_extended_acl(dir_fd):
                fail(f"workspace has an unexpected ACL at launch: {rel_dir or '.'}")
            for name in files:
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
                    if fd_has_extended_acl(fd):
                        rel = os.path.join(rel_dir, name) if rel_dir else name
                        fail(f"workspace has an unexpected ACL at launch: {rel}")
                finally:
                    os.close(fd)
    finally:
        os.close(root_fd)


def normalized_nonempty_lines(output: str) -> list[str]:
    return [line.strip() for line in output.split("\n") if line.strip()]


def validated_codex_version(output: str) -> str:
    """Return the audited base version from one exact Codex version line."""

    lines = normalized_nonempty_lines(output)
    if len(lines) != 1:
        fail("Codex version probe must emit exactly one normalized line")
    match = re.fullmatch(
        r"(?:codex-cli|codex) (\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?",
        lines[0],
    )
    if not match:
        fail("Codex version output is not the audited exact form")
    version = tuple(int(part) for part in match.groups())
    if not (MIN_VERSION <= version < MAX_VERSION):
        fail(
            "Codex version must be >=0.144.1 and <0.145.0 "
            f"(found {'.'.join(match.groups())})"
        )
    return ".".join(match.groups())


def validated_operator_canary_value(output: str, expected_sha256: str) -> str:
    """Return the root-attested operator witness in its safe contract form."""

    lines = normalized_nonempty_lines(output)
    if (len(lines) != 1
            or hashlib.sha256(lines[0].encode("utf-8")).hexdigest() != expected_sha256):
        fail("operator launchd canary does not match the root attestation")
    value = lines[0]
    # This is a non-secret isolation witness, but it crosses a pipe-delimited
    # shell contract. Keep its accepted form in lockstep with the dedicated
    # bridge's inherited-witness validator and exclude all controls/delimiters.
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{16,256}", value):
        fail("operator launchd canary is not bounded safe ASCII")
    return value


def require_live_shared_group(runtime_gid: int, current_groups: Optional[list[int]] = None) -> None:
    groups = os.getgroups() if current_groups is None else current_groups
    if runtime_gid not in groups:
        fail(
            "current process credentials do not include the dedicated shared group; "
            "log out/in, restart the operator tmux server, and retry"
        )


def runner_child_path(node_path: str) -> str:
    """Mirror qofi-codex-runner child_env PATH byte-for-byte."""
    node_dir = os.path.dirname(node_path)
    directories: list[str] = []
    for candidate in (
        os.path.join(node_dir, "bin"), node_dir,
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ):
        if candidate not in directories:
            directories.append(candidate)
    return os.pathsep.join(directories)


def _bounded_package_json(repo: str) -> dict[str, object] | None:
    path = os.path.join(repo, "package.json")
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as exc:
        fail(f"could not inspect project package.json: {exc}")
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_size > MAX_PROJECT_MANIFEST):
        fail("project package.json must be a regular non-symlink file <=1MiB")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
        ):
            fail("project package.json changed while opening")
        raw = os.read(fd, MAX_PROJECT_MANIFEST + 1)
    finally:
        os.close(fd)
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as exc:
        fail(f"project package.json is invalid: {exc}")
    if not isinstance(value, dict):
        fail("project package.json must contain a JSON object")
    return value


def detect_project_tool_requirements(repo: str) -> set[str]:
    """Derive bounded executable requirements without executing repository code."""
    required: set[str] = set()
    exists = lambda name: os.path.isfile(os.path.join(repo, name))
    if exists("uv.lock"):
        required.update(("uv", "python3"))
    if exists("Cargo.toml") or exists("Cargo.lock"):
        required.update(("cargo", "rustc"))
    if exists("go.mod") or exists("go.work"):
        required.add("go")
    if exists("deno.json") or exists("deno.jsonc") or exists("deno.lock"):
        required.add("deno")
    if exists("Package.swift"):
        required.update(("xcrun", "swift", "swiftc"))
    try:
        if any(name.endswith((".xcodeproj", ".xcworkspace")) for name in os.listdir(repo)):
            required.update(("xcodebuild", "xcrun"))
    except OSError as exc:
        fail(f"could not scan project root for tool requirements: {exc}")

    package = _bounded_package_json(repo)
    package_managers: set[str] = set()
    exact_pnpm_pin = False
    if exists("bun.lock") or exists("bun.lockb"):
        package_managers.add("bun")
    if exists("package-lock.json") or exists("npm-shrinkwrap.json"):
        package_managers.add("npm")
    if exists("pnpm-lock.yaml"):
        package_managers.add("pnpm")
    if exists("yarn.lock"):
        package_managers.add("yarn")
    if package is not None:
        required.add("node")
        declared = package.get("packageManager")
        if declared is not None:
            if not isinstance(declared, str) or not declared:
                fail("project packageManager must be a non-empty string")
            manager = declared.split("@", 1)[0].lower()
            if manager not in {"bun", "npm", "pnpm", "yarn"}:
                fail(f"project packageManager is unsupported by the dedicated runtime: {manager}")
            if manager == "pnpm":
                plain = f"pnpm@{SUPPORTED_PNPM_VERSION}"
                if declared not in (plain, f"{plain}+{SUPPORTED_PNPM_INTEGRITY}"):
                    fail(
                        f"project pnpm packageManager must exactly pin the audited "
                        f"global runtime version {plain}"
                    )
                exact_pnpm_pin = True
            package_managers.add(manager)
        elif not package_managers:
            # npm is Node's conventional package.json default when neither a
            # packageManager declaration nor another manager lock is present.
            package_managers.add("npm")
        scripts = package.get("scripts", {})
        if scripts is not None and not isinstance(scripts, dict):
            fail("project package.json scripts must be an object")
        if isinstance(scripts, dict):
            script_text = "\n".join(value for value in scripts.values() if isinstance(value, str))
            script_tools = {
                "bun": {"bun"},
                "npm": {"npm"},
                "npx": {"npx"},
                "pnpm": {"pnpm"},
                "yarn": {"yarn"},
                "deno": {"deno"},
                "uv": {"uv", "python3"},
                "cargo": {"cargo", "rustc"},
                "go": {"go"},
                "swift": {"swift"},
                "xcodebuild": {"xcodebuild"},
                "xcrun": {"xcrun"},
            }
            for command, tools in script_tools.items():
                if re.search(
                    rf"(?:^|[\s;&|()]){re.escape(command)}(?:$|[\s;&|()])",
                    script_text,
                ):
                    required.update(tools)

    if ("pnpm" in package_managers or "pnpm" in required) and not exact_pnpm_pin:
        fail(
            f"projects requiring pnpm must declare packageManager "
            f"pnpm@{SUPPORTED_PNPM_VERSION}"
        )

    for manager in package_managers:
        if manager == "npm":
            required.update(("npm", "npx"))
        else:
            required.add(manager)
    return required


def validate_project_tool_requirements(
    repo: str,
    pinned_path: str,
    forbidden: list[str],
    *,
    dedicated: bool,
    swarm_home: str,
    owner_uid: int,
) -> list[str]:
    required = sorted(detect_project_tool_requirements(repo))
    resolved_tools: list[tuple[str, str]] = []
    for tool in required:
        resolved = shutil.which(tool, path=pinned_path)
        if not resolved:
            if dedicated:
                runtime_cli = os.path.join(swarm_home, "bin", "swarm-codex-runtime.sh")
                if tool in {"bun", "node", "npm", "npx", "pnpm"}:
                    fail(
                        f"project stack requires baseline root tool '{tool}', but it is absent from "
                        f"the exact dedicated runner PATH ({pinned_path}); repair with: "
                        f"sudo {runtime_cli} install --repo {repo}"
                    )
                if tool in {"git", "python3", "swift", "swiftc", "xcodebuild", "xcrun"}:
                    fail(
                        f"project stack requires system tool '{tool}', but it is absent from the "
                        f"exact dedicated runner PATH ({pinned_path}); install/repair the matching "
                        f"macOS Command Line Tools/Xcode capability, then rerun: "
                        f"{runtime_cli} prepare-workspace --repo {repo}"
                    )
                fail(
                    f"project stack requires '{tool}', but the v2 dedicated runtime does not "
                    "provide a supported root provisioning route for that stack; this repository "
                    "is unsupported until the runtime toolchain contract is extended"
                )
            fail(f"project stack requires {tool}, but no executable exists in the validated tool PATH")
        resolved_tools.append((tool, resolved))
    for tool, resolved in resolved_tools:
        if dedicated:
            safe_executable(resolved, f"project tool {tool}", forbidden, owner_uid=0)
        else:
            # Preserve the current-user test seam's historical acceptance of
            # package-manager env wrappers; production v2 uses root wrappers
            # with absolute interpreters and the stricter validator above.
            info = os.lstat(os.path.realpath(resolved))
            if (not stat.S_ISREG(info.st_mode) or info.st_mode & 0o022
                    or not os.access(resolved, os.X_OK)):
                fail(f"project stack tool is unsafe: {resolved}")
    return required


def validate_runner_tool_probe_output(
    output: str,
    required_tools: list[str],
    pinned_path: str,
) -> dict[str, str]:
    observed: dict[str, str] = {}
    for line in output.splitlines():
        fields = line.split("\t")
        if len(fields) != 2 or fields[0] in observed:
            fail("dedicated runner project-tool probe emitted malformed output")
        observed[fields[0]] = fields[1]
    expected = {
        name: os.path.realpath(shutil.which(name, path=pinned_path) or "")
        for name in required_tools
    }
    if observed != expected:
        fail("dedicated runner project-tool probe disagrees with the validated exact child PATH")
    return observed


def load_runtime_attestation(
    repo: str,
    swarm_home: str,
    operator_home: str,
    *,
    require_workspace: bool = True,
    path: str = ATTESTATION_PATH,
    require_root_owner: bool = True,
) -> dict[str, object]:
    """Load and verify the fixed v2 root runner/account/toolchain authority."""

    expected = {
        "schema", "operator_uid", "runtime_uid", "runtime_user",
        "runtime_gid", "runtime_group", "runtime_home", "codex_home",
        "runner_path", "runner_sha256", "node_path", "node_sha256",
        "codex_script", "codex_script_sha256", "launchd_canary_name",
        "launchd_canary_sha256",
        "fable_reviewer_path", "fable_reviewer_sha256",
        "fable_doctrine_path", "fable_doctrine_sha256",
        "fable_schema_path", "fable_schema_sha256",
        "fable_reviewer_config_sha256", "codex_config_sha256",
    }
    try:
        info = os.lstat(path)
    except OSError as exc:
        fail(
            f"dedicated runtime attestation missing: {path}: {exc}; "
            "current-user Codex execution is disabled because macOS securityd/launchd IPC is not isolated"
        )
    if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_mode & 0o022 or info.st_size < 2 or info.st_size > 16 * 1024):
        fail("dedicated runtime attestation must be a bounded non-writable regular file")
    if require_root_owner and info.st_uid != 0:
        fail("dedicated runtime attestation must be root-owned")
    parent = os.path.dirname(path)
    parent_info = os.lstat(parent)
    if (not stat.S_ISDIR(parent_info.st_mode) or stat.S_ISLNK(parent_info.st_mode)
            or (require_root_owner and parent_info.st_uid != 0) or parent_info.st_mode & 0o022):
        fail("dedicated runtime attestation parent must be a root-controlled real directory")
    if os.path.realpath(path) != path:
        fail("dedicated runtime attestation path must be canonical")
    fd = -1
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if ((opened.st_dev, opened.st_ino, opened.st_uid, opened.st_mode, opened.st_size)
                != (info.st_dev, info.st_ino, info.st_uid, info.st_mode, info.st_size)):
            fail("dedicated runtime attestation changed while opening")
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            fd = -1
            attestation = json.load(handle)
    except (OSError, ValueError) as exc:
        fail(f"dedicated runtime attestation is unreadable: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)
    if not isinstance(attestation, dict) or set(attestation) != expected:
        fail("dedicated runtime attestation has unknown or missing keys")
    if attestation.get("schema") != ATTESTATION_SCHEMA:
        fail("dedicated runtime attestation has the wrong schema")

    operator_uid = attestation.get("operator_uid")
    runtime_uid = attestation.get("runtime_uid")
    runtime_gid = attestation.get("runtime_gid")
    runtime_user = attestation.get("runtime_user")
    runtime_group = attestation.get("runtime_group")
    if type(operator_uid) is not int or operator_uid != os.getuid():
        fail("attested operator_uid does not match the host daemon account")
    if type(runtime_uid) is not int or runtime_uid <= 0 or runtime_uid == operator_uid:
        fail("attested runtime_uid must be a distinct non-root OS account")
    if type(runtime_gid) is not int or runtime_gid <= 0:
        fail("attested runtime_gid must be a positive integer")
    if not isinstance(runtime_user, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,63}", runtime_user):
        fail("attested runtime_user is invalid")
    if not isinstance(runtime_group, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,63}", runtime_group):
        fail("attested runtime_group is invalid")
    try:
        runtime_pw = pwd.getpwnam(runtime_user)
        runtime_by_uid = pwd.getpwuid(runtime_uid)
        runtime_gr = grp.getgrnam(runtime_group)
        runtime_gr_by_gid = grp.getgrgid(runtime_gid)
        operator_pw = pwd.getpwuid(operator_uid)
        operator_by_name = pwd.getpwnam(operator_pw.pw_name)
    except KeyError:
        fail("attested runtime user/group/operator does not exist")
    if (operator_by_name.pw_uid != operator_uid or operator_pw.pw_dir != operator_home
            or runtime_pw.pw_uid != runtime_uid or runtime_by_uid.pw_name != runtime_user
            or runtime_by_uid.pw_uid != runtime_uid
            or runtime_pw.pw_gid != runtime_gid or runtime_by_uid.pw_gid != runtime_gid
            or runtime_pw.pw_dir != runtime_by_uid.pw_dir
            or runtime_pw.pw_shell != "/usr/bin/false" or runtime_by_uid.pw_shell != "/usr/bin/false"
            or runtime_gr.gr_gid != runtime_gid or runtime_gr_by_gid.gr_name != runtime_group
            or runtime_gr_by_gid.gr_gid != runtime_gid):
        fail("attested uid/name/home/gid is not bidirectional in the OS directory")
    if set(runtime_gr.gr_mem) != {operator_pw.pw_name, runtime_user}:
        fail("dedicated shared group has missing or unexpected explicit members")
    try:
        runtime_groups = set(os.getgrouplist(runtime_user, runtime_pw.pw_gid))
        operator_groups = set(os.getgrouplist(operator_pw.pw_name, operator_pw.pw_gid))
    except OSError as exc:
        fail(f"could not resolve dedicated shared-group membership: {exc}")
    try:
        runtime_group_names = {grp.getgrgid(gid).gr_name for gid in runtime_groups}
    except KeyError:
        fail("dedicated runtime has an unresolvable supplementary gid")
    if runtime_group_names - ({runtime_group} | ALLOWED_IMPLICIT_RUNTIME_GROUPS):
        fail("dedicated runtime has an unexpected or privileged supplementary group")
    if runtime_gid not in operator_groups:
        fail("dedicated shared group must contain the operator account")
    require_live_shared_group(runtime_gid)
    runtime_home = clean_path(str(attestation.get("runtime_home", "")), "attested runtime_home")
    if (runtime_pw.pw_uid != runtime_uid or os.path.realpath(runtime_pw.pw_dir) != runtime_home
            or runtime_pw.pw_dir != runtime_home):
        fail("attested runtime uid/user/home do not match the OS directory record")
    if runtime_home == operator_home or inside(runtime_home, operator_home) or inside(operator_home, runtime_home):
        fail("dedicated runtime home must not overlap the operator home")
    safe_dir_chain(runtime_home, owner_uid=runtime_uid)
    runtime_home_info = os.lstat(runtime_home)
    if (runtime_home_info.st_uid != runtime_uid
            or stat.S_IMODE(runtime_home_info.st_mode) != 0o700):
        fail("dedicated runtime home must be runtime-owned mode 0700")

    runtime_codex_home = clean_path(str(attestation.get("codex_home", "")), "attested codex_home")
    if runtime_codex_home != os.path.join(runtime_home, ".codex"):
        fail("attested codex_home must be the dedicated account's ~/.codex")
    safe_dir_chain(runtime_codex_home, exact_private_from=runtime_home, owner_uid=runtime_uid)
    codex_home_info = os.lstat(runtime_codex_home)
    if codex_home_info.st_uid != runtime_uid or stat.S_IMODE(codex_home_info.st_mode) != 0o700:
        fail("dedicated Codex home must be runtime-owned mode 0700")
    auth = os.path.join(runtime_codex_home, "auth.json")
    validate_dedicated_auth_metadata(auth, runtime_uid, runtime_gid)
    runtime_temp = os.path.join(runtime_home, ".tmp")
    safe_dir_chain(runtime_temp, exact_private_from=runtime_home, owner_uid=runtime_uid)
    runtime_temp_info = os.lstat(runtime_temp)
    if (runtime_temp_info.st_uid != runtime_uid
            or stat.S_IMODE(runtime_temp_info.st_mode) != 0o700):
        fail("dedicated runtime temp must be runtime-owned mode 0700")

    temp_roots = {
        os.path.realpath(value)
        for value in (tempfile.gettempdir(), "/tmp", "/private/tmp", "/var/tmp", "/var/folders")
        if os.path.exists(value)
    }
    for root in (repo, swarm_home, operator_home, *temp_roots):
        if inside(root, runtime_home) or inside(runtime_home, root):
            fail(f"dedicated runtime home overlaps an untrusted/operator root: {root}")

    if require_workspace:
        # The installer establishes a dedicated shared group, not world/staff
        # writability. Prove searchable ancestors plus an operator-owned,
        # shared-group, setgid, group-rwx workspace root.
        current = os.path.sep
        parts = repo.split(os.path.sep)[1:]
        for index, part in enumerate(parts):
            current = os.path.join(current, part)
            component = os.lstat(current)
            if stat.S_ISLNK(component.st_mode) or not stat.S_ISDIR(component.st_mode):
                fail(f"target workspace path component is not a real directory: {current}")
            if index == len(parts) - 1:
                if (component.st_uid != operator_uid or component.st_gid != runtime_gid
                        or component.st_mode & 0o2070 != 0o2070 or component.st_mode & 0o002):
                    fail("target workspace lacks operator/shared-group/setgid collaboration modes")
            elif component.st_uid == runtime_uid:
                searchable = bool(component.st_mode & 0o100)
            elif component.st_gid in runtime_groups:
                searchable = bool(component.st_mode & 0o010)
            else:
                searchable = bool(component.st_mode & 0o001)
            if index != len(parts) - 1 and not searchable:
                fail("target workspace ancestor is not searchable by the dedicated runtime account")
        assert_workspace_acl_git_boundary(repo)

    canary_name = attestation.get("launchd_canary_name")
    canary_hash = attestation.get("launchd_canary_sha256")
    if (not isinstance(canary_name, str)
            or not re.fullmatch(r"[A-Z_][A-Z0-9_]{0,63}", canary_name)):
        fail("attested launchd canary name is invalid")
    if not isinstance(canary_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", canary_hash):
        fail("attested launchd canary hash is invalid")

    forbidden = [repo, swarm_home, operator_home, runtime_home, *temp_roots]
    runner = safe_executable(str(attestation.get("runner_path", "")), "root Codex runner", forbidden, owner_uid=0)
    if runner != RUNNER_PATH:
        fail(f"attested runner_path must be exactly {RUNNER_PATH}")
    node = safe_executable(str(attestation.get("node_path", "")), "root Node executable", forbidden, owner_uid=0)
    script = safe_regular(str(attestation.get("codex_script", "")), "root Codex script", forbidden, owner_uid=0)

    fable_paths = (
        ("fable_reviewer_path", "fable_reviewer_sha256", FABLE_REVIEWER_PATH, True),
        ("fable_doctrine_path", "fable_doctrine_sha256", FABLE_DOCTRINE_PATH, False),
        ("fable_schema_path", "fable_schema_sha256", FABLE_SCHEMA_PATH, False),
    )
    for path_key, hash_key, fixed_path, executable in fable_paths:
        if attestation.get(path_key) != fixed_path:
            fail(f"attested {path_key} is not the fixed reviewer authority")
        authority_path = (safe_executable if executable else safe_regular)(
            fixed_path, f"root {path_key}", forbidden, owner_uid=0,
        )
        expected_hash = attestation.get(hash_key)
        if (not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash)
                or bounded_file_sha256(authority_path) != expected_hash):
            fail(f"root authority hash mismatch: {hash_key}")

    for hash_key in ("fable_reviewer_config_sha256", "codex_config_sha256"):
        if not isinstance(attestation.get(hash_key), str) or not re.fullmatch(
            r"[0-9a-f]{64}", str(attestation.get(hash_key)),
        ):
            fail(f"root authority hash is malformed: {hash_key}")
    reviewer_config = os.path.join(swarm_home, "fable-reviewer.json")
    reviewer_config_info = os.lstat(reviewer_config)
    if (not stat.S_ISREG(reviewer_config_info.st_mode)
            or stat.S_ISLNK(reviewer_config_info.st_mode)
            or reviewer_config_info.st_uid != operator_uid
            or reviewer_config_info.st_mode & 0o022
            or reviewer_config_info.st_nlink != 1):
        fail("Fable reviewer policy is not an operator-controlled regular file")
    if bounded_file_sha256(reviewer_config, 64 * 1024) != attestation["fable_reviewer_config_sha256"]:
        fail("Fable reviewer policy differs from the installed root authority")

    for authority_path, hash_key in (
        (runner, "runner_sha256"), (node, "node_sha256"), (script, "codex_script_sha256"),
    ):
        expected_hash = attestation.get(hash_key)
        if (not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash)
                or bounded_file_sha256(authority_path) != expected_hash):
            fail(f"root authority hash mismatch: {hash_key}")
    verify_current_runner_source(swarm_home, operator_uid, str(attestation["runner_sha256"]))
    attestation["runtime_home"] = runtime_home
    attestation["codex_home"] = runtime_codex_home
    attestation["runtime_temp"] = runtime_temp
    attestation["runner_path"] = runner
    attestation["node_path"] = node
    attestation["codex_script"] = script
    return attestation


def optional_viewer_native_authority(
    *,
    path: str = ATTESTATION_PATH,
    toolchain_root: str = ROOT_TOOLCHAIN,
    require_root_owner: bool = True,
) -> tuple[str, str] | None:
    """Return the hash-attested native viewer tools, or no native capability.

    The persisted Bun event viewer does not depend on the dedicated runtime
    attestation.  Keep that diagnostic surface available when the optional
    native TUI authority is missing or stale, while proving the native Node
    and Codex script against the same fixed root record used by the runner.
    Only viewer execution authority participates in this projection: adding,
    removing, or refreshing an unrelated reviewer capability must not make an
    already-attested native client disappear.
    """

    required_keys = {
        "schema", "operator_uid", "node_path", "node_sha256",
        "codex_script", "codex_script_sha256",
    }
    expected_node = os.path.join(toolchain_root, "node")
    expected_codex = os.path.join(toolchain_root, "codex", "bin", "codex.js")
    owner_uid = 0 if require_root_owner else os.getuid()

    def identity(info: os.stat_result) -> tuple[int, ...]:
        return (
            info.st_dev, info.st_ino, info.st_uid, info.st_gid,
            info.st_mode, info.st_nlink, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns,
        )

    def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
        value: dict[str, object] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate attestation key")
            value[key] = item
        return value

    try:
        # All fail-closed helpers report through stderr.  This is an optional
        # capability probe, so suppress those diagnostics and return a clean
        # absence marker to the pipe-delimited viewer contract.
        with contextlib.redirect_stderr(io.StringIO()):
            if (not os.path.isabs(path) or os.path.normpath(path) != path
                    or os.path.realpath(path) != path):
                fail("native viewer attestation path is not canonical")
            before = os.lstat(path)
            if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
                    or before.st_mode & 0o022 or before.st_nlink != 1
                    or not 2 <= before.st_size <= 16 * 1024):
                fail("native viewer attestation is unsafe")
            if require_root_owner and before.st_uid != 0:
                fail("native viewer attestation is not root-owned")
            if not require_root_owner and before.st_uid not in (0, os.getuid()):
                fail("native viewer attestation has the wrong owner")
            parent = os.path.dirname(path)
            parent_info = os.lstat(parent)
            if (not stat.S_ISDIR(parent_info.st_mode) or stat.S_ISLNK(parent_info.st_mode)
                    or parent_info.st_mode & 0o022
                    or (require_root_owner and parent_info.st_uid != 0)
                    or (not require_root_owner
                        and parent_info.st_uid not in (0, os.getuid()))):
                fail("native viewer attestation parent is unsafe")

            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                opened = os.fstat(fd)
                if identity(opened) != identity(before):
                    fail("native viewer attestation changed while opening")
                chunks: list[bytes] = []
                total = 0
                while True:
                    chunk = os.read(fd, 4096)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > 16 * 1024:
                        fail("native viewer attestation is oversized")
                    chunks.append(chunk)
                after = os.fstat(fd)
                if identity(after) != identity(opened):
                    fail("native viewer attestation changed while reading")
            finally:
                os.close(fd)
            if identity(os.lstat(path)) != identity(after):
                fail("native viewer attestation was replaced while reading")
            attestation = json.loads(
                b"".join(chunks).decode("utf-8", "strict"),
                object_pairs_hook=reject_duplicate_keys,
            )
            if not isinstance(attestation, dict) or not required_keys.issubset(attestation):
                fail("native viewer attestation is missing viewer authority keys")
            if (attestation.get("schema") != ATTESTATION_SCHEMA
                    or type(attestation.get("operator_uid")) is not int
                    or attestation.get("operator_uid") != os.getuid()):
                fail("native viewer attestation identity is stale")
            if (attestation.get("node_path") != expected_node
                    or attestation.get("codex_script") != expected_codex):
                fail("native viewer tool paths differ from the fixed authority")

            node_hash = attestation.get("node_sha256")
            codex_hash = attestation.get("codex_script_sha256")
            if (not isinstance(node_hash, str)
                    or not re.fullmatch(r"[0-9a-f]{64}", node_hash)
                    or not isinstance(codex_hash, str)
                    or not re.fullmatch(r"[0-9a-f]{64}", codex_hash)):
                fail("native viewer tool hashes are malformed")
            node = safe_executable(
                expected_node, "attested native viewer Node", [], owner_uid=owner_uid,
            )
            codex = safe_regular(
                expected_codex, "attested native viewer Codex", [], owner_uid=owner_uid,
            )
            if node != expected_node or codex != expected_codex:
                fail("native viewer tool path contains indirection")
            for authority_path, expected_hash in (
                (node, node_hash), (codex, codex_hash),
            ):
                file_info = os.lstat(authority_path)
                if file_info.st_nlink != 1:
                    fail("native viewer authority has multiple hard links")
                if bounded_file_sha256(authority_path) != expected_hash:
                    fail("native viewer authority hash mismatch")
            return node, codex
    except (OSError, UnicodeError, ValueError, TypeError, SystemExit):
        return None


def prepare_operator_review_workspace(codex_home: str) -> str:
    """Create/attest one empty owner-private cwd for the compatibility lane."""

    path = os.path.join(codex_home, "qofi-review-workspace")
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700
            or os.path.realpath(path) != path):
        fail("operator review workspace must be an owner-private canonical directory")
    fd = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(fd)
        if ((opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino)
                or fd_has_extended_acl(fd) or os.listdir(fd)):
            fail("operator review workspace must be ACL-free and empty")
    finally:
        os.close(fd)
    return path


def prepare_viewer_codex_home(account_home: str, repo: str) -> str:
    """Create/attest a per-repository auth-free CODEX_HOME for native viewers."""

    root = os.path.join(account_home, ".qofi-codex-viewers")
    repo_key = hashlib.sha256(repo.encode("utf-8")).hexdigest()[:32]
    path = os.path.join(root, repo_key)
    for candidate in (root, path):
        try:
            os.mkdir(candidate, 0o700)
        except FileExistsError:
            pass
        info = os.lstat(candidate)
        if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700
                or os.path.realpath(candidate) != candidate):
            fail("native viewer CODEX_HOME must be an owner-private canonical directory")
        fd = os.open(
            candidate,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            opened = os.fstat(fd)
            if ((opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino)
                    or fd_has_extended_acl(fd)):
                fail("native viewer CODEX_HOME changed while opening or has an extended ACL")
        finally:
            os.close(fd)
    safe_dir_chain(path, exact_private_from=account_home)
    return path


def replace_review_cwd(args: list[str], review: str) -> list[str]:
    """Bind the direct current-user review to the attested empty workspace."""

    result = list(args)
    seen = 0
    index = 0
    while index < len(result):
        if result[index] in ("-C", "--cd", "--cwd"):
            if index + 1 >= len(result):
                fail("operator review Codex argv contains a dangling cwd option")
            result[index + 1] = review
            seen += 1
            index += 2
            continue
        if result[index].startswith(("--cd=", "--cwd=")):
            result[index] = result[index].split("=", 1)[0] + "=" + review
            seen += 1
        index += 1
    if seen != 1:
        fail("operator review Codex argv must contain exactly one cwd option")
    return result


def main(
    *,
    skip_runtime_attestation: bool = False,
    account_home_override: str | None = None,
) -> None:
    mode = "workspace-check"
    operator_review = False
    if len(sys.argv) >= 2 and sys.argv[1] in (
        "--exec", "--review-check", "--review-exec", "--viewer-check",
        "--operator-review-check", "--operator-review-exec",
    ):
        mode = {"--exec": "workspace-exec", "--review-check": "review-check",
                "--review-exec": "review-exec", "--viewer-check": "viewer-check",
                "--operator-review-check": "review-check",
                "--operator-review-exec": "review-exec"}[sys.argv[1]]
        operator_review = sys.argv[1].startswith("--operator-review-")
        if operator_review:
            skip_runtime_attestation = True
    exec_mode = mode.endswith("exec")
    review_mode = mode.startswith("review")
    if exec_mode:
        if len(sys.argv) < 6 or sys.argv[4] != "--":
            fail("usage: codex-host-preflight.py [--exec|--review-exec|--operator-review-exec] REPO SWARM_HOME -- CODEX_ARG...")
        repo_arg, swarm_home_arg = sys.argv[2], sys.argv[3]
        exec_args = sys.argv[5:]
        if not exec_args:
            fail("--exec requires at least one Codex argument")
    elif mode in ("review-check", "viewer-check"):
        if len(sys.argv) != 4:
            fail("usage: codex-host-preflight.py [--review-check|--operator-review-check|--viewer-check] REPO SWARM_HOME")
        repo_arg, swarm_home_arg = sys.argv[2], sys.argv[3]
        exec_args = []
    else:
        if len(sys.argv) != 3:
            fail("usage: codex-host-preflight.py REPO SWARM_HOME")
        repo_arg, swarm_home_arg = sys.argv[1], sys.argv[2]
        exec_args = []
    requested_repo = clean_path(repo_arg, "repo")
    repo = os.path.realpath(requested_repo)
    if repo != requested_repo:
        fail("repo must be an absolute canonical path with no symlink indirection")
    swarm_home = os.path.realpath(clean_path(swarm_home_arg, "SWARM_HOME"))
    repo_info = os.lstat(repo)
    if not stat.S_ISDIR(repo_info.st_mode) or stat.S_ISLNK(repo_info.st_mode):
        fail("repo must be a real canonical directory")
    # The unattended child may write anywhere in its target workspace. It
    # must therefore never be able to edit the host daemon, launcher, project
    # checker, or trusted-cli resolver that a later restart executes outside
    # the sandbox. Equality and either containment direction collapse that
    # trust boundary, even when the immediate CLI executable lives elsewhere.
    if not review_mode and (inside(repo, swarm_home) or inside(swarm_home, repo)):
        fail("Codex target repo and SWARM_HOME must not overlap in either direction")
    uid = os.getuid()
    account_home = clean_path(
        account_home_override or pwd.getpwuid(uid).pw_dir,
        "account HOME",
    )
    if os.path.realpath(account_home) != account_home:
        fail("account HOME must not contain symlink indirection")
    ambient_home = clean_path(os.environ.get("HOME", ""), "HOME")
    if ambient_home != account_home or os.path.realpath(ambient_home) != account_home:
        fail(f"ambient HOME must exactly match the account home {account_home}")
    home_info = os.lstat(account_home)
    if (not stat.S_ISDIR(home_info.st_mode) or stat.S_ISLNK(home_info.st_mode)
            or home_info.st_uid != uid or home_info.st_mode & 0o022):
        fail("account HOME is not an owner-controlled real directory")

    if mode == "viewer-check":
        viewer_forbidden = [repo, swarm_home, account_home, *[
            os.path.realpath(path) for path in ("/tmp", "/private/tmp", "/var/tmp")
            if os.path.exists(path)
        ]]
        viewer_bun = safe_executable(
            os.path.join(ROOT_TOOLCHAIN, "bin", "bun"), "root viewer Bun",
            viewer_forbidden, owner_uid=0,
        )
        viewer_path = os.pathsep.join([
            os.path.dirname(viewer_bun), ROOT_TOOLCHAIN,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ])
        viewer_node = ""
        viewer_codex = ""
        viewer_codex_home = ""
        version = ""
        native_authority = optional_viewer_native_authority()
        if native_authority is not None:
            try:
                # Native viewing is optional.  A stale version or unusable
                # auth-free viewer home removes that capability without
                # taking away the separately attested Bun event reader.
                with contextlib.redirect_stderr(io.StringIO()):
                    viewer_node, viewer_codex = native_authority
                    viewer_codex_home = prepare_viewer_codex_home(account_home, repo)
                    version = validated_codex_version(bounded_probe(
                        viewer_node, [viewer_codex, "--version"], {
                            "HOME": account_home,
                            "CODEX_HOME": viewer_codex_home,
                            "PATH": viewer_path,
                            "LANG": "C",
                            "LC_ALL": "C",
                        }, "native viewer Codex version probe",
                    ))
            except (OSError, SystemExit):
                viewer_node = ""
                viewer_codex = ""
                viewer_codex_home = ""
                version = ""
        viewer_values = (
            viewer_bun, viewer_node, viewer_codex, version,
            account_home, viewer_codex_home, viewer_path,
        )
        if any("|" in value or "\n" in value or "\r" in value for value in viewer_values):
            fail("validated native viewer path contains an unsupported delimiter")
        print("|".join(viewer_values))
        return

    codex_home = clean_path(os.path.join(account_home, ".codex"), "pinned CODEX_HOME")
    ambient_codex_home = os.environ.get("CODEX_HOME")
    if ambient_codex_home:
        ambient_codex_home = clean_path(ambient_codex_home, "ambient CODEX_HOME")
        if os.path.realpath(ambient_codex_home) != os.path.realpath(codex_home):
            fail("ambient CODEX_HOME differs from the pinned CODEX_HOME")
    safe_dir_chain(codex_home, exact_private_from=account_home)
    if os.path.realpath(codex_home) != codex_home:
        fail("pinned CODEX_HOME must not contain symlink indirection")

    temp_roots = {
        os.path.realpath(path)
        for path in (tempfile.gettempdir(), "/tmp", "/var/tmp", "/private/tmp")
        if os.path.exists(path)
    }
    for root in [repo, swarm_home, *temp_roots]:
        if inside(root, codex_home) or inside(codex_home, root):
            fail(f"CODEX_HOME/auth storage overlaps a sandbox-readable or temporary root: {root}")

    if skip_runtime_attestation:
        # The explicit operator-review mode preserves the historical Claude
        # contrarian lane when no dedicated daemon runtime is installed. It is
        # read-only and tool-less; unattended workspace execution never enters
        # this branch.
        attestation = None
        runtime_uid = uid
        runtime_user = pwd.getpwuid(uid).pw_name
        runtime_home = account_home
        runtime_codex_home = codex_home
    else:
        attestation = load_runtime_attestation(
            repo, swarm_home, account_home, require_workspace=not review_mode,
        )
        runtime_uid = int(attestation["runtime_uid"])
        runtime_user = str(attestation["runtime_user"])
        runtime_home = str(attestation["runtime_home"])
        runtime_codex_home = str(attestation["codex_home"])

    operator_review_workspace = ""
    operator_review_auth: OperatorReviewAuthAttestation | None = None
    if operator_review:
        operator_review_workspace = prepare_operator_review_workspace(codex_home)
        operator_review_auth = attest_operator_review_auth(account_home, codex_home)

    forbidden = [repo, swarm_home, codex_home, runtime_codex_home, *temp_roots]
    if attestation is None:
        resolver_path = os.path.join(swarm_home, "bin", "trusted-cli.py")
        try:
            spec = importlib.util.spec_from_file_location("qofi_trusted_cli", resolver_path)
            if spec is None or spec.loader is None:
                raise RuntimeError("could not load resolver")
            resolver = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(resolver)
            requested_executable, requested_prefix = resolver.resolve_exec_plan(
                "codex", workspace=repo, swarm_home=swarm_home,
                home=Path(runtime_home), uid=runtime_uid,
            )
        except Exception as exc:
            fail(f"fixed Codex resolver failed: {exc}")
        codex = safe_executable(
            str(requested_executable), "trusted Codex executable", forbidden,
            owner_uid=runtime_uid,
        )
        codex_prefix = [
            safe_regular(str(item), "trusted Codex argv prefix", forbidden, owner_uid=runtime_uid)
            for item in requested_prefix
        ]
        if len(codex_prefix) > 1:
            fail("Codex exec plan has an unsupported multi-item argv prefix")
    else:
        codex = str(attestation["node_path"])
        codex_prefix = [str(attestation["codex_script"])]
    bun_candidates = [os.path.join(ROOT_TOOLCHAIN, "bin", "bun")]
    if attestation is None:
        bun_candidates.extend([
            os.path.join(account_home, ".local", "bin", "bun"),
            os.path.join(account_home, ".bun", "bin", "bun"),
            "/usr/local/bin/bun", "/opt/homebrew/bin/bun",
        ])
    requested_bun = next((candidate for candidate in bun_candidates if os.path.lexists(candidate)), "")
    if not requested_bun:
        fail("no fixed trusted Bun candidate is installed")
    bun = safe_executable(requested_bun, "trusted Bun executable", forbidden)

    tool_dirs: list[str] = []
    if attestation is not None:
        pinned_path = runner_child_path(codex)
        for candidate in pinned_path.split(os.pathsep):
            if optional_tool_dir(candidate, owner_uid=0) != candidate:
                fail(f"dedicated runner PATH directory is absent or unsafe: {candidate}")
    else:
        venv_dir = optional_tool_dir(os.path.join(repo, ".venv", "bin"), workspace=repo)
        if venv_dir:
            tool_dirs.append(venv_dir)
        fixed_dirs = [
            os.path.join(ROOT_TOOLCHAIN, "bin"), ROOT_TOOLCHAIN,
            os.path.join(runtime_home, ".local", "bin"),
            os.path.join(runtime_home, ".cargo", "bin"),
            os.path.join(runtime_home, ".bun", "bin"),
            os.path.dirname(bun),
            os.path.dirname(codex),
            *(os.path.dirname(item) for item in codex_prefix),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/Xcode.app/Contents/Developer/usr/bin",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
            "/Library/Developer/CommandLineTools/usr/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        for candidate in fixed_dirs:
            safe = optional_tool_dir(candidate)
            if safe and safe not in tool_dirs:
                tool_dirs.append(safe)
        pinned_path = os.pathsep.join(tool_dirs)

    required_tools = [] if review_mode else validate_project_tool_requirements(
        repo, pinned_path, forbidden,
        dedicated=attestation is not None,
        swarm_home=swarm_home,
        owner_uid=runtime_uid,
    )
    probe_env = {
        "HOME": account_home,
        "CODEX_HOME": runtime_codex_home,
        "PATH": pinned_path,
        "LANG": "C",
        "LC_ALL": "C",
    }
    if attestation is not None:
        runtime_temp = str(attestation["runtime_temp"])
        probe_env.update({"TMPDIR": runtime_temp, "TMP": runtime_temp, "TEMP": runtime_temp})
    operator_canary_value = ""
    if attestation is None:
        probe_env["CODEX_HOME"] = runtime_codex_home
        probe_binary = codex
        probe_prefix = [*codex_prefix]
    else:
        sudo = safe_executable("/usr/bin/sudo", "trusted sudo executable", forbidden)
        probe_binary = sudo
        runner = str(attestation["runner_path"])
        probe_prefix = ["-n", "--", runner]
        if review_mode:
            probe_prefix.extend(["--mode", "review"])
        probe_prefix.extend(["--parent-pid", str(os.getpid()), "--"])
        canary_output = bounded_probe(
            "/bin/launchctl", ["getenv", str(attestation["launchd_canary_name"])],
            probe_env, "operator launchd canary probe",
        )
        operator_canary_value = validated_operator_canary_value(
            canary_output, str(attestation["launchd_canary_sha256"]),
        )
        if required_tools:
            tool_output = bounded_probe(
                sudo,
                ["-n", "--", runner, "--check-tools", "--parent-pid", str(os.getpid()),
                 "--", *required_tools],
                probe_env,
                "dedicated runner project-tool probe (rerun runtime install/prepare-workspace if it fails)",
            )
            validate_runner_tool_probe_output(tool_output, required_tools, pinned_path)

    version_output = bounded_probe(
        probe_binary, [*probe_prefix, "--version"], probe_env, "Codex version probe",
    )
    version = validated_codex_version(version_output)

    auth_output = bounded_probe(
        probe_binary, [
            *probe_prefix,
            "login",
            "-c", 'forced_login_method="chatgpt"',
            "-c", 'cli_auth_credentials_store="file"',
            "status",
        ], probe_env, "Codex auth probe",
    )
    if operator_review_auth is not None:
        revalidate_operator_review_auth(operator_review_auth)
    if normalized_nonempty_lines(auth_output) != ["Logged in using ChatGPT"]:
        fail("Codex auth probe did not return the exact ChatGPT subscription status")

    values = [
        codex, bun, account_home, codex_home, version,
        *(codex_prefix or [""]), pinned_path, str(runtime_uid), runtime_user,
        runtime_home, runtime_codex_home,
        str(attestation["runtime_gid"]) if attestation is not None else str(pwd.getpwuid(uid).pw_gid),
        str(attestation["runtime_group"]) if attestation is not None else grp.getgrgid(pwd.getpwuid(uid).pw_gid).gr_name,
        str(attestation["runner_path"]) if attestation is not None else "operator-review-direct",
        ATTESTATION_SCHEMA if attestation is not None else "qofi-codex-operator-review/v1",
        operator_canary_value,
    ]
    if any("|" in value or "\n" in value or "\r" in value for value in values):
        fail("validated host path contains an unsupported delimiter")
    if exec_mode:
        actual_prefix = [*probe_prefix]
        child_args = list(exec_args)
        child_cwd = None
        if attestation is not None and review_mode:
            actual_prefix = ["-n", "--", str(attestation["runner_path"]), "--mode", "review",
                             "--parent-pid", str(os.getpid()), "--"]
        elif operator_review:
            child_args = replace_review_cwd(child_args, operator_review_workspace)
            child_cwd = operator_review_workspace
            assert operator_review_auth is not None
            revalidate_operator_review_auth(operator_review_auth)
        try:
            child = subprocess.Popen(
                [probe_binary, *actual_prefix, *child_args], env=probe_env, cwd=child_cwd,
                stdin=None, stdout=None, stderr=None,
            )
            raise SystemExit(child.wait())
        except OSError as exc:
            fail(f"could not execute the validated Codex plan: {exc}")
    print("|".join(values))


if __name__ == "__main__":
    main()
