#!/usr/bin/python3
"""Contract tests for the owner-local manager lifecycle/review client."""

from __future__ import annotations

import http.server
import json
import os
import socketserver
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "bin" / "codex-manager-control.py"


def health(**changes: object) -> dict[str, object]:
    value: dict[str, object] = {
        "schema": "qofi-codex-app-server-manager/v1",
        "status": "ready",
        "phase": "idle",
        "generation": 1,
        "registeredSwarmCount": 0,
        "upstreamReady": True,
        "upstreamState": "ready",
        "managerVersion": "0.1.0",
        "protocolVersion": "0.144.1",
        "cliVersion": "0.144.1",
    }
    value.update(changes)
    return value


class UnixHttpServer(socketserver.UnixStreamServer):
    allow_reuse_address = False


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    server: "FixtureServer"

    def log_message(self, _format: str, *args: object) -> None:
        del args

    def body(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        return json.loads(raw) if raw else {}

    def send_json(self, value: dict[str, object], status: int = 200) -> None:
        raw = (json.dumps(value, separators=(",", ":")) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/v1/health":
            self.send_json({"error": "not found"}, 404)
            return
        self.send_json(self.server.health_value)

    def do_POST(self) -> None:  # noqa: N802
        value = self.body()
        self.server.requests.append((self.path, value))
        if self.path == "/v1/drain":
            self.send_json({"drained": True, "generation": 1})
        elif self.path == "/v1/resume":
            self.send_json({"ready": True, "generation": 2})
        elif self.path == "/v1/shutdown":
            self.send_json({"stopping": True})
        elif self.path == "/v1/review/start":
            self.send_json({
                "leaseId": "b" * 64,
                "cleanupToken": "c" * 64,
                "threadId": "thread-1",
                "turnId": "turn-1",
                "result": {
                    "ok": True,
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "status": "completed",
                    "messages": ["first", "second"],
                    "ambiguous": False,
                },
                "cleanupRequired": True,
                "generation": 1,
            })
        elif self.path == "/v1/turn/cleanup-complete":
            self.send_json({"ready": True, "generation": 2})
        else:
            self.send_json({"error": "not found"}, 404)


class FixtureServer(UnixHttpServer):
    def __init__(self, path: str, health_value: dict[str, object]):
        self.health_value = health_value
        self.requests: list[tuple[str, dict[str, object]]] = []
        super().__init__(path, FixtureHandler)


class ControlTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="qofi-manager-control.")
        self.canonical_temp = os.path.realpath(self.temp.name)
        os.chmod(self.canonical_temp, 0o700)
        self.socket_path = os.path.join(self.canonical_temp, "control.sock")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_with_server(
        self,
        command: str,
        *,
        input_text: str = "",
        health_value: dict[str, object] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], FixtureServer]:
        server = FixtureServer(self.socket_path, health_value or health())
        os.chmod(self.socket_path, 0o600)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        result = subprocess.run(
            ["/usr/bin/python3", "-I", "-B", str(HELPER), "--socket", self.socket_path, command],
            input=input_text,
            text=True,
            capture_output=True,
            timeout=10,
            env={"HOME": self.canonical_temp, "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        )
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        return result, server

    def test_ready_requires_the_exact_compatible_idle_contract(self) -> None:
        result, _server = self.run_with_server("ready")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["schema"], health()["schema"])

        result, _server = self.run_with_server(
            "ready", health_value=health(status="busy", phase="active"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not ready", result.stderr)

        reserved = health(status="busy", phase="reserved")
        result, _server = self.run_with_server("health", health_value=reserved)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["phase"], "reserved")

        result, _server = self.run_with_server("ready", health_value=reserved)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not ready", result.stderr)

    def test_lifecycle_acknowledgements_are_bounded_and_validated(self) -> None:
        for command, key in (("drain", "drained"), ("resume", "ready"), ("shutdown", "stopping")):
            result, server = self.run_with_server(command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)[key])
            self.assertEqual(server.requests, [(f"/v1/{command}", {})])

    def test_review_acks_cleanup_before_printing_bounded_messages(self) -> None:
        result, server = self.run_with_server("review", input_text="review this")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "first\nsecond\n")
        self.assertEqual(server.requests[0][0], "/v1/review/start")
        self.assertEqual(server.requests[0][1]["prompt"], "review this")
        self.assertRegex(str(server.requests[0][1]["requestId"]), r"^[0-9a-f]{32}$")
        self.assertEqual(server.requests[1], (
            "/v1/turn/cleanup-complete",
            {"cleanupToken": "c" * 64, "leaseId": "b" * 64, "ok": True},
        ))


if __name__ == "__main__":
    unittest.main()
