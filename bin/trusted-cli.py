#!/usr/bin/python3
"""Resolve review CLIs from fixed, validated host install roots.

Production exposes only ``resolve`` and ``exec-plan`` for known CLIs. Tests import the pure
``resolve_cli`` function and inject candidates directly; there is no runtime
environment/argument override that an agent can select.
"""

from __future__ import annotations

import os
import pwd
import stat
import sys
from pathlib import Path
from typing import Iterable, Sequence


class TrustError(RuntimeError):
    pass


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _safe_chain(path: Path, root: Path, uid: int) -> None:
    """Validate every existing component from root through path.

    Owner-write is permitted for the operator's private install roots; the
    unattended Codex sandbox cannot write outside its target workspace. Group
    or world write, foreign ownership, and intermediate symlinks are refused.
    """

    raw_root = Path(os.path.abspath(root))
    chain = list(reversed(raw_root.parents)) + [raw_root]
    for component in chain:
        info = os.lstat(component)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise TrustError(f"unsafe trusted-root component: {component}")
        if info.st_uid not in (0, uid) or info.st_mode & 0o022:
            raise TrustError(f"unsafe trusted-root owner or mode: {component}")
    root = Path(os.path.realpath(raw_root))
    path = Path(os.path.abspath(path))
    if not _inside(path, root):
        raise TrustError(f"path escapes trusted install root: {path}")
    current = root
    parts = path.relative_to(root).parts
    for index, part in enumerate(parts):
        current = current / part
        info = os.lstat(current)
        is_final = index == len(parts) - 1
        if stat.S_ISLNK(info.st_mode) and not is_final:
            raise TrustError(f"symlinked install parent: {current}")
        if info.st_uid not in (0, uid):
            raise TrustError(f"foreign-owned install path: {current}")
        if not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o022:
            raise TrustError(f"group/world-writable install path: {current}")


def _default_candidates(kind: str, home: Path) -> list[Path]:
    if kind == "node":
        return [
            *sorted((home / ".nvm/versions/node").glob("*/bin/node"), reverse=True),
            home / ".local/bin/node",
            Path("/usr/local/bin/node"),
            Path("/opt/homebrew/bin/node"),
        ]
    if kind == "codex":
        nvm = sorted(
            (home / ".nvm/versions/node").glob("*/bin/codex"),
            reverse=True,
        )
        return [
            home / ".local/bin/codex",
            *nvm,
            Path("/usr/local/bin/codex"),
            Path("/opt/homebrew/bin/codex"),
        ]
    if kind == "claude":
        return [
            home / ".local/bin/claude",
            Path("/usr/local/bin/claude"),
            Path("/opt/homebrew/bin/claude"),
        ]
    raise TrustError(f"unsupported CLI: {kind}")


def resolve_cli(
    kind: str,
    *,
    candidates: Sequence[Path] | None = None,
    home: Path | None = None,
    workspace: Path | None = None,
    swarm_home: Path | None = None,
    allowed_roots: Iterable[Path] | None = None,
    forbidden_roots: Iterable[Path] | None = None,
    uid: int | None = None,
) -> Path:
    uid = os.getuid() if uid is None else uid
    home = Path(pwd.getpwuid(uid).pw_dir) if home is None else Path(home)
    workspace = Path.cwd() if workspace is None else Path(workspace)
    swarm_home = Path(__file__).resolve().parent.parent if swarm_home is None else Path(swarm_home)
    workspace = Path(os.path.realpath(workspace))
    swarm_home = Path(os.path.realpath(swarm_home))
    forbidden = list(forbidden_roots) if forbidden_roots is not None else [
        workspace,
        swarm_home,
        Path("/tmp"),
        Path("/private/tmp"),
        Path("/var/tmp"),
        Path("/var/folders"),
    ]
    forbidden = [Path(os.path.realpath(root)) for root in forbidden]
    roots = list(allowed_roots) if allowed_roots is not None else [
        home / ".local",
        home / ".nvm/versions",
        Path("/usr/local"),
        Path("/opt/homebrew"),
    ]
    roots = [Path(os.path.realpath(root)) for root in roots if Path(root).exists()]

    failures: list[str] = []
    for candidate in candidates or _default_candidates(kind, home):
        candidate = Path(os.path.abspath(candidate))
        if not candidate.exists() or candidate.is_dir():
            continue
        try:
            resolved = Path(os.path.realpath(candidate))
            if any(_inside(candidate, root) or _inside(resolved, root) for root in forbidden):
                raise TrustError("executable is inside workspace/swarm/temp")
            root = next(
                (root for root in roots if _inside(candidate, root) and _inside(resolved, root)),
                None,
            )
            if root is None:
                raise TrustError("launcher and target are not under one approved install root")
            _safe_chain(candidate, root, uid)
            _safe_chain(resolved, root, uid)
            info = os.stat(resolved)
            if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
                raise TrustError("resolved target is not an executable regular file")
            if info.st_uid not in (0, uid) or info.st_mode & 0o022:
                raise TrustError("resolved target has unsafe owner or mode")
            return candidate
        except (OSError, TrustError) as exc:
            failures.append(f"{candidate}: {exc}")
    detail = "; ".join(failures[-3:])
    raise TrustError(f"no trusted {kind} CLI found" + (f" ({detail})" if detail else ""))


def resolve_exec_plan(kind: str, **kwargs: object) -> tuple[Path, list[Path]]:
    """Return an absolute executable and immutable argv prefix.

    The official npm Codex launcher is a JavaScript file with
    ``#!/usr/bin/env node``. We never trust that ambient lookup: validate the
    sibling NVM node and execute ``[absolute-node, canonical-codex.js]``.
    """

    launcher = resolve_cli(kind, **kwargs)
    target = Path(os.path.realpath(launcher))
    with target.open("rb") as source:
        first = source.readline(256).rstrip(b"\r\n")
    if first == b"#!/usr/bin/env node":
        node_launcher = launcher.parent / "node"
        node_kwargs = dict(kwargs)
        node_kwargs.pop("candidates", None)
        node = resolve_cli(kind, candidates=[node_launcher], **node_kwargs)
        return Path(os.path.realpath(node)), [target]
    if first.startswith(b"#!/usr/bin/env"):
        raise TrustError(f"ambient env shebang is not trusted: {target}")
    return target, []


def main(argv: Sequence[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("resolve", "exec-plan") or argv[2] not in ("node", "codex", "claude"):
        print("usage: trusted-cli.py resolve|exec-plan node|codex|claude", file=sys.stderr)
        return 2
    try:
        if argv[1] == "resolve":
            print(resolve_cli(argv[2]))
        else:
            executable, prefix = resolve_exec_plan(argv[2])
            fields = [str(executable), *(str(item) for item in prefix)]
            if any("\t" in item or "\n" in item for item in fields):
                raise TrustError("resolved path contains a control character")
            print("\t".join(fields))
        return 0
    except TrustError as exc:
        print(f"trusted-cli: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
