#!/usr/bin/python3
"""No-spend Claude fixture used only by test-fable-reviewer-mcp.py."""

import json
import os
from pathlib import Path
import signal
import sys
import subprocess
import time


home = Path(os.environ["HOME"])
home.joinpath("argv.json").write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
payload = sys.stdin.read()
home.joinpath("stdin.json").write_text(payload, encoding="utf-8")
home.joinpath("env.json").write_text(json.dumps({
    "has_api_key": bool(os.environ.get("ANTHROPIC_API_KEY")),
    "has_oauth": bool(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")),
    "nonessential_traffic": os.environ.get("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"),
    "cwd_is_home": os.getcwd() == str(home),
}), encoding="utf-8")
behavior = home.joinpath("behavior").read_text(encoding="utf-8").strip()


def append_concurrency(event):
    log_fd = os.open(str(home / "concurrency.log"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(log_fd, ("%s %d\n" % (event, os.getpid())).encode("ascii"))
    os.close(log_fd)


if behavior == "serialize":
    append_concurrency("start")
    time.sleep(0.4)
    append_concurrency("end")
if behavior == "supervision":
    def terminate(_signum, _frame):
        append_concurrency("end")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminate)
    child = subprocess.Popen(["/bin/sleep", "30"])
    home.joinpath("active.pid").write_text(str(os.getpid()), encoding="ascii")
    home.joinpath("descendant.pid").write_text(str(child.pid), encoding="ascii")
    append_concurrency("start")
    while True:
        time.sleep(10)
if behavior in ("descendant", "timeout-descendant"):
    child = subprocess.Popen(["/bin/sleep", "30"])
    home.joinpath("descendant.pid").write_text(str(child.pid), encoding="ascii")
if behavior in ("timeout", "timeout-descendant"):
    time.sleep(10)
    raise SystemExit(0)
sys.stdout.write(home.joinpath("response.json").read_text(encoding="utf-8"))
