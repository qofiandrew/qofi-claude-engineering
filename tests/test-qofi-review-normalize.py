#!/usr/bin/python3 -I
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "bin" / "qofi-review-normalize.py"
FIXTURES = ROOT / "tests" / "fixtures" / "fable-reviewer"
spec = importlib.util.spec_from_file_location("qofi_review_normalize", SOURCE)
assert spec and spec.loader
normalizer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = normalizer
spec.loader.exec_module(normalizer)

FABLE_SOURCE = ROOT / "bin" / "qofi-fable-reviewer-mcp.py"
fable_spec = importlib.util.spec_from_file_location("qofi_fable_contract_symmetry", FABLE_SOURCE)
assert fable_spec and fable_spec.loader
fable = importlib.util.module_from_spec(fable_spec)
sys.modules[fable_spec.name] = fable
fable_spec.loader.exec_module(fable)


class ReviewNormalizerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="qofi-review-normalize-")
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.repo = self.root / "repo"
        self.repo.mkdir(mode=0o700)
        self.results = self.root / "results"
        self.results.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def legacy_bytes(self) -> bytes:
        return (FIXTURES / "legacy-v1.json").read_bytes()

    def test_raw_v1_maps_through_the_canonical_v2_normalizer(self) -> None:
        result, job_id, source_hash = normalizer.normalize_source(self.legacy_bytes())
        self.assertIsNone(job_id)
        self.assertEqual(hashlib.sha256(self.legacy_bytes()).hexdigest(), source_hash)
        self.assertEqual("qofi-adversarial-review-output/v2", result["schema"])
        self.assertEqual("needs-changes", result["verdict"])
        self.assertEqual("src/write.ts:41-44", result["findings"][0]["locus"])
        self.assertEqual("Add a failure-injection replay test.", result["findings"][0]["suggested_test"])

    def test_normalizer_and_fable_contract_emit_byte_identical_v2(self) -> None:
        legacy = json.loads(self.legacy_bytes())
        via_wrapper = normalizer.legacy_v1_to_v2(legacy)
        via_fable_contract = fable.legacy_v1_to_v2(legacy)
        self.assertEqual(via_fable_contract, via_wrapper)
        self.assertEqual(normalizer.compact_json(via_wrapper), fable.compact_json(via_fable_contract).encode("utf-8") + b"\n")

    def test_upstream_valid_reversed_line_range_is_preserved(self) -> None:
        legacy = json.loads(self.legacy_bytes())
        legacy["findings"][0]["line_start"] = 44
        legacy["findings"][0]["line_end"] = 41
        via_wrapper = normalizer.legacy_v1_to_v2(legacy)
        via_fable_contract = fable.legacy_v1_to_v2(legacy)
        self.assertEqual(via_fable_contract, via_wrapper)
        self.assertEqual("src/write.ts:44-41", via_wrapper["findings"][0]["locus"])

    def test_actual_plugin_job_artifact_becomes_a_private_v2_result_set_sidecar(self) -> None:
        source = (FIXTURES / "codex-companion-v1-job.json").read_bytes()
        artifact, path = normalizer.ingest_source(source, self.repo, result_root=self.results)
        self.assertEqual("qofi-legacy-codex-review-artifact/v1", artifact["schema"])
        self.assertEqual("review-m5example-a1b2c3", artifact["source_job_id"])
        self.assertEqual("qofi-adversarial-review-output/v2", artifact["result"]["schema"])
        self.assertEqual("needs-changes", artifact["result"]["verdict"])
        self.assertIsNone(artifact["reviewed_diff_sha256"])
        self.assertEqual("unavailable-legacy-plugin", artifact["provenance_status"])
        self.assertEqual(hashlib.sha256(source).hexdigest(), artifact["source_payload_sha256"])
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        self.assertEqual(artifact, json.loads(path.read_text(encoding="utf-8")))

    def test_actual_foreground_json_shape_is_normalized(self) -> None:
        stored = json.loads((FIXTURES / "codex-companion-v1-job.json").read_text(encoding="utf-8"))
        foreground = json.dumps(stored["result"], separators=(",", ":")).encode("utf-8")
        result, job_id, source_hash = normalizer.normalize_source(foreground)
        self.assertIsNone(job_id)
        self.assertEqual(hashlib.sha256(foreground).hexdigest(), source_hash)
        self.assertEqual("needs-changes", result["verdict"])

    def test_exported_result_shape_is_consumed_without_mutating_raw_v1(self) -> None:
        stored = json.loads((FIXTURES / "codex-companion-v1-job.json").read_text(encoding="utf-8"))
        exported = {"job": {"id": stored["id"], "kind": stored["kind"]}, "storedJob": stored}
        raw_before = json.dumps(exported, sort_keys=True)
        result, job_id, _ = normalizer.normalize_source(json.dumps(exported).encode("utf-8"))
        self.assertEqual(stored["id"], job_id)
        self.assertEqual("needs-changes", result["verdict"])
        self.assertEqual(raw_before, json.dumps(exported, sort_keys=True))

    def test_approval_records_explicit_legacy_scope_limits(self) -> None:
        legacy = {
            "verdict": "approve", "summary": "No material finding in the selected target.",
            "findings": [], "next_steps": [],
        }
        result = normalizer.legacy_v1_to_v2(legacy)
        self.assertEqual("approve", result["verdict"])
        self.assertTrue(result["checked"])
        self.assertIn("did not identify unchecked scope", result["not_checked"][0])

    def test_invalid_and_secret_bearing_v1_fail_closed(self) -> None:
        legacy = json.loads(self.legacy_bytes())
        legacy["extra"] = "schema drift"
        with self.assertRaises(normalizer.NormalizeError):
            normalizer.legacy_v1_to_v2(legacy)
        secret = json.loads(self.legacy_bytes())
        secret["summary"] = "api_key=sk-secretmaterial"
        with self.assertRaises(normalizer.NormalizeError):
            normalizer.legacy_v1_to_v2(secret)

        sensitive = json.loads(
            (FIXTURES / "synthetic-sensitive-output-tokens.json").read_text(encoding="utf-8")
        )
        for fixture in sensitive:
            with self.subTest(token_kind=fixture["label"]):
                token = "".join(fixture["parts"])
                secret = json.loads(self.legacy_bytes())
                secret["findings"][0]["body"] = token
                source = json.dumps(secret, separators=(",", ":")).encode("utf-8")
                with self.assertRaises(normalizer.NormalizeError) as raised:
                    normalizer.ingest_source(source, self.repo, result_root=self.results)
                self.assertNotIn(token, str(raised.exception))
                self.assertEqual([], list(self.results.rglob("*.json")))

        sha1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        sha256 = "8f14e45fceea167a5a36dedd4bea2543d82e3f5ab9ab4fe7b81d7b623a8d6f41"
        ordinary_ids = ("user_profile", "account_state", "org_slug")
        ordinary = json.loads(self.legacy_bytes())
        ordinary["findings"][0]["body"] = "sha1: %s; sha256: %s; identifiers: %s" % (
            sha1, sha256, ", ".join(ordinary_ids),
        )
        artifact, path = normalizer.ingest_source(
            json.dumps(ordinary, separators=(",", ":")).encode("utf-8"),
            self.repo,
            result_root=self.results,
        )
        self.assertEqual("needs-changes", artifact["result"]["verdict"])
        self.assertIn(sha1.encode("ascii"), path.read_bytes())
        self.assertIn(sha256.encode("ascii"), path.read_bytes())
        for ordinary_id in ordinary_ids:
            self.assertIn(ordinary_id.encode("ascii"), path.read_bytes())

    def test_result_set_refuses_symlink_and_non_private_root(self) -> None:
        self.results.chmod(0o755)
        with self.assertRaises(normalizer.NormalizeError):
            normalizer.ingest_source(self.legacy_bytes(), self.repo, result_root=self.results)
        self.results.chmod(0o700)
        target = self.root / "target"
        target.mkdir(mode=0o700)
        self.results.rmdir()
        self.results.symlink_to(target, target_is_directory=True)
        with self.assertRaises(normalizer.NormalizeError):
            normalizer.ingest_source(self.legacy_bytes(), self.repo, result_root=self.results)

    def test_plugin_wrapper_forces_foreground_json_and_never_recaptures_git(self) -> None:
        fake_node = self.root / "node"
        fake_node.write_text("node", encoding="utf-8")
        fake_node.chmod(0o700)
        fake_companion = self.root / "codex-companion.mjs"
        fake_companion.write_text("companion", encoding="utf-8")
        fake_companion.chmod(0o600)
        fake_data = self.root / "plugin-data"
        fake_data.mkdir(mode=0o700)
        trusted = types.SimpleNamespace(resolve_cli=lambda *args, **kwargs: fake_node)
        stored = json.loads((FIXTURES / "codex-companion-v1-job.json").read_text(encoding="utf-8"))
        foreground = json.dumps(stored["result"]).encode("utf-8")
        completed = subprocess.CompletedProcess([], 0, stdout=foreground, stderr=b"")
        with patch.object(normalizer, "discover_companion", return_value=fake_companion), \
             patch.object(normalizer, "_load_trusted_cli", return_value=trusted), \
             patch.object(normalizer, "_ensure_private_child", return_value=fake_data), \
             patch.object(normalizer.subprocess, "run", return_value=completed) as invoked:
            source = normalizer.run_companion(self.repo, base="main", scope="branch", focus=("auth boundaries",))
        self.assertEqual(foreground, source)
        command = invoked.call_args.args[0]
        joined = "\0".join(command)
        for required in ("adversarial-review", "--wait", "--json", "--model", "gpt-5.6-sol", "--base", "main", "--scope", "branch"):
            self.assertIn(required, command)
        self.assertNotIn("git", joined)
        self.assertNotIn("--background", command)

    def test_sidecar_never_manufactures_a_reviewed_diff_hash(self) -> None:
        result = normalizer.legacy_v1_to_v2(json.loads(self.legacy_bytes()))
        artifact = normalizer.build_artifact(
            result,
            repository_key="a" * 64,
            source_hash="b" * 64,
            source_job_id=None,
            now=dt.datetime(2026, 7, 13, 10, 11, 12, tzinfo=dt.timezone.utc),
        )
        self.assertIsNone(artifact["reviewed_diff_sha256"])
        self.assertEqual("unavailable-legacy-plugin", artifact["provenance_status"])


if __name__ == "__main__":
    unittest.main()
