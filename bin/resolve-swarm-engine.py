#!/usr/bin/python3
"""Resolve exactly one canonical swarm.conf row for a repository."""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path


class MissingRepoError(ValueError):
    """The config is valid but has no row for the requested repository."""


def resolve(config: Path, repo: Path, requested: str | None = None) -> str:
    if requested not in (None, "claude", "codex"):
        raise ValueError("requested engine must be claude or codex")
    fd = os.open(config, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        os.close(fd)
        raise ValueError("swarm.conf must be a regular non-symlink")
    if info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022:
        os.close(fd)
        raise ValueError("swarm.conf has unsafe owner or mode")
    if info.st_size > 1024 * 1024:
        os.close(fd)
        raise ValueError("swarm.conf exceeds 1 MiB")
    target = os.path.realpath(repo)
    matches: list[str] = []
    with os.fdopen(fd, "r", encoding="utf-8") as source:
        for number, raw in enumerate(source, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            fields = [field.strip() for field in raw.rstrip("\r\n").split("|")]
            if len(fields) < 2 or not fields[0] or not fields[1]:
                raise ValueError(f"malformed swarm.conf row {number}")
            if not os.path.isabs(fields[1]):
                raise ValueError(f"repo path in row {number} is not absolute")
            if os.path.realpath(fields[1]) != target:
                continue
            engine = fields[6] if len(fields) >= 7 and fields[6] else "claude"
            if engine not in ("claude", "codex"):
                raise ValueError(f"invalid engine in matching row {number}")
            matches.append(engine)
    if not matches:
        raise MissingRepoError("expected exactly one canonical repo row; found 0")
    if len(matches) != 1:
        # Multiple names may intentionally share one physical checkout. Cwd
        # alone cannot identify the authoring swarm, but an explicit engine is
        # safe when at least one matching row proves that engine is registered.
        if requested is not None and requested in matches:
            return requested
        raise ValueError(
            f"expected one repo row or an explicit matching engine; found {len(matches)}"
        )
    return matches[0]


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print("usage: resolve-swarm-engine.py SWARM_CONF REPO [claude|codex]", file=sys.stderr)
        return 2
    try:
        print(resolve(Path(argv[1]), Path(argv[2]), argv[3] if len(argv) == 4 else None))
        return 0
    except MissingRepoError as exc:
        print(f"resolve-swarm-engine: {exc}", file=sys.stderr)
        return 4
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"resolve-swarm-engine: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
