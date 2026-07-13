#!/usr/bin/env python3
"""Write one macOS generic-password value without a controlling terminal.

The secret is accepted only on stdin.  It is never accepted on argv, printed,
or included in an exception.  /usr/bin/security is placed in a new session so
its bare ``-w`` prompt cannot bypass the supplied pipe and wait on the caller's
controlling terminal.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
from typing import Optional


MAX_SECRET_BYTES = 1024 * 1024
WRITE_TIMEOUT_SECONDS = 15
SECURITY = "/usr/bin/security"
_ACTIVE_PROCESS: Optional[subprocess.Popen[bytes]] = None
_CANCEL_SIGNAL = 0


def fail(message: str, code: int = 2) -> int:
    print(f"security-add-generic-password: {message}", file=sys.stderr)
    return code


def read_secret() -> bytes:
    # One extra byte distinguishes a maximum-sized value from oversized input.
    raw = sys.stdin.buffer.read(MAX_SECRET_BYTES + 2)
    if len(raw) > MAX_SECRET_BYTES + 1:
        raise ValueError("stdin value exceeds the size limit")

    # `security find-generic-password -w` appends one newline, so restoration
    # may legitimately provide exactly one trailing LF.  No interior newline or
    # carriage return is valid for this line-oriented prompt.
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    if not raw:
        raise ValueError("stdin value is empty")
    if len(raw) > MAX_SECRET_BYTES:
        raise ValueError("stdin value exceeds the size limit")
    if b"\n" in raw or b"\r" in raw:
        raise ValueError("stdin value is not a single line")
    return raw


def kill_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError:
        try:
            process.kill()
        except OSError:
            pass


def terminate_and_reap(process: subprocess.Popen[bytes]) -> None:
    kill_process_group(process)
    try:
        process.communicate(timeout=2)
    except (subprocess.TimeoutExpired, OSError):
        pass


def handle_cancel(signum: int, _frame: object) -> None:
    """Kill the prompt child immediately; the main path performs the reap."""
    global _CANCEL_SIGNAL
    _CANCEL_SIGNAL = signum
    if _ACTIVE_PROCESS is not None:
        kill_process_group(_ACTIVE_PROCESS)


def security_environment() -> dict[str, str]:
    # Keep only the identity/locale context securityd needs. In particular, do
    # not forward arbitrary loader, Python, shell, or credential variables.
    child_env = {"PATH": "/usr/bin:/bin"}
    for name in (
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "__CF_USER_TEXT_ENCODING",
    ):
        value = os.environ.get(name)
        if value is not None:
            child_env[name] = value
    return child_env


def main() -> int:
    global _ACTIVE_PROCESS, _CANCEL_SIGNAL
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--service", required=True)
    parser.add_argument("--account", required=True)
    try:
        args = parser.parse_args()
    except SystemExit:
        return fail("invalid arguments")

    try:
        secret = read_secret()
    except (OSError, ValueError) as exc:
        return fail(str(exc))

    command = [
        SECURITY,
        "add-generic-password",
        "-U",
        "-s",
        args.service,
        "-a",
        args.account,
    ]
    # A bare -w must remain the final argument or `security` treats the next
    # token as the password instead of prompting on its input. The caller
    # therefore refuses explicit-keychain writes: this CLI cannot combine its
    # required trailing keychain operand with a final bare -w securely.
    command.append("-w")

    prompt_input = secret + b"\n" + secret + b"\n"
    handled_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    old_handlers = {signum: signal.getsignal(signum) for signum in handled_signals}
    _ACTIVE_PROCESS = None
    _CANCEL_SIGNAL = 0
    for signum in handled_signals:
        signal.signal(signum, handle_cancel)
    try:
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                start_new_session=True,
                env=security_environment(),
            )
        except OSError:
            if _CANCEL_SIGNAL:
                return fail("keychain write was interrupted", 128 + _CANCEL_SIGNAL)
            return fail("could not start /usr/bin/security", 126)

        _ACTIVE_PROCESS = process
        if _CANCEL_SIGNAL:
            kill_process_group(process)
        try:
            process.communicate(input=prompt_input, timeout=WRITE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            terminate_and_reap(process)
            return fail("keychain write timed out", 124)
        except (KeyboardInterrupt, OSError):
            terminate_and_reap(process)
            return fail("keychain write was interrupted", 130)

        if _CANCEL_SIGNAL:
            # communicate() above reaped the child after the handler killed its
            # process group. Preserve the conventional signal-derived status.
            return fail("keychain write was interrupted", 128 + _CANCEL_SIGNAL)

        if process.returncode is None:
            terminate_and_reap(process)
            return fail("keychain write did not terminate", 125)
        if process.returncode < 0:
            return 128 + min(-process.returncode, 127)
        return process.returncode
    finally:
        _ACTIVE_PROCESS = None
        for signum, old_handler in old_handlers.items():
            signal.signal(signum, old_handler)


if __name__ == "__main__":
    raise SystemExit(main())
