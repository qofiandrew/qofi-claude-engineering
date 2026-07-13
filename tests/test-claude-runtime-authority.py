#!/usr/bin/python3 -I -B
"""Structural authority regressions for the deliberately restricted Claude lane."""

from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ClaudeRuntimeAuthorityTests(unittest.TestCase):
    def test_raw_claude_completion_is_restricted_without_synthetic_review(self) -> None:
        source = (ROOT / "bin/swarm-harness-authority-boundary.ts").read_text(encoding="utf-8")
        self.assertIn("restricted-no-attested-exact-final-reviewer", source)
        self.assertIn("Raw Claude hook JSON and its paths are worker-controlled", source)
        self.assertNotIn("function unavailableResult", source)
        self.assertNotIn("const result = unavailableResult()", source)

    def test_completion_projection_preserves_runtime_and_canonical_receipt_identity(self) -> None:
        source = (ROOT / "bin/swarm-harness-authority-boundary.ts").read_text(encoding="utf-8")
        self.assertIn("runtime: event.runtime", source)
        self.assertIn("canonicalAuthorityJson(receipt)", source)
        self.assertNotIn("runtime: 'claude' as const", source)

    def test_mutable_cli_cannot_certify_or_execute_tests_as_root(self) -> None:
        source = (ROOT / "bin/swarm-runtime-conformance.ts").read_text(encoding="utf-8")
        self.assertIn("command: 'check' | 'diagnose'", source)
        self.assertIn("diagnose refuses root execution of mutable repository tests", source)
        self.assertNotIn("command: 'check' | 'certify'", source)

    def test_native_tui_is_unchanged_but_ineligible_for_adoption(self) -> None:
        source = (ROOT / "bin/swarm-up.sh").read_text(encoding="utf-8")
        self.assertIn("0|'') return 0", source)
        self.assertIn("native interactive Claude is not a supervised lifecycle boundary", source)
        self.assertIn('tmux send-keys -t "$sess" "claude --dangerously-load-development-channels', source)


if __name__ == "__main__":
    unittest.main()
