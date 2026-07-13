#!/usr/bin/python3
from __future__ import annotations

import importlib.util
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "bin/trusted-cli.py"
spec = importlib.util.spec_from_file_location("trusted_cli", MODULE_PATH)
assert spec and spec.loader
trusted_cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trusted_cli)


class TrustedCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix=".qofi-trusted-cli-", dir=Path.home())
        self.base = Path(self.temp.name)
        self.install = self.base / "install"
        self.install.mkdir(mode=0o700)
        self.workspace = self.base / "workspace"
        self.workspace.mkdir(mode=0o700)
        self.swarm = self.base / "swarm"
        self.swarm.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def executable(self, path: Path, first: bytes = b"#!/bin/sh\n") -> Path:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(first + b"exit 0\n")
        path.chmod(0o700)
        return path

    def resolve(self, candidate: Path) -> Path:
        return trusted_cli.resolve_cli(
            "codex",
            candidates=[candidate],
            home=self.base,
            workspace=self.workspace,
            swarm_home=self.swarm,
            allowed_roots=[self.install],
            forbidden_roots=[self.workspace, self.swarm],
        )

    def test_regular_executable_under_private_root(self) -> None:
        binary = self.executable(self.install / "bin/codex")
        self.assertEqual(self.resolve(binary), binary)

    def test_node_uses_only_known_private_install_roots(self) -> None:
        node = self.executable(self.install / "versions/node/v22/bin/node")
        resolved = trusted_cli.resolve_cli(
            "node",
            candidates=[node],
            home=self.base,
            workspace=self.workspace,
            swarm_home=self.swarm,
            allowed_roots=[self.install],
            forbidden_roots=[self.workspace, self.swarm],
        )
        self.assertEqual(node, resolved)

    def test_workspace_and_unsafe_parent_are_rejected(self) -> None:
        workspace_binary = self.executable(self.workspace / "codex")
        with self.assertRaises(trusted_cli.TrustError):
            trusted_cli.resolve_cli(
                "codex",
                candidates=[workspace_binary],
                home=self.base,
                workspace=self.workspace,
                swarm_home=self.swarm,
                allowed_roots=[self.workspace],
                forbidden_roots=[self.workspace, self.swarm],
            )
        binary = self.executable(self.install / "unsafe/codex")
        binary.parent.chmod(0o777)
        with self.assertRaises(trusted_cli.TrustError):
            self.resolve(binary)
        binary.parent.chmod(0o700)
        self.install.chmod(0o777)
        with self.assertRaises(trusted_cli.TrustError):
            self.resolve(binary)
        self.install.chmod(0o700)

    def test_symlink_parent_and_outside_target_are_rejected(self) -> None:
        real_dir = self.install / "real"
        binary = self.executable(real_dir / "codex")
        (self.install / "link").symlink_to(real_dir, target_is_directory=True)
        with self.assertRaises(trusted_cli.TrustError):
            self.resolve(self.install / "link/codex")
        outside = self.executable(self.base / "outside/codex")
        (self.install / "outside-link").symlink_to(outside)
        with self.assertRaises(trusted_cli.TrustError):
            self.resolve(self.install / "outside-link")

    def test_official_env_node_shape_becomes_absolute_plan(self) -> None:
        bin_dir = self.install / "node/v22/bin"
        node = self.executable(bin_dir / "node")
        target = self.executable(
            self.install / "node/v22/lib/node_modules/@openai/codex/bin/codex.js",
            b"#!/usr/bin/env node\n",
        )
        launcher = bin_dir / "codex"
        launcher.symlink_to(Path("../lib/node_modules/@openai/codex/bin/codex.js"))
        executable, prefix = trusted_cli.resolve_exec_plan(
            "codex",
            candidates=[launcher],
            home=self.base,
            workspace=self.workspace,
            swarm_home=self.swarm,
            allowed_roots=[self.install],
            forbidden_roots=[self.workspace, self.swarm],
        )
        self.assertEqual(executable, node.resolve())
        self.assertEqual(prefix, [target.resolve()])

    def test_other_env_shebang_is_rejected(self) -> None:
        script = self.executable(self.install / "bin/codex", b"#!/usr/bin/env python3\n")
        with self.assertRaises(trusted_cli.TrustError):
            trusted_cli.resolve_exec_plan(
                "codex",
                candidates=[script],
                home=self.base,
                workspace=self.workspace,
                swarm_home=self.swarm,
                allowed_roots=[self.install],
                forbidden_roots=[self.workspace, self.swarm],
            )

    def test_production_cli_exposes_no_candidate_override(self) -> None:
        result = subprocess.run(
            ["/usr/bin/python3", "-I", "-B", str(MODULE_PATH), "exec-plan", "codex", str(self.install)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
