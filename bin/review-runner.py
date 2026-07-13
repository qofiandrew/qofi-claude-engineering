#!/usr/bin/env python3
"""Run one advisory reviewer command with hard time/input/output bounds."""

from __future__ import annotations

import argparse
import os
import resource
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Callable


BIDI_CONTROLS = {
    "\u061c", "\u200e", "\u200f", "\u202a", "\u202b", "\u202c", "\u202d", "\u202e",
    "\u2066", "\u2067", "\u2068", "\u2069",
}


def sanitize_terminal_output(payload: bytes) -> bytes:
    """Remove terminal control strings, cursor controls, and bidi overrides.

    Reviewer output is influenced by an untrusted diff/directive. It may be
    printed into an operator's terminal, so OSC clipboard/title sequences and
    CSI cursor controls must remain data rather than terminal instructions.
    """

    text = payload.decode("utf-8", "replace")
    result: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        code = ord(char)
        if char in BIDI_CONTROLS:
            index += 1
            continue
        if char == "\x1b":
            index += 1
            if index >= len(text):
                break
            kind = text[index]
            index += 1
            if kind == "[":  # CSI: parameters/intermediates through final byte.
                while index < len(text) and not ("@" <= text[index] <= "~"):
                    index += 1
                if index < len(text):
                    index += 1
                continue
            if kind in "]P^_X":  # OSC/DCS/PM/APC/SOS through BEL or ST.
                while index < len(text):
                    if text[index] == "\x07":
                        index += 1
                        break
                    if text[index:index + 2] == "\x1b\\":
                        index += 2
                        break
                    index += 1
                continue
            # Fe/character-set/other short ESC sequence. Consume intermediate
            # bytes and one final byte, never reflecting the escape itself.
            while index < len(text) and " " <= text[index] <= "/":
                index += 1
            if index < len(text):
                index += 1
            continue
        if code in (0x90, 0x98, 0x9D, 0x9E, 0x9F):
            # Eight-bit DCS/SOS/OSC/PM/APC form through C1 ST. An unterminated
            # string consumes the remainder rather than reaching the terminal.
            index += 1
            while index < len(text) and ord(text[index]) != 0x9C:
                index += 1
            if index < len(text):
                index += 1
            continue
        if code == 0x9B:  # Eight-bit CSI.
            index += 1
            while index < len(text) and not ("@" <= text[index] <= "~"):
                index += 1
            if index < len(text):
                index += 1
            continue
        if char == "\r":
            if index + 1 >= len(text) or text[index + 1] != "\n":
                result.append("\n")
            index += 1
            continue
        if (code < 0x20 and char not in ("\n", "\t")) or 0x7F <= code <= 0x9F:
            index += 1
            continue
        result.append(char)
        index += 1
    return "".join(result).encode("utf-8")


def group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # macOS can leave an unsignalable zombie process-group shell briefly
        # after its last live member exits. There is nothing left to reap/kill.
        return False


def kill_group(proc: subprocess.Popen[bytes]) -> None:
    # The group can outlive its leader (for example `cmd & exit`). Always
    # address the process group, even after Popen.poll() reports leader exit.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    deadline = time.monotonic() + 0.5
    while group_alive(proc.pid) and time.monotonic() < deadline:
        time.sleep(0.02)
    if group_alive(proc.pid):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def read_regular_beneath(root: str, path: str, limit: int) -> bytes:
    """Open one regular file beneath root without following any symlink.

    Walking with directory fds keeps parent replacement from redirecting the
    trusted wrapper between validation and open.
    """

    raw_root = os.path.abspath(root)
    candidate = os.path.abspath(path)
    try:
        relative = os.path.relpath(candidate, raw_root)
        if relative == os.pardir or relative.startswith(os.pardir + os.sep):
            # macOS commonly spells the same temp tree as both /var/... and
            # /private/var/.... Map only through the canonical parent; paths
            # lexically beneath root retain their components so openat still
            # rejects any in-repo parent symlink.
            mapped = os.path.join(os.path.realpath(os.path.dirname(candidate)), os.path.basename(candidate))
            relative = os.path.relpath(mapped, os.path.realpath(raw_root))
    except ValueError as exc:
        raise OSError("input path is outside the allowed root") from exc
    parts = relative.split(os.sep)
    if not parts or relative == os.pardir or relative.startswith(os.pardir + os.sep):
        raise OSError("input path is outside the allowed root")
    if any(part in ("", ".", "..") for part in parts):
        raise OSError("input path is not canonical beneath the allowed root")

    root = os.path.realpath(raw_root)

    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    dir_fd = os.open(root, os.O_RDONLY | directory | nofollow)
    opened: list[int] = [dir_fd]
    try:
        for part in parts[:-1]:
            dir_fd = os.open(part, os.O_RDONLY | directory | nofollow, dir_fd=dir_fd)
            opened.append(dir_fd)
        fd = os.open(
            parts[-1],
            os.O_RDONLY | nofollow | getattr(os, "O_NONBLOCK", 0),
            dir_fd=dir_fd,
        )
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise OSError("input is not a regular file")
            if info.st_size > limit:
                raise OSError(f"input exceeded {limit} bytes")
            with os.fdopen(fd, "rb", closefd=False) as source:
                payload = source.read(limit + 1)
            if len(payload) > limit:
                raise OSError(f"input exceeded {limit} bytes")
            return payload
        finally:
            os.close(fd)
    finally:
        for opened_fd in reversed(opened):
            os.close(opened_fd)


def read_stdin_bounded(limit: int, timeout: int, interrupted: Callable[[], int]) -> bytes:
    fd = sys.stdin.buffer.fileno()
    chunks: list[bytes] = []
    total = 0
    deadline = time.monotonic() + timeout
    was_blocking = os.get_blocking(fd)
    os.set_blocking(fd, False)
    try:
        while True:
            signum = interrupted()
            if signum:
                raise InterruptedError(signum)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            try:
                chunk = os.read(fd, min(65536, limit + 1 - total))
            except BlockingIOError:
                time.sleep(min(0.05, remaining))
                continue
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
            total += len(chunk)
            if total > limit:
                return b"".join(chunks)
    finally:
        os.set_blocking(fd, was_blocking)


def main() -> int:
    interrupted_signal = 0

    def note_signal(signum: int, _frame: object) -> None:
        nonlocal interrupted_signal
        interrupted_signal = signum

    signal.signal(signal.SIGTERM, note_signal)
    signal.signal(signal.SIGHUP, note_signal)
    signal.signal(signal.SIGINT, note_signal)

    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--input-timeout", type=int, default=10)
    parser.add_argument("--max-input", type=int, default=5 * 1024 * 1024)
    parser.add_argument("--max-output", type=int, default=1024 * 1024)
    parser.add_argument("--input-file")
    parser.add_argument("--input-root")
    parser.add_argument("--clean-env", action="store_true")
    parser.add_argument("--sanitize-terminal", action="store_true")
    parser.add_argument("--set-env", action="append", default=[])
    parser.add_argument("--pass-env", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not (1 <= args.timeout <= 600):
        parser.error("a command and timeout from 1 through 600 seconds are required")
    if not (1024 <= args.max_input <= 32 * 1024 * 1024):
        parser.error("max-input must be from 1024 through 33554432 bytes")
    if not (1024 <= args.max_output <= 8 * 1024 * 1024):
        parser.error("max-output must be from 1024 through 8388608 bytes")
    if not (1 <= args.input_timeout <= 60):
        parser.error("input-timeout must be from 1 through 60 seconds")
    if bool(args.input_file) != bool(args.input_root):
        parser.error("--input-file and --input-root must be supplied together")
    child_env = {} if args.clean_env else dict(os.environ)
    for name in args.pass_env:
        if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", name):
            parser.error(f"invalid pass-env name: {name}")
        if name in os.environ:
            child_env[name] = os.environ[name]
    for assignment in args.set_env:
        name, separator, value = assignment.partition("=")
        if not separator or not re.fullmatch(r"[A-Z_][A-Z0-9_]*", name) or "\x00" in value:
            parser.error(f"invalid set-env assignment: {assignment}")
        child_env[name] = value

    try:
        payload = (
            read_regular_beneath(args.input_root, args.input_file, args.max_input)
            if args.input_file
            else read_stdin_bounded(
                args.max_input,
                args.input_timeout,
                lambda: interrupted_signal,
            )
        )
    except InterruptedError as exc:
        signum = int(exc.args[0]) if exc.args else interrupted_signal
        print(f"review-runner: interrupted by signal {signum} while reading input", file=sys.stderr)
        return 128 + signum
    except TimeoutError:
        print(f"review-runner: input timed out after {args.input_timeout}s", file=sys.stderr)
        return 124
    except OSError as exc:
        print(f"review-runner: refused input file: {exc}", file=sys.stderr)
        return 126
    if len(payload) > args.max_input:
        print(f"review-runner: input exceeded {args.max_input} bytes", file=sys.stderr)
        return 126

    input_file = tempfile.TemporaryFile()
    input_file.write(payload)
    input_file.seek(0)
    # Never publish a pathname. The caller/model can have a same-UID background
    # process; reopening a named temp after execution would permit an
    # unlink/symlink swap that turns this trusted relay into a host-file reader.
    output_file = tempfile.TemporaryFile(dir=args.cwd)

    def child_limits() -> None:
        resource.setrlimit(resource.RLIMIT_FSIZE, (args.max_output, args.max_output))
        os.umask(0o077)

    proc: subprocess.Popen[bytes] | None = None
    timed_out = False
    output_limited = False
    try:
        proc = subprocess.Popen(
            command,
            cwd=args.cwd,
            stdin=input_file,
            stdout=output_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            preexec_fn=child_limits,
            env=child_env,
        )
        deadline = time.monotonic() + args.timeout
        while proc.poll() is None:
            if interrupted_signal:
                kill_group(proc)
                break
            try:
                if os.fstat(output_file.fileno()).st_size >= args.max_output:
                    output_limited = True
                    kill_group(proc)
                    break
            except OSError:
                output_limited = True
                kill_group(proc)
                break
            # Check the deadline after the file size. RLIMIT_FSIZE can leave a
            # still-running child pinned exactly at the cap; if this process is
            # descheduled until the deadline, that observable limit violation
            # must not be misclassified as an ordinary child timeout.
            if time.monotonic() >= deadline:
                timed_out = True
                kill_group(proc)
                break
            time.sleep(0.05)
        proc.wait()

        output_file.seek(0)
        output = output_file.read(args.max_output)
        if args.sanitize_terminal:
            output = sanitize_terminal_output(output)
        sys.stdout.buffer.write(output)
        if output and not output.endswith(b"\n"):
            sys.stdout.buffer.write(b"\n")

        # Recheck the authoritative file size after reap. This also resolves a
        # deadline/limit collision if the child reached the cap between the
        # last poll and termination.
        if output_limited or os.fstat(output_file.fileno()).st_size >= args.max_output:
            print(f"review-runner: output exceeded {args.max_output} bytes", file=sys.stderr)
            return 125
        if timed_out:
            print(f"review-runner: timed out after {args.timeout}s", file=sys.stderr)
            return 124
        if interrupted_signal:
            print(f"review-runner: interrupted by signal {interrupted_signal}", file=sys.stderr)
            return 128 + interrupted_signal
        return proc.returncode if proc.returncode >= 0 else 128 - proc.returncode
    except FileNotFoundError as exc:
        print(f"review-runner: command failed to start: {exc}", file=sys.stderr)
        return 127
    finally:
        if proc is not None:
            kill_group(proc)
        input_file.close()
        output_file.close()


if __name__ == "__main__":
    raise SystemExit(main())
