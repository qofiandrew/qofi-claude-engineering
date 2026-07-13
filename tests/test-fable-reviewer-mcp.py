#!/usr/bin/python3 -I
"""Focused no-spend contract tests for the Fable reviewer MCP shim."""

from __future__ import annotations

import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import socketserver
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "bin" / "qofi-fable-reviewer-mcp.py"
FIXTURES = ROOT / "tests" / "fixtures" / "fable-reviewer"
spec = importlib.util.spec_from_file_location("qofi_fable_reviewer_mcp", SOURCE)
assert spec and spec.loader
mcp = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mcp
spec.loader.exec_module(mcp)


class Clock:
    def __init__(self) -> None:
        self.value = 1_700_000_000.0
        self.sleeps = []

    def now(self) -> float:
        return self.value

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.value += seconds


class FableReviewerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="fable-reviewer-test-")
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / "state"
        self.home = self.root / "home"
        self.state.mkdir(mode=0o700)
        self.home.mkdir(mode=0o700)
        self.fake = self.root / "fake-claude"
        shutil.copyfile(FIXTURES / "fake-claude.py", self.fake)
        self.fake.chmod(0o700)
        shutil.copyfile(FIXTURES / "claude-success.json", self.home / "response.json")
        (self.home / "behavior").write_text("success\n", encoding="utf-8")
        self.clock = Clock()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def scope(self, **changes):
        policy = mcp.ReviewPolicy(
            auth_lane=changes.pop("auth_lane", "device"),
            max_calls_per_task=changes.pop("max_calls_per_task", 1),
            max_calls_per_window=changes.pop("max_calls_per_window", 10),
            window_seconds=changes.pop("window_seconds", 60),
            timeout_seconds=changes.pop("timeout_seconds", 2),
            failure_policy="review-pending",
        )
        return mcp.ReviewScope(
            swarm=changes.pop("swarm", "press-backend"),
            profile=changes.pop("profile", "default"),
            task_id=changes.pop("task_id", "task-123"),
            state_dir=str(self.state),
            policy=policy,
        )

    def reviewer(self, scope=None, api_key_provider=None):
        selected = scope or self.scope()
        return mcp.FableReviewer(
            scope_provider=lambda: selected,
            claude_bin=str(self.fake),
            claude_home=str(self.home),
            doctrine_path=str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
            schema_path=str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
            api_key_provider=api_key_provider,
            now=self.clock.now,
            sleeper=self.clock.sleep,
        )

    def arguments(self, fixture="diff.patch"):
        return {
            "diff_or_files": (FIXTURES / fixture).read_text(encoding="utf-8"),
            "context_refs": [{"name": "standing-invariants", "content": "SYNC != LIVE; push is operator-only."}],
            "mode": "code",
        }

    def bun_intake(self, task_id, profile="default"):
        script = r'''
import { readFableReviewArtifacts } from './codex-bridge/review-artifacts.ts'
const artifacts = readFableReviewArtifacts(process.argv[1], process.argv[2], 'press-backend', process.argv[3])
process.stdout.write(JSON.stringify(artifacts))
'''
        completed = subprocess.run(
            ["bun", "-e", script, str(self.state), task_id, profile],
            cwd=ROOT, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return json.loads(completed.stdout.decode("utf-8"))

    def test_fixture_diff_produces_schema_valid_private_artifact(self) -> None:
        result = self.reviewer().review(self.arguments())
        self.assertEqual("approve", result["verdict"])
        self.assertEqual(result, mcp.validate_v2_result(result))
        artifacts = list((self.state / "review-artifacts" / "task-123" / "default").glob("fable-review-*.json"))
        self.assertEqual(1, len(artifacts))
        artifact = json.loads(artifacts[0].read_text(encoding="utf-8"))
        self.assertEqual("qofi-fable-review-artifact/v1", artifact["schema"])
        self.assertRegex(artifact["reviewed_diff_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(result, artifact["result"])
        self.assertEqual(0o600, stat.S_IMODE(artifacts[0].stat().st_mode))

        argv = json.loads((self.home / "argv.json").read_text(encoding="utf-8"))
        for flag in ("-p", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-chrome", "--no-session-persistence", "--json-schema"):
            self.assertIn(flag, argv)
        self.assertEqual("claude-fable-5", argv[argv.index("--model") + 1])
        self.assertEqual("", argv[argv.index("--tools") + 1])
        self.assertEqual('{"mcpServers":{}}', argv[argv.index("--mcp-config") + 1])
        self.assertEqual("dontAsk", argv[argv.index("--permission-mode") + 1])
        self.assertEqual("json", argv[argv.index("--output-format") + 1])

    def test_manager_one_shot_returns_exact_artifact_receipt(self) -> None:
        arguments = {
            "diff_or_files": "qofi completion review: no workspace file changes",
            "context_refs": [],
            "mode": "code",
        }
        _, reviewed_hash = mcp.normalize_review_input(arguments)
        scope = self.scope(task_id="terminal-task")
        request = {
            "schema": "qofi-fable-reviewer-one-shot-request/v1",
            "scope": {
                "schema": "qofi-fable-reviewer-scope/v1",
                "slot": scope.slot,
                "slot_token": "a" * 64,
                "early_review": scope.early_review,
                "swarm": scope.swarm,
                "profile": scope.profile,
                "task_id": scope.task_id,
                "state_dir": scope.state_dir,
                "policy": {
                    "auth_lane": scope.policy.auth_lane,
                    "max_calls_per_task": scope.policy.max_calls_per_task,
                    "max_calls_per_window": scope.policy.max_calls_per_window,
                    "window_seconds": scope.policy.window_seconds,
                    "timeout_seconds": scope.policy.timeout_seconds,
                    "failure_policy": scope.policy.failure_policy,
                },
            },
            "arguments": arguments,
            "expected_reviewed_diff_sha256": reviewed_hash,
        }
        parent_read, parent_write = os.pipe()
        try:
            completed = subprocess.run(
                [
                    sys.executable, "-I", "-B", str(SOURCE), "--one-shot",
                    "--parent-fd", str(parent_read),
                    "--claude-bin", str(self.fake),
                    "--claude-home", str(self.home),
                    "--doctrine", str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
                    "--schema", str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
                ],
                input=(mcp.compact_json(request) + "\n").encode("utf-8"),
                pass_fds=(parent_read,),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
        finally:
            os.close(parent_read)
            os.close(parent_write)
        self.assertEqual(0, completed.returncode, completed.stderr)
        response = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual("qofi-fable-reviewer-one-shot-result/v1", response["schema"])
        self.assertEqual(reviewed_hash, response["reviewed_diff_sha256"])
        self.assertEqual("approve", response["result"]["verdict"])
        self.assertRegex(response["artifact"]["name"], r"^fable-review-.*\.json$")
        self.assertRegex(response["artifact"]["sha256"], r"^[0-9a-f]{64}$")
        artifact = self.state / "review-artifacts" / "terminal-task" / "default" / response["artifact"]["name"]
        self.assertEqual(response["artifact"]["sha256"], hashlib.sha256(artifact.read_bytes()).hexdigest())

    def test_manager_liveness_eof_reaps_one_shot_claude_group_without_artifact(self) -> None:
        (self.home / "behavior").write_text("supervision\n", encoding="utf-8")
        arguments = {
            "diff_or_files": "qofi completion review: no workspace file changes",
            "context_refs": [],
            "mode": "code",
        }
        _, reviewed_hash = mcp.normalize_review_input(arguments)
        scope = self.scope(task_id="manager-loss")
        request = {
            "schema": "qofi-fable-reviewer-one-shot-request/v1",
            "scope": {
                "schema": "qofi-fable-reviewer-scope/v1",
                "slot": scope.slot,
                "slot_token": "b" * 64,
                "early_review": scope.early_review,
                "swarm": scope.swarm,
                "profile": scope.profile,
                "task_id": scope.task_id,
                "state_dir": scope.state_dir,
                "policy": {
                    "auth_lane": scope.policy.auth_lane,
                    "max_calls_per_task": scope.policy.max_calls_per_task,
                    "max_calls_per_window": scope.policy.max_calls_per_window,
                    "window_seconds": scope.policy.window_seconds,
                    "timeout_seconds": 10,
                    "failure_policy": scope.policy.failure_policy,
                },
            },
            "arguments": arguments,
            "expected_reviewed_diff_sha256": reviewed_hash,
        }

        def wait_for_pid(path: Path) -> int:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    return int(path.read_text(encoding="ascii"))
                except (FileNotFoundError, ValueError):
                    time.sleep(0.02)
            self.fail("one-shot Claude process tree did not start")

        def wait_gone(pid: int) -> None:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return
                time.sleep(0.02)
            self.fail("one-shot Claude process survived manager-liveness EOF: %d" % pid)

        parent_read, parent_write = os.pipe()
        process = subprocess.Popen(
            [
                sys.executable, "-I", "-B", str(SOURCE), "--one-shot",
                "--parent-fd", str(parent_read),
                "--claude-bin", str(self.fake),
                "--claude-home", str(self.home),
                "--doctrine", str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
                "--schema", str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=(parent_read,),
        )
        os.close(parent_read)
        try:
            assert process.stdin is not None
            process.stdin.write((mcp.compact_json(request) + "\n").encode("utf-8"))
            process.stdin.close()
            process.stdin = None
            active_pid = wait_for_pid(self.home / "active.pid")
            descendant_pid = wait_for_pid(self.home / "descendant.pid")

            os.close(parent_write)
            parent_write = -1
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(70, process.returncode, (stdout, stderr))
            wait_gone(active_pid)
            wait_gone(descendant_pid)
            self.assertEqual(
                [],
                list((self.state / "review-artifacts").rglob("fable-review-*.json")),
            )
        finally:
            if parent_write >= 0:
                os.close(parent_write)
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    def test_active_worker_manager_refusal_returns_unavailable_without_artifact(self) -> None:
        class RefusingScopeHandler(socketserver.StreamRequestHandler):
            def handle(handler_self) -> None:
                raw = bytearray()
                while b"\r\n\r\n" not in raw and len(raw) <= 16384:
                    chunk = handler_self.request.recv(4096)
                    if not chunk:
                        return
                    raw.extend(chunk)
                body = b'{"error":"worker-initiated reviewer scope is disabled"}'
                handler_self.request.sendall(
                    b"HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: "
                    + str(len(body)).encode("ascii")
                    + b"\r\nConnection: close\r\n\r\n"
                    + body
                )

        class ScopeServer(socketserver.UnixStreamServer):
            allow_reuse_address = False

        manager_path = self.root / "r.sock"
        server = ScopeServer(str(manager_path), RefusingScopeHandler)
        os.chmod(manager_path, 0o600)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            reviewer = mcp.FableReviewer(
                scope_provider=mcp.ManagerScopeProvider(str(manager_path)),
                claude_bin=str(self.fake),
                claude_home=str(self.home),
                doctrine_path=str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
                schema_path=str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
                now=self.clock.now,
                sleeper=self.clock.sleep,
            )
            response = mcp.McpServer(reviewer).handle({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": "adversarial_review", "arguments": self.arguments()},
            })
            self.assertEqual(
                "review-unavailable",
                response["result"]["structuredContent"]["verdict"],
            )
            self.assertFalse((self.home / "argv.json").exists())
            self.assertFalse((self.state / "fable-review-budget.json").exists())
            self.assertEqual([], list((self.state / "review-artifacts").rglob("*.json")))
        finally:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=5)

    def test_reviewed_hash_uses_exact_diff_bytes_and_canonical_bytewise_files(self) -> None:
        base = {"context_refs": [], "mode": "code"}
        _, raw_hash = mcp.normalize_review_input({**base, "diff_or_files": "abc"})
        _, wrapped_hash = mcp.normalize_review_input({**base, "diff_or_files": {"diff": "abc"}})
        self.assertEqual("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", raw_hash)
        self.assertEqual(raw_hash, wrapped_hash)

        files = [
            {"path": "a.ts", "content": "alpha\n"},
            {"path": "b.ts", "content": "β\n"},
        ]
        _, files_hash = mcp.normalize_review_input({**base, "diff_or_files": {"files": files}})
        self.assertEqual("bcd3782db3aa17d895fc62fd4267063f44aa48ac9f9de5b647b0f61511ea3c83", files_hash)
        _, reversed_hash = mcp.normalize_review_input({**base, "diff_or_files": {"files": list(reversed(files))}})
        self.assertEqual(files_hash, reversed_hash)
        with self.assertRaises(mcp.ReviewerError):
            mcp.normalize_review_input({**base, "diff_or_files": {"files": [files[0], files[0]]}})

    def test_injection_remains_stdin_data_and_cannot_change_doctrine(self) -> None:
        injection = (FIXTURES / "injection.patch").read_text(encoding="utf-8")
        result = self.reviewer().review(self.arguments("injection.patch"))
        self.assertEqual("approve", result["verdict"])
        argv = json.loads((self.home / "argv.json").read_text(encoding="utf-8"))
        self.assertNotIn(injection, json.dumps(argv))
        doctrine = (ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md").read_text(encoding="utf-8")
        self.assertEqual(doctrine, argv[argv.index("--system-prompt") + 1])
        stdin = json.loads((self.home / "stdin.json").read_text(encoding="utf-8"))
        self.assertEqual(injection, stdin["diff_or_files"])
        self.assertIn("untrusted DATA", stdin["data_boundary"])

    def test_account_identifiers_are_rejected_without_return_or_artifact_leak(self) -> None:
        shutil.copyfile(FIXTURES / "claude-sensitive.json", self.home / "response.json")
        result = self.reviewer().review(self.arguments())
        self.assertEqual("review-unavailable", result["verdict"])
        rendered = json.dumps(result, sort_keys=True)
        for forbidden in ("reviewer@example.com", "org_4FableSecret", "account_live_identifier"):
            self.assertNotIn(forbidden, rendered)
        artifacts = list((self.state / "review-artifacts").rglob("*.json"))
        self.assertEqual(1, len(artifacts))
        artifact = artifacts[0].read_text(encoding="utf-8")
        self.assertIn('"verdict":"review-unavailable"', artifact)
        for forbidden in ("reviewer@example.com", "org_4FableSecret", "account_live_identifier"):
            self.assertNotIn(forbidden, artifact)

        sensitive = json.loads(
            (FIXTURES / "synthetic-sensitive-output-tokens.json").read_text(encoding="utf-8")
        )
        response = json.loads((FIXTURES / "claude-success.json").read_text(encoding="utf-8"))
        response["structured_output"].update({
            "verdict": "needs-changes",
            "summary": "The bounded output contains a finding.",
            "checked": ["The supplied diff."],
            "not_checked": [],
            "findings": [{
                "severity": "high",
                "locus": "src/auth.ts:12",
                "claim": "The output confidentiality boundary must reject this value.",
                "evidence": "placeholder",
                "suggested_test": "Assert unsafe bytes never cross the result boundary.",
            }],
            "next_steps": [],
        })
        for index, fixture in enumerate(sensitive):
            with self.subTest(token_kind=fixture["label"]):
                token = "".join(fixture["parts"])
                response["structured_output"]["findings"][0]["evidence"] = token
                (self.home / "response.json").write_text(json.dumps(response), encoding="utf-8")
                selected = self.scope(
                    task_id="sensitive-%02d" % index,
                    max_calls_per_task=1,
                    max_calls_per_window=32,
                )
                rejected = self.reviewer(selected).review(self.arguments())
                self.assertTrue(mcp.contains_secret_material(token))
                self.assertEqual("review-unavailable", rejected["verdict"])
                self.assertNotIn(token, json.dumps(rejected, sort_keys=True))
                paths = list((self.state / "review-artifacts" / selected.task_id / "default").glob("*.json"))
                self.assertEqual(1, len(paths))
                persisted = paths[0].read_bytes()
                self.assertNotIn(token.encode("utf-8"), persisted)
                self.assertIn(b'"verdict":"review-unavailable"', persisted)

        # Common provenance values must remain usable.  A plain SHA-256 and a
        # long source identifier are not credentials and should survive the
        # exact same canonical output validator and artifact path.
        sha1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        sha256 = "8f14e45fceea167a5a36dedd4bea2543d82e3f5ab9ab4fe7b81d7b623a8d6f41"
        code_id = "resolveCanonicalReviewerOutputForTaskVersion2026"
        ordinary_ids = ("user_profile", "account_state", "org_slug")
        self.assertFalse(mcp.contains_secret_material(sha1))
        self.assertFalse(mcp.contains_secret_material(sha256))
        self.assertFalse(mcp.contains_secret_material(code_id))
        for ordinary_id in ordinary_ids:
            self.assertFalse(mcp.contains_secret_material(ordinary_id))
        response["structured_output"]["findings"][0]["evidence"] = (
            "sha1: %s; sha256: %s; identifiers: %s via %s"
            % (sha1, sha256, ", ".join(ordinary_ids), code_id)
        )
        (self.home / "response.json").write_text(json.dumps(response), encoding="utf-8")
        accepted_scope = self.scope(
            task_id="ordinary-provenance", max_calls_per_task=1, max_calls_per_window=32,
        )
        accepted = self.reviewer(accepted_scope).review(self.arguments())
        self.assertEqual("needs-changes", accepted["verdict"])
        accepted_artifacts = list(
            (self.state / "review-artifacts" / accepted_scope.task_id / "default").glob("*.json")
        )
        self.assertEqual(1, len(accepted_artifacts))
        self.assertIn(sha1.encode("ascii"), accepted_artifacts[0].read_bytes())
        self.assertIn(sha256.encode("ascii"), accepted_artifacts[0].read_bytes())
        for ordinary_id in ordinary_ids:
            self.assertIn(ordinary_id.encode("ascii"), accepted_artifacts[0].read_bytes())

    def test_timeout_is_review_unavailable_not_approval(self) -> None:
        (self.home / "behavior").write_text("timeout\n", encoding="utf-8")
        result = self.reviewer(self.scope(timeout_seconds=1)).review(self.arguments())
        self.assertEqual("review-unavailable", result["verdict"])
        self.assertIn("timed out", result["summary"])

    def test_unknown_or_recursive_tool_call_is_refused_without_invocation(self) -> None:
        server = mcp.McpServer(self.reviewer())
        response = server.handle({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "adversarial_review.adversarial_review", "arguments": self.arguments()},
        })
        self.assertTrue(response["result"]["isError"])
        self.assertFalse((self.home / "argv.json").exists())

    def test_window_exhaustion_waits_at_fifo_head_instead_of_dropping(self) -> None:
        queue = mcp.BudgetQueue(str(self.state), now=self.clock.now, sleeper=self.clock.sleep)
        first = self.scope(task_id="task-one", max_calls_per_window=1, window_seconds=60)
        second = self.scope(task_id="task-two", max_calls_per_window=1, window_seconds=60)
        self.assertEqual("acquired", queue.acquire(first))
        self.assertEqual("acquired", queue.acquire(second))
        self.assertEqual(1, len(self.clock.sleeps))
        self.assertAlmostEqual(60, self.clock.sleeps[0])

    def test_budget_lru_retains_4096_entries_and_prunes_only_the_oldest(self) -> None:
        stale = {"old-%04d" % index: 1 for index in range(mcp.MAX_BUDGET_TASK_COUNTS)}
        mcp.private_atomic_json(str(self.state / "fable-review-budget.json"), {
            "schema": "qofi-fable-review-budget/v1",
            "window_started_at": self.clock.now(),
            "window_count": 0,
            "task_counts": stale,
        }, mcp.MAX_ARTIFACT_BYTES)
        queue = mcp.BudgetQueue(str(self.state), now=self.clock.now, sleeper=self.clock.sleep)
        self.assertEqual("acquired", queue.acquire(self.scope(task_id="current-task")))
        persisted = json.loads((self.state / "fable-review-budget.json").read_text(encoding="utf-8"))
        self.assertEqual(mcp.MAX_BUDGET_TASK_COUNTS, len(persisted["task_counts"]))
        self.assertNotIn("old-0000", persisted["task_counts"])
        self.assertIn("old-0001", persisted["task_counts"])
        self.assertEqual(1, persisted["task_counts"]["current-task"])
        self.assertEqual("current-task", persisted["task_order"][-1])

    def test_budget_state_and_lock_refuse_hard_links(self) -> None:
        state_path = self.state / "fable-review-budget.json"
        mcp.private_atomic_json(str(state_path), {
            "schema": "qofi-fable-review-budget/v2",
            "window_started_at": self.clock.now(),
            "window_count": 0,
            "task_counts": {},
            "task_order": [],
        }, mcp.MAX_BUDGET_STATE_BYTES)
        os.link(state_path, self.state / "budget-state-alias")
        with self.assertRaisesRegex(mcp.ReviewerError, "unsafe budget state"):
            mcp.BudgetQueue(str(self.state), now=self.clock.now, sleeper=self.clock.sleep).acquire(self.scope())

        os.unlink(self.state / "budget-state-alias")
        lock_path = self.state / "fable-review-budget.lock"
        lock_path.write_bytes(b"")
        lock_path.chmod(0o600)
        os.link(lock_path, self.state / "budget-lock-alias")
        with self.assertRaisesRegex(mcp.ReviewerError, "unsafe budget lock"):
            mcp.BudgetQueue(str(self.state), now=self.clock.now, sleeper=self.clock.sleep).acquire(self.scope())

    def test_private_json_refuses_overwriting_a_hard_link(self) -> None:
        path = self.state / "private.json"
        mcp.private_atomic_json(str(path), {"value": 1}, 4096)
        os.link(path, self.state / "private-alias.json")
        with self.assertRaisesRegex(mcp.ReviewerError, "unsafe existing private JSON"):
            mcp.private_atomic_json(str(path), {"value": 2}, 4096)

    def test_post_replace_fsync_failure_cannot_leave_a_canonical_approval(self) -> None:
        reviewer = self.reviewer()
        scope = self.scope()
        approval = mcp.validate_v2_result(json.loads(
            (FIXTURES / "claude-success.json").read_text(encoding="utf-8")
        )["structured_output"])
        real_fsync = mcp.os.fsync

        def fail_directory_fsync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("injected directory fsync failure")
            return real_fsync(fd)

        with patch.object(mcp.os, "fsync", side_effect=fail_directory_fsync):
            with self.assertRaises(OSError):
                reviewer._write_artifact(scope, "code", "a" * 64, approval)
        profile = self.state / "review-artifacts" / scope.task_id / scope.profile
        self.assertEqual([], list(profile.glob("fable-review-*.json")))

    def test_parked_task_budget_survives_a_b_a_interleaving(self) -> None:
        queue = mcp.BudgetQueue(str(self.state), now=self.clock.now, sleeper=self.clock.sleep)
        task_a = self.scope(task_id="parked-a", max_calls_per_task=1)
        task_b = self.scope(task_id="parked-b", max_calls_per_task=1)
        self.assertEqual("acquired", queue.acquire(task_a))
        self.assertEqual("acquired", queue.acquire(task_b))
        self.assertEqual("task-exhausted", queue.acquire(task_a))
        persisted = json.loads((self.state / "fable-review-budget.json").read_text(encoding="utf-8"))
        self.assertEqual({"parked-b": 1, "parked-a": 1}, persisted["task_counts"])
        self.assertEqual(["parked-b", "parked-a"], persisted["task_order"])

    def test_per_task_budget_is_a_hard_unavailable_cap(self) -> None:
        selected = self.scope(max_calls_per_task=1)
        reviewer = self.reviewer(selected)
        self.assertEqual("approve", reviewer.review(self.arguments())["verdict"])
        self.assertEqual("review-unavailable", reviewer.review(self.arguments())["verdict"])

    def test_manager_slot_refuses_second_invocation_before_budget_charge(self) -> None:
        selected = self.scope(task_id="single-manager-slot")

        class SingleSlotProvider:
            def __init__(provider_self) -> None:
                provider_self.acquired = False
                provider_self.revalidations = 0

            def __call__(provider_self):
                if provider_self.acquired:
                    raise mcp.ScopeError("completion reviewer slot already acquired")
                provider_self.acquired = True
                return selected

            def revalidate(provider_self, expected):
                provider_self.revalidations += 1
                self.assertEqual(selected, expected)
                return selected

        provider = SingleSlotProvider()
        reviewer = mcp.FableReviewer(
            scope_provider=provider,
            claude_bin=str(self.fake),
            claude_home=str(self.home),
            doctrine_path=str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
            schema_path=str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
            now=self.clock.now,
            sleeper=self.clock.sleep,
        )
        self.assertEqual("approve", reviewer.review(self.arguments())["verdict"])
        budget_before = json.loads((self.state / "fable-review-budget.json").read_text(encoding="utf-8"))
        self.assertEqual(1, budget_before["task_counts"][selected.task_id])
        self.assertEqual("review-unavailable", reviewer.review(self.arguments())["verdict"])
        budget_after = json.loads((self.state / "fable-review-budget.json").read_text(encoding="utf-8"))
        self.assertEqual(budget_before, budget_after)
        self.assertGreaterEqual(provider.revalidations, 3)
        artifacts = list((self.state / "review-artifacts" / selected.task_id / "default").glob("*.json"))
        self.assertEqual(1, len(artifacts))

    def test_worker_cannot_supply_phase_or_grant_an_early_review(self) -> None:
        arguments = {**self.arguments(), "phase": "early"}
        server = mcp.McpServer(self.reviewer(self.scope(task_id="worker-phase")))
        response = server.handle({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "adversarial_review", "arguments": arguments},
        })
        self.assertTrue(response["result"]["isError"])
        self.assertFalse((self.state / "fable-review-budget.json").exists())
        self.assertFalse((self.home / "argv.json").exists())
        tool = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        properties = tool["result"]["tools"][0]["inputSchema"]["properties"]
        self.assertNotIn("phase", properties)
        self.assertNotIn("slot", properties)

    def test_profile_rotation_does_not_reset_the_per_task_budget(self) -> None:
        first_scope = self.scope(task_id="rotated-task", profile="default", max_calls_per_task=1)
        second_scope = self.scope(task_id="rotated-task", profile="reserve", max_calls_per_task=1)
        self.assertEqual("approve", self.reviewer(first_scope).review(self.arguments())["verdict"])
        self.assertEqual("review-unavailable", self.reviewer(second_scope).review(self.arguments())["verdict"])

        budget = json.loads((self.state / "fable-review-budget.json").read_text(encoding="utf-8"))
        self.assertEqual(1, budget["task_counts"]["rotated-task"])
        self.assertEqual(1, len(list(
            (self.state / "review-artifacts" / "rotated-task" / "default").glob("*.json")
        )))
        self.assertEqual(1, len(list(
            (self.state / "review-artifacts" / "rotated-task" / "reserve").glob("*.json")
        )))

    def test_exhausted_retries_upsert_one_artifact_and_preserve_prior_block(self) -> None:
        response = json.loads((self.home / "response.json").read_text(encoding="utf-8"))
        blocked = response["structured_output"]
        blocked.update({
            "verdict": "block",
            "summary": "A falsifiable invariant violation blocks ratification.",
            "checked": ["The supplied diff and standing invariants."],
            "not_checked": ["Live deployment behavior was not supplied."],
            "findings": [{
                "severity": "high",
                "locus": "src/check.ts:1",
                "claim": "The transition violates the readiness invariant.",
                "evidence": "The reviewed diff sets ready before its prerequisite.",
                "suggested_test": "Assert the prerequisite is established before ready changes.",
            }],
            "next_steps": ["Correct the transition order and rerun review."],
        })
        (self.home / "response.json").write_text(json.dumps(response), encoding="utf-8")

        reviewer = self.reviewer(self.scope(task_id="bounded-artifacts", max_calls_per_task=1))
        first = reviewer.review(self.arguments())
        self.assertEqual("block", first["verdict"])
        for _ in range(40):
            self.assertEqual("review-unavailable", reviewer.review(self.arguments())["verdict"])

        artifacts = list((self.state / "review-artifacts" / "bounded-artifacts" / "default").glob("*.json"))
        self.assertEqual(2, len(artifacts))
        self.assertLessEqual(len(artifacts), 2)
        self.assertEqual(1, sum(path.name == mcp.BUDGET_EXHAUSTED_ARTIFACT_NAME for path in artifacts))
        persisted = [json.loads(path.read_text(encoding="utf-8")) for path in artifacts]
        self.assertEqual(1, sum(item["result"]["verdict"] == "block" for item in persisted))
        self.assertEqual(first, next(item["result"] for item in persisted if item["result"]["verdict"] == "block"))

    def test_one_completion_candidate_plus_budget_sentinel_remain_intake_valid(self) -> None:
        selected = self.scope(task_id="maximum-budget", max_calls_per_window=12)
        reviewer = self.reviewer(selected)
        approved = json.loads((self.home / "response.json").read_text(encoding="utf-8"))["structured_output"]
        reviewer._invoke = lambda *_args: approved
        self.assertEqual("approve", reviewer.review(self.arguments())["verdict"])
        self.assertEqual("review-unavailable", reviewer.review(self.arguments())["verdict"])
        artifacts = self.bun_intake("maximum-budget")
        self.assertEqual(2, len(artifacts))
        self.assertEqual(1, sum(item["result"]["verdict"] == "approve" for item in artifacts))
        self.assertEqual(1, sum(item["result"]["verdict"] == "review-unavailable" for item in artifacts))

    def test_missing_claude_keeps_required_mcp_available_and_returns_pending_artifact(self) -> None:
        reviewer = mcp.FableReviewer(
            scope_provider=lambda: self.scope(task_id="missing-cli"),
            claude_bin=str(self.root / "absent-claude"),
            claude_home=str(self.home),
            doctrine_path=str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
            schema_path=str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
            now=self.clock.now,
            sleeper=self.clock.sleep,
        )
        server = mcp.McpServer(reviewer)
        initialized = server.handle({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18"},
        })
        self.assertEqual("qofi-fable-reviewer", initialized["result"]["serverInfo"]["name"])
        listed = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        self.assertEqual(["adversarial_review"], [tool["name"] for tool in listed["result"]["tools"]])
        called = server.handle({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "adversarial_review", "arguments": self.arguments()},
        })
        self.assertFalse(called["result"]["isError"])
        self.assertEqual("review-unavailable", called["result"]["structuredContent"]["verdict"])
        artifacts = list((self.state / "review-artifacts" / "missing-cli" / "default").glob("*.json"))
        self.assertEqual(1, len(artifacts))
        self.assertIn('"verdict":"review-unavailable"', artifacts[0].read_text(encoding="utf-8"))

    def test_budget_or_provenance_failure_can_never_surface_approval(self) -> None:
        class BrokenBudget:
            def acquire(self, _scope):
                raise OSError("forced lock failure")

        reviewer = self.reviewer()
        reviewer._budget = lambda _state_dir: BrokenBudget()
        for _ in range(40):
            result = reviewer.review(self.arguments())
            self.assertEqual("review-unavailable", result["verdict"])
        self.assertFalse((self.home / "argv.json").exists())
        artifacts = self.bun_intake("task-123")
        self.assertEqual(1, len(artifacts))
        self.assertEqual(mcp.BUDGET_EXHAUSTED_ARTIFACT_NAME, next(
            (self.state / "review-artifacts" / "task-123" / "default").iterdir()
        ).name)

        reviewer = self.reviewer(self.scope(task_id="artifact-failure"))
        reviewer._write_artifact = lambda *_args: (_ for _ in ()).throw(OSError("forced persistence failure"))
        result = reviewer.review(self.arguments())
        self.assertEqual("review-unavailable", result["verdict"])

    def test_scope_is_revalidated_after_each_wait_and_before_artifact(self) -> None:
        approved = json.loads((self.home / "response.json").read_text(encoding="utf-8"))["structured_output"]
        for boundary, expected_invocations in ((2, 0), (3, 0), (4, 1)):
            with self.subTest(revalidation_call=boundary):
                original = self.scope(task_id="stale-%d" % boundary)
                changed = self.scope(task_id="stale-%d" % boundary, profile="reserve")
                provider_calls = 0

                def scope_provider():
                    nonlocal provider_calls
                    provider_calls += 1
                    return changed if provider_calls >= boundary else original

                reviewer = mcp.FableReviewer(
                    scope_provider=scope_provider,
                    claude_bin=str(self.fake),
                    claude_home=str(self.home),
                    doctrine_path=str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
                    schema_path=str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
                    now=self.clock.now,
                    sleeper=self.clock.sleep,
                )
                invocations = 0

                def invoke(*_args):
                    nonlocal invocations
                    invocations += 1
                    return approved

                reviewer._invoke = invoke
                result = reviewer.review(self.arguments())
                self.assertEqual("review-unavailable", result["verdict"])
                self.assertIn("trusted swarm scope", result["summary"])
                self.assertEqual(expected_invocations, invocations)
                self.assertFalse((
                    self.state / "review-artifacts" / original.task_id
                ).exists())

    def test_api_key_exists_only_in_child_lane_environment(self) -> None:
        secret = "sk-ant-test-only-never-log"
        result = self.reviewer(self.scope(auth_lane="anthropic-api-key"), api_key_provider=lambda: secret).review(self.arguments())
        self.assertEqual("approve", result["verdict"])
        env = json.loads((self.home / "env.json").read_text(encoding="utf-8"))
        self.assertTrue(env["has_api_key"])
        self.assertFalse(env["has_oauth"])
        self.assertEqual("1", env["nonessential_traffic"])
        argv = json.loads((self.home / "argv.json").read_text(encoding="utf-8"))
        self.assertIn("--bare", argv)
        for artifact in (self.state / "review-artifacts").rglob("*.json"):
            self.assertNotIn(secret, artifact.read_text(encoding="utf-8"))

    def test_default_api_key_provider_binds_service_and_operator_account(self) -> None:
        completed = types.SimpleNamespace(returncode=0, stdout=b"test-key-material\n")
        with patch.object(mcp.subprocess, "run", return_value=completed) as run:
            self.assertEqual("test-key-material", mcp.KeychainApiKeyProvider("fixed-service")())
        argv = run.call_args.args[0]
        self.assertEqual("/usr/bin/security", argv[0])
        self.assertEqual("fixed-service", argv[argv.index("-s") + 1])
        self.assertEqual(mcp.pwd.getpwuid(os.geteuid()).pw_name, argv[argv.index("-a") + 1])
        self.assertNotIn("test-key-material", json.dumps(run.call_args.kwargs))

    def test_device_lane_does_not_forward_ambient_oauth_or_use_bare(self) -> None:
        with patch.dict(os.environ, {"CLAUDE_CODE_OAUTH_TOKEN": "must-not-cross"}):
            result = self.reviewer().review(self.arguments())
        self.assertEqual("approve", result["verdict"])
        env = json.loads((self.home / "env.json").read_text(encoding="utf-8"))
        argv = json.loads((self.home / "argv.json").read_text(encoding="utf-8"))
        self.assertFalse(env["has_oauth"])
        self.assertNotIn("--bare", argv)

    def test_normal_and_timeout_paths_kill_forked_descendants(self) -> None:
        for behavior, timeout in (("descendant", 2), ("timeout-descendant", 1)):
            with self.subTest(behavior=behavior):
                (self.home / "behavior").write_text(behavior + "\n", encoding="utf-8")
                pid_file = self.home / "descendant.pid"
                try:
                    pid_file.unlink()
                except FileNotFoundError:
                    pass
                result = self.reviewer(self.scope(task_id="task-" + behavior, timeout_seconds=timeout)).review(self.arguments())
                expected = "approve" if behavior == "descendant" else "review-unavailable"
                self.assertEqual(expected, result["verdict"])
                child_pid = int(pid_file.read_text(encoding="ascii"))
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.02)
                else:
                    self.fail("reviewer descendant survived process-group cleanup")

    def test_independent_reviewer_processes_use_one_operator_global_fifo(self) -> None:
        (self.home / "behavior").write_text("serialize\n", encoding="utf-8")
        state_one = self.root / "state-one"
        state_two = self.root / "state-two"
        state_one.mkdir(mode=0o700)
        state_two.mkdir(mode=0o700)
        child = r'''
import importlib.util, json, sys
source, state, home, fake, doctrine, schema, task = sys.argv[1:]
spec = importlib.util.spec_from_file_location("qofi_fable_child", source)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
scope = module.ReviewScope(
    swarm="press-backend", profile="default", task_id=task, state_dir=state,
    policy=module.ReviewPolicy(
        auth_lane="device", max_calls_per_task=1, max_calls_per_window=4,
        window_seconds=60, timeout_seconds=5, failure_policy="review-pending",
    ),
)
reviewer = module.FableReviewer(
    scope_provider=lambda: scope, claude_bin=fake, claude_home=home,
    doctrine_path=doctrine, schema_path=schema,
)
result = reviewer.review({
    "diff_or_files": "GLOBAL-FIFO-RAW-PAYLOAD", "context_refs": [], "mode": "code",
})
raise SystemExit(0 if result["verdict"] == "approve" else 3)
'''
        common = [
            str(SOURCE), None, str(self.home), str(self.fake),
            str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
            str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
        ]
        command_one = [sys.executable, "-I", "-B", "-c", child] + [common[0], str(state_one)] + common[2:] + ["fifo-one"]
        command_two = [sys.executable, "-I", "-B", "-c", child] + [common[0], str(state_two)] + common[2:] + ["fifo-two"]
        first = subprocess.Popen(command_one, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        global_state = self.home / ".codex" / "fable-reviewer-global" / "queue.json"
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                if json.loads(global_state.read_text(encoding="utf-8"))["next_ticket"] >= 1:
                    break
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.01)
        else:
            first.kill()
            self.fail("first reviewer never entered the global queue")
        second = subprocess.Popen(command_two, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        first_out, first_err = first.communicate(timeout=10)
        second_out, second_err = second.communicate(timeout=10)
        self.assertEqual(0, first.returncode, (first_out, first_err))
        self.assertEqual(0, second.returncode, (second_out, second_err))
        events = (self.home / "concurrency.log").read_text(encoding="ascii").splitlines()
        self.assertEqual(["start", "end", "start", "end"], [line.split()[0] for line in events])
        final_state = json.loads(global_state.read_text(encoding="utf-8"))
        self.assertEqual([], final_state["queue"])
        self.assertEqual(2, final_state["serving_ticket"])
        for path in global_state.parent.iterdir():
            if path.is_file():
                self.assertNotIn("GLOBAL-FIFO-RAW-PAYLOAD", path.read_text(encoding="utf-8", errors="ignore"))

    def test_actual_shim_termination_and_sigkill_reap_group_before_next_invocation(self) -> None:
        class ScopeHandler(socketserver.StreamRequestHandler):
            def handle(handler_self) -> None:
                raw = bytearray()
                while b"\r\n\r\n" not in raw and len(raw) <= 16384:
                    chunk = handler_self.request.recv(4096)
                    if not chunk:
                        return
                    raw.extend(chunk)
                response = json.dumps(handler_self.server.scope, separators=(",", ":")).encode("utf-8")
                handler_self.request.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                    + str(len(response)).encode("ascii")
                    + b"\r\nConnection: close\r\n\r\n"
                    + response
                )

        class ScopeServer(socketserver.UnixStreamServer):
            allow_reuse_address = False

        request = json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "adversarial_review", "arguments": self.arguments()},
        }, separators=(",", ":")).encode("utf-8") + b"\n"

        def wait_for_pid(path: Path) -> int:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    return int(path.read_text(encoding="ascii"))
                except (FileNotFoundError, ValueError):
                    time.sleep(0.02)
            self.fail("fake Claude process tree did not start")

        def wait_gone(pid: int) -> None:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return
                time.sleep(0.02)
            self.fail("supervised Claude process survived shim cancellation: %d" % pid)

        for method in ("terminate", "kill"):
            with self.subTest(method=method):
                home = self.root / ("home-" + method)
                state = self.root / ("state-" + method)
                home.mkdir(mode=0o700)
                state.mkdir(mode=0o700)
                shutil.copyfile(FIXTURES / "claude-success.json", home / "response.json")
                (home / "behavior").write_text("supervision\n", encoding="utf-8")
                manager_path = self.root / ("m-" + method[0] + ".sock")
                server = ScopeServer(str(manager_path), ScopeHandler)
                server.scope = {
                    "schema": "qofi-fable-reviewer-scope/v1",
                    "slot": "completion-candidate",
                    "slot_token": "a" * 64,
                    "early_review": "disabled-no-trusted-boundary",
                    "swarm": "press-backend",
                    "profile": "default",
                    "task_id": "cancel-" + method,
                    "state_dir": str(state),
                    "policy": {
                        "auth_lane": "device",
                        "max_calls_per_task": 1,
                        "max_calls_per_window": 10,
                        "window_seconds": 60,
                        "timeout_seconds": 10,
                        "failure_policy": "review-pending",
                    },
                }
                os.chmod(manager_path, 0o600)
                server_thread = threading.Thread(target=server.serve_forever, daemon=True)
                server_thread.start()
                command = [
                    sys.executable, "-I", "-B", str(SOURCE),
                    "--manager-socket", str(manager_path),
                    "--claude-bin", str(self.fake),
                    "--claude-home", str(home),
                    "--doctrine", str(ROOT / "templates" / "_base" / "codex" / "fable-reviewer-doctrine.md"),
                    "--schema", str(ROOT / "templates" / "_base" / "codex" / "adversarial-review-output.schema.json"),
                ]
                first = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    assert first.stdin is not None
                    first.stdin.write(request)
                    first.stdin.flush()
                    active_pid = wait_for_pid(home / "active.pid")
                    descendant_pid = wait_for_pid(home / "descendant.pid")
                    getattr(first, method)()
                    first.wait(timeout=8)

                    # Enter the next invocation immediately. Its queue ticket can
                    # recover the dead shim, but the inherited flock must keep
                    # it behind the still-cleaning supervisor.
                    (home / "behavior").write_text("serialize\n", encoding="utf-8")
                    server.scope["task_id"] = "cancel-%s-retry" % method
                    second = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    second_out, second_err = second.communicate(request, timeout=12)
                    for stream in (second.stdin, second.stdout, second.stderr):
                        if stream is not None:
                            stream.close()
                    self.assertEqual(0, second.returncode, (second_out, second_err))
                    response = json.loads(second_out.decode("utf-8"))
                    self.assertEqual("approve", response["result"]["structuredContent"]["verdict"])
                    self.assertEqual(
                        ["start", "end", "start", "end"],
                        [line.split()[0] for line in (home / "concurrency.log").read_text(encoding="ascii").splitlines()],
                    )
                    wait_gone(active_pid)
                    wait_gone(descendant_pid)
                    queue = json.loads((home / ".codex" / "fable-reviewer-global" / "queue.json").read_text(encoding="utf-8"))
                    self.assertEqual([], queue["queue"])
                    self.assertEqual(2, queue["serving_ticket"])
                finally:
                    if first.poll() is None:
                        first.kill()
                        first.wait(timeout=5)
                    for stream in (first.stdin, first.stdout, first.stderr):
                        if stream is not None:
                            stream.close()
                    server.shutdown()
                    server.server_close()
                    server_thread.join(timeout=5)

    def test_initialize_and_tool_text_are_self_contained(self) -> None:
        server = mcp.McpServer(self.reviewer())
        initialized = server.handle({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18"},
        })
        instructions = initialized["result"]["instructions"]
        self.assertLessEqual(len(instructions), 512)
        self.assertIn("review-unavailable", instructions)
        listed = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        self.assertEqual(["adversarial_review"], [tool["name"] for tool in listed["result"]["tools"]])

    def test_rpc_header_count_and_aggregate_bytes_are_bounded(self) -> None:
        body = b"{}"
        too_many = (
            b"Content-Length: 2\r\n"
            + b"".join(("X-%02d: x\r\n" % index).encode("ascii") for index in range(mcp.MAX_RPC_HEADER_COUNT))
            + b"\r\n" + body
        )
        with self.assertRaisesRegex(mcp.ReviewerError, "aggregate bound"):
            mcp.read_rpc(io.BytesIO(too_many))

        wide_value = b"x" * (mcp.MAX_RPC_HEADER_LINE_BYTES - 16)
        too_wide_in_aggregate = (
            b"Content-Length: 2\r\n"
            + b"".join(b"X-Test: " + wide_value + b"\r\n" for _ in range(9))
            + b"\r\n" + body
        )
        with self.assertRaisesRegex(mcp.ReviewerError, "aggregate bound"):
            mcp.read_rpc(io.BytesIO(too_wide_in_aggregate))

    def test_installed_defaults_point_only_at_root_controlled_artifacts(self) -> None:
        args = mcp.parse_args([])
        self.assertEqual("/usr/local/libexec/qofi-fable-reviewer-doctrine.md", args.doctrine)
        self.assertEqual("/usr/local/libexec/qofi-adversarial-review-output.schema.json", args.schema)


if __name__ == "__main__":
    unittest.main()
