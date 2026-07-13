#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from importlib.machinery import SourceFileLoader


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "bin" / "qofi-harness-lifecycle-broker"
SPEC = importlib.util.spec_from_loader(
    "qofi_harness_lifecycle_broker", SourceFileLoader("qofi_harness_lifecycle_broker", str(SOURCE)),
)
assert SPEC and SPEC.loader
broker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = broker
SPEC.loader.exec_module(broker)


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def identity(path: Path) -> dict[str, object]:
    info = path.lstat()
    return {
        "path": str(path),
        "size": info.st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "mode": stat.S_IMODE(info.st_mode),
    }


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.uid = os.getuid()
        self.user = pwd.getpwuid(self.uid)
        self.authority = root / "etc"
        self.registrations = self.authority / "registrations"
        self.bundle = root / "bundle"
        self.repo = root / "repo"
        self.state = root / "state"
        self.receipts = self.authority / "receipts"
        self.tokens = self.authority / "tokens"
        for path in (
            self.authority, self.registrations, self.bundle, self.repo, self.state,
            self.receipts, self.tokens,
        ):
            path.mkdir(mode=0o700)
            path.chmod(0o700)
        self.installed_broker = root / "qofi-harness-lifecycle-broker"
        shutil.copyfile(SOURCE, self.installed_broker)
        self.installed_broker.chmod(0o755)
        self.bun = root / "bun"
        self.bun.write_bytes(b"#!/bin/sh\nexit 0\n")
        self.bun.chmod(0o755)
        self.entry = self.bundle / "bin" / "swarm-harness-authority-boundary.ts"
        self.entry.parent.mkdir(mode=0o700)
        self.entry.write_text("// installed root lifecycle entry\n", encoding="utf-8")
        self.entry.chmod(0o600)
        self.receipt = self.receipts / "press-backend.json"
        self.receipt.write_bytes(canonical({"contract": "claude-codex-v1"}))
        self.receipt.chmod(0o600)
        self.token = self.tokens / "press-backend"
        self.token.write_text("test-discord-token", encoding="utf-8")
        self.token.chmod(0o600)
        self.transcript = root / "transcript.jsonl"
        self.transcript.write_text('{"type":"assistant"}\n', encoding="utf-8")
        self.transcript.chmod(0o600)
        self.claude = root / "claude"
        self.codex = root / "codex"
        for path, version in ((self.claude, "Claude 2.1.207"), (self.codex, "codex 0.144.1")):
            path.write_text(f"#!/bin/sh\necho '{version}'\n", encoding="utf-8")
            path.chmod(0o755)
        self.paths = broker.BrokerPaths(
            authority_root=self.authority,
            attestation=self.authority / "attestation.json",
            registrations=self.registrations,
            conformance=self.authority / "conformance.json",
            installed_broker=self.installed_broker,
        )
        self.bundle_sha = self.write_attestation()
        self.write_registration()
        self.write_conformance()

    def write_attestation(self) -> str:
        files = []
        digest = hashlib.sha256()
        for path in sorted(self.bundle.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(self.bundle).as_posix()
            data = path.read_bytes()
            files.append({
                "path": rel, "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "mode": stat.S_IMODE(path.stat().st_mode),
            })
            digest.update(rel.encode())
            digest.update(b"\0")
            digest.update(str(len(data)).encode())
            digest.update(b"\0")
            digest.update(data)
        value = {
            "schema": broker.ATTESTATION_SCHEMA,
            "broker": identity(self.installed_broker),
            "bun": identity(self.bun),
            "bundle_root": str(self.bundle),
            "bundle_sha256": digest.hexdigest(),
            "runtime_entry": "bin/swarm-harness-authority-boundary.ts",
            "runtime_files": files,
        }
        self.paths.attestation.write_bytes(canonical(value))
        self.paths.attestation.chmod(0o600)
        return digest.hexdigest()

    def write_registration(self) -> None:
        policy = "b" * 64
        value = {
            "schema": broker.REGISTRATION_SCHEMA,
            "enabled": True,
            "operator_uid": self.uid,
            "operator_user": self.user.pw_name,
            "operator_home": self.user.pw_dir,
            "repo_root": str(self.repo),
            "repo_root_sha256": broker.repo_digest(self.repo),
            "roadmap_repo_root": str(self.repo),
            "swarm": "press-backend",
            "dr_refs": ["ADR-0023"],
            "receipt_path": str(self.receipt),
            "receipt_sha256": hashlib.sha256(self.receipt.read_bytes()).hexdigest(),
            "completion_policy_sha256": policy,
            "state_root": str(self.state),
            "channel_id": "1508921858165047390",
            "fallback_channel_id": "1510301812434141194",
            "token_path": str(self.token),
            "token_sha256": hashlib.sha256(self.token.read_bytes()).hexdigest(),
            "manager_socket": None,
        }
        self.registration_path = self.registrations / f"{broker.repo_digest(self.repo)}.json"
        self.registration_path.write_bytes(canonical(value))
        self.registration_path.chmod(0o600)

    def rewrite_registration(self, **changes: object) -> dict[str, object]:
        value = json.loads(self.registration_path.read_bytes())
        value.update(changes)
        self.registration_path.write_bytes(canonical(value))
        self.registration_path.chmod(0o600)
        return value

    def write_conformance(self, *, suite: str | None = None) -> None:
        value = {
            "schema": broker.CONFORMANCE_SCHEMA,
            "contract": "claude-codex-v1",
            "suite_bundle_sha256": suite or self.bundle_sha,
            "completion_policy_sha256": "b" * 64,
            "receipt_contract": "claude-codex-v1",
            "tested_at": "2026-07-13T12:00:00.000Z",
            "passed_runtimes": ["claude", "codex"],
            "claude": {**identity(self.claude), "version": "Claude 2.1.207", "argv_prefix": []},
            "codex": {**identity(self.codex), "version": "codex 0.144.1", "argv_prefix": ["/root-prefix"]},
        }
        self.paths.conformance.write_bytes(canonical(value))
        self.paths.conformance.chmod(0o600)

    def hook(self, event: str = "Stop") -> bytes:
        return canonical({
            "hook_event_name": event,
            "session_id": "session-1",
            "task_id": "task-1",
            "cwd": str(self.repo),
            "transcript_path": str(self.transcript),
        })

    def request(
        self, operation: str = "conformance-check", payload: dict | None = None,
        runtime: str = "claude",
    ) -> bytes:
        return canonical({
            "schema": broker.BROKER_REQUEST_SCHEMA,
            "operation": operation,
            "runtime": runtime,
            "swarm": "press-backend",
            "payload": payload or {},
        })


class BrokerAuthorityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="qofi-harness-broker.")
        root = Path(os.path.realpath(self.temp.name))
        root.chmod(0o700)
        self.fixture = Fixture(root)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_unregistered_repo_is_safe_noop(self) -> None:
        other = self.fixture.root / "other"
        other.mkdir(mode=0o700)
        payload = json.loads(self.fixture.hook())
        payload["cwd"] = str(other)
        result = broker.dispatch_hook(self.fixture.paths, canonical(payload), owner_uid=self.fixture.uid)
        self.assertFalse(result.adopted)
        self.assertEqual(0, result.returncode)

    def test_registered_native_hook_is_untrusted_and_cannot_run_bundle(self) -> None:
        calls = []
        result = broker.dispatch_hook(
            self.fixture.paths, self.fixture.hook(), owner_uid=self.fixture.uid,
            runtime_invoker=lambda *args: calls.append(args),
        )
        self.assertTrue(result.adopted)
        self.assertEqual(2, result.returncode)
        self.assertEqual([], calls)
        self.assertIn(b"refused", result.stdout)

    def test_test_seam_proves_only_attested_bundle_runs_and_registry_dr_wins(self) -> None:
        captured = {}

        def invoke(bun, entry, raw, env, cwd):
            captured.update({"bun": bun, "entry": entry, "env": env, "cwd": cwd})
            return broker.RuntimeResult(0, b"ok\n", b"")

        # A worker-editable lookalike has no influence on installed identity.
        (self.fixture.repo / "swarm-stop-hook.ts").write_text("attacker bytes", encoding="utf-8")
        hook = json.loads(self.fixture.hook())
        hook["dr_refs"] = ["ADR-9999"]
        result = broker.dispatch_hook(
            self.fixture.paths, canonical(hook), owner_uid=self.fixture.uid,
            runtime_invoker=invoke, claude_hook_authorizer=lambda *_: True,
            lifecycle_authorizer=lambda *_: True,
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual(self.fixture.entry, captured["entry"])
        self.assertEqual("ADR-0023", captured["env"]["SWARM_HARNESS_DR_REFS"])

    def test_conformance_remains_hardblocked_without_fixed_root_exec_wrapper(self) -> None:
        denied = broker.dispatch_hook(
            self.fixture.paths, self.fixture.request(), owner_uid=self.fixture.uid,
        )
        value = json.loads(denied.stdout)
        self.assertFalse(value["allowed"])
        self.assertEqual("root-exec-wrapper-unavailable", value["reason_code"])
        self.assertIsNone(value["execution"])

        self.fixture.write_conformance(suite="f" * 64)
        stale = broker.dispatch_hook(
            self.fixture.paths, self.fixture.request(), owner_uid=self.fixture.uid,
        )
        self.assertFalse(json.loads(stale.stdout)["allowed"])

    def test_lifecycle_hardblock_precedes_codex_manager_receipt_consumption(self) -> None:
        calls: list[object] = []
        result = broker.dispatch_hook(
            self.fixture.paths,
            self.fixture.request(
                "task-complete",
                {
                    "completion_token": "a" * 64,
                    "task_id": "task-1",
                    "turn_id": "turn-1",
                    "summary": "bounded",
                },
                runtime="codex",
            ),
            owner_uid=self.fixture.uid,
            codex_authorizer=lambda *args: calls.append(args) or None,
        )
        self.assertTrue(result.adopted)
        self.assertEqual(2, result.returncode)
        self.assertEqual([], calls)

    def test_malformed_adopted_operation_fails_closed(self) -> None:
        value = json.loads(self.fixture.request())
        value["operation"] = "worker-invented-operation"
        result = broker.dispatch_hook(self.fixture.paths, canonical(value), owner_uid=self.fixture.uid)
        self.assertTrue(result.adopted)
        self.assertEqual(2, result.returncode)

    def test_hard_linked_attested_bundle_file_is_refused(self) -> None:
        os.link(self.fixture.entry, self.fixture.bundle / "attacker-link")
        result = broker.dispatch_hook(
            self.fixture.paths, self.fixture.hook(), owner_uid=self.fixture.uid,
            claude_hook_authorizer=lambda *_: True,
            lifecycle_authorizer=lambda *_: True,
        )
        self.assertEqual(2, result.returncode)
        self.assertIn(b"authority refusal", result.stderr)

    def test_attestation_file_inventory_is_bounded_at_256(self) -> None:
        value = json.loads(self.fixture.paths.attestation.read_bytes())
        value["runtime_files"] = [value["runtime_files"][0]] * 257
        self.fixture.paths.attestation.write_bytes(canonical(value))
        with self.assertRaisesRegex(broker.BrokerError, "attestation is malformed"):
            broker.load_attested_runtime(self.fixture.paths, self.fixture.uid)

    def test_state_root_rejects_link_and_mutable_parent_substitution(self) -> None:
        original = json.loads(self.fixture.registration_path.read_bytes())
        linked = self.fixture.root / "linked-state"
        linked.symlink_to(self.fixture.state, target_is_directory=True)
        linked_registration = self.fixture.rewrite_registration(state_root=str(linked))
        with self.assertRaisesRegex(broker.BrokerError, "linked component"):
            broker._parse_registration(
                linked_registration, self.fixture.repo, self.fixture.uid,
            )

        mutable = self.fixture.root / "mutable-state-parent"
        mutable.mkdir(mode=0o700)
        nested = mutable / "state"
        nested.mkdir(mode=0o700)
        mutable.chmod(0o777)
        mutable_registration = self.fixture.rewrite_registration(state_root=str(nested))
        with self.assertRaisesRegex(broker.BrokerError, "not root controlled"):
            broker._parse_registration(
                mutable_registration, self.fixture.repo, self.fixture.uid,
            )
        self.fixture.registration_path.write_bytes(canonical(original))

    def test_runtime_timeout_kills_and_reaps_its_process_group(self) -> None:
        child_pid = self.fixture.root / "descendant.pid"
        fake_bun = self.fixture.root / "blocking-bun"
        fake_bun.write_text(
            "#!/usr/bin/python3\n"
            "import os, signal, time\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "    with open(os.environ['PIDFILE'], 'w') as handle:\n"
            "        handle.write(str(os.getpid()))\n"
            "        handle.flush(); os.fsync(handle.fileno())\n"
            "    while True: time.sleep(10)\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "while True: time.sleep(10)\n",
            encoding="utf-8",
        )
        fake_bun.chmod(0o755)
        result = broker.run_runtime_process(
            fake_bun,
            self.fixture.entry,
            b"{}\n",
            {"PIDFILE": str(child_pid)},
            self.fixture.repo,
            timeout_seconds=0.8,
            terminate_grace_seconds=0.1,
        )
        self.assertEqual(2, result.returncode)
        self.assertIn(b"timed out", result.stdout)
        self.assertTrue(child_pid.exists())
        pid = int(child_pid.read_text(encoding="utf-8"))

        def descendant_is_live() -> bool:
            status = subprocess.run(
                ["/bin/ps", "-p", str(pid), "-o", "stat="],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
            return bool(status) and not status.startswith("Z")

        for _ in range(40):
            if not descendant_is_live():
                break
            time.sleep(0.025)
        self.assertFalse(descendant_is_live())

    def test_codex_boundary_preflights_restricted_publisher_before_side_effects(self) -> None:
        source = (ROOT / "bin" / "swarm-harness-authority-boundary.ts").read_text(
            encoding="utf-8",
        )
        branch = source.index(
            "if (process.env.SWARM_HARNESS_BROKER_OPERATION === 'task-complete'",
        )
        preflight = source.index("const stores = lifecycleStores(adoption, operatorUid)", branch)
        manager = source.index("const manager = input.manager_receipt", branch)
        sender = source.index("new DiscordRestSender", branch)
        result_write = source.index("atomicCanonicalAuthorityRecord", sender)
        self.assertLess(preflight, manager)
        self.assertLess(preflight, sender)
        self.assertLess(preflight, result_write)


if __name__ == "__main__":
    unittest.main()
