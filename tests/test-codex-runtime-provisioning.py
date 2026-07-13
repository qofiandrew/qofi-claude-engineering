#!/usr/bin/env python3
"""Unprivileged regression tests for the real dedicated-runtime provisioner."""

from __future__ import annotations

import argparse
import builtins
import contextlib
import grp
import hashlib
import importlib.util
import importlib.machinery
import io
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "bin" / "swarm-codex-runtime.py"
SPEC = importlib.util.spec_from_file_location("qofi_codex_runtime_test", SOURCE)
assert SPEC is not None and SPEC.loader is not None
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)
RUNNER_SOURCE = ROOT / "bin" / "qofi-codex-runner"
RUNNER_LOADER = importlib.machinery.SourceFileLoader("qofi_codex_runner_test", str(RUNNER_SOURCE))
RUNNER_SPEC = importlib.util.spec_from_loader(RUNNER_LOADER.name, RUNNER_LOADER)
assert RUNNER_SPEC is not None
runner = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_LOADER.exec_module(runner)
LAUNCHER_SOURCE = ROOT / "bin" / "qofi-codex-manager-launcher"
LAUNCHER_LOADER = importlib.machinery.SourceFileLoader(
    "qofi_codex_manager_launcher_test", str(LAUNCHER_SOURCE),
)
LAUNCHER_SPEC = importlib.util.spec_from_loader(LAUNCHER_LOADER.name, LAUNCHER_LOADER)
assert LAUNCHER_SPEC is not None
launcher = importlib.util.module_from_spec(LAUNCHER_SPEC)
LAUNCHER_LOADER.exec_module(launcher)


def completed(command: list[str], returncode: int = 0, stdout: str = "", stderr: str = ""):
    return subprocess.CompletedProcess(command, returncode, stdout, stderr)


def metadata(root: Path) -> dict[str, tuple[int, int, int, str]]:
    result: dict[str, tuple[int, int, int, str]] = {}
    for current, dirs, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        rel_dir = "" if current_path == root else str(current_path.relative_to(root))
        info = os.lstat(current_path)
        result[rel_dir] = (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), "d")
        for name in files:
            path = current_path / name
            if path.is_symlink():
                continue
            info = os.lstat(path)
            result[str(path.relative_to(root))] = (
                info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), "f",
            )
    return result


class ProvisioningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.uid = os.getuid()
        self.gid = os.getgid()
        self.operator = pwd.getpwuid(self.uid)
        self.shared = grp.getgrgid(self.gid)
        runtime.ROOT_AUTHORITY_UID = self.uid
        runtime.ROOT_AUTHORITY_GID = self.gid
        runner.ROOT_AUTHORITY_UID = self.uid

    def test_workspace_three_tiers_git_inheritance_and_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            root = Path(outer) / "repo"
            root.mkdir(mode=0o755)
            (root / "src").mkdir(mode=0o755)
            (root / "src" / "ordinary.txt").write_text("ordinary\n")
            os.chmod(root / "src" / "ordinary.txt", 0o644)
            (root / "AGENTS.md").write_text("doctrine\n")
            os.chmod(root / "AGENTS.md", 0o600)
            (root / ".env").write_text("SECRET=value\n")
            os.chmod(root / ".env", 0o644)
            (root / ".git" / "objects" / "info").mkdir(parents=True, mode=0o755)
            (root / ".git" / "refs" / "heads").mkdir(parents=True, mode=0o755)
            (root / ".git" / "index").write_bytes(b"index")
            os.chmod(root / ".git" / "index", 0o644)
            sentinel = Path(outer) / "outside-secret"
            sentinel.write_text("untouched\n")
            os.chmod(sentinel, 0o600)
            (root / "outside-link").symlink_to(sentinel)

            before = metadata(root)
            sentinel_before = (sentinel.read_text(), stat.S_IMODE(os.lstat(sentinel).st_mode))
            _, snapshot = runtime.capture_workspace_metadata(str(root))
            runtime.prepare_workspace(str(root), self.operator, self.shared)

            self.assertEqual(stat.S_IMODE(os.lstat(root / ".env").st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.lstat(root / "AGENTS.md").st_mode) & 0o070, 0o040)
            self.assertEqual(stat.S_IMODE(os.lstat(root / "src" / "ordinary.txt").st_mode) & 0o060, 0o060)
            self.assertEqual(stat.S_IMODE(os.lstat(root / ".git").st_mode), 0o2750)

            old_umask = os.umask(0o022)
            try:
                (root / ".git" / "objects" / "aa").mkdir(mode=0o777)
                (root / ".git" / "objects" / "aa" / "new-object").write_bytes(b"object")
                (root / ".git" / "refs" / "heads" / "new-branch").write_text("deadbeef\n")
                (root / ".git" / "index").write_bytes(b"new-index")
            finally:
                os.umask(old_umask)
            runtime.verify_workspace(str(root), self.operator, self.shared)
            self.assertEqual(
                (sentinel.read_text(), stat.S_IMODE(os.lstat(sentinel).st_mode)),
                sentinel_before,
            )

            runtime.rollback_workspace(str(root), self.operator, self.shared, snapshot)
            after = metadata(root)
            for rel, saved in before.items():
                self.assertEqual(after[rel], saved, rel)

    def test_workspace_verifier_skips_pnpm_directory_symlinks_without_following(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            root = outer / "repo"
            package = root / "node_modules/.pnpm/typescript@5.9.3/node_modules/typescript"
            package.mkdir(parents=True)
            (package / "package.json").write_text("{}\n")
            link = root / "node_modules/typescript"
            link.symlink_to(
                ".pnpm/typescript@5.9.3/node_modules/typescript",
                target_is_directory=True,
            )
            outside = outer / "outside-directory"
            outside.mkdir(mode=0o700)
            secret = outside / "secret"
            secret.write_text("untouched\n")
            secret.chmod(0o600)
            outside_link = root / "node_modules/outside-directory"
            outside_link.symlink_to(outside, target_is_directory=True)
            outside_before = (
                outside.stat().st_uid,
                outside.stat().st_gid,
                stat.S_IMODE(outside.stat().st_mode),
                secret.stat().st_uid,
                secret.stat().st_gid,
                stat.S_IMODE(secret.stat().st_mode),
                secret.read_text(),
            )

            _canonical, before = runtime.capture_workspace_metadata(str(root))
            self.assertNotIn("node_modules/typescript", before)
            self.assertNotIn("node_modules/outside-directory", before)
            self.assertIn(
                "node_modules/.pnpm/typescript@5.9.3/node_modules/typescript",
                before,
            )
            runtime.prepare_workspace(str(root), self.operator, self.shared)
            runtime.verify_workspace(str(root), self.operator, self.shared)

            self.assertTrue(link.is_symlink())
            self.assertEqual(
                os.readlink(link),
                ".pnpm/typescript@5.9.3/node_modules/typescript",
            )
            self.assertTrue(outside_link.is_symlink())
            self.assertEqual(
                (
                    outside.stat().st_uid,
                    outside.stat().st_gid,
                    stat.S_IMODE(outside.stat().st_mode),
                    secret.stat().st_uid,
                    secret.stat().st_gid,
                    stat.S_IMODE(secret.stat().st_mode),
                    secret.read_text(),
                ),
                outside_before,
            )
            self.assertEqual(
                runtime.rollback_workspace(str(root), self.operator, self.shared, before),
                "rolled-back",
            )

    def test_workspace_verifier_fails_closed_on_directory_type_race(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            root = Path(outer_raw) / "repo"
            victim = root / "directory"
            victim.mkdir(parents=True)
            runtime.prepare_workspace(str(root), self.operator, self.shared)

            original_scan = runtime.assert_workspace_no_acls_or_nested_git_fd
            original_open = os.open
            armed = False
            replaced = False

            def scan_then_arm(*args, **kwargs):
                nonlocal armed
                result = original_scan(*args, **kwargs)
                armed = True
                return result

            def replace_before_open(path, flags, *args, **kwargs):
                nonlocal replaced
                if (armed and not replaced and path == "directory"
                        and flags & getattr(os, "O_DIRECTORY", 0)
                        and kwargs.get("dir_fd") is not None):
                    victim.rmdir()
                    victim.write_text("replacement\n")
                    replaced = True
                return original_open(path, flags, *args, **kwargs)

            stderr = io.StringIO()
            with mock.patch.object(
                runtime,
                "assert_workspace_no_acls_or_nested_git_fd",
                side_effect=scan_then_arm,
            ), mock.patch.object(runtime.os, "open", side_effect=replace_before_open), \
                    contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit):
                    runtime.verify_workspace(str(root), self.operator, self.shared)

            self.assertTrue(replaced)
            self.assertIn(
                "workspace path changed while opening during verification: directory",
                stderr.getvalue(),
            )

    def test_release_never_replays_metadata_to_tightened_or_replaced_inodes(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            root = outer / "repo"
            root.mkdir(mode=0o755)
            target = root / "target"
            target.write_text("original\n")
            target.chmod(0o755)
            registry = outer / "registry.json"
            with mock.patch.object(runtime, "WORKSPACE_REGISTRY", str(registry)):
                runtime.snapshot_workspace(str(root))
                runtime.prepare_workspace(str(root), self.operator, self.shared)
                runtime.finalize_workspace_snapshot(str(root))
                journal = runtime.workspace_registry()[str(root)]

                replacement = root / "replacement"
                replacement.write_text("old inode\n")
                replacement.chmod(0o755)
                runtime.snapshot_workspace(str(root))
                runtime.prepare_workspace(str(root), self.operator, self.shared)
                runtime.finalize_workspace_snapshot(str(root))
                journal = runtime.workspace_registry()[str(root)]
                target.chmod(0o600)
                replacement.unlink()
                replacement.write_text("new inode\n")
                replacement.chmod(0o600)
                new_file = root / "created-after-prepare"
                new_file.write_text("new\n")
                new_file.chmod(0o640)

                outcome = runtime.cleanup_workspace(str(root), self.operator, journal)
                self.assertEqual(outcome, "released")
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(replacement.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(new_file.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
                self.assertEqual(replacement.read_text(), "new inode\n")

    def test_release_skips_a_replaced_workspace_root(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            root = outer / "repo"
            root.mkdir(mode=0o755)
            _canonical, entries = runtime.capture_workspace_metadata(str(root))
            journal = {
                "root": [entries[""][4], entries[""][5]],
                "phase": "prepared",
                "entries": {"": {"before": entries[""], "managed": entries[""]}},
            }
            old = outer / "old-repo"
            root.rename(old)
            root.mkdir(mode=0o755)
            before = metadata(root)
            self.assertEqual(runtime.cleanup_workspace(str(root), self.operator, journal), "replaced")
            self.assertEqual(metadata(root), before)

    def test_command_release_retains_journal_for_moved_or_replaced_root(self) -> None:
        for replacement_present in (False, True):
            with self.subTest(replacement_present=replacement_present), \
                    tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
                outer = Path(outer_raw)
                root = outer / "repo"
                root.mkdir(mode=0o755)
                (root / "tracked").write_text("original\n")
                registry_path = outer / "registry.json"
                with mock.patch.object(runtime, "WORKSPACE_REGISTRY", str(registry_path)):
                    runtime.snapshot_workspace(str(root))
                    runtime.prepare_workspace(str(root), self.operator, self.shared)
                    runtime.finalize_workspace_snapshot(str(root))
                    original_journal = runtime.workspace_registry()[str(root)]
                    original_identity = tuple(original_journal["root"])

                    moved = outer / "moved-repo"
                    root.rename(moved)
                    replacement_before = None
                    if replacement_present:
                        root.mkdir(mode=0o711)
                        (root / "sentinel").write_text("replacement\n")
                        (root / "sentinel").chmod(0o604)
                        replacement_before = metadata(root)

                    released: list[int] = []
                    args = argparse.Namespace(repo=str(root))
                    with contextlib.ExitStack() as stack:
                        stack.enter_context(mock.patch.object(runtime, "require_macos"))
                        stack.enter_context(mock.patch.object(runtime, "require_root"))
                        stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                        stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value={
                            "runtime_uid": self.uid + 100,
                            "operator_uid": self.uid,
                            "runtime_group": self.shared.gr_name,
                        }))
                        stack.enter_context(mock.patch.object(
                            runtime, "exact_runtime_identity",
                            return_value=(self.operator, self.operator, self.shared),
                        ))
                        stack.enter_context(mock.patch.object(
                            runtime, "acquire_lifecycle_lock", return_value=97,
                        ))
                        stack.enter_context(mock.patch.object(
                            runtime, "release_lifecycle_lock", side_effect=released.append,
                        ))
                        with self.assertRaises(SystemExit):
                            runtime.command_release(args)

                    self.assertEqual(released, [97])
                    retained = runtime.workspace_registry()
                    self.assertIn(str(root), retained)
                    self.assertEqual(tuple(retained[str(root)]["root"]), original_identity)
                    moved_info = moved.stat()
                    self.assertEqual((moved_info.st_dev, moved_info.st_ino), original_identity)
                    self.assertEqual(
                        stat.S_IMODE(moved_info.st_mode),
                        original_journal["entries"][""]["managed"][2],
                    )
                    if replacement_before is not None:
                        self.assertEqual(metadata(root), replacement_before)
                        self.assertEqual((root / "sentinel").read_text(), "replacement\n")

    def test_recovery_release_cas_binds_exact_root_journal(self) -> None:
        repo = "/tmp/qofi-recovery-journal"
        journal = {"root": [1, 2], "phase": "prepared", "entries": {}}
        released: list[int] = []
        args = argparse.Namespace(repo=repo, expected_journal_sha256="0" * 64)
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "require_macos"))
            stack.enter_context(mock.patch.object(runtime, "require_root"))
            stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
            stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value={}))
            stack.enter_context(mock.patch.object(
                runtime, "exact_runtime_identity",
                return_value=(self.operator, self.operator, self.shared),
            ))
            stack.enter_context(mock.patch.object(runtime, "acquire_lifecycle_lock", return_value=43))
            stack.enter_context(mock.patch.object(
                runtime, "release_lifecycle_lock", side_effect=released.append,
            ))
            stack.enter_context(mock.patch.object(runtime, "workspace_registry", return_value={repo: journal}))
            cleanup = stack.enter_context(mock.patch.object(runtime, "cleanup_workspace"))
            with self.assertRaises(SystemExit):
                runtime.command_release(args)
        cleanup.assert_not_called()
        self.assertEqual(released, [43])

    def test_workspace_journal_evidence_is_bounded_to_digest(self) -> None:
        repo = "/tmp/qofi-recovery-journal"
        journal = {"root": [1, 2], "phase": "prepared", "entries": {}}
        args = argparse.Namespace(repo=repo)
        output = io.StringIO()
        with contextlib.ExitStack() as stack, contextlib.redirect_stdout(output):
            stack.enter_context(mock.patch.object(runtime, "require_macos"))
            stack.enter_context(mock.patch.object(runtime, "require_root"))
            stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
            stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value={}))
            stack.enter_context(mock.patch.object(
                runtime, "exact_runtime_identity",
                return_value=(self.operator, self.operator, self.shared),
            ))
            stack.enter_context(mock.patch.object(runtime, "workspace_registry", return_value={repo: journal}))
            runtime.command_workspace_journal_evidence(args)
        evidence = json.loads(output.getvalue())
        self.assertEqual(evidence, {
            "schema": "qofi-codex-workspace-journal-evidence/v1",
            "repo": repo,
            "present": True,
            "journal_sha256": runtime.workspace_journal_sha256(journal),
        })

    def test_quiescence_proof_rechecks_service_uid_under_global_lock(self) -> None:
        for remaining in ([], [9876]):
            with self.subTest(remaining=remaining):
                released: list[int] = []
                output = io.StringIO()
                with contextlib.ExitStack() as stack, contextlib.redirect_stdout(output):
                    stack.enter_context(mock.patch.object(runtime, "require_macos"))
                    stack.enter_context(mock.patch.object(runtime, "require_root"))
                    stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                    stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value={}))
                    stack.enter_context(mock.patch.object(runtime, "acquire_lifecycle_lock", return_value=71))
                    stack.enter_context(mock.patch.object(
                        runtime, "release_lifecycle_lock", side_effect=released.append,
                    ))
                    stack.enter_context(mock.patch.object(
                        runtime, "exact_runtime_identity",
                        return_value=(self.operator, self.operator, self.shared),
                    ))
                    stack.enter_context(mock.patch.object(runtime, "service_pids", return_value=remaining))
                    if remaining:
                        with self.assertRaises(SystemExit):
                            runtime.command_quiescence_proof()
                    else:
                        runtime.command_quiescence_proof()
                        self.assertEqual(json.loads(output.getvalue()), {
                            "schema": "qofi-codex-quiescence-proof/v1",
                            "status": "quiescent",
                        })
                self.assertEqual(released, [71])

    def test_root_swap_immediately_before_open_never_mutates_replacement(self) -> None:
        for operation in ("prepare", "release", "rollback"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory(
                dir=Path.home(),
            ) as outer_raw:
                outer = Path(outer_raw)
                root = outer / "repo"
                root.mkdir(mode=0o755)
                (root / "original").write_text("original\n")
                (root / "original").chmod(0o644)
                _canonical, before = runtime.capture_workspace_metadata(str(root))
                identity = (int(before[""][4]), int(before[""][5]))
                journal = {
                    "root": [*identity],
                    "phase": "prepared",
                    "entries": {
                        rel: {"before": saved, "managed": saved}
                        for rel, saved in before.items()
                    },
                }

                replacement = outer / "replacement"
                replacement.mkdir(mode=0o711)
                sentinel = replacement / "sentinel"
                sentinel.write_text("replacement must remain untouched\n")
                sentinel.chmod(0o604)
                replacement_before = metadata(replacement)
                detached = outer / "detached-original"
                real_open = runtime.os.open
                swapped = False

                def swap_then_open(path, flags, *args, **kwargs):
                    nonlocal swapped
                    if (not swapped and os.fspath(path) == str(root)
                            and kwargs.get("dir_fd") is None):
                        root.rename(detached)
                        replacement.rename(root)
                        swapped = True
                    return real_open(path, flags, *args, **kwargs)

                with mock.patch.object(runtime.os, "open", side_effect=swap_then_open):
                    if operation == "prepare":
                        with self.assertRaises(SystemExit):
                            runtime.prepare_workspace(
                                str(root), self.operator, self.shared,
                                expected_identity=identity,
                            )
                    elif operation == "release":
                        self.assertEqual(
                            runtime.cleanup_workspace(str(root), self.operator, journal),
                            "replaced",
                        )
                    else:
                        self.assertEqual(
                            runtime.rollback_workspace(
                                str(root), self.operator, self.shared, before,
                            ),
                            "replaced",
                        )
                self.assertTrue(swapped)
                self.assertEqual(metadata(root), replacement_before)
                self.assertEqual(
                    (root / "sentinel").read_text(),
                    "replacement must remain untouched\n",
                )

    def test_git_alternates_and_special_files_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            root = Path(outer) / "repo"
            (root / ".git" / "objects" / "info").mkdir(parents=True)
            (root / ".git" / "objects" / "info" / "alternates").write_text("/tmp/outside\n")
            with self.assertRaises(SystemExit):
                runtime.prepare_workspace(str(root), self.operator, self.shared)
            (root / ".git" / "objects" / "info" / "alternates").unlink()
            fifo = root / "pipe"
            os.mkfifo(fifo)
            with self.assertRaises(SystemExit):
                runtime.prepare_workspace(str(root), self.operator, self.shared)

    def test_workspace_hardlinks_are_rejected_before_root_mutation(self) -> None:
        for rel in ("ordinary.txt", ".git/objects/aa/object"):
            with self.subTest(rel=rel), tempfile.TemporaryDirectory(
                dir=Path.home(),
            ) as outer_raw:
                outer = Path(outer_raw)
                root = outer / "repo"
                root.mkdir(mode=0o755)
                external = outer / "outside-secret"
                external.write_text("must remain private\n")
                external.chmod(0o600)
                alias = root / rel
                alias.parent.mkdir(parents=True, exist_ok=True)
                os.link(external, alias)
                before = metadata(root)
                external_before = (
                    external.stat().st_uid,
                    external.stat().st_gid,
                    stat.S_IMODE(external.stat().st_mode),
                    external.read_text(),
                )

                with self.assertRaises(SystemExit):
                    runtime.capture_workspace_metadata(str(root))
                with self.assertRaises(SystemExit):
                    runtime.prepare_workspace(str(root), self.operator, self.shared)

                self.assertEqual(metadata(root), before)
                self.assertEqual(
                    (
                        external.stat().st_uid,
                        external.stat().st_gid,
                        stat.S_IMODE(external.stat().st_mode),
                        external.read_text(),
                    ),
                    external_before,
                )

        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            root = Path(outer_raw) / "repo"
            root.mkdir(mode=0o755)
            source = root / "source.txt"
            source.write_text("managed\n")
            runtime.prepare_workspace(str(root), self.operator, self.shared)
            os.link(source, root / "second-name.txt")
            with self.assertRaises(SystemExit):
                runtime.verify_workspace(str(root), self.operator, self.shared)

    def test_closed_node_modules_hardlinks_are_read_only_and_not_journaled(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            root = Path(outer_raw) / "repo"
            first = root / "node_modules/.pnpm/@esbuild+darwin-arm64@0.18.20/" \
                "node_modules/@esbuild/darwin-arm64/bin/esbuild"
            second = root / "node_modules/.pnpm/esbuild@0.18.20/" \
                "node_modules/esbuild/bin/esbuild"
            first.parent.mkdir(parents=True)
            second.parent.mkdir(parents=True)
            first.write_bytes(b"pnpm-managed-binary\n")
            first.chmod(0o755)
            os.link(first, second)
            inode_before = (
                first.stat().st_uid,
                first.stat().st_gid,
                stat.S_IMODE(first.stat().st_mode),
                first.stat().st_ino,
                first.stat().st_nlink,
                first.read_bytes(),
            )

            _canonical, before = runtime.capture_workspace_metadata(str(root))
            first_rel = str(first.relative_to(root))
            second_rel = str(second.relative_to(root))
            self.assertNotIn(first_rel, before)
            self.assertNotIn(second_rel, before)
            self.assertIn("node_modules/.pnpm", before)

            runtime.prepare_workspace(str(root), self.operator, self.shared)
            runtime.verify_workspace(str(root), self.operator, self.shared)
            self.assertEqual(
                (
                    first.stat().st_uid,
                    first.stat().st_gid,
                    stat.S_IMODE(first.stat().st_mode),
                    first.stat().st_ino,
                    first.stat().st_nlink,
                    first.read_bytes(),
                ),
                inode_before,
            )
            self.assertEqual(second.stat().st_ino, first.stat().st_ino)

            self.assertEqual(
                runtime.rollback_workspace(str(root), self.operator, self.shared, before),
                "rolled-back",
            )
            self.assertEqual(
                (
                    first.stat().st_uid,
                    first.stat().st_gid,
                    stat.S_IMODE(first.stat().st_mode),
                    first.stat().st_ino,
                    first.stat().st_nlink,
                    first.read_bytes(),
                ),
                inode_before,
            )

            registry = Path(outer_raw) / "registry.json"
            with mock.patch.object(runtime, "WORKSPACE_REGISTRY", str(registry)):
                runtime.snapshot_workspace(str(root))
                runtime.prepare_workspace(str(root), self.operator, self.shared)
                runtime.finalize_workspace_snapshot(str(root))
                journal = runtime.workspace_registry()[str(root)]
                self.assertNotIn(first_rel, journal["entries"])
                self.assertNotIn(second_rel, journal["entries"])
                self.assertEqual(
                    runtime.cleanup_workspace(str(root), self.operator, journal),
                    "released",
                )
            self.assertEqual(
                (
                    first.stat().st_uid,
                    first.stat().st_gid,
                    stat.S_IMODE(first.stat().st_mode),
                    first.stat().st_ino,
                    first.stat().st_nlink,
                    first.read_bytes(),
                ),
                inode_before,
            )

    def test_node_modules_hardlinks_must_be_closed_and_immutable(self) -> None:
        for mode, name in ((0o775, "writable"), (0o700, "unreadable")):
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                dir=Path.home(),
            ) as outer_raw:
                root = Path(outer_raw) / "repo"
                first = root / "node_modules/.pnpm/pkg/node_modules/pkg/file"
                second = root / "node_modules/.pnpm/consumer/node_modules/consumer/file"
                first.parent.mkdir(parents=True)
                second.parent.mkdir(parents=True)
                first.write_text("dependency\n")
                first.chmod(mode)
                os.link(first, second)
                before = metadata(root)

                with self.assertRaises(SystemExit):
                    runtime.capture_workspace_metadata(str(root))
                with self.assertRaises(SystemExit):
                    runtime.prepare_workspace(str(root), self.operator, self.shared)
                self.assertEqual(metadata(root), before)

        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            root = Path(outer_raw) / "repo"
            ordinary = root / "ordinary.txt"
            dependency = root / "node_modules/.pnpm/pkg/node_modules/pkg/file"
            ordinary.parent.mkdir(parents=True)
            dependency.parent.mkdir(parents=True)
            ordinary.write_text("cross-tier\n")
            ordinary.chmod(0o644)
            os.link(ordinary, dependency)
            with self.assertRaises(SystemExit):
                runtime.capture_workspace_metadata(str(root))

    def test_workspace_setid_files_are_rejected_before_root_mutation(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            root = Path(outer_raw) / "repo"
            root.mkdir(mode=0o755)
            executable = root / "privileged-tool"
            executable.write_text("not really an executable\n")
            executable.chmod(0o6755)
            before = metadata(root)

            with self.assertRaises(SystemExit):
                runtime.capture_workspace_metadata(str(root))
            with self.assertRaises(SystemExit):
                runtime.prepare_workspace(str(root), self.operator, self.shared)

            self.assertEqual(metadata(root), before)
            self.assertEqual(stat.S_IMODE(executable.stat().st_mode), 0o6755)

    def test_workspace_inode_helper_rejects_device_and_owner_escape(self) -> None:
        base = types.SimpleNamespace(
            st_mode=stat.S_IFREG | 0o644,
            st_dev=41,
            st_ino=99,
            st_uid=self.uid,
            st_nlink=1,
        )
        with self.assertRaises(SystemExit):
            runtime.assert_single_link_regular_file(
                base, "mounted/file", expected_dev=42, expected_uid=self.uid,
            )
        foreign_owner = types.SimpleNamespace(**{
            **base.__dict__, "st_dev": 42, "st_uid": self.uid + 1,
        })
        with self.assertRaises(SystemExit):
            runtime.assert_single_link_regular_file(
                foreign_owner, "foreign/file", expected_dev=42, expected_uid=self.uid,
            )
        runtime.assert_single_link_regular_file(
            foreign_owner, "runtime-created/file", expected_dev=42,
            allowed_uids={self.uid, self.uid + 1},
        )

    def test_nested_git_and_workspace_acls_are_rejected_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            root = Path(outer) / "repo"
            (root / "nested" / ".git").mkdir(parents=True)
            target = root / ".env"
            target.write_text("SECRET=value\n")
            os.chmod(target, 0o640)
            before = metadata(root)
            with self.assertRaises(SystemExit):
                runtime.prepare_workspace(str(root), self.operator, self.shared)
            self.assertEqual(metadata(root), before)

            shutil.rmtree(root / "nested" / ".git")
            outside_git = Path(outer) / "outside-git"
            outside_git.mkdir()
            (root / ".git").symlink_to(outside_git, target_is_directory=True)
            before_symlink = metadata(root)
            with self.assertRaises(SystemExit):
                runtime.prepare_workspace(str(root), self.operator, self.shared)
            self.assertEqual(metadata(root), before_symlink)
            (root / ".git").unlink()
            if sys.platform == "darwin":
                subprocess.run(
                    ["/bin/chmod", "+a", "everyone allow read", str(target)], check=True,
                )
                acl_mode = stat.S_IMODE(os.lstat(target).st_mode)
                with self.assertRaises(SystemExit):
                    runtime.prepare_workspace(str(root), self.operator, self.shared)
                self.assertEqual(stat.S_IMODE(os.lstat(target).st_mode), acl_mode)
                subprocess.run(["/bin/chmod", "-N", str(target)], check=True)
            runtime.prepare_workspace(str(root), self.operator, self.shared)
            (root / "future" / ".git").mkdir(parents=True)
            with self.assertRaises(SystemExit):
                runtime.verify_workspace(str(root), self.operator, self.shared)

    def test_claude_worktrees_are_opaque_and_roundtrip_without_content_mutation(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            root = Path(outer) / "repo"
            checkout = root / ".claude" / "worktrees" / "teammate"
            checkout.mkdir(parents=True)
            (checkout / ".git").write_text("gitdir: /operator/owned/worktree\n")
            private = checkout / "private.txt"
            private.write_text("claude-only\n")
            private.chmod(0o604)
            worktrees = root / ".claude" / "worktrees"
            worktrees.chmod(0o755)
            before_private = metadata(checkout)

            _canonical, before = runtime.capture_workspace_metadata(str(root))
            self.assertIn(".claude/worktrees", before)
            self.assertNotIn(".claude/worktrees/teammate", before)
            runtime.prepare_workspace(str(root), self.operator, self.shared)
            runtime.verify_workspace(str(root), self.operator, self.shared)

            self.assertEqual(stat.S_IMODE(worktrees.stat().st_mode), 0o700)
            self.assertEqual(metadata(checkout), before_private)
            runtime.rollback_workspace(str(root), self.operator, self.shared, before)
            self.assertEqual(stat.S_IMODE(worktrees.stat().st_mode), 0o755)
            self.assertEqual(metadata(checkout), before_private)

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL contract")
    def test_runtime_acl_reset_and_runner_reject_unexpected_auth_acl(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            home = Path(outer) / "runtime"
            codex = home / ".codex"
            temporary = home / ".tmp"
            codex.mkdir(parents=True)
            temporary.mkdir()
            auth = codex / "auth.json"
            auth.write_text("{}\n")
            for path in (home, codex, temporary):
                subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(path)], check=True)
                runtime.reset_runtime_acl(str(path), self.operator.pw_name)
            subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(auth)], check=True)
            runtime.reset_runtime_acl(str(auth))
            authority = {"runtime_home": str(home), "codex_home": str(codex)}
            runner.validate_runtime_acls(authority, self.operator.pw_name)
            subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(auth)], check=True)
            with self.assertRaises(SystemExit):
                runner.validate_runtime_acls(authority, self.operator.pw_name)
            subprocess.run(["/bin/chmod", "-N", str(auth)], check=True)

    @unittest.skipUnless(sys.platform == "darwin", "macOS root authority ACL contract")
    def test_root_authority_chain_strips_artifacts_and_rejects_acl_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            authority = outer / "authority"
            authority.mkdir(mode=0o700)
            source = outer / "runner-source"
            source.write_text("#!/bin/sh\nexit 0\n")
            source.chmod(0o755)
            target = authority / "runner"

            subprocess.run(
                ["/bin/chmod", "+a", "everyone allow add_file", str(authority)],
                check=True,
            )
            try:
                with self.assertRaises(SystemExit):
                    runtime.install_root_program(
                        str(source), str(target), self.uid, "ACL fixture runner",
                    )
                self.assertFalse(target.exists())
            finally:
                subprocess.run(["/bin/chmod", "-N", str(authority)], check=True)

            runtime.install_root_program(
                str(source), str(target), self.uid, "ACL fixture runner",
            )
            runtime.validate_root_authority_file(
                str(target), "ACL fixture runner", executable=True, exact_mode=0o755,
            )
            runner.safe_root_file(str(target), "ACL fixture runner", executable=True)

            subprocess.run(
                ["/bin/chmod", "+a", "everyone allow read", str(target)], check=True,
            )
            try:
                with self.assertRaises(SystemExit):
                    runtime.validate_root_authority_file(str(target), "ACL fixture runner")
                with self.assertRaises(SystemExit):
                    runner.safe_root_file(str(target), "ACL fixture runner", executable=True)
                fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    runtime.strip_extended_acl_fd(fd, "ACL fixture runner")
                    self.assertFalse(runtime.fd_has_extended_acl(fd))
                finally:
                    os.close(fd)
            finally:
                subprocess.run(["/bin/chmod", "-N", str(target)], check=True)

            subprocess.run(
                ["/bin/chmod", "+a", "everyone allow add_file", str(authority)],
                check=True,
            )
            try:
                with self.assertRaises(SystemExit):
                    runner.safe_root_file(str(target), "ACL fixture runner", executable=True)
            finally:
                subprocess.run(["/bin/chmod", "-N", str(authority)], check=True)

    def test_sudoers_is_never_published_before_execution_authority_validation(self) -> None:
        with mock.patch.object(
            runtime, "validate_sudo_publish_authority", side_effect=SystemExit(2),
        ), mock.patch.object(runtime, "atomic_write") as writer:
            with self.assertRaises(SystemExit):
                runtime.install_sudoers(self.operator)
        writer.assert_not_called()

    def test_sudoers_grants_only_the_exact_argument_free_manager_launcher(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            sudoers = Path(outer_raw) / "qofi-codex-runtime"
            commands: list[list[str]] = []
            runtime_user = pwd.struct_passwd((
                "_qofi_fixture", "x", self.uid + 100, self.gid, "",
                str(Path(outer_raw) / "runtime"), "/usr/bin/false",
            ))

            def write(path, content, mode):
                Path(path).write_text(content)
                Path(path).chmod(mode)

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "SUDOERS", str(sudoers)))
                stack.enter_context(mock.patch.object(
                    runtime, "validate_sudo_publish_authority",
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "ensure_root_authority_directory",
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "atomic_write", side_effect=write,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "run",
                    side_effect=lambda command, **_kwargs: (
                        commands.append(command) or completed(command)
                    ),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "validate_root_authority_file",
                ))
                runtime.install_sudoers(self.operator, runtime_user)

            self.assertEqual(
                sudoers.read_text(),
                "# managed by swarm-codex-runtime.sh; runner validates every argument and attested hash\n"
                f"{self.operator.pw_name} ALL=(root) NOPASSWD: {runtime.RUNNER} *\n"
                f'{self.operator.pw_name} ALL=(root) NOPASSWD: '
                f'{runtime.MANAGER_LAUNCHER} ""\n'
                f'{runtime_user.pw_name} ALL=(#{self.operator.pw_uid}) NOPASSWD: '
                f'/usr/bin/python3 -I -B {runtime.FABLE_REVIEWER}\n',
            )
            self.assertEqual(
                commands,
                [["/usr/sbin/visudo", "-cf", f"{sudoers}.tmp.{os.getpid()}"]],
            )

    def test_root_program_post_publish_bind_failure_rolls_back(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            authority = outer / "authority"
            authority.mkdir(mode=0o755)
            source = outer / "reviewer-source"
            source.write_text("#!/usr/bin/env python3\n")
            source.chmod(0o755)
            real_validate = runtime.validate_root_authority_file

            for prior in (None, b"#!/bin/sh\nexit 0\n"):
                target = authority / ("new-reviewer" if prior is None else "old-reviewer")
                if prior is not None:
                    target.write_bytes(prior)
                    target.chmod(0o755)

                def reject_installed(path, label, **kwargs):
                    value = real_validate(path, label, **kwargs)
                    if label.startswith("installed Fable publication rollback fixture"):
                        raise RuntimeError("injected post-publication validation failure")
                    return value

                with mock.patch.object(
                    runtime, "validate_root_authority_file", side_effect=reject_installed,
                ), self.assertRaisesRegex(RuntimeError, "post-publication"):
                    runtime.install_root_program(
                        str(source), str(target), self.uid,
                        "Fable publication rollback fixture",
                    )

                if prior is None:
                    self.assertFalse(target.exists())
                else:
                    self.assertEqual(target.read_bytes(), prior)
                self.assertFalse(Path(str(target) + f".old.{os.getpid()}").exists())
                self.assertFalse(Path(str(target) + f".tmp.{os.getpid()}").exists())

    def test_manager_bundle_is_a_single_node_target_closure_built_as_operator(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            swarm_home = Path(outer_raw) / "swarm"
            source = swarm_home / "codex-bridge" / "app-server-manager.ts"
            source.parent.mkdir(parents=True)
            source.write_text("export const fixture = true;\n")
            calls: list[tuple[list[str], str, str, int]] = []

            def build(_operator, command, *, cwd, label, max_stdout, **_kwargs):
                calls.append((command, cwd, label, max_stdout))
                return b"x" * 1024

            with mock.patch.object(
                runtime, "run_as_operator_capture_bytes", side_effect=build,
            ):
                output = runtime.build_manager_bundle(
                    str(swarm_home), self.operator, "/fixed/root-bun",
                )
            self.assertEqual(output, b"x" * 1024)
            self.assertEqual(len(calls), 1)
            command, cwd, label, maximum = calls[0]
            self.assertEqual(command, [
                "/fixed/root-bun",
                "--no-env-file", "--config=/dev/null", "--no-install",
                "--no-addons", "--no-macros",
                "build", str(source), "--target=node", "--format=esm",
            ])
            self.assertNotIn("--outfile", command)
            self.assertNotIn("/private/tmp", command)
            self.assertEqual(cwd, str(swarm_home))
            self.assertEqual(label, "single-file App Server manager bundle")
            self.assertEqual(maximum, runtime.MAX_MANAGER_BUNDLE_BYTES)

    def test_manager_bundle_capture_is_binary_separate_bounded_and_timed(self) -> None:
        command = [
            "/usr/bin/python3", "-I", "-B", "-c",
            "import os; os.write(1,b'\\x00\\xffbundle'); os.write(2,b'diagnostic')",
        ]
        output = runtime.run_as_operator_capture_bytes(
            self.operator, command, cwd=str(ROOT), label="binary bundle fixture",
            max_stdout=64, max_stderr=64,
        )
        self.assertEqual(output, b"\x00\xffbundle")

        pipe_stress_size = 32 * 8192
        output = runtime.run_as_operator_capture_bytes(
            self.operator,
            [
                "/usr/bin/python3", "-I", "-B", "-c",
                (
                    "import os\n"
                    "for _ in range(32):\n"
                    " os.write(1,b'x'*8192)\n"
                    " os.write(2,b'e'*8192)\n"
                ),
            ],
            cwd=str(ROOT), label="full dual-pipe bundle fixture",
            max_stdout=pipe_stress_size, max_stderr=pipe_stress_size,
        )
        self.assertEqual(output, b"x" * pipe_stress_size)

        with self.assertRaises(SystemExit):
            runtime.run_as_operator_capture_bytes(
                self.operator,
                [
                    "/usr/bin/python3", "-I", "-B", "-c",
                    "import os,time; os.write(1,b'oversized'); time.sleep(5)",
                ],
                cwd=str(ROOT),
                label="oversized bundle fixture", max_stdout=2, max_stderr=64,
            )
        with self.assertRaises(SystemExit):
            runtime.run_as_operator_capture_bytes(
                self.operator,
                ["/usr/bin/python3", "-I", "-B", "-c", "import time; time.sleep(5)"],
                cwd=str(ROOT), label="timed bundle fixture",
                max_stdout=64, max_stderr=64, timeout=0.05,
            )

        terminated: list[int] = []
        real_terminate = runtime.terminate_process_group

        def terminate(process, *args, **kwargs):
            terminated.append(process.pid)
            return real_terminate(process, *args, **kwargs)

        with mock.patch.object(
            runtime.os, "set_blocking", side_effect=RuntimeError("injected selector setup"),
        ), mock.patch.object(
            runtime, "terminate_process_group", side_effect=terminate,
        ), self.assertRaisesRegex(RuntimeError, "selector setup"):
            runtime.run_as_operator_capture_bytes(
                self.operator,
                ["/usr/bin/python3", "-I", "-B", "-c", "import time; time.sleep(5)"],
                cwd=str(ROOT), label="exception bundle fixture",
                max_stdout=64, max_stderr=64,
            )
        self.assertEqual(len(terminated), 1)

    def test_captured_manager_bundle_publishes_without_operator_path_and_rolls_back(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            authority = Path(outer_raw) / "authority"
            authority.mkdir(mode=0o755)
            target = authority / "manager.mjs"
            content = b"x" * 1024

            backup = runtime.install_root_program_bytes(
                content, str(target), "first manager bundle fixture",
            )
            self.assertIsNone(backup)
            self.assertEqual(target.read_bytes(), content)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
            self.assertFalse(Path(str(target) + f".tmp.{os.getpid()}").exists())

            target.write_bytes(b"old-manager\n")
            target.chmod(0o755)
            backup = runtime.install_root_program_bytes(
                content, str(target), "manager bundle fixture",
            )
            self.assertEqual(target.read_bytes(), content)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
            self.assertIsNotNone(backup)
            assert backup is not None
            self.assertEqual(Path(backup).read_bytes(), b"old-manager\n")
            self.assertFalse(Path(str(target) + f".tmp.{os.getpid()}").exists())
            Path(backup).unlink()

            target.write_bytes(b"rollback-old\n")
            target.chmod(0o755)
            real_validate = runtime.validate_root_authority_file

            def reject_installed(path, label, **kwargs):
                value = real_validate(path, label, **kwargs)
                if label.startswith("installed manager bundle rollback fixture"):
                    raise RuntimeError("injected post-publication validation failure")
                return value

            with mock.patch.object(
                runtime, "validate_root_authority_file", side_effect=reject_installed,
            ), self.assertRaises(RuntimeError):
                runtime.install_root_program_bytes(
                    content, str(target), "manager bundle rollback fixture",
                )
            self.assertEqual(target.read_bytes(), b"rollback-old\n")
            self.assertFalse(Path(str(target) + f".old.{os.getpid()}").exists())
            self.assertFalse(Path(str(target) + f".tmp.{os.getpid()}").exists())

    def test_trusted_source_still_rejects_a_writable_ancestor(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            writable = Path(outer_raw) / "world-writable"
            writable.mkdir()
            writable.chmod(0o777)
            payload = writable / "bundle.mjs"
            payload.write_bytes(b"x" * 1024)
            payload.chmod(0o600)
            with self.assertRaises(SystemExit):
                runtime.open_trusted_source(
                    str(payload), self.uid, "writable-parent bundle fixture",
                )

    def test_manager_mutation_locks_use_launcher_then_runner_and_reverse_release(self) -> None:
        authority = {"runtime_uid": self.uid + 100}
        events: list[str] = []

        with mock.patch.object(
            runtime, "acquire_manager_mutation_lock",
            side_effect=lambda: events.append("acquire-manager") or 70,
        ), mock.patch.object(
            runtime, "acquire_lifecycle_lock",
            side_effect=lambda selected: (
                self.assertIs(selected, authority),
                events.append("acquire-runner"),
                71,
            )[-1],
        ):
            manager_fd, runner_fd = runtime.acquire_manager_mutation_locks(authority)
        self.assertEqual((manager_fd, runner_fd), (70, 71))

        with mock.patch.object(
            runtime, "release_lifecycle_lock",
            side_effect=lambda fd: (
                self.assertEqual(fd, runner_fd), events.append("release-runner"),
            ),
        ), mock.patch.object(
            runtime.fcntl, "flock",
            side_effect=lambda fd, operation: (
                self.assertEqual((fd, operation), (manager_fd, runtime.fcntl.LOCK_UN)),
                events.append("unlock-manager"),
            ),
        ), mock.patch.object(
            runtime.os, "close",
            side_effect=lambda fd: (
                self.assertEqual(fd, manager_fd), events.append("close-manager"),
            ),
        ):
            runtime.release_manager_mutation_locks(manager_fd, runner_fd)
        self.assertEqual(events, [
            "acquire-manager", "acquire-runner", "release-runner",
            "unlock-manager", "close-manager",
        ])

        events.clear()
        with mock.patch.object(
            runtime, "acquire_manager_mutation_lock", return_value=72,
        ), mock.patch.object(
            runtime, "acquire_lifecycle_lock",
            side_effect=RuntimeError("runner lock fixture"),
        ), mock.patch.object(
            runtime.fcntl, "flock",
            side_effect=lambda fd, operation: events.append(f"unlock-{fd}-{operation}"),
        ), mock.patch.object(
            runtime.os, "close", side_effect=lambda fd: events.append(f"close-{fd}"),
        ), self.assertRaisesRegex(RuntimeError, "runner lock fixture"):
            runtime.acquire_manager_mutation_locks(authority)
        self.assertEqual(events, [f"unlock-72-{runtime.fcntl.LOCK_UN}", "close-72"])

        events.clear()
        lock_info = types.SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600, st_uid=self.uid,
        )

        def contended_flock(fd, operation):
            self.assertEqual(fd, 73)
            if operation == runtime.fcntl.LOCK_EX | runtime.fcntl.LOCK_NB:
                events.append("contended")
                raise BlockingIOError
            self.assertEqual(operation, runtime.fcntl.LOCK_UN)
            events.append("unlock")

        with mock.patch.object(runtime.os, "open", return_value=73), \
                mock.patch.object(runtime.os, "fstat", return_value=lock_info), \
                mock.patch.object(runtime, "fd_has_extended_acl", return_value=False), \
                mock.patch.object(runtime.time, "monotonic", side_effect=[10.0, 10.0]), \
                mock.patch.object(runtime.time, "sleep") as slept, \
                mock.patch.object(runtime.fcntl, "flock", side_effect=contended_flock), \
                mock.patch.object(
                    runtime.os, "close", side_effect=lambda fd: events.append(f"close-{fd}"),
                ), self.assertRaises(SystemExit):
            runtime.acquire_manager_mutation_lock(timeout=0)
        self.assertEqual(events, ["contended", "unlock", "close-73"])
        slept.assert_not_called()

    def test_install_holds_both_manager_locks_before_admission_or_mutation(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            repo = outer / "repo"
            swarm_home = outer / "swarm"
            repo.mkdir()
            swarm_home.mkdir()
            args = argparse.Namespace(
                operator_user=self.operator.pw_name,
                repo=str(repo), runtime_home=str(outer / "runtime"),
                runtime_user="_runtime_fixture",
                runtime_group="_runtime_group_fixture",
            )

            def run_case(*, lock_timeout: bool):
                events: list[str] = []

                def lexists(path):
                    if path == runtime.MANAGER_ADMISSION:
                        events.append("admission-check")
                    return False

                def acquire(_authority):
                    events.append("acquire-both")
                    if lock_timeout:
                        raise SystemExit(2)
                    return 73, 74

                def immutable_preflight(*_args):
                    events.append("immutable-preflight")
                    raise RuntimeError("stop after locked admission proof")

                with contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.object(runtime, "require_macos"))
                    stack.enter_context(mock.patch.object(runtime, "require_root"))
                    stack.enter_context(mock.patch.object(
                        runtime, "operator_record", return_value=self.operator,
                    ))
                    stack.enter_context(mock.patch.object(runtime, "validate_runtime_home_target"))
                    stack.enter_context(mock.patch.object(
                        runtime, "requested_pnpm_version", return_value=None,
                    ))
                    stack.enter_context(mock.patch.object(
                        runtime.os.path, "lexists", side_effect=lexists,
                    ))
                    stack.enter_context(mock.patch.object(
                        runtime, "acquire_manager_mutation_locks", side_effect=acquire,
                    ))
                    released = stack.enter_context(mock.patch.object(
                        runtime, "release_manager_mutation_locks",
                        side_effect=lambda *_args: events.append("release-both"),
                    ))
                    stack.enter_context(mock.patch.object(
                        runtime, "resolve_operator_pnpm", side_effect=immutable_preflight,
                    ))
                    ensure_group = stack.enter_context(mock.patch.object(runtime, "ensure_group"))
                    ensure_user = stack.enter_context(mock.patch.object(runtime, "ensure_user"))
                    bundle = stack.enter_context(mock.patch.object(runtime, "build_manager_bundle"))
                    authority = stack.enter_context(mock.patch.object(
                        runtime, "write_manager_authority",
                    ))
                    if lock_timeout:
                        with self.assertRaises(SystemExit):
                            runtime.command_install(args, str(swarm_home))
                    else:
                        with self.assertRaisesRegex(RuntimeError, "locked admission proof"):
                            runtime.command_install(args, str(swarm_home))
                for mutation in (ensure_group, ensure_user, bundle, authority):
                    mutation.assert_not_called()
                return events, released

            events, released = run_case(lock_timeout=False)
            self.assertEqual(events, [
                "acquire-both", "admission-check", "immutable-preflight", "release-both",
            ])
            released.assert_called_once_with(73, 74)

            events, released = run_case(lock_timeout=True)
            self.assertEqual(events, ["acquire-both"])
            released.assert_not_called()

    def test_legacy_install_bootstraps_before_fable_companion_proof(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            repo = outer / "repo"
            swarm_home = outer / "swarm"
            repo.mkdir()
            swarm_home.mkdir()
            lifecycle = outer / "qofi-codex-runtime"
            lifecycle.write_text("#!/usr/bin/env python3\n")
            lifecycle.chmod(0o755)
            attestation = outer / "attestation.json"
            attestation.write_text("{}\n")
            missing_reviewer = outer / "missing-reviewer"
            missing_doctrine = outer / "missing-doctrine"
            missing_schema = outer / "missing-schema"
            runtime_home = str(outer / "runtime")
            runtime_user = "_runtime_fixture"
            runtime_group = "_runtime_group_fixture"
            legacy = {key: "fixture" for key in runtime.LEGACY_EXACT_KEYS}
            legacy.update({
                "schema": runtime.SCHEMA,
                "operator_uid": self.uid,
                "runtime_uid": self.uid + 100,
                "runtime_gid": self.gid,
                "runtime_user": runtime_user,
                "runtime_group": runtime_group,
                "runtime_home": runtime_home,
                "launchd_canary_name": "QOFI_CODEX_RUNTIME_CANARY_FIXTURE",
            })
            args = argparse.Namespace(
                operator_user=self.operator.pw_name, repo=str(repo),
                runtime_home=runtime_home, runtime_user=runtime_user,
                runtime_group=runtime_group,
            )
            released: list[tuple[int, int]] = []

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "LIFECYCLE", str(lifecycle)))
                stack.enter_context(mock.patch.object(
                    runtime, "FABLE_REVIEWER", str(missing_reviewer),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "FABLE_DOCTRINE", str(missing_doctrine),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "FABLE_SCHEMA", str(missing_schema),
                ))
                stack.enter_context(mock.patch.object(runtime, "ATTESTATION", str(attestation)))
                stack.enter_context(mock.patch.object(
                    runtime, "MANAGER_ADMISSION", str(outer / "missing-admission"),
                ))
                stack.enter_context(mock.patch.object(runtime.sys, "argv", [str(lifecycle)]))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(
                    runtime, "operator_record", return_value=self.operator,
                ))
                stack.enter_context(mock.patch.object(runtime, "validate_runtime_home_target"))
                stack.enter_context(mock.patch.object(
                    runtime, "requested_pnpm_version", return_value=None,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks", return_value=(73, 74),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "release_manager_mutation_locks",
                    side_effect=lambda manager_fd, runner_fd: released.append(
                        (manager_fd, runner_fd),
                    ),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "resolve_operator_pnpm", return_value=None,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "load_attestation", return_value=legacy,
                ))
                companion = stack.enter_context(mock.patch.object(
                    runtime, "require_fixed_reviewer_authority",
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "quiesce_service_uid",
                    side_effect=RuntimeError("reached legacy migration transaction"),
                ))
                with self.assertRaisesRegex(RuntimeError, "legacy migration"):
                    runtime.command_install(args, str(swarm_home))

            companion.assert_not_called()
            self.assertEqual(released, [(73, 74)])
            for path in (missing_reviewer, missing_doctrine, missing_schema):
                self.assertFalse(os.path.lexists(path))

    def test_expanded_install_still_requires_existing_fable_authority(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            repo = outer / "repo"
            swarm_home = outer / "swarm"
            repo.mkdir()
            swarm_home.mkdir()
            attestation = outer / "attestation.json"
            attestation.write_text("{}\n")
            args = argparse.Namespace(
                operator_user=self.operator.pw_name, repo=str(repo),
                runtime_home=str(outer / "runtime"), runtime_user="_runtime_fixture",
                runtime_group="_runtime_group_fixture",
            )
            expanded = {key: "fixture" for key in runtime.EXACT_KEYS}
            expanded.update({
                "operator_uid": self.uid,
                "runtime_uid": self.uid + 100,
                "runtime_gid": self.gid,
                "runtime_user": args.runtime_user,
                "runtime_group": args.runtime_group,
                "runtime_home": args.runtime_home,
                "launchd_canary_name": "QOFI_CODEX_RUNTIME_CANARY_FIXTURE",
            })
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "ATTESTATION", str(attestation)))
                stack.enter_context(mock.patch.object(
                    runtime, "MANAGER_ADMISSION", str(outer / "missing-admission"),
                ))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                entry = stack.enter_context(mock.patch.object(
                    runtime, "require_fixed_lifecycle",
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "operator_record", return_value=self.operator,
                ))
                stack.enter_context(mock.patch.object(runtime, "validate_runtime_home_target"))
                stack.enter_context(mock.patch.object(
                    runtime, "requested_pnpm_version", return_value=None,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks", return_value=(75, 76),
                ))
                stack.enter_context(mock.patch.object(runtime, "release_manager_mutation_locks"))
                stack.enter_context(mock.patch.object(
                    runtime, "resolve_operator_pnpm", return_value=None,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "load_attestation", return_value=expanded,
                ))
                companion = stack.enter_context(mock.patch.object(
                    runtime, "require_fixed_reviewer_authority",
                    side_effect=RuntimeError("expanded companion proof"),
                ))
                quiesce = stack.enter_context(mock.patch.object(
                    runtime, "quiesce_service_uid",
                ))
                with self.assertRaisesRegex(RuntimeError, "expanded companion proof"):
                    runtime.command_install(args, str(swarm_home))

            entry.assert_called_once_with(include_reviewer=False)
            companion.assert_called_once_with()
            quiesce.assert_not_called()

    def test_uninstall_rebinds_all_manager_authority_under_both_locks(self) -> None:
        value = {
            "operator_uid": self.uid,
            "runtime_uid": self.uid + 100,
            "runtime_gid": self.gid,
            "runtime_user": "_runtime_fixture",
            "runtime_group": "_runtime_group_fixture",
            "runtime_home": "/Users/_qofi_codex_uninstall_fixture",
            "launchd_canary_name": "QOFI_CODEX_RUNTIME_CANARY_FIXTURE",
        }
        args = argparse.Namespace(remove_account=False)
        events: list[str] = []
        load_count = 0
        identity_count = 0
        manager_count = 0

        def load_attestation():
            nonlocal load_count
            load_count += 1
            events.append("attestation-pre" if load_count == 1 else "attestation-locked")
            return dict(value)

        def exact_identity(_value):
            nonlocal identity_count
            identity_count += 1
            events.append("identity-pre" if identity_count == 1 else "identity-locked")
            return self.operator, self.operator, self.shared

        def manager_authority(_operator, _value):
            nonlocal manager_count
            manager_count += 1
            events.append("manager-authority-pre" if manager_count == 1 else "manager-authority-locked")
            return {}

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "require_macos"))
            stack.enter_context(mock.patch.object(runtime, "require_root"))
            stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
            stack.enter_context(mock.patch.object(
                runtime, "load_attestation", side_effect=load_attestation,
            ))
            stack.enter_context(mock.patch.object(
                runtime, "exact_runtime_identity", side_effect=exact_identity,
            ))
            stack.enter_context(mock.patch.object(
                runtime, "validate_manager_authority", side_effect=manager_authority,
            ))
            stack.enter_context(mock.patch.object(
                runtime.pwd, "getpwnam", side_effect=KeyError,
            ))
            stack.enter_context(mock.patch.object(
                runtime, "acquire_manager_mutation_locks",
                side_effect=lambda selected: (
                    self.assertEqual(selected, value),
                    events.append("acquire-both"),
                    (75, 76),
                )[-1],
            ))
            stack.enter_context(mock.patch.object(
                runtime.os.path, "lexists",
                side_effect=lambda path: (
                    events.append("admission-locked") or True
                    if path == runtime.MANAGER_ADMISSION else False
                ),
            ))
            stack.enter_context(mock.patch.object(
                runtime, "validate_root_authority_file",
                side_effect=lambda *_args, **_kwargs: events.append("admission-authority"),
            ))
            released = stack.enter_context(mock.patch.object(
                runtime, "release_manager_mutation_locks",
                side_effect=lambda *_args: events.append("release-both"),
            ))
            unlinked = stack.enter_context(mock.patch.object(runtime.os, "unlink"))
            registry = stack.enter_context(mock.patch.object(runtime, "workspace_registry"))
            with self.assertRaises(SystemExit):
                runtime.command_uninstall(args)

        self.assertEqual(events, [
            "attestation-pre", "identity-pre", "manager-authority-pre",
            "acquire-both", "attestation-locked", "identity-locked",
            "manager-authority-locked", "admission-locked",
            "admission-authority", "release-both",
        ])
        released.assert_called_once_with(75, 76)
        unlinked.assert_not_called()
        registry.assert_not_called()

    def test_manager_recovery_processes_are_exactly_admission_bound(self) -> None:
        launcher_pid = 42000
        manager_pid = 42001
        launcher_started = "Sun Jul 12 12:00:00 2026"
        manager_started = "Sun Jul 12 12:00:01 2026"
        authority = {
            "schema": runtime.MANAGER_AUTHORITY_SCHEMA,
            "operator_uid": self.uid,
            "operator_user": self.operator.pw_name,
            "operator_home": self.operator.pw_dir,
            "node_path": "/fixed/node",
            "node_sha256": "a" * 64,
            "manager_bundle_path": "/fixed/manager.mjs",
            "manager_bundle_sha256": "b" * 64,
            "manager_launcher_path": "/fixed/manager-launcher",
            "manager_launcher_sha256": "c" * 64,
            "manager_python_path": "/fixed/python",
            "manager_python_sha256": "d" * 64,
            "manager_state_dir": "/fixed/state",
            "swarm_home": "/fixed/swarm",
            "manager_environment_sha256": "e" * 64,
        }
        admission = {
            key: value for key, value in authority.items()
            if key in runtime.MANAGER_ADMISSION_KEYS
        }
        admission.update({
            "schema": runtime.MANAGER_ADMISSION_SCHEMA,
            "nonce": "f" * 64,
            "launcher_pid": launcher_pid,
            "launcher_started": launcher_started,
            "manager_pid": manager_pid,
            "manager_started": manager_started,
        })
        snapshots = {
            launcher_pid: {
                "pid": launcher_pid, "ppid": 1,
                "uid": self.uid, "ruid": self.uid, "svuid": self.uid,
                "gid": self.gid, "rgid": self.gid, "svgid": self.gid,
                "started": launcher_started,
            },
            manager_pid: {
                "pid": manager_pid, "ppid": launcher_pid, "pgid": manager_pid,
                "uid": self.uid, "ruid": self.uid, "svuid": self.uid,
                "gid": self.operator.pw_gid, "rgid": self.operator.pw_gid,
                "svgid": self.operator.pw_gid,
                "started": manager_started,
            },
        }
        executables = {
            launcher_pid: authority["manager_python_path"],
            manager_pid: authority["node_path"],
        }
        arguments = {
            launcher_pid: [
                authority["manager_python_path"], "-I",
                authority["manager_launcher_path"],
            ],
            manager_pid: [
                authority["node_path"], "--disable-sigusr1",
                authority["manager_bundle_path"],
                "--state-dir", authority["manager_state_dir"],
                "--swarm-home", authority["swarm_home"],
            ],
        }

        def invoke(*, admission_changes=None, snapshot_changes=None,
                   executable_changes=None, argument_changes=None):
            selected_admission = dict(admission)
            selected_admission.update(admission_changes or {})
            selected_snapshots = {pid: dict(value) for pid, value in snapshots.items()}
            for pid, changes in (snapshot_changes or {}).items():
                selected_snapshots[pid].update(changes)
            selected_executables = dict(executables)
            selected_executables.update(executable_changes or {})
            selected_arguments = dict(arguments)
            selected_arguments.update(argument_changes or {})
            with mock.patch.object(
                runtime, "process_snapshot", side_effect=selected_snapshots.get,
            ), mock.patch.object(
                runtime, "process_executable_path", side_effect=selected_executables.get,
            ), mock.patch.object(
                runtime, "process_arguments", side_effect=selected_arguments.get,
            ):
                return runtime.validate_manager_recovery_processes(
                    authority, selected_admission, self.operator,
                )

        self.assertEqual(invoke(), (snapshots[launcher_pid], snapshots[manager_pid]))
        refused = (
            ("admission authority mismatch", {
                "admission_changes": {"node_sha256": "0" * 64},
            }),
            ("manager parent PID mismatch", {
                "snapshot_changes": {manager_pid: {"ppid": launcher_pid + 9}},
            }),
            ("manager primary group mismatch", {
                "snapshot_changes": {manager_pid: {"gid": self.operator.pw_gid + 1}},
            }),
            ("manager process group mismatch", {
                "snapshot_changes": {manager_pid: {"pgid": manager_pid + 1}},
            }),
            ("manager executable mismatch", {
                "executable_changes": {manager_pid: "/tmp/replaced-node"},
            }),
            ("launcher argv injection", {
                "argument_changes": {
                    launcher_pid: ["/fixed/python", "-I", "-c", "import os"],
                },
            }),
            ("launcher argv omits exact interpreter", {
                "argument_changes": {
                    launcher_pid: ["-I", authority["manager_launcher_path"]],
                },
            }),
        )
        for label, changes in refused:
            with self.subTest(label=label), self.assertRaises(SystemExit):
                invoke(**changes)

    def test_manager_recovery_health_binds_socket_peer_endpoint_and_state(self) -> None:
        authority = {"manager_state_dir": "/fixed/state"}
        manager_pid = 42001
        health = {
            "schema": "qofi-codex-app-server-manager/v1",
            "managerVersion": "0.1.0",
            "protocolVersion": "0.144.1",
            "cliVersion": "0.144.1",
            "generation": 2,
            "registeredSwarmCount": 0,
            "status": "ambiguous",
            "phase": "ambiguous",
            "upstreamState": "ambiguous",
            "upstreamReady": False,
        }

        def socket_info(inode: int):
            return types.SimpleNamespace(
                st_dev=1, st_ino=inode, st_mode=stat.S_IFSOCK | 0o600,
                st_uid=self.uid, st_gid=self.gid,
                st_mtime_ns=100, st_ctime_ns=200,
            )

        stable = socket_info(10)

        def invoke(selected_health, *, peer_pid=manager_pid, identities=None):
            body = json.dumps(
                selected_health, sort_keys=True, separators=(",", ":"),
            ).encode("utf-8")
            response = (
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode("ascii")
                + body
            )
            client = mock.Mock()
            client.getsockopt.return_value = runtime.struct.pack("=i", peer_pid)
            client.recv.side_effect = [response]
            selected_identities = identities or [stable, stable, stable]
            with mock.patch.object(runtime.os, "lstat", side_effect=selected_identities), \
                    mock.patch.object(
                        runtime, "path_has_extended_acl", return_value=False,
                    ), mock.patch.object(
                        runtime.socket, "socket", return_value=client,
                    ):
                result = runtime.query_stopped_manager_recovery_health(
                    authority, self.operator, manager_pid,
                )
            return result, client

        result, client = invoke(health)
        self.assertEqual(result, health)
        client.connect.assert_called_once_with("/fixed/state/control.sock")
        client.getsockopt.assert_called_once_with(0, 0x002, 4)
        client.sendall.assert_called_once()
        client.close.assert_called_once()

        refused = (
            ("kernel peer PID mismatch", health, {
                "peer_pid": manager_pid + 1,
            }),
            ("registered manager", dict(health, registeredSwarmCount=1), {}),
            ("non-ambiguous health", dict(
                health, status="ready", phase="ready", upstreamState="ready",
                upstreamReady=True,
            ), {}),
            ("endpoint inode changed", health, {
                "identities": [stable, socket_info(11)],
            }),
        )
        for label, selected_health, options in refused:
            with self.subTest(label=label), self.assertRaises(SystemExit):
                invoke(selected_health, **options)

    def test_manager_recovery_launcher_lock_is_authority_bound(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            lock_path = Path(outer_raw) / "manager-launcher.lock"
            lock_path.write_bytes(b"")
            lock_path.chmod(0o600)
            with mock.patch.object(
                runtime, "MANAGER_LAUNCHER_LOCK", str(lock_path),
            ), mock.patch.object(
                runtime, "fd_has_extended_acl", return_value=False,
            ):
                fd, identity = runtime.open_manager_recovery_launcher_lock()
            try:
                self.assertEqual(
                    identity,
                    runtime._manager_admission_identity(os.fstat(fd)),
                )
            finally:
                os.close(fd)

            real_close = os.close

            def rejected(*, mode=0o600, has_acl=False, observed=None):
                lock_path.chmod(mode)
                with contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.object(
                        runtime, "MANAGER_LAUNCHER_LOCK", str(lock_path),
                    ))
                    stack.enter_context(mock.patch.object(
                        runtime, "fd_has_extended_acl", return_value=has_acl,
                    ))
                    if observed is not None:
                        stack.enter_context(mock.patch.object(
                            runtime.os, "lstat", return_value=observed,
                        ))
                    closed = stack.enter_context(mock.patch.object(
                        runtime.os, "close", side_effect=real_close,
                    ))
                    with self.assertRaises(SystemExit):
                        runtime.open_manager_recovery_launcher_lock()
                closed.assert_called_once()

            rejected(mode=0o644)
            rejected(has_acl=True)
            decoy = Path(outer_raw) / "decoy.lock"
            decoy.write_bytes(b"")
            decoy.chmod(0o600)
            rejected(observed=os.lstat(decoy))

    def test_manager_recovery_runner_lock_is_authority_bound_and_bounded(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            lock_path = Path(outer_raw) / "runner.lock"
            lock_path.write_bytes(b"")
            lock_path.chmod(0o600)
            with mock.patch.object(runtime, "LOCK", str(lock_path)), \
                    mock.patch.object(
                        runtime, "fd_has_extended_acl", return_value=False,
                    ):
                fd = runtime.acquire_manager_recovery_runner_lock(timeout=0)
            contender = os.open(lock_path, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    runtime.fcntl.flock(
                        contender, runtime.fcntl.LOCK_EX | runtime.fcntl.LOCK_NB,
                    )
            finally:
                os.close(contender)
                runtime.fcntl.flock(fd, runtime.fcntl.LOCK_UN)
                os.close(fd)

            real_close = os.close

            def rejected(*, mode=0o600, has_acl=False, observed=None):
                lock_path.chmod(mode)
                with contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.object(runtime, "LOCK", str(lock_path)))
                    stack.enter_context(mock.patch.object(
                        runtime, "fd_has_extended_acl", return_value=has_acl,
                    ))
                    if observed is not None:
                        stack.enter_context(mock.patch.object(
                            runtime.os, "lstat", return_value=observed,
                        ))
                    closed = stack.enter_context(mock.patch.object(
                        runtime.os, "close", side_effect=real_close,
                    ))
                    with self.assertRaises(SystemExit):
                        runtime.acquire_manager_recovery_runner_lock(timeout=0)
                closed.assert_called_once()

            rejected(mode=0o644)
            rejected(has_acl=True)
            decoy = Path(outer_raw) / "decoy-runner.lock"
            decoy.write_bytes(b"")
            decoy.chmod(0o600)
            rejected(observed=os.lstat(decoy))

        lock_info = types.SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600, st_uid=self.uid,
        )
        events: list[str] = []

        def flock(fd, operation):
            self.assertEqual(fd, 82)
            if operation == runtime.fcntl.LOCK_EX | runtime.fcntl.LOCK_NB:
                events.append("contended")
                raise BlockingIOError
            self.assertEqual(operation, runtime.fcntl.LOCK_UN)
            events.append("unlock")

        with mock.patch.object(runtime.os, "open", return_value=82), \
                mock.patch.object(runtime.os, "fstat", return_value=lock_info), \
                mock.patch.object(runtime, "fd_has_extended_acl", return_value=False), \
                mock.patch.object(runtime.time, "monotonic", side_effect=[10.0, 10.0]), \
                mock.patch.object(runtime.time, "sleep") as slept, \
                mock.patch.object(runtime.fcntl, "flock", side_effect=flock), \
                mock.patch.object(
                    runtime.os, "close", side_effect=lambda fd: events.append(f"close-{fd}"),
                ), self.assertRaises(SystemExit):
            runtime.acquire_manager_recovery_runner_lock(timeout=0)
        self.assertEqual(events, ["contended", "unlock", "close-82"])
        slept.assert_not_called()

    def test_manager_recovery_waits_for_launcher_lock_and_supervised_cleanup(self) -> None:
        launcher_lock_fd = 80
        runner_lock_fd = 81
        launcher = {"pid": 42000, "started": "launcher"}
        manager = {"pid": 42001, "started": "manager"}
        runtime_authority = {"runtime_gid": self.gid}

        def file_info(inode: int):
            return types.SimpleNamespace(
                st_dev=1, st_ino=inode, st_mode=stat.S_IFREG | 0o600,
                st_uid=self.uid, st_gid=self.gid, st_size=0,
                st_mtime_ns=100 + inode, st_ctime_ns=200 + inode,
            )

        admission_info = file_info(10)
        launcher_lock_info = file_info(11)
        runner_lock_info = file_info(12)
        admission_identity = runtime._manager_admission_identity(admission_info)
        launcher_lock_identity = runtime._manager_admission_identity(launcher_lock_info)
        launcher_attempts = 0
        flock_events: list[tuple[int, int]] = []
        admission_observations = iter([
            admission_info, admission_info, FileNotFoundError(),
        ])

        def flock(fd, operation):
            nonlocal launcher_attempts
            flock_events.append((fd, operation))
            if fd == launcher_lock_fd and operation == (
                    runtime.fcntl.LOCK_EX | runtime.fcntl.LOCK_NB):
                launcher_attempts += 1
                if launcher_attempts == 1:
                    raise BlockingIOError

        def lstat(path):
            if path == runtime.MANAGER_ADMISSION:
                observed = next(admission_observations)
                if isinstance(observed, BaseException):
                    raise observed
                return observed
            if path == runtime.MANAGER_LAUNCHER_LOCK:
                return launcher_lock_info
            raise AssertionError(path)

        def fstat(fd):
            if fd == launcher_lock_fd:
                return launcher_lock_info
            if fd == runner_lock_fd:
                return runner_lock_info
            raise AssertionError(fd)

        with contextlib.ExitStack() as stack:
            snapshots = stack.enter_context(mock.patch.object(
                runtime, "process_snapshot",
                # Admission is present in the final pre-flock sample below,
                # then the launcher releases its lock. Only this under-lock
                # child sample is allowed to authorize completion.
                return_value=None,
            ))
            stack.enter_context(mock.patch.object(runtime.os, "lstat", side_effect=lstat))
            stack.enter_context(mock.patch.object(runtime.os, "fstat", side_effect=fstat))
            stack.enter_context(mock.patch.object(runtime.fcntl, "flock", side_effect=flock))
            slept = stack.enter_context(mock.patch.object(runtime.time, "sleep"))
            stack.enter_context(mock.patch.object(
                runtime, "fd_has_extended_acl", return_value=False,
            ))
            quiesced = stack.enter_context(mock.patch.object(runtime, "quiesce_service_uid"))
            stack.enter_context(mock.patch.object(
                runtime, "exact_runtime_identity",
                return_value=(self.operator, self.operator, self.shared),
            ))
            pids = stack.enter_context(mock.patch.object(
                runtime, "service_pids", return_value=[],
            ))
            closed = stack.enter_context(mock.patch.object(runtime.os, "close"))
            runtime.wait_for_manager_recovery_quiescence(
                runtime_authority, admission_identity, launcher, manager,
                launcher_lock_fd, launcher_lock_identity, runner_lock_fd,
            )

        snapshots.assert_called_once_with(manager["pid"])
        slept.assert_called_once_with(0.05)
        self.assertEqual(
            flock_events,
            [
                (launcher_lock_fd, runtime.fcntl.LOCK_EX | runtime.fcntl.LOCK_NB),
                (launcher_lock_fd, runtime.fcntl.LOCK_EX | runtime.fcntl.LOCK_NB),
            ],
        )
        quiesced.assert_called_once_with(runtime_authority)
        pids.assert_called_once_with(self.uid, self.gid)
        closed.assert_not_called()

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(
                runtime, "process_snapshot", return_value=manager,
            ))
            stack.enter_context(mock.patch.object(
                runtime.os, "lstat",
                side_effect=lambda path: (
                    admission_info if path == runtime.MANAGER_ADMISSION
                    else launcher_lock_info
                ),
            ))
            stack.enter_context(mock.patch.object(runtime.os, "fstat", side_effect=fstat))
            stack.enter_context(mock.patch.object(runtime.fcntl, "flock"))
            with self.assertRaises(SystemExit):
                runtime.wait_for_manager_recovery_quiescence(
                    runtime_authority, admission_identity, launcher, manager,
                    launcher_lock_fd, launcher_lock_identity, runner_lock_fd,
                )

    def test_manager_recovery_rebinds_before_signal_and_rejects_admission_change(self) -> None:
        args = argparse.Namespace(swarm_home="/fixed/swarm")
        runtime_authority = {"operator_uid": self.uid}
        authority = {"swarm_home": args.swarm_home}
        admission = {"launcher_pid": 42000, "manager_pid": 42001}
        admission_identity = (1, 2, 3)
        launcher_lock_fd = 97
        launcher_lock_identity = (4, 5, 6)
        runner_lock_fd = 98
        launcher = {"pid": admission["launcher_pid"], "started": "launcher"}
        manager = {"pid": admission["manager_pid"], "started": "manager"}

        def invoke(admissions, *, expect_failure=False,
                   launcher_lock_observations=(True, True),
                   final_process_change=False):
            events: list[str] = []
            selected_admissions = iter(admissions)
            selected_lock_observations = iter(launcher_lock_observations)
            validation_count = 0
            health_count = 0
            runner_lock_held = False

            def load_admission():
                events.append("admission")
                return next(selected_admissions)

            def validate(*_args):
                nonlocal validation_count
                validation_count += 1
                if final_process_change and validation_count == 3:
                    events.append("processes-changed")
                    return launcher, dict(manager, pid=43001)
                events.append("processes")
                return launcher, manager

            def health(*_args):
                nonlocal health_count
                health_count += 1
                if health_count == 2:
                    # Simulate a concurrent resume attempt at the last logical
                    # observation. It must remain unable to reach registration.
                    events.append(
                        "resume-blocked" if runner_lock_held else "registration-reached"
                    )
                events.append("health")
                return {}

            def open_launcher_lock():
                events.append("launcher-lock")
                return launcher_lock_fd, launcher_lock_identity

            def acquire_runner_lock():
                nonlocal runner_lock_held
                self.assertFalse(runner_lock_held)
                runner_lock_held = True
                events.append("runner-lock")
                return runner_lock_fd

            def flock(fd, operation):
                nonlocal runner_lock_held
                if (fd == launcher_lock_fd
                        and operation == runtime.fcntl.LOCK_EX | runtime.fcntl.LOCK_NB):
                    lock_held = next(selected_lock_observations)
                    events.append("launcher-lock-held" if lock_held else "launcher-lock-free")
                    if lock_held:
                        raise BlockingIOError
                elif fd == launcher_lock_fd and operation == runtime.fcntl.LOCK_UN:
                    events.append("launcher-lock-unlock")
                elif fd == runner_lock_fd and operation == runtime.fcntl.LOCK_UN:
                    self.assertTrue(runner_lock_held)
                    runner_lock_held = False
                    events.append("runner-lock-unlock")
                else:
                    self.fail(f"unexpected recovery lock operation: {(fd, operation)}")

            def kill(*_args):
                events.append("signal")

            def wait(*_args):
                self.assertTrue(runner_lock_held)
                events.append("quiescence-with-runner-lock")

            def close(fd):
                if fd == launcher_lock_fd:
                    events.append("launcher-lock-close")
                elif fd == runner_lock_fd:
                    self.assertFalse(runner_lock_held)
                    events.append("runner-lock-close")
                else:
                    self.fail(f"unexpected recovery fd close: {fd}")

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(
                    runtime, "canonical_dir", return_value=args.swarm_home,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "load_attestation", return_value=runtime_authority,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "exact_runtime_identity",
                    return_value=(self.operator, self.operator, self.shared),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "validate_manager_authority", return_value=authority,
                ))
                stack.enter_context(mock.patch.object(
                    runtime.os.path, "realpath", return_value=runtime.LIFECYCLE,
                ))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.dict(
                    runtime.os.environ, {"SUDO_UID": str(self.uid)}, clear=False,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "load_manager_admission", side_effect=load_admission,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "validate_manager_recovery_processes", side_effect=validate,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "query_stopped_manager_recovery_health", side_effect=health,
                ))
                opened = stack.enter_context(mock.patch.object(
                    runtime, "open_manager_recovery_launcher_lock",
                    side_effect=open_launcher_lock,
                ))
                runner_opened = stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_recovery_runner_lock",
                    side_effect=acquire_runner_lock,
                ))
                flocked = stack.enter_context(mock.patch.object(
                    runtime.fcntl, "flock", side_effect=flock,
                ))
                killed = stack.enter_context(mock.patch.object(
                    runtime.os, "kill", side_effect=kill,
                ))
                waited = stack.enter_context(mock.patch.object(
                    runtime, "wait_for_manager_recovery_quiescence", side_effect=wait,
                ))
                closed = stack.enter_context(mock.patch.object(
                    runtime.os, "close", side_effect=close,
                ))
                output = stack.enter_context(mock.patch.object(builtins, "print"))
                failure = None
                try:
                    runtime.command_recover_manager(args)
                except SystemExit as exc:
                    if not expect_failure:
                        raise
                    failure = exc
            self.assertNotIn("registration-reached", events)
            return (
                events, opened, runner_opened, flocked, killed, waited,
                closed, output, failure,
            )

        events, opened, runner_opened, flocked, killed, waited, closed, output, failure = invoke([
            (admission, admission_identity),
            (dict(admission), admission_identity),
            (dict(admission), admission_identity),
        ])
        self.assertIsNone(failure)
        self.assertEqual(
            events,
            [
                "admission", "processes", "health",
                "launcher-lock", "launcher-lock-held",
                "admission", "processes", "runner-lock",
                "resume-blocked", "health",
                "admission", "processes", "launcher-lock-held",
                "signal", "quiescence-with-runner-lock",
                "launcher-lock-unlock", "launcher-lock-close",
                "runner-lock-unlock", "runner-lock-close",
            ],
        )
        opened.assert_called_once_with()
        runner_opened.assert_called_once_with()
        killed.assert_called_once_with(admission["launcher_pid"], runtime.signal.SIGTERM)
        waited.assert_called_once_with(
            runtime_authority, admission_identity, launcher, manager,
            launcher_lock_fd, launcher_lock_identity, runner_lock_fd,
        )
        self.assertEqual(
            closed.call_args_list,
            [mock.call(launcher_lock_fd), mock.call(runner_lock_fd)],
        )
        output.assert_called_once_with(
            "swarm-codex-runtime: stopped zero-registration manager recovered",
        )

        changed_admission = dict(admission, manager_pid=43001)
        events, opened, runner_opened, flocked, killed, waited, closed, output, failure = invoke([
            (admission, admission_identity),
            (changed_admission, admission_identity),
        ], expect_failure=True, launcher_lock_observations=(True,))
        self.assertIsInstance(failure, SystemExit)
        self.assertEqual(
            events, [
                "admission", "processes", "health",
                "launcher-lock", "launcher-lock-held", "admission",
                "launcher-lock-unlock", "launcher-lock-close",
            ],
        )
        runner_opened.assert_not_called()
        killed.assert_not_called()
        waited.assert_not_called()
        closed.assert_called_once_with(launcher_lock_fd)
        output.assert_called_once_with(
            "swarm-codex-runtime: manager recovery admission changed before termination",
            file=runtime.sys.stderr,
        )

        events, opened, runner_opened, flocked, killed, waited, closed, output, failure = invoke([
            (admission, admission_identity),
        ], expect_failure=True, launcher_lock_observations=(False,))
        self.assertIsInstance(failure, SystemExit)
        self.assertEqual(
            events,
            [
                "admission", "processes", "health", "launcher-lock",
                "launcher-lock-free", "launcher-lock-unlock",
                "launcher-lock-unlock", "launcher-lock-close",
            ],
        )
        runner_opened.assert_not_called()
        killed.assert_not_called()
        waited.assert_not_called()
        closed.assert_called_once_with(launcher_lock_fd)
        output.assert_called_once_with(
            "swarm-codex-runtime: admitted manager launcher does not hold its singleton lock",
            file=runtime.sys.stderr,
        )

        events, opened, runner_opened, flocked, killed, waited, closed, output, failure = invoke([
            (admission, admission_identity),
            (dict(admission), admission_identity),
            (changed_admission, admission_identity),
        ], expect_failure=True, launcher_lock_observations=(True,))
        self.assertIsInstance(failure, SystemExit)
        self.assertEqual(
            events,
            [
                "admission", "processes", "health",
                "launcher-lock", "launcher-lock-held",
                "admission", "processes", "runner-lock",
                "resume-blocked", "health", "admission",
                "launcher-lock-unlock", "launcher-lock-close",
                "runner-lock-unlock", "runner-lock-close",
            ],
        )
        runner_opened.assert_called_once_with()
        killed.assert_not_called()
        waited.assert_not_called()
        self.assertEqual(
            closed.call_args_list,
            [mock.call(launcher_lock_fd), mock.call(runner_lock_fd)],
        )
        output.assert_called_once_with(
            "swarm-codex-runtime: manager recovery admission changed after the health proof",
            file=runtime.sys.stderr,
        )

        events, opened, runner_opened, flocked, killed, waited, closed, output, failure = invoke([
            (admission, admission_identity),
            (dict(admission), admission_identity),
            (dict(admission), admission_identity),
        ], expect_failure=True, launcher_lock_observations=(True,),
            final_process_change=True)
        self.assertIsInstance(failure, SystemExit)
        self.assertEqual(
            events,
            [
                "admission", "processes", "health",
                "launcher-lock", "launcher-lock-held",
                "admission", "processes", "runner-lock",
                "resume-blocked", "health",
                "admission", "processes-changed",
                "launcher-lock-unlock", "launcher-lock-close",
                "runner-lock-unlock", "runner-lock-close",
            ],
        )
        runner_opened.assert_called_once_with()
        killed.assert_not_called()
        waited.assert_not_called()
        self.assertEqual(
            closed.call_args_list,
            [mock.call(launcher_lock_fd), mock.call(runner_lock_fd)],
        )
        output.assert_called_once_with(
            "swarm-codex-runtime: manager recovery process identity changed after the health proof",
            file=runtime.sys.stderr,
        )

        events, opened, runner_opened, flocked, killed, waited, closed, output, failure = invoke([
            (admission, admission_identity),
            (dict(admission), admission_identity),
            (dict(admission), admission_identity),
        ], expect_failure=True, launcher_lock_observations=(True, False))
        self.assertIsInstance(failure, SystemExit)
        self.assertEqual(
            events,
            [
                "admission", "processes", "health",
                "launcher-lock", "launcher-lock-held",
                "admission", "processes", "runner-lock",
                "resume-blocked", "health",
                "admission", "processes", "launcher-lock-free",
                "launcher-lock-unlock", "launcher-lock-unlock",
                "launcher-lock-close", "runner-lock-unlock", "runner-lock-close",
            ],
        )
        runner_opened.assert_called_once_with()
        killed.assert_not_called()
        waited.assert_not_called()
        self.assertEqual(
            closed.call_args_list,
            [mock.call(launcher_lock_fd), mock.call(runner_lock_fd)],
        )
        output.assert_called_once_with(
            "swarm-codex-runtime: manager launcher exited after the health proof",
            file=runtime.sys.stderr,
        )

    def test_stale_manager_admission_is_authority_bound_before_termination(self) -> None:
        operator = types.SimpleNamespace(pw_uid=self.uid)
        authority = {
            "schema": launcher.AUTHORITY_SCHEMA,
            "operator_uid": self.uid,
            "operator_user": self.operator.pw_name,
            "operator_home": self.operator.pw_dir,
            "node_path": "/fixed/node",
            "node_sha256": "a" * 64,
            "manager_bundle_path": "/fixed/manager.mjs",
            "manager_bundle_sha256": "b" * 64,
            "manager_launcher_path": launcher.LAUNCHER,
            "manager_launcher_sha256": "c" * 64,
            "manager_python_path": "/fixed/python",
            "manager_python_sha256": "d" * 64,
            "manager_state_dir": "/fixed/state",
            "swarm_home": "/fixed/swarm",
            "manager_environment_sha256": "e" * 64,
        }
        manager_pid = 42001
        started = "Sun Jul 12 12:00:01 2026"
        stale = {
            key: value for key, value in authority.items()
            if key in launcher.ADMISSION_KEYS
        }
        stale.update({
            "schema": launcher.ADMISSION_SCHEMA,
            "nonce": "f" * 64,
            "launcher_pid": 42000,
            "launcher_started": "Sun Jul 12 12:00:00 2026",
            "manager_pid": manager_pid,
            "manager_started": started,
        })

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(launcher.os.path, "lexists", return_value=True))
            stack.enter_context(mock.patch.object(
                launcher, "load_json_authority", return_value=stale,
            ))
            stack.enter_context(mock.patch.object(
                launcher, "process_record",
                side_effect=[(self.uid, 1, started), None],
            ))
            stack.enter_context(mock.patch.object(
                launcher, "process_executable_path", return_value=authority["node_path"],
            ))
            stack.enter_context(mock.patch.object(
                launcher, "process_arguments",
                return_value=launcher.manager_arguments(authority),
            ))
            killed = stack.enter_context(mock.patch.object(launcher.os, "killpg"))
            unlinked = stack.enter_context(mock.patch.object(launcher.os, "unlink"))
            waited = stack.enter_context(mock.patch.object(launcher, "wait_for_runner_lock"))
            launcher.remove_stale_admission(authority, operator)
        killed.assert_called_once_with(manager_pid, launcher.signal.SIGTERM)
        unlinked.assert_called_once_with(launcher.ADMISSION)
        waited.assert_called_once_with()

        drifted = dict(stale, node_sha256="0" * 64)
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(launcher.os.path, "lexists", return_value=True))
            stack.enter_context(mock.patch.object(
                launcher, "load_json_authority", return_value=drifted,
            ))
            killed = stack.enter_context(mock.patch.object(launcher.os, "killpg"))
            unlinked = stack.enter_context(mock.patch.object(launcher.os, "unlink"))
            with self.assertRaises(SystemExit):
                launcher.remove_stale_admission(authority, operator)
        killed.assert_not_called()
        unlinked.assert_not_called()

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(launcher.os.path, "lexists", return_value=True))
            stack.enter_context(mock.patch.object(
                launcher, "load_json_authority", return_value=stale,
            ))
            stack.enter_context(mock.patch.object(
                launcher, "process_record", return_value=(self.uid, 1, started),
            ))
            stack.enter_context(mock.patch.object(
                launcher, "process_executable_path", return_value=authority["node_path"],
            ))
            stack.enter_context(mock.patch.object(
                launcher, "process_arguments", return_value=["/fixed/node", "--inspect"],
            ))
            killed = stack.enter_context(mock.patch.object(launcher.os, "killpg"))
            unlinked = stack.enter_context(mock.patch.object(launcher.os, "unlink"))
            with self.assertRaises(SystemExit):
                launcher.remove_stale_admission(authority, operator)
        killed.assert_not_called()
        unlinked.assert_not_called()

    def test_manager_child_denies_debugger_before_gate_drop_and_node_exec(self) -> None:
        ptrace = mock.Mock(return_value=0)
        libc = types.SimpleNamespace(ptrace=ptrace)
        with mock.patch.object(launcher.sys, "platform", "darwin"), \
                mock.patch.object(launcher.ctypes, "CDLL", return_value=libc):
            launcher.deny_debugger_attach()
        ptrace.assert_called_once_with(31, 0, None, 0)

        ptrace.reset_mock(return_value=True)
        ptrace.return_value = -1
        with mock.patch.object(launcher.sys, "platform", "darwin"), \
                mock.patch.object(launcher.ctypes, "CDLL", return_value=libc), \
                mock.patch.object(launcher.ctypes, "get_errno", return_value=1), \
                self.assertRaises(SystemExit) as denied:
            launcher.deny_debugger_attach()
        self.assertEqual(denied.exception.code, 126)
        ptrace.assert_called_once_with(31, 0, None, 0)

        events: list[str] = []
        authority = {
            "node_path": "/fixed/node",
            "manager_bundle_path": "/fixed/manager.mjs",
            "manager_state_dir": "/fixed/state",
            "swarm_home": "/fixed/swarm",
        }

        def fail_exec(*_args):
            events.append("exec")
            raise OSError("injected after order proof")

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(
                launcher, "deny_debugger_attach", side_effect=lambda: events.append("deny"),
            ))
            stack.enter_context(mock.patch.object(
                launcher.os, "setsid", side_effect=lambda: events.append("setsid"),
            ))
            stack.enter_context(mock.patch.object(
                launcher.os, "read", side_effect=lambda *_: (events.append("gate") or b"1"),
            ))
            stack.enter_context(mock.patch.object(launcher.os, "close"))
            stack.enter_context(mock.patch.object(launcher.os, "open", return_value=17))
            stack.enter_context(mock.patch.object(launcher.os, "dup2"))
            stack.enter_context(mock.patch.object(
                launcher.os, "initgroups", side_effect=lambda *_: events.append("initgroups"),
            ))
            stack.enter_context(mock.patch.object(
                launcher.os, "setgid", side_effect=lambda *_: events.append("setgid"),
            ))
            stack.enter_context(mock.patch.object(
                launcher.os, "setuid", side_effect=lambda *_: events.append("setuid"),
            ))
            stack.enter_context(mock.patch.object(launcher.os, "getuid", return_value=self.uid))
            stack.enter_context(mock.patch.object(launcher.os, "geteuid", return_value=self.uid))
            stack.enter_context(mock.patch.object(launcher.os, "getgid", return_value=self.gid))
            stack.enter_context(mock.patch.object(launcher.os, "getegid", return_value=self.gid))
            stack.enter_context(mock.patch.object(launcher.os, "getgroups", return_value=[self.gid]))
            stack.enter_context(mock.patch.object(
                launcher.os, "umask", side_effect=lambda *_: events.append("umask"),
            ))
            stack.enter_context(mock.patch.object(
                launcher.os, "chdir", side_effect=lambda *_: events.append("chdir"),
            ))
            stack.enter_context(mock.patch.object(launcher.os, "execve", side_effect=fail_exec))
            stack.enter_context(mock.patch.object(
                launcher.os, "_exit", side_effect=SystemExit(126),
            ))
            with self.assertRaises(SystemExit):
                launcher.child_exec(authority, self.operator, {}, 91)
        self.assertEqual(events, [
            "deny", "setsid", "gate", "initgroups", "setgid", "setuid",
            "umask", "chdir", "exec",
        ])

    def test_manager_launcher_sets_root_umask_before_lock_creation(self) -> None:
        events: list[object] = []
        operator = types.SimpleNamespace(pw_uid=self.uid)
        environment = {"SUDO_UID": str(self.uid)}
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(launcher.sys, "argv", [launcher.LAUNCHER]))
            stack.enter_context(mock.patch.object(launcher.os, "getuid", return_value=0))
            stack.enter_context(mock.patch.object(launcher.os, "geteuid", return_value=0))
            stack.enter_context(mock.patch.object(launcher.os, "environ", environment))
            stack.enter_context(mock.patch.object(
                launcher.os, "umask", side_effect=lambda mode: events.append(("umask", mode)),
            ))
            stack.enter_context(mock.patch.object(
                launcher, "load_and_validate_authority",
                return_value=({}, operator, {}),
            ))
            stack.enter_context(mock.patch.object(
                launcher, "open_lock", side_effect=lambda: (events.append("open_lock") or 92),
            ))
            stack.enter_context(mock.patch.object(launcher, "remove_stale_admission"))
            stack.enter_context(mock.patch.object(launcher, "supervise", return_value=0))
            stack.enter_context(mock.patch.object(launcher.os, "close"))
            with self.assertRaises(SystemExit) as stopped:
                launcher.main()
        self.assertEqual(stopped.exception.code, 0)
        self.assertEqual(events, [("umask", 0o077), "open_lock"])

    def test_root_runner_treats_keychain_storage_as_opaque(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            home = Path(outer) / "runtime"
            keychains = home / "Library" / "Keychains"
            keychains.mkdir(parents=True)
            home.chmod(0o700)
            (home / "Library").chmod(0o755)
            keychains.chmod(0o711)
            opaque = keychains / "platform-uuid"
            opaque.mkdir(mode=0o700)
            (opaque / "keychain-2.db").write_text("opaque securityd state\n")
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(home), "/usr/bin/false",
            ))
            with mock.patch.object(
                runner.os, "listdir", side_effect=AssertionError("must remain opaque"),
            ):
                runner.validate_runtime_keychain_dir(str(home), self.uid, self.gid)
            with mock.patch.object(
                runtime.os, "listdir", side_effect=AssertionError("must remain opaque"),
            ):
                runtime.validate_runtime_keychain_storage(runtime_user)
            keychains.chmod(0o755)
            with self.assertRaises(SystemExit):
                runner.validate_runtime_keychain_dir(str(home), self.uid, self.gid)

    def test_runtime_keychain_search_list_is_cleared_and_proven_empty(self) -> None:
        runtime_user = pwd.struct_passwd((
            "runtime", "x", self.uid, self.gid, "", str(Path.home()), "/usr/bin/false",
        ))
        calls: list[list[str]] = []

        def empty(_record, command, capture=False):
            calls.append(command)
            return completed(command)

        with mock.patch.object(runtime, "run_as_runtime", side_effect=empty), \
                mock.patch.object(runtime, "validate_runtime_keychain_storage"):
            runtime.establish_empty_keychain_search(runtime_user)
        self.assertEqual(calls, [
            ["/usr/bin/security", "list-keychains", "-d", "user", "-s"],
            ["/usr/bin/security", "list-keychains", "-d", "user"],
        ])

        with mock.patch.object(
            runtime,
            "run_as_runtime",
            return_value=completed(
                ["/usr/bin/security"], stdout='"/Users/runtime/login.keychain-db"\n',
            ),
        ), self.assertRaises(SystemExit):
            runtime.verify_runtime_keychain_search_empty(runtime_user)

        authority = {
            "runtime_home": str(Path.home()),
            "runtime_user": "runtime",
            "runtime_uid": self.uid,
            "runtime_primary_gid": self.gid,
            "codex_home": str(Path.home() / ".codex"),
            "node_path": "/usr/local/libexec/qofi-codex-toolchain/node",
        }
        with mock.patch.object(
            runner, "runtime_context_command", return_value=["/fixed/keychain-proof"],
        ), mock.patch.object(
            runner.subprocess, "run", return_value=completed(["keychain-proof"]),
        ) as execute:
            runner.verify_runtime_keychain_search_empty(authority)
        self.assertEqual(execute.call_args.kwargs["cwd"], str(Path.home()))

        with mock.patch.object(
            runner, "runtime_context_command", return_value=["/fixed/keychain-proof"],
        ), mock.patch.object(
            runner.subprocess,
            "run",
            return_value=completed(["keychain-proof"], stdout='"login.keychain-db"\n'),
        ), self.assertRaises(SystemExit):
            runner.verify_runtime_keychain_search_empty(authority)

    def test_secure_copy_rejects_symlinks_and_detects_mutation(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            source = Path(outer) / "source"
            source.mkdir(mode=0o755)
            payload = source / "payload"
            payload.write_bytes(b"a" * 8192)
            destination = Path(outer) / "copy"
            runtime.copy_trusted_file(str(payload), str(destination), self.uid)
            self.assertEqual(destination.read_bytes(), payload.read_bytes())

            tree = source / "tree"
            tree.mkdir()
            (tree / "escape").symlink_to("/private/etc/passwd")
            with self.assertRaises(SystemExit):
                runtime.copy_trusted_tree(str(tree), str(Path(outer) / "tree-copy"), self.uid)

            changing = source / "changing"
            changing.write_bytes(b"before")
            original_read = os.read
            changed = False

            def mutate_after_read(fd: int, size: int) -> bytes:
                nonlocal changed
                data = original_read(fd, size)
                if data and not changed:
                    changed = True
                    with open(changing, "ab") as handle:
                        handle.write(b"after")
                return data

            with mock.patch.object(runtime.os, "read", side_effect=mutate_after_read):
                with self.assertRaises(SystemExit):
                    runtime.copy_trusted_file(
                        str(changing), str(Path(outer) / "changing-copy"), self.uid,
                    )

    def test_mutable_resolver_runs_only_after_operator_drop_and_paths_are_fd_validated(self) -> None:
        opened: list[str] = []

        def open_source(path, *_args, **_kwargs):
            opened.append(path)
            return os.open("/dev/null", os.O_RDONLY)

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "validate_source"))
            dropped = stack.enter_context(mock.patch.object(
                runtime,
                "run_as_operator_bounded",
                return_value="/trusted/node\t/trusted/codex.js\n",
            ))
            stack.enter_context(mock.patch.object(runtime, "open_trusted_source", side_effect=open_source))
            node, script = runtime.resolve_operator_codex(self.operator, str(ROOT), str(ROOT))
        self.assertEqual((node, script), ("/trusted/node", "/trusted/codex.js"))
        self.assertEqual(opened, ["/trusted/node", "/trusted/codex.js"])
        command = dropped.call_args.args[1]
        self.assertEqual(command[:3], ["/usr/bin/python3", "-I", "-B"])
        self.assertEqual(command[-2:], ["exec-plan", "codex"])

    def test_bounded_operator_helper_also_runs_from_direct_operator_verify(self) -> None:
        output = runtime.run_as_operator_bounded(
            self.operator,
            ["/bin/echo", "operator-ok"],
            cwd=str(ROOT),
            label="operator fixture",
        )
        self.assertEqual(output, "operator-ok\n")

    def test_uid_wide_quiescence_validates_identity_before_process_enumeration(self) -> None:
        authority = {"runtime_uid": self.uid + 100}
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "exact_runtime_identity", side_effect=SystemExit(2)))
            processes = stack.enter_context(mock.patch.object(runtime, "service_pids"))
            with self.assertRaises(SystemExit):
                runtime.quiesce_service_uid(authority)
        processes.assert_not_called()

    def test_runner_uid_wide_kill_validates_identity_before_process_enumeration(self) -> None:
        authority = {"runtime_uid": self.uid + 100}
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runner, "validate_exact_os_identity", side_effect=SystemExit(70)))
            processes = stack.enter_context(mock.patch.object(runner, "runtime_pids"))
            with self.assertRaises(SystemExit):
                runner.kill_runtime_uid(authority)
        processes.assert_not_called()

    def test_quiescence_ignores_only_exact_macos_runtime_infrastructure(self) -> None:
        service_uid = self.uid + 100
        service_gid = self.gid + 100
        snapshots = [
            {"pid": pid, "ppid": 1, "pgid": pid, "session": 0,
             "uid": service_uid, "ruid": service_uid, "svuid": service_uid,
             "gid": service_gid, "rgid": service_gid, "svgid": service_gid,
             "started": f"fixture-{pid}"}
            for pid in (111, 222, 333)
        ]
        with mock.patch.object(runtime, "process_snapshots", return_value=snapshots), \
                mock.patch.object(runtime, "allowed_runtime_infrastructure_pid", return_value=111):
            self.assertEqual(runtime.service_pids(service_uid, service_gid), [222, 333])
        with mock.patch.object(runner, "process_snapshots", return_value=snapshots), \
                mock.patch.object(runner, "allowed_runtime_infrastructure_pid", return_value=111):
            self.assertEqual(runner.runtime_pids(service_uid, service_gid), [222, 333])

    def test_macos_runtime_infrastructure_exception_is_exact(self) -> None:
        service_uid = self.uid + 100
        service_gid = self.gid + 100
        snapshot = {
            "pid": 111, "ppid": 1, "pgid": 111, "session": 0,
            "uid": service_uid, "ruid": service_uid, "svuid": service_uid,
            "gid": service_gid, "rgid": service_gid, "svgid": service_gid,
            "started": "Sun Jul 12 00:00:00 2026",
        }
        lifecycle_info = types.SimpleNamespace(
            st_uid=0, st_gid=0, st_nlink=1, st_flags=0x00080000,
        )
        runner_info = types.SimpleNamespace(
            st_uid=0, st_gid=0, st_nlink=1, st_mode=stat.S_IFREG | 0o755,
            st_size=1024, st_flags=0x00080000,
        )
        with mock.patch.object(runtime.sys, "platform", "darwin"), \
                mock.patch.object(
                    runtime, "process_executable_path",
                    return_value=runtime.MACOS_RUNTIME_INFRASTRUCTURE,
                ), mock.patch.object(
                    runtime, "validate_root_authority_file", return_value=lifecycle_info,
                ), mock.patch.object(runtime.os.path, "realpath", side_effect=lambda path: path), \
                mock.patch.object(
                    runtime, "exact_process_command",
                    return_value="/usr/sbin/distnoted agent",
                ), mock.patch.object(runtime, "process_snapshot", return_value=snapshot):
            self.assertEqual(
                runtime.allowed_runtime_infrastructure_pid([snapshot], service_uid, service_gid),
                111,
            )
            self.assertIsNone(runtime.allowed_runtime_infrastructure_pid(
                [snapshot, dict(snapshot, pid=222, pgid=222)], service_uid, service_gid,
            ))
        with mock.patch.object(runner.sys, "platform", "darwin"), \
                mock.patch.object(
                    runner, "process_executable_path",
                    return_value=runner.MACOS_RUNTIME_INFRASTRUCTURE,
                ), mock.patch.object(runner, "safe_root_file", return_value=runner_info), \
                mock.patch.object(runner.os.path, "realpath", side_effect=lambda path: path), \
                mock.patch.object(
                    runner, "exact_process_command",
                    return_value="/usr/sbin/distnoted agent",
                ) as command, mock.patch.object(runner, "process_snapshot", return_value=snapshot):
            self.assertEqual(
                runner.allowed_runtime_infrastructure_pid([snapshot], service_uid, service_gid),
                111,
            )
            command.return_value = "/usr/sbin/distnoted hostile"
            self.assertIsNone(
                runner.allowed_runtime_infrastructure_pid([snapshot], service_uid, service_gid),
            )

    def test_runner_parent_binding_rejects_pid_reuse_and_non_ancestry(self) -> None:
        parent = os.getpid()
        authority = {"operator_uid": self.uid}
        record = (self.uid, os.getppid(), "Sat Jul 11 12:00:00 2026")
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(runner.os.environ, {"SUDO_UID": str(self.uid)}))
            stack.enter_context(mock.patch.object(runner.os, "geteuid", return_value=0))
            stack.enter_context(mock.patch.object(runner.os, "getuid", return_value=0))
            ancestry = stack.enter_context(mock.patch.object(runner, "is_ancestor", return_value=True))
            process = stack.enter_context(mock.patch.object(runner, "process_record", return_value=record))
            runner.verify_invoker(authority, parent)
            self.assertTrue(runner.parent_is_live(parent, self.uid))
            process.return_value = (self.uid, os.getppid(), "Sat Jul 11 12:00:01 2026")
            self.assertFalse(runner.parent_is_live(parent, self.uid))
            process.return_value = record
            ancestry.return_value = False
            self.assertFalse(runner.parent_is_live(parent, self.uid))

    def _workspace_runner_args(self) -> list[str]:
        filesystem = (
            f'permissions.{runner.WORKSPACE_PROFILE}.filesystem='
            '{":root"="deny",":minimal"="read",":tmpdir"="deny",":slash_tmp"="deny"}'
        )
        args = [
            "exec", "--json", "--ignore-user-config", "--ignore-rules",
            "--enable", "multi_agent",
        ]
        for feature in runner.WORKSPACE_DISABLED_FEATURES:
            args.extend(["--disable", feature])
        args.extend([
            "--skip-git-repo-check",
            "-c", f'default_permissions="{runner.WORKSPACE_PROFILE}"',
            "-c", f'permissions.{runner.WORKSPACE_PROFILE}.extends=":workspace"',
            "-c", filesystem,
            "-c", f"permissions.{runner.WORKSPACE_PROFILE}.network.enabled=false",
            "-c", 'approval_policy="never"',
            "-c", 'forced_login_method="chatgpt"',
            "-c", 'cli_auth_credentials_store="file"',
            "-c", "allow_login_shell=false",
            "-c", 'web_search="disabled"',
            "-c", 'shell_environment_policy.inherit="all"',
            "-c", "shell_environment_policy.set={}",
            "-c", "shell_environment_policy.experimental_use_profile=false",
            "-c", "shell_environment_policy.ignore_default_excludes=false",
            "-c", "mcp_servers={}",
            "-c", 'model_reasoning_effort="ultra"',
            "-c", 'model="gpt-5.6-sol"',
            "-",
        ])
        return args

    def _review_runner_args(self) -> list[str]:
        args = [
            "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
            "--skip-git-repo-check", "-C", str(ROOT),
        ]
        for feature in runner.REVIEW_DISABLED_FEATURES:
            args.extend(["--disable", feature])
        for value in (
            'default_permissions="qofi-review-readonly"',
            'permissions.qofi-review-readonly.filesystem={":root"="deny",":minimal"="read",":workspace_roots"={"."="deny"},":tmpdir"="deny",":slash_tmp"="deny"}',
            "permissions.qofi-review-readonly.network.enabled=false",
            "allow_login_shell=false", 'web_search="disabled"',
            'approval_policy="never"', 'forced_login_method="chatgpt"',
            'cli_auth_credentials_store="file"',
            "project_doc_max_bytes=0", "mcp_servers={}",
            'shell_environment_policy.inherit="core"',
            "shell_environment_policy.ignore_default_excludes=false",
            'model="gpt-5.6-sol"',
            'model_reasoning_effort="ultra"',
        ):
            args.extend(["-c", value])
        args.extend(["review", "-"])
        return args

    def test_runner_argv_grammar_accepts_only_hardened_production_shapes(self) -> None:
        authority = {
            "runtime_home": "/Users/_qofi_runtime_fixture",
            "runtime_uid": self.uid + 100,
            "launchd_canary_name": "QOFI_CODEX_RUNTIME_CANARY_TEST1234",
        }
        parent_pid = os.getpid()
        runner.validate_command_grammar(
            "workspace", ["--version"], authority, parent_pid=parent_pid,
        )
        runner.validate_command_grammar(
            "workspace", [
                "login",
                "-c", 'forced_login_method="chatgpt"',
                "-c", 'cli_auth_credentials_store="file"',
                "status",
            ], authority, parent_pid=parent_pid,
        )
        runner.validate_command_grammar(
            "workspace", self._workspace_runner_args(), authority,
            parent_pid=parent_pid,
        )
        cpo_workspace = self._workspace_runner_args()
        cpo_workspace[cpo_workspace.index('model_reasoning_effort="ultra"')] = (
            'model_reasoning_effort="medium"'
        )
        runner.validate_command_grammar(
            "workspace", cpo_workspace, authority, parent_pid=parent_pid,
        )
        runner.validate_command_grammar(
            "review", self._review_runner_args(), authority, parent_pid=parent_pid,
        )
        runner.validate_command_grammar(
            "app-server", list(runner.APP_SERVER_ARGS), authority,
            parent_pid=parent_pid,
        )

        filesystem = (
            f'permissions.{runner.WORKSPACE_PROFILE}.filesystem='
            '{":root"="deny",":minimal"="read",":tmpdir"="deny",":slash_tmp"="deny"}'
        )
        sandbox = [
            "sandbox", "-P", runner.WORKSPACE_PROFILE, "-C", str(ROOT),
            "-c", f'permissions.{runner.WORKSPACE_PROFILE}.extends=":workspace"',
            "-c", filesystem,
            "-c", f"permissions.{runner.WORKSPACE_PROFILE}.network.enabled=false",
            "-c", 'shell_environment_policy.inherit="none"',
            "-c", "shell_environment_policy.set={}",
            "-c", "shell_environment_policy.experimental_use_profile=false",
            "--", "/usr/bin/id", "-u",
        ]
        runner.validate_command_grammar(
            "workspace", sandbox, authority, parent_pid=parent_pid,
        )
        sandbox_prefix = sandbox[:sandbox.index("--") + 1]
        hardened_canaries = [
            [
                "/bin/sh", "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT,
                "qofi-toolchain-probe", "git", "/usr/bin/git",
            ],
            [
                "/bin/sh", "-c", runner.SANDBOX_GIT_READ_SCRIPT,
                "qofi-git-read-canary", "/usr/bin/git", str(ROOT),
            ],
            [
                "/bin/sh", "-c", runner.SANDBOX_WORKSPACE_WRITE_SCRIPT,
                "qofi-runtime-write-canary",
                str(ROOT / f".qofi-runtime-write-canary-{parent_pid}"),
                str(ROOT / f".qofi-runtime-write-canary-{parent_pid}-deleted"),
            ],
            [
                "/bin/sh", "-c", runner.SANDBOX_DETACHED_SCRIPT,
                "qofi-runtime-detached-canary",
                str(ROOT / f".qofi-runtime-detached-canary-{parent_pid}"),
            ],
            ["/bin/launchctl", "getenv", authority["launchd_canary_name"]],
            ["/usr/bin/security", "list-keychains", "-d", "user"],
        ]
        for command in hardened_canaries:
            runner.validate_command_grammar(
                "workspace", [*sandbox_prefix, *command], authority,
                parent_pid=parent_pid,
            )
        with tempfile.TemporaryDirectory(dir=Path.home()) as operator_home:
            turn_tmp = (
                Path(operator_home) / ".codex" / "channels" / "discord-alpha"
                / "tool-tmp" / "message_123"
            )
            turn_tmp.mkdir(parents=True, mode=0o700)
            turn_tmp.chmod(0o700)
            fake_operator = pwd.struct_passwd((
                self.operator.pw_name, "x", self.uid, self.gid, "",
                operator_home, self.operator.pw_shell,
            ))
            dynamic = (
                f'permissions.{runner.WORKSPACE_PROFILE}.filesystem='
                f'{{":root"="deny",":minimal"="read",":tmpdir"="deny",":slash_tmp"="deny",'
                f'{json.dumps(str(turn_tmp))}="write"}}'
            )
            with mock.patch.object(runner.pwd, "getpwuid", return_value=fake_operator):
                runner.validate_filesystem_override(
                    dynamic, {**authority, "operator_uid": self.uid}, str(ROOT),
                )

    def test_workspace_filesystem_requires_the_complete_temp_deny_baseline(self) -> None:
        authority = {"runtime_home": "/Users/_qofi_runtime_fixture"}
        prefix = f"permissions.{runner.WORKSPACE_PROFILE}.filesystem="

        def encoded(entries: dict[str, str]) -> str:
            return prefix + "{" + ",".join(
                f"{json.dumps(key)}={json.dumps(value)}"
                for key, value in entries.items()
            ) + "}"

        baseline = {
            ":root": "deny", ":minimal": "read",
            ":tmpdir": "deny", ":slash_tmp": "deny",
        }
        runner.validate_filesystem_override(encoded(baseline), authority, str(ROOT))

        invalid = []
        for key in baseline:
            invalid.append({name: value for name, value in baseline.items() if name != key})
        for key, access in (
            (":root", "read"), (":minimal", "deny"),
            (":tmpdir", "read"), (":slash_tmp", "read"),
        ):
            invalid.append({**baseline, key: access})
        invalid.append({**baseline, ":unknown_tmp": "deny"})

        for entries in invalid:
            with self.subTest(entries=entries), self.assertRaises(SystemExit):
                runner.validate_filesystem_override(encoded(entries), authority, str(ROOT))

    def test_toolchain_canary_is_exact_ordered_bounded_and_semantic(self) -> None:
        authority = {"runtime_home": "/Users/_qofi_runtime_fixture"}
        parent_pid = os.getpid()
        names = sorted(set(runner.TOOL_PROBES) - {"yarn"})
        parameters = [
            value for name in names for value in (name, f"/trusted/{name}")
        ]
        with mock.patch.object(runner, "validate_sandbox_tool") as validate:
            runner.validate_sandbox_shell_command(
                [
                    "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT,
                    "qofi-toolchain-probe", *parameters,
                ],
                authority, str(ROOT), parent_pid,
            )
        self.assertEqual(
            validate.call_args_list,
            [mock.call(f"/trusted/{name}", {name}) for name in names],
        )

        malformed = [
            [],
            ["git"],
            ["python3", "/usr/bin/python3", "git", "/usr/bin/git"],
            ["git", "/usr/bin/git", "git", "/usr/bin/git"],
            ["ruby", "/usr/bin/ruby"],
            [
                value
                for name in sorted(runner.TOOL_PROBES)
                for value in (name, f"/trusted/{name}")
            ],
        ]
        with mock.patch.object(runner, "validate_sandbox_tool"):
            for bad_parameters in malformed:
                with self.subTest(parameters=bad_parameters), self.assertRaises(SystemExit):
                    runner.validate_sandbox_shell_command(
                        [
                            "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT,
                            "qofi-toolchain-probe", *bad_parameters,
                        ],
                        authority, str(ROOT), parent_pid,
                    )
            with self.assertRaises(SystemExit):
                runner.validate_sandbox_shell_command(
                    [
                        "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT + " ",
                        "qofi-toolchain-probe", "git", "/usr/bin/git",
                    ],
                    authority, str(ROOT), parent_pid,
                )

        # A valid root executable still cannot stand in for another semantic
        # name in the pair vector.
        with self.assertRaises(SystemExit):
            runner.validate_sandbox_shell_command(
                [
                    "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT,
                    "qofi-toolchain-probe", "python3", "/usr/bin/git",
                ],
                authority, str(ROOT), parent_pid,
            )

    def test_toolchain_canary_preserves_special_argv_and_exact_pnpm_pin(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            log = outer / "argv.log"

            def tool(name: str, version: str = "ok") -> str:
                path = outer / name
                path.write_text(
                    "#!/bin/sh\n"
                    f"printf '%s:%s\\n' {name!r} \"$*\" >> {str(log)!r}\n"
                    f"printf '%s\\n' {version!r}\n",
                )
                path.chmod(0o700)
                return str(path)

            pairs = [
                "go", tool("go"),
                "pnpm", tool("pnpm", runner.SUPPORTED_PNPM_VERSION),
                "xcodebuild", tool("xcodebuild"),
                "xcrun", tool("xcrun"),
            ]
            result = subprocess.run(
                [
                    "/bin/sh", "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT,
                    "qofi-toolchain-probe", *pairs,
                ],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                log.read_text().splitlines(),
                ["go:version", "pnpm:--version", "xcodebuild:-version", "xcrun:--find clang"],
            )

            rejected = subprocess.run(
                [
                    "/bin/sh", "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT,
                    "qofi-toolchain-probe", "pnpm", tool("wrong-pnpm", "9.12.4"),
                ],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(rejected.returncode, 69)
            self.assertIn("pnpm must be exactly 9.12.3", rejected.stderr)

            extra_newline = subprocess.run(
                [
                    "/bin/sh", "-c", runner.SANDBOX_TOOL_PROBE_SCRIPT,
                    "qofi-toolchain-probe",
                    "pnpm", tool("extra-newline-pnpm", "9.12.3\n"),
                ],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(extra_newline.returncode, 69)

    def test_git_read_canary_trusts_only_the_validated_workspace(self) -> None:
        commands = runner.SANDBOX_GIT_READ_SCRIPT.splitlines()
        self.assertEqual(commands[0], "set -eu")
        self.assertEqual(len(commands), 4)
        for command in commands[1:]:
            self.assertIn('-c safe.directory="$2"', command)
            self.assertNotIn("safe.directory=*", command)
            self.assertLess(
                command.index('-c safe.directory="$2"'),
                command.index('-C "$2"'),
            )

    def test_direct_operator_sudo_cannot_invoke_unsafe_codex_commands(self) -> None:
        authority = {
            "runtime_home": "/Users/_qofi_runtime_fixture",
            "runtime_uid": self.uid + 100,
            "launchd_canary_name": "QOFI_CODEX_RUNTIME_CANARY_TEST1234",
        }
        parent_pid = os.getpid()
        unsafe = [
            ["logout"],
            ["login"],
            ["exec", "--dangerously-bypass-approvals-and-sandbox", "-"],
            ["exec", "--sandbox", "danger-full-access", "-"],
            ["exec", "-c", 'approval_policy="on-request"', "-"],
        ]
        for command in unsafe:
            with self.subTest(command=command), self.assertRaises(SystemExit):
                runner.validate_command_grammar(
                    "workspace", command, authority, parent_pid=parent_pid,
                )
        weakened = self._workspace_runner_args()
        index = weakened.index(
            f'permissions.{runner.WORKSPACE_PROFILE}.filesystem='
            '{":root"="deny",":minimal"="read",":tmpdir"="deny",":slash_tmp"="deny"}',
        )
        weakened[index] = (
            f'permissions.{runner.WORKSPACE_PROFILE}.filesystem='
            '{":root"="read",":minimal"="read",":tmpdir"="deny",":slash_tmp"="deny"}'
        )
        with self.assertRaises(SystemExit):
            runner.validate_command_grammar(
                "workspace", weakened, authority, parent_pid=parent_pid,
            )
        unsupported_effort = self._workspace_runner_args()
        unsupported_effort[
            unsupported_effort.index('model_reasoning_effort="ultra"')
        ] = 'model_reasoning_effort="high"'
        with self.assertRaises(SystemExit):
            runner.validate_command_grammar(
                "workspace", unsupported_effort, authority, parent_pid=parent_pid,
            )
        review = self._review_runner_args()
        review.insert(-1, "--dangerously-bypass-approvals-and-sandbox")
        with self.assertRaises(SystemExit):
            runner.validate_command_grammar(
                "review", review, authority, parent_pid=parent_pid,
            )
        generic_exec = self._review_runner_args()
        generic_exec[-2:] = ["-"]
        with self.assertRaises(SystemExit):
            runner.validate_command_grammar(
                "review", generic_exec, authority, parent_pid=parent_pid,
            )
        filesystem = (
            f'permissions.{runner.WORKSPACE_PROFILE}.filesystem='
            '{":root"="deny",":minimal"="read",":tmpdir"="deny",":slash_tmp"="deny"}'
        )
        sandbox_prefix = [
            "sandbox", "-P", runner.WORKSPACE_PROFILE, "-C", str(ROOT),
            "-c", f'permissions.{runner.WORKSPACE_PROFILE}.extends=":workspace"',
            "-c", filesystem,
            "-c", f"permissions.{runner.WORKSPACE_PROFILE}.network.enabled=false",
            "-c", 'shell_environment_policy.inherit="none"',
            "-c", "shell_environment_policy.set={}",
            "-c", "shell_environment_policy.experimental_use_profile=false",
            "--",
        ]
        for command in (
            ["/bin/sh", "-c", "id"],
            ["/bin/launchctl", "submit", "-l", "operator-job", "--",
             "/usr/bin/touch", str(ROOT / "escaped")],
            ["/usr/bin/security", "find-generic-password", "-ga", "secret"],
            ["/usr/bin/git", "config", "--global", "credential.helper"],
        ):
            with self.subTest(sandbox_command=command), self.assertRaises(SystemExit):
                runner.validate_command_grammar(
                    "workspace", [*sandbox_prefix, *command], authority,
                    parent_pid=parent_pid,
                )
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(
                runner.sys, "argv", [
                    str(RUNNER_SOURCE), "--parent-pid", str(parent_pid), "--", "logout",
                ],
            ))
            stack.enter_context(mock.patch.object(
                runner, "validate_authority", return_value=authority,
            ))
            invoker = stack.enter_context(mock.patch.object(runner, "verify_invoker"))
            child = stack.enter_context(mock.patch.object(runner, "run_child"))
            with self.assertRaises(SystemExit):
                runner.main()
        invoker.assert_not_called()
        child.assert_not_called()

    def test_app_server_runner_accepts_only_exact_hardened_stdio_argv(self) -> None:
        authority = {"runtime_home": "/Users/_qofi_runtime_fixture"}
        parent_pid = os.getpid()
        expected = list(runner.APP_SERVER_ARGS)

        self.assertEqual(expected[:4], [
            "app-server", "--listen", "stdio://", "--strict-config",
        ])
        self.assertIn('forced_login_method="chatgpt"', expected)
        self.assertIn('cli_auth_credentials_store="file"', expected)
        self.assertIn('model_provider="openai"', expected)
        self.assertIn("model_providers={}", expected)
        self.assertNotIn("mcp_servers={}", expected)
        self.assertIn("analytics.enabled=false", expected)
        self.assertNotIn("unix://", " ".join(expected))
        self.assertNotIn("ws://", " ".join(expected))
        runner.validate_command_grammar(
            "app-server", expected, authority, parent_pid=parent_pid,
        )

        refused = [
            ["app-server"],
            ["app-server", "--stdio"],
            ["app-server", "--listen", "unix://"],
            ["app-server", "--listen", "unix:///private/tmp/qofi.sock"],
            ["app-server", "--listen", "ws://127.0.0.1:4500"],
            ["app-server", "--listen=stdio://"],
            [*expected, "--ws-auth", "capability-token"],
            [*expected, "-c", 'approval_policy="on-request"'],
        ]
        for argv in refused:
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                runner.validate_command_grammar(
                    "app-server", argv, authority, parent_pid=parent_pid,
                )

    def test_app_server_mode_keeps_global_lock_and_cleans_runtime_on_exit(self) -> None:
        parent_pid = os.getpid()
        authority = {
            "operator_uid": self.uid,
            "runtime_uid": self.uid + 100,
            "runtime_home": "/Users/_qofi_runtime_fixture",
        }
        events: list[str] = []

        def acquire(_mode, _parent_pid, _operator_uid):
            events.append("lock")
            return 93

        def admit(_authority, _parent_pid):
            events.append("admission")

        def kill(_authority):
            events.append("kill")

        def child(_authority, _parent_pid, mode, argv):
            self.assertEqual(mode, "app-server")
            self.assertEqual(argv, list(runner.APP_SERVER_ARGS))
            self.assertEqual(events, ["admission", "lock", "kill"])
            events.append("child")
            return 0

        def close(fd):
            self.assertEqual(fd, 93)
            events.append("close")

        argv = [
            str(RUNNER_SOURCE), "--mode", "app-server",
            "--parent-pid", str(parent_pid), "--", *runner.APP_SERVER_ARGS,
        ]
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runner.sys, "argv", argv))
            stack.enter_context(mock.patch.object(
                runner, "validate_authority", return_value=authority,
            ))
            stack.enter_context(mock.patch.object(runner, "verify_invoker"))
            stack.enter_context(mock.patch.object(
                runner, "parent_is_live", return_value=True,
            ))
            stack.enter_context(mock.patch.object(
                runner, "verify_app_server_manager_admission", side_effect=admit,
            ))
            stack.enter_context(mock.patch.object(
                runner, "lock_global", side_effect=acquire,
            ))
            stack.enter_context(mock.patch.object(
                runner, "kill_runtime_uid", side_effect=kill,
            ))
            stack.enter_context(mock.patch.object(
                runner, "verify_runtime_keychain_search_empty",
            ))
            stack.enter_context(mock.patch.object(
                runner, "run_child", side_effect=child,
            ))
            stack.enter_context(mock.patch.object(runner.os, "close", side_effect=close))
            with self.assertRaises(SystemExit) as stopped:
                runner.main()
        self.assertEqual(stopped.exception.code, 0)
        self.assertEqual(
            events, ["admission", "lock", "kill", "child", "kill", "close"],
        )

    def test_direct_operator_app_server_is_refused_before_global_lock(self) -> None:
        parent_pid = os.getpid()
        authority = {
            "operator_uid": self.uid,
            "runtime_uid": self.uid + 100,
            "runtime_home": "/Users/_qofi_runtime_fixture",
        }
        argv = [
            str(RUNNER_SOURCE), "--mode", "app-server",
            "--parent-pid", str(parent_pid), "--", *runner.APP_SERVER_ARGS,
        ]
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runner.sys, "argv", argv))
            stack.enter_context(mock.patch.object(
                runner, "validate_authority", return_value=authority,
            ))
            invoker = stack.enter_context(mock.patch.object(runner, "verify_invoker"))
            admission = stack.enter_context(mock.patch.object(
                runner, "verify_app_server_manager_admission", side_effect=SystemExit(2),
            ))
            lock = stack.enter_context(mock.patch.object(runner, "lock_global"))
            child = stack.enter_context(mock.patch.object(runner, "run_child"))
            with self.assertRaises(SystemExit):
                runner.main()
        invoker.assert_called_once_with(authority, parent_pid)
        admission.assert_called_once_with(authority, parent_pid)
        lock.assert_not_called()
        child.assert_not_called()

    def test_telemetry_runner_quiesces_under_global_lock_before_reading(self) -> None:
        parent_pid = os.getpid()
        authority = {
            "operator_uid": self.uid,
            "runtime_uid": self.uid + 100,
            "runtime_home": "/Users/_qofi_runtime_fixture",
            "codex_home": "/Users/_qofi_runtime_fixture/.codex-profiles/team-a",
        }
        events: list[str] = []

        def acquire(mode, _parent_pid, _operator_uid):
            self.assertEqual(mode, "telemetry")
            events.append("lock")
            return 94

        def kill(_authority):
            events.append("kill")

        def keychain(_authority):
            events.append("keychain")

        def telemetry(_authority):
            self.assertEqual(events, ["lock", "kill", "keychain"])
            events.append("telemetry")
            return 0

        argv = [
            str(RUNNER_SOURCE), "--telemetry", "--profile", "team-a",
            "--parent-pid", str(parent_pid),
        ]
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runner.sys, "argv", argv))
            stack.enter_context(mock.patch.object(
                runner, "validate_authority", return_value=authority,
            ))
            stack.enter_context(mock.patch.object(runner, "verify_invoker"))
            stack.enter_context(mock.patch.object(runner, "parent_is_live", return_value=True))
            stack.enter_context(mock.patch.object(runner, "lock_global", side_effect=acquire))
            stack.enter_context(mock.patch.object(runner, "kill_runtime_uid", side_effect=kill))
            stack.enter_context(mock.patch.object(
                runner, "verify_runtime_keychain_search_empty", side_effect=keychain,
            ))
            stack.enter_context(mock.patch.object(
                runner, "emit_latest_telemetry", side_effect=telemetry,
            ))
            stack.enter_context(mock.patch.object(runner.os, "close"))
            with self.assertRaises(SystemExit) as stopped:
                runner.main()
        self.assertEqual(stopped.exception.code, 0)
        self.assertEqual(events, ["lock", "kill", "keychain", "telemetry", "kill"])

    def test_manager_admission_binds_authority_processes_hashes_argv_and_acl(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            state_dir = outer / "state"
            swarm_home = outer / "swarm"
            state_dir.mkdir(mode=0o700)
            swarm_home.mkdir(mode=0o755)
            state_dir.chmod(0o700)
            swarm_home.chmod(0o755)
            manager_pid = 41001
            launcher_pid = 41000
            manager_started = "Sun Jul 12 12:00:01 2026"
            launcher_started = "Sun Jul 12 12:00:00 2026"
            node = "/usr/local/libexec/qofi-codex-toolchain/node"
            bundle = runner.MANAGER_BUNDLE
            launcher_path = runner.MANAGER_LAUNCHER
            python = (
                runtime.process_executable_path(os.getpid())
                or "/Library/Developer/CommandLineTools/Python"
            )
            hashes = {
                node: "a" * 64,
                bundle: "b" * 64,
                launcher_path: "c" * 64,
                python: "d" * 64,
            }
            manager = {
                "schema": runner.MANAGER_AUTHORITY_SCHEMA,
                "operator_uid": self.uid,
                "operator_user": self.operator.pw_name,
                "operator_home": self.operator.pw_dir,
                "node_path": node,
                "node_sha256": hashes[node],
                "manager_bundle_path": bundle,
                "manager_bundle_sha256": hashes[bundle],
                "manager_launcher_path": launcher_path,
                "manager_launcher_sha256": hashes[launcher_path],
                "manager_python_path": python,
                "manager_python_sha256": hashes[python],
                "manager_state_dir": str(state_dir),
                "swarm_home": str(swarm_home),
                "manager_environment_sha256": runner.manager_environment_sha256(
                    self.operator.pw_name, self.operator.pw_dir,
                ),
            }
            admission = {
                key: value
                for key, value in manager.items()
                if key in runner.MANAGER_ADMISSION_KEYS
            }
            admission.update({
                "schema": runner.MANAGER_ADMISSION_SCHEMA,
                "nonce": "e" * 64,
                "launcher_pid": launcher_pid,
                "launcher_started": launcher_started,
                "manager_pid": manager_pid,
                "manager_started": manager_started,
            })
            authority = {
                "operator_uid": self.uid,
                "operator_user": self.operator.pw_name,
                "node_path": node,
                "node_sha256": hashes[node],
            }
            records = {
                manager_pid: (self.uid, launcher_pid, manager_started),
                launcher_pid: (0, 1, launcher_started),
            }
            executables = {manager_pid: node, launcher_pid: python}
            arguments = {
                manager_pid: [
                    node, "--disable-sigusr1", bundle,
                    "--state-dir", str(state_dir),
                    "--swarm-home", str(swarm_home),
                ],
                launcher_pid: [python, "-I", launcher_path],
            }
            self.assertEqual(arguments[manager_pid][1], "--disable-sigusr1")

            def invoke(*, manager_changes=None, admission_changes=None,
                       record_changes=None, executable_changes=None,
                       argument_changes=None, parent_pid=manager_pid,
                       has_acl=False):
                selected_manager = dict(manager)
                selected_manager.update(manager_changes or {})
                selected_admission = dict(admission)
                selected_admission.update(admission_changes or {})
                selected_records = dict(records)
                selected_records.update(record_changes or {})
                selected_executables = dict(executables)
                selected_executables.update(executable_changes or {})
                selected_arguments = dict(arguments)
                selected_arguments.update(argument_changes or {})

                def load(path, *_args, **_kwargs):
                    if path == runner.MANAGER_AUTHORITY:
                        return selected_manager
                    if path == runner.MANAGER_ADMISSION:
                        return selected_admission
                    raise AssertionError(path)

                with contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.object(
                        runner, "load_root_json_exact", side_effect=load,
                    ))
                    stack.enter_context(mock.patch.object(runner, "safe_root_file"))
                    stack.enter_context(mock.patch.object(
                        runner, "sha256_file", side_effect=lambda path: hashes[path],
                    ))
                    stack.enter_context(mock.patch.object(
                        runner, "process_record", side_effect=selected_records.get,
                    ))
                    stack.enter_context(mock.patch.object(
                        runner, "process_executable_path",
                        side_effect=selected_executables.get,
                    ))
                    stack.enter_context(mock.patch.object(
                        runner, "process_arguments", side_effect=selected_arguments.get,
                    ))
                    stack.enter_context(mock.patch.object(
                        runner, "is_ancestor", return_value=True,
                    ))
                    stack.enter_context(mock.patch.object(
                        runner, "fd_has_extended_acl", return_value=has_acl,
                    ))
                    runner.verify_app_server_manager_admission(authority, parent_pid)

            invoke()
            refused = (
                ("direct parent", {"parent_pid": manager_pid + 9}),
                ("stale identity", {
                    "record_changes": {
                        manager_pid: (self.uid, launcher_pid, "different start"),
                    },
                }),
                ("node executable drift", {
                    "executable_changes": {manager_pid: "/tmp/other-node"},
                }),
                ("manager argv injection", {
                    "argument_changes": {
                        manager_pid: [*arguments[manager_pid], "--import", "/tmp/hook"],
                    },
                }),
                ("inspector signal left enabled", {
                    "argument_changes": {
                        manager_pid: [
                            node, bundle, "--state-dir", str(state_dir),
                            "--swarm-home", str(swarm_home),
                        ],
                    },
                }),
                ("launcher argv injection", {
                    "argument_changes": {
                        launcher_pid: [python, "-I", "-c", "import os"],
                    },
                }),
                ("Python executable drift", {
                    "executable_changes": {launcher_pid: "/usr/bin/python3"},
                }),
                ("admission authority drift", {
                    "admission_changes": {"node_sha256": "f" * 64},
                }),
                ("environment authority drift", {
                    "manager_changes": {"manager_environment_sha256": "f" * 64},
                }),
                ("extended ACL", {"has_acl": True}),
            )
            for label, options in refused:
                with self.subTest(label=label), self.assertRaises(SystemExit):
                    invoke(**options)

    def test_exact_identity_rejects_reverse_uid_and_unexpected_shared_member(self) -> None:
        runtime_uid = self.uid + 100
        runtime_name = "_runtime_fixture"
        runtime_home = "/Users/_runtime_fixture"
        runtime_pw = pwd.struct_passwd((
            runtime_name, "x", runtime_uid, self.gid, "", runtime_home, "/usr/bin/false",
        ))
        authority = {
            "operator_uid": self.uid,
            "runtime_uid": runtime_uid,
            "runtime_user": runtime_name,
            "runtime_gid": self.gid,
            "runtime_group": self.shared.gr_name,
            "runtime_home": runtime_home,
        }

        def pw_by_uid(uid):
            return self.operator if uid == self.uid else runtime_pw

        def pw_by_name(name):
            return self.operator if name == self.operator.pw_name else runtime_pw

        shared = grp.struct_group((
            self.shared.gr_name, "x", self.gid, [self.operator.pw_name, runtime_name],
        ))
        fake_pwd = types.SimpleNamespace(getpwuid=pw_by_uid, getpwnam=pw_by_name)
        fake_grp = types.SimpleNamespace(
            getgrnam=lambda _name: shared,
            getgrgid=lambda _gid: shared,
        )
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "pwd", fake_pwd))
            stack.enter_context(mock.patch.object(runtime, "grp", fake_grp))
            stack.enter_context(mock.patch.object(
                runtime.os, "getgrouplist",
                side_effect=lambda name, _gid: [self.gid],
            ))
            runtime.exact_runtime_identity(authority, require_ds=False)
            wrong = pwd.struct_passwd((
                "reused_uid", "x", runtime_uid, self.gid, "", runtime_home, "/usr/bin/false",
            ))
            fake_pwd.getpwuid = lambda uid: self.operator if uid == self.uid else wrong
            with self.assertRaises(SystemExit):
                runtime.exact_runtime_identity(authority, require_ds=False)

        unexpected = grp.struct_group((
            self.shared.gr_name, "x", self.gid,
            [self.operator.pw_name, runtime_name, "admin_intruder"],
        ))
        fake_pwd.getpwuid = pw_by_uid
        fake_grp.getgrnam = lambda _name: unexpected
        fake_grp.getgrgid = lambda _gid: unexpected
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "pwd", fake_pwd))
            stack.enter_context(mock.patch.object(runtime, "grp", fake_grp))
            stack.enter_context(mock.patch.object(runtime.os, "getgrouplist", return_value=[self.gid]))
            with self.assertRaises(SystemExit):
                runtime.exact_runtime_identity(authority, require_ds=False)

    def test_precommit_proves_fixed_runner_through_operator_sudo(self) -> None:
        expected = "qofi-codex-runner: OK v2 authority/hash/account contract\n"
        fable = "qofi-codex-runner: OK service-uid/operator Fable MCP contract\n"
        with mock.patch.object(
            runtime, "run_as_operator_bounded", side_effect=[expected, fable],
        ) as proof:
            runtime.prove_runner_sudo_precommit(self.operator)
        self.assertEqual(
            proof.call_args_list[0].args[1],
            ["/usr/bin/sudo", "-n", "--", runtime.RUNNER, "--verify-install"],
        )
        self.assertEqual(
            proof.call_args_list[1].args[1],
            ["/usr/bin/sudo", "-n", "--", runtime.RUNNER, "--verify-fable-reviewer"],
        )

    def test_operator_verify_requires_exact_root_runner_proof(self) -> None:
        expected = "qofi-codex-runner: OK v2 authority/hash/account contract\n"
        with mock.patch.object(
            runtime.subprocess, "run", return_value=completed([], stdout=expected),
        ) as execute:
            runtime.prove_runner_sudo_verify(self.operator, "team-a")
        self.assertEqual(execute.call_args.args[0], [
            "/usr/bin/sudo", "-n", "--", runtime.RUNNER, "--verify",
            "--profile", "team-a",
        ])
        self.assertEqual(execute.call_args.kwargs["env"], {
            "HOME": self.operator.pw_dir,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        })

        failures = (
            completed([], stdout=expected + "extra\n"),
            completed([], stdout=expected, stderr="warning\n"),
            completed([], returncode=1, stderr="denied\n"),
        )
        for result in failures:
            with mock.patch.object(runtime.subprocess, "run", return_value=result), \
                    self.assertRaises(SystemExit):
                runtime.prove_runner_sudo_verify(self.operator)

    def test_first_install_directory_services_rollback_is_marker_bound(self) -> None:
        fake_runtime = pwd.struct_passwd((
            "_runtime_fixture", "x", self.uid + 100, self.gid, "", "/nonexistent/runtime", "/usr/bin/false",
        ))
        commands: list[list[str]] = []

        def fake_run(command, **_kwargs):
            commands.append(command)
            return completed(command)

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "quiesce_service_uid"))
            stack.enter_context(mock.patch.object(runtime.grp, "getgrnam", return_value=self.shared))
            stack.enter_context(mock.patch.object(runtime, "ds_record", return_value=True))
            stack.enter_context(mock.patch.object(runtime, "ds_values_attribute", return_value=[]))
            stack.enter_context(mock.patch.object(runtime, "ds_string_attribute", side_effect=lambda kind, _name, field: (
                runtime.RUNTIME_USER_REALNAME if kind == "Users" and field == "RealName"
                else runtime.RUNTIME_GROUP_REALNAME if kind == "Groups" and field == "RealName"
                else None
            )))
            stack.enter_context(mock.patch.object(runtime, "ds_numeric_attribute", return_value=fake_runtime.pw_uid))
            stack.enter_context(mock.patch.object(runtime, "run", side_effect=fake_run))
            runtime.rollback_directory_services(
                operator=self.operator,
                runtime_user=fake_runtime.pw_name,
                runtime_group="_runtime_group_fixture",
                runtime_home=fake_runtime.pw_dir,
                runtime=fake_runtime,
                user_created=True,
                group_created=True,
                home_existed=False,
                operator_member_added=True,
                runtime_member_added=True,
                prior_runtime_primary_gid=None,
            )
        self.assertIn(["/usr/bin/dscl", ".", "-delete", "/Users/_runtime_fixture"], commands)
        self.assertIn(["/usr/bin/dscl", ".", "-delete", "/Groups/_runtime_group_fixture"], commands)
        self.assertIn(
            ["/usr/sbin/dseditgroup", "-o", "edit", "-d", self.operator.pw_name,
             "-t", "user", "_runtime_group_fixture"],
            commands,
        )
        self.assertIn(
            ["/usr/sbin/dseditgroup", "-o", "edit", "-d", fake_runtime.pw_name,
             "-t", "user", "_runtime_group_fixture"],
            commands,
        )

    def test_partial_managed_user_rollback_restores_prior_primary_gid(self) -> None:
        commands: list[list[str]] = []

        def fake_run(command, **_kwargs):
            commands.append(command)
            return completed(command)

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "ds_record", return_value=True))
            stack.enter_context(mock.patch.object(runtime, "ds_values_attribute", return_value=[]))
            stack.enter_context(mock.patch.object(runtime, "ds_numeric_attribute", return_value=4242))
            stack.enter_context(mock.patch.object(runtime, "run", side_effect=fake_run))
            runtime.rollback_directory_services(
                operator=self.operator,
                runtime_user="_runtime_fixture",
                runtime_group="_runtime_group_fixture",
                runtime_home="/nonexistent/runtime",
                runtime=None,
                user_created=False,
                group_created=False,
                home_existed=True,
                operator_member_added=False,
                runtime_member_added=False,
                prior_runtime_primary_gid=4242,
            )
        self.assertIn(
            ["/usr/bin/dscl", ".", "-create", "/Users/_runtime_fixture",
             "PrimaryGroupID", "4242"],
            commands,
        )

    def _minimal_tool_sources(self, outer: Path) -> tuple[str, str, str]:
        prefix = outer / "node-prefix"
        node = prefix / "bin" / "node"
        node.parent.mkdir(parents=True)
        node.write_text("#!/bin/sh\nexit 0\n")
        os.chmod(node, 0o755)
        npm_bin = prefix / "lib" / "node_modules" / "npm" / "bin"
        npm_bin.mkdir(parents=True)
        (npm_bin.parent / "package.json").write_text('{"name":"npm"}\n')
        for name in ("npm-cli.js", "npx-cli.js"):
            (npm_bin / name).write_text("process.stdout.write('10.9.7\\n')\n")
            os.chmod(npm_bin / name, 0o755)
        codex_bin = outer / "codex-package" / "bin"
        codex_bin.mkdir(parents=True)
        (codex_bin.parent / "package.json").write_text('{"name":"codex"}\n')
        script = codex_bin / "codex.js"
        script.write_text("process.stdout.write('codex-cli 0.144.1\\n')\n")
        bun = outer / "bun"
        bun.write_text("#!/bin/sh\necho 1.3.14\n")
        os.chmod(bun, 0o755)
        return str(node), str(script), str(bun)

    def test_toolchain_installs_npm_npx_and_all_probes_use_service_uid(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            node, script, bun = self._minimal_tool_sources(outer)
            toolchain = outer / "installed-toolchain"
            service_calls: list[list[str]] = []

            def harden(root: str) -> None:
                for current, dirs, files in os.walk(root):
                    os.chmod(current, 0o755)
                    for name in files:
                        path = os.path.join(current, name)
                        os.chmod(path, stat.S_IMODE(os.lstat(path).st_mode) | 0o444)

            def service_probe(_record, command: list[str], capture: bool = False):
                service_calls.append(command)
                joined = " ".join(command)
                if command[-1] == "--version" and "codex.js" in joined:
                    return completed(command, stdout="codex-cli 0.144.1\n")
                if command[-1] == "--version" and command[-2].endswith("/bun"):
                    return completed(command, stdout="1.3.14\n")
                return completed(command, stdout="10.9.7\n")

            fake_runtime = pwd.struct_passwd(("runtime", "x", self.uid + 100, self.gid, "", str(outer), "/usr/bin/false"))
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "TOOLCHAIN", str(toolchain)))
                stack.enter_context(mock.patch.object(runtime, "root_control_tree", side_effect=harden))
                stack.enter_context(mock.patch.object(runtime, "run_as_runtime", side_effect=service_probe))
                installed_node, installed_script, backup = runtime.install_toolchain(
                    node, script, bun, self.uid, fake_runtime,
                )
            self.assertIsNone(backup)
            self.assertTrue(Path(installed_node).is_file())
            self.assertTrue(Path(installed_script).is_file())
            self.assertTrue((toolchain / "bin" / "npm").is_file())
            self.assertTrue((toolchain / "bin" / "npx").is_file())
            self.assertGreaterEqual(len(service_calls), 6)
            self.assertTrue(all(call[0] != "/usr/bin/sudo" for call in service_calls))

    def test_exact_cached_pnpm_is_root_copied_and_service_uid_probed(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            node, script, bun = self._minimal_tool_sources(outer)
            pnpm = outer / "pnpm-source"
            (pnpm / "bin").mkdir(parents=True)
            (pnpm / "package.json").write_text(json.dumps({
                "name": "pnpm",
                "version": "9.12.3",
                "bin": {"pnpm": "bin/pnpm.cjs", "pnpx": "bin/pnpx.cjs"},
            }))
            (pnpm / ".corepack").write_text(json.dumps({
                "locator": {"name": "pnpm", "reference": "9.12.3"},
                "bin": {"pnpm": "./bin/pnpm.cjs", "pnpx": "./bin/pnpx.cjs"},
                "hash": runtime.SUPPORTED_PNPM_INTEGRITY,
            }))
            (pnpm / "bin" / "pnpm.cjs").write_text(
                "process.stdout.write('9.12.3\\n')\n",
            )
            (pnpm / "bin" / "pnpx.cjs").write_text("process.exit(0)\n")
            os.chmod(pnpm / "bin" / "pnpm.cjs", 0o755)
            os.chmod(pnpm / "bin" / "pnpx.cjs", 0o755)
            toolchain = outer / "installed-toolchain"
            service_calls: list[list[str]] = []

            def harden(root: str) -> None:
                for current, _dirs, files in os.walk(root):
                    os.chmod(current, 0o755)
                    for name in files:
                        path = os.path.join(current, name)
                        os.chmod(path, stat.S_IMODE(os.lstat(path).st_mode) | 0o444)

            def service_probe(_record, command: list[str], capture: bool = False):
                service_calls.append(command)
                joined = " ".join(command)
                if "pnpm.cjs" in joined or command[0].endswith("/bin/pnpm"):
                    return completed(command, stdout="9.12.3\n")
                if command[-1] == "--version" and "codex.js" in joined:
                    return completed(command, stdout="codex-cli 0.144.1\n")
                if command[-1] == "--version" and command[-2].endswith("/bun"):
                    return completed(command, stdout="1.3.14\n")
                return completed(command, stdout="10.9.7\n")

            fake_runtime = pwd.struct_passwd((
                "runtime", "x", self.uid + 100, self.gid, "", str(outer), "/usr/bin/false",
            ))
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "TOOLCHAIN", str(toolchain)))
                stack.enter_context(mock.patch.object(runtime, "root_control_tree", side_effect=harden))
                stack.enter_context(mock.patch.object(runtime, "run_as_runtime", side_effect=service_probe))
                runtime.install_toolchain(
                    node, script, bun, self.uid, fake_runtime, str(pnpm), "9.12.3",
                )

            wrapper = toolchain / "bin" / "pnpm"
            self.assertEqual(
                wrapper.read_text(),
                f'#!/bin/sh\nexec "{toolchain / "node"}" '
                f'"{toolchain / "pnpm/bin/pnpm.cjs"}" "$@"\n',
            )
            self.assertEqual(
                json.loads((toolchain / "pnpm/package.json").read_text())["version"],
                "9.12.3",
            )
            self.assertTrue(any("pnpm.cjs" in " ".join(call) for call in service_calls))
            self.assertTrue(any(call[0].endswith("/bin/pnpm") for call in service_calls))

            pnpm_before = (toolchain / "pnpm/bin/pnpm.cjs").read_bytes()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "TOOLCHAIN", str(toolchain)))
                stack.enter_context(mock.patch.object(runtime, "root_control_tree", side_effect=harden))
                stack.enter_context(mock.patch.object(runtime, "run_as_runtime", side_effect=service_probe))
                _node, _script, prior = runtime.install_toolchain(
                    node, script, bun, self.uid, fake_runtime,
                )
            self.assertIsNotNone(prior)
            self.assertEqual((toolchain / "pnpm/bin/pnpm.cjs").read_bytes(), pnpm_before)
            self.assertTrue((toolchain / "bin/pnpm").is_file())

    def test_pnpm_provisioning_requires_exact_pin_and_trusted_corepack_cache(self) -> None:
        self.assertEqual(runtime.SUPPORTED_PNPM_VERSION, runner.SUPPORTED_PNPM_VERSION)
        self.assertEqual(runtime.SUPPORTED_PNPM_VERSION, "9.12.3")
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            home = outer / "home"
            repo = outer / "repo"
            repo.mkdir()
            home.mkdir()
            (repo / "pnpm-lock.yaml").write_text("lockfileVersion: '9.0'\n")
            (repo / "package.json").write_text(json.dumps({"scripts": {"test": "pnpm test"}}))
            with self.assertRaises(SystemExit):
                runtime.requested_pnpm_version(str(repo))

            (repo / "package.json").write_text(json.dumps({
                "packageManager": "pnpm@9.12.3",
                "scripts": {"test": "pnpm test"},
            }))
            self.assertEqual(runtime.requested_pnpm_version(str(repo)), "9.12.3")
            (repo / "package.json").write_text(json.dumps({
                "packageManager": f"pnpm@9.12.3+{runtime.SUPPORTED_PNPM_INTEGRITY}",
            }))
            self.assertEqual(runtime.requested_pnpm_version(str(repo)), "9.12.3")
            (repo / "package.json").write_text(json.dumps({
                "packageManager": "pnpm@9.12.3+sha512.not-the-audited-integrity",
            }))
            with self.assertRaises(SystemExit):
                runtime.requested_pnpm_version(str(repo))
            (repo / "package.json").write_text(json.dumps({
                "packageManager": "pnpm@10.0.0",
            }))
            with self.assertRaises(SystemExit):
                runtime.requested_pnpm_version(str(repo))
            (repo / "package.json").write_text(json.dumps({
                "packageManager": "pnpm@9.12.3",
                "scripts": {"test": "pnpm test"},
            }))
            fake_operator = pwd.struct_passwd((
                "operator", "x", self.uid, self.gid, "", str(home), "/bin/zsh",
            ))
            with mock.patch.object(
                runtime, "TOOLCHAIN", str(outer / "missing-toolchain"),
            ), self.assertRaises(SystemExit):
                runtime.resolve_operator_pnpm(fake_operator, str(repo))

            package = home / ".cache/node/corepack/v1/pnpm/9.12.3"
            (package / "bin").mkdir(parents=True)
            (package / "package.json").write_text(json.dumps({
                "name": "pnpm", "version": "9.12.3",
                "bin": {"pnpm": "bin/pnpm.cjs", "pnpx": "bin/pnpx.cjs"},
            }))
            (package / ".corepack").write_text(json.dumps({
                "locator": {"name": "pnpm", "reference": "9.12.3"},
                "bin": {"pnpm": "./bin/pnpm.cjs", "pnpx": "./bin/pnpx.cjs"},
                "hash": runtime.SUPPORTED_PNPM_INTEGRITY,
            }))
            (package / "bin/pnpm.cjs").write_text("process.exit(0)\n")
            (package / "bin/pnpx.cjs").write_text("process.exit(0)\n")
            os.chmod(package / "bin/pnpm.cjs", 0o755)
            os.chmod(package / "bin/pnpx.cjs", 0o755)
            self.assertEqual(
                runtime.resolve_operator_pnpm(fake_operator, str(repo)),
                (str(package), "9.12.3"),
            )

    def test_pnpm_pin_failure_precedes_lock_and_directory_services(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            repo = outer / "repo"
            swarm_home = outer / "swarm"
            repo.mkdir()
            swarm_home.mkdir()
            (repo / "pnpm-lock.yaml").write_text("lockfileVersion: '9.0'\n")
            (repo / "package.json").write_text(json.dumps({
                "packageManager": "pnpm@10.0.0",
            }))
            args = argparse.Namespace(
                operator_user=self.operator.pw_name,
                repo=str(repo),
                runtime_home=str(outer / "runtime-home"),
                runtime_user="_runtime_fixture",
                runtime_group="_runtime_group_fixture",
            )
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "operator_record", return_value=self.operator))
                stack.enter_context(mock.patch.object(runtime, "validate_runtime_home_target"))
                stack.enter_context(mock.patch.object(
                    runtime, "ATTESTATION", str(outer / "missing-attestation"),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "MANAGER_ADMISSION", str(outer / "missing-manager-admission"),
                ))
                acquire = stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks",
                ))
                ensure_group = stack.enter_context(mock.patch.object(runtime, "ensure_group"))
                ensure_user = stack.enter_context(mock.patch.object(runtime, "ensure_user"))
                with self.assertRaises(SystemExit):
                    runtime.command_install(args, str(swarm_home))
            acquire.assert_not_called()
            ensure_group.assert_not_called()
            ensure_user.assert_not_called()

            (repo / "package.json").write_text(json.dumps({
                "packageManager": "pnpm@9.12.3",
            }))
            private_home = outer / "operator-home"
            private_home.mkdir()
            fake_operator = pwd.struct_passwd((
                self.operator.pw_name, "x", self.uid, self.gid, "",
                str(private_home), self.operator.pw_shell,
            ))
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(
                    runtime, "operator_record", return_value=fake_operator,
                ))
                stack.enter_context(mock.patch.object(runtime, "validate_runtime_home_target"))
                stack.enter_context(mock.patch.object(
                    runtime, "ATTESTATION", str(outer / "missing-attestation"),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "MANAGER_ADMISSION", str(outer / "missing-manager-admission"),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "TOOLCHAIN", str(outer / "missing-toolchain"),
                ))
                acquire = stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks", return_value=(96, 97),
                ))
                release = stack.enter_context(mock.patch.object(
                    runtime, "release_manager_mutation_locks",
                ))
                ensure_group = stack.enter_context(mock.patch.object(runtime, "ensure_group"))
                ensure_user = stack.enter_context(mock.patch.object(runtime, "ensure_user"))
                with self.assertRaises(SystemExit):
                    runtime.command_install(args, str(swarm_home))
            acquire.assert_called_once()
            release.assert_called_once_with(96, 97)
            ensure_group.assert_not_called()
            ensure_user.assert_not_called()

    def test_toolchain_rejects_old_bun_before_commit(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            node, script, bun = self._minimal_tool_sources(outer)
            toolchain = outer / "installed-toolchain"

            def harden(root: str) -> None:
                for current, _dirs, files in os.walk(root):
                    os.chmod(current, 0o755)
                    for name in files:
                        os.chmod(os.path.join(current, name), 0o755)

            def service_probe(_record, command: list[str], capture: bool = False):
                if command[-2].endswith("/bun"):
                    return completed(command, stdout="1.2.9\n")
                return completed(command, stdout="codex-cli 0.144.1\n")

            fake_runtime = pwd.struct_passwd(("runtime", "x", self.uid + 100, self.gid, "", str(outer), "/usr/bin/false"))
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "TOOLCHAIN", str(toolchain)))
                stack.enter_context(mock.patch.object(runtime, "root_control_tree", side_effect=harden))
                stack.enter_context(mock.patch.object(runtime, "run_as_runtime", side_effect=service_probe))
                with self.assertRaises(SystemExit):
                    runtime.install_toolchain(node, script, bun, self.uid, fake_runtime)
            self.assertFalse(toolchain.exists())

    def test_install_failure_restores_authority_toolchain_registry_and_workspace(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            repo = outer / "repo"
            (repo / ".git" / "objects").mkdir(parents=True)
            (repo / "ordinary").write_text("data\n")
            os.chmod(repo / "ordinary", 0o644)
            before = metadata(repo)
            authority = outer / "authority"
            authority.mkdir()
            paths = {
                "ATTESTATION": authority / "attestation.json",
                "MANAGER_AUTHORITY": authority / "manager-authority.json",
                "SUDOERS": authority / "sudoers",
                "WORKSPACE_REGISTRY": authority / "registry.json",
                "RUNNER": authority / "runner",
                "LIFECYCLE": authority / "lifecycle",
                "MANAGER_LAUNCHER": authority / "manager-launcher",
                "MANAGER_BUNDLE": authority / "manager-bundle.mjs",
                "FABLE_REVIEWER": authority / "fable-reviewer.py",
                "FABLE_DOCTRINE": authority / "fable-doctrine.md",
                "FABLE_SCHEMA": authority / "fable-schema.json",
                "TOOLCHAIN": authority / "toolchain",
            }
            for key in (
                "ATTESTATION", "MANAGER_AUTHORITY", "SUDOERS",
                "WORKSPACE_REGISTRY", "RUNNER", "LIFECYCLE",
                "MANAGER_LAUNCHER", "MANAGER_BUNDLE",
            ):
                paths[key].write_text(f"old-{key}\n")
            paths["TOOLCHAIN"].mkdir()
            (paths["TOOLCHAIN"] / "old").write_text("old-toolchain\n")
            released: list[int] = []
            canary_commands: list[list[str]] = []
            real_prepare_workspace = runtime.prepare_workspace
            fake_runtime = pwd.struct_passwd(("runtime", "x", self.uid + 100, self.gid, "", str(outer / "runtime-home"), "/usr/bin/false"))

            def install_toolchain(*_args):
                backup = str(paths["TOOLCHAIN"]) + f".old.{os.getpid()}"
                os.rename(paths["TOOLCHAIN"], backup)
                paths["TOOLCHAIN"].mkdir()
                return str(paths["TOOLCHAIN"] / "node"), str(paths["TOOLCHAIN"] / "codex.js"), backup

            def install_runner(*_args):
                backup = str(paths["RUNNER"]) + f".old.{os.getpid()}"
                os.rename(paths["RUNNER"], backup)
                paths["RUNNER"].write_text("new-runner\n")
                return backup

            def install_lifecycle(*_args):
                backup = str(paths["LIFECYCLE"]) + f".old.{os.getpid()}"
                os.rename(paths["LIFECYCLE"], backup)
                paths["LIFECYCLE"].write_text("new-lifecycle\n")
                return backup

            def install_root_program(_source, target, *_args, **_kwargs):
                selected = Path(target)
                backup = str(selected) + f".old.{os.getpid()}"
                if selected.exists():
                    os.rename(selected, backup)
                else:
                    backup = None
                selected.write_text(f"new-{selected.name}\n")
                return backup

            def install_root_program_bytes(_content, target, *_args):
                return install_root_program(None, target)

            def replace(path: Path, text: str) -> None:
                temporary = path.with_suffix(path.suffix + ".new")
                temporary.write_text(text)
                os.replace(temporary, path)

            def failing_prepare(repo_path, operator, shared, **kwargs):
                real_prepare_workspace(repo_path, operator, shared, **kwargs)
                raise RuntimeError("injected after workspace mutation")

            def fake_run(command, **_kwargs):
                canary_commands.append(command)
                return completed(command)

            patchers = [mock.patch.object(runtime, name, str(path)) for name, path in paths.items()]
            args = argparse.Namespace(
                operator_user=self.operator.pw_name, repo=str(repo),
                runtime_home=fake_runtime.pw_dir, runtime_group=self.shared.gr_name,
                runtime_user=fake_runtime.pw_name,
            )
            with contextlib.ExitStack() as stack:
                for patcher in patchers:
                    stack.enter_context(patcher)
                stack.enter_context(mock.patch.object(
                    runtime, "MANAGER_ADMISSION", str(authority / "manager-admission"),
                ))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "operator_record", return_value=self.operator))
                stack.enter_context(mock.patch.object(runtime, "validate_runtime_home_target"))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks", return_value=(90, 91),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "release_manager_mutation_locks",
                    side_effect=lambda manager_fd, runner_fd: released.append(
                        (manager_fd, runner_fd),
                    ),
                ))
                stack.enter_context(mock.patch.object(runtime, "ensure_group", return_value=self.shared))
                stack.enter_context(mock.patch.object(runtime, "ensure_user", return_value=fake_runtime))
                stack.enter_context(mock.patch.object(runtime, "ds_record", return_value=False))
                stack.enter_context(mock.patch.object(runtime, "quiesce_service_uid"))
                stack.enter_context(mock.patch.object(runtime, "add_group_member"))
                stack.enter_context(mock.patch.object(runtime, "ensure_runtime_bootstrap"))
                stack.enter_context(mock.patch.object(runtime, "secure_runtime_home"))
                stack.enter_context(mock.patch.object(runtime, "establish_empty_keychain_search"))
                stack.enter_context(mock.patch.object(runtime, "resolve_operator_codex", return_value=("node", "script")))
                stack.enter_context(mock.patch.object(runtime, "resolve_operator_bun", return_value="bun"))
                stack.enter_context(mock.patch.object(runtime, "install_toolchain", side_effect=install_toolchain))
                stack.enter_context(mock.patch.object(runtime, "install_runner", side_effect=install_runner))
                stack.enter_context(mock.patch.object(runtime, "install_lifecycle", side_effect=install_lifecycle))
                stack.enter_context(mock.patch.object(
                    runtime, "build_manager_bundle",
                    return_value=b"x" * 1024,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "install_root_program", side_effect=install_root_program,
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "install_root_program_bytes",
                    side_effect=install_root_program_bytes,
                ))
                stack.enter_context(mock.patch.object(runtime, "prove_runner_sudo_precommit"))
                stack.enter_context(mock.patch.object(runtime, "exact_runtime_identity"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value={
                    "operator_uid": self.uid,
                    "runtime_uid": fake_runtime.pw_uid,
                    "runtime_gid": self.shared.gr_gid,
                    "runtime_user": fake_runtime.pw_name,
                    "runtime_group": self.shared.gr_name,
                    "runtime_home": fake_runtime.pw_dir,
                    "launchd_canary_name": "OLD_CANARY",
                }))
                stack.enter_context(mock.patch.object(runtime, "set_operator_canary", return_value=("NEW_CANARY", "f" * 64)))
                stack.enter_context(mock.patch.object(runtime, "write_attestation", side_effect=lambda *_: replace(paths["ATTESTATION"], "new-attestation\n")))
                stack.enter_context(mock.patch.object(
                    runtime, "write_manager_authority",
                    side_effect=lambda *_: replace(
                        paths["MANAGER_AUTHORITY"], "new-manager-authority\n",
                    ),
                ))
                stack.enter_context(mock.patch.object(runtime, "install_sudoers", side_effect=lambda *_: replace(paths["SUDOERS"], "new-sudoers\n")))
                stack.enter_context(mock.patch.object(
                    runtime, "snapshot_workspace",
                    side_effect=lambda *_, **__: replace(
                        paths["WORKSPACE_REGISTRY"], "new-registry\n",
                    ),
                ))
                stack.enter_context(mock.patch.object(runtime, "prepare_workspace", side_effect=failing_prepare))
                stack.enter_context(mock.patch.object(runtime, "run", side_effect=fake_run))
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    runtime.command_install(args, str(ROOT))

            self.assertEqual(released, [(90, 91)])
            for key in (
                "ATTESTATION", "MANAGER_AUTHORITY", "SUDOERS", "WORKSPACE_REGISTRY",
            ):
                self.assertEqual(paths[key].read_text(), f"old-{key}\n")
            self.assertEqual(paths["RUNNER"].read_text(), "old-RUNNER\n")
            self.assertEqual(paths["LIFECYCLE"].read_text(), "old-LIFECYCLE\n")
            self.assertEqual(
                paths["MANAGER_LAUNCHER"].read_text(), "old-MANAGER_LAUNCHER\n",
            )
            self.assertEqual(
                paths["MANAGER_BUNDLE"].read_text(), "old-MANAGER_BUNDLE\n",
            )
            for key in ("FABLE_REVIEWER", "FABLE_DOCTRINE", "FABLE_SCHEMA"):
                self.assertFalse(paths[key].exists())
                self.assertFalse(Path(str(paths[key]) + f".old.{os.getpid()}").exists())
            self.assertEqual((paths["TOOLCHAIN"] / "old").read_text(), "old-toolchain\n")
            self.assertEqual(metadata(repo), before)
            self.assertIn(
                ["/bin/launchctl", "asuser", str(self.uid), "/bin/launchctl", "unsetenv", "NEW_CANARY"],
                canary_commands,
            )

    def test_prepare_failure_restores_registry_and_workspace(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            repo = outer / "repo"
            (repo / ".git" / "objects").mkdir(parents=True)
            (repo / "ordinary").write_text("data\n")
            os.chmod(repo / "ordinary", 0o644)
            before = metadata(repo)
            registry = outer / "registry.json"
            original_registry = '{"schema":"qofi-codex-workspaces/v1","workspaces":{}}\n'
            registry.write_text(original_registry)
            registry.chmod(0o600)
            real_prepare_workspace = runtime.prepare_workspace
            released: list[int] = []
            value = {
                "runtime_uid": self.uid + 100,
                "operator_uid": self.uid,
                "runtime_group": self.shared.gr_name,
            }

            def fail_after_mutation(repo_path, operator, shared, **kwargs):
                real_prepare_workspace(repo_path, operator, shared, **kwargs)
                raise RuntimeError("injected prepare failure")

            args = argparse.Namespace(repo=str(repo))
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "WORKSPACE_REGISTRY", str(registry)))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(
                    runtime, "exact_runtime_identity",
                    return_value=(self.operator, self.operator, self.shared),
                ))
                stack.enter_context(mock.patch.object(runtime, "acquire_lifecycle_lock", return_value=93))
                stack.enter_context(mock.patch.object(runtime, "release_lifecycle_lock", side_effect=released.append))
                stack.enter_context(mock.patch.object(runtime, "prepare_workspace", side_effect=fail_after_mutation))
                with self.assertRaisesRegex(RuntimeError, "injected prepare"):
                    runtime.command_prepare(args)
            self.assertEqual(released, [93])
            self.assertEqual(registry.read_text(), original_registry)
            self.assertEqual(metadata(repo), before)

    def test_unmanaged_directory_records_are_never_adopted(self) -> None:
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(runtime, "ds_record", return_value=True))
            stack.enter_context(mock.patch.object(runtime, "ds_string_attribute", return_value="Unrelated Account"))
            commands = stack.enter_context(mock.patch.object(runtime, "run"))
            with self.assertRaises(SystemExit):
                runtime.ensure_group("_qofi_codex_shared")
            with self.assertRaises(SystemExit):
                runtime.ensure_user("_qofi_codex", "/Users/_qofi_codex", self.gid)
        commands.assert_not_called()

    def test_runtime_bootstrap_retries_transient_asuser_readiness_race(self) -> None:
        service = pwd.struct_passwd((
            "runtime", "x", self.uid + 100, self.gid, "", "/Users/runtime", "/usr/bin/false",
        ))
        bootstrap = completed(["launchctl", "bootstrap"])
        transient = completed(
            ["launchctl", "asuser"], returncode=1,
            stderr="Failed to get user context: 1: Operation not permitted\n",
        )
        ready = completed(["launchctl", "asuser"], stdout=f"{service.pw_uid}\n")
        with mock.patch.object(runtime, "run", return_value=bootstrap) as run_command, \
                mock.patch.object(
                    runtime, "run_as_runtime", side_effect=[transient, ready],
                ) as prove, \
                mock.patch.object(runtime.time, "sleep") as sleep:
            runtime.ensure_runtime_bootstrap(service)

        run_command.assert_called_once_with(
            ["/bin/launchctl", "bootstrap", f"user/{service.pw_uid}"],
            check=False, capture=True,
        )
        self.assertEqual(prove.call_count, 2)
        sleep.assert_called_once_with(runtime.RUNTIME_BOOTSTRAP_PROOF_INTERVAL)

    def test_runtime_bootstrap_accepts_existing_domain_when_proof_succeeds(self) -> None:
        service = pwd.struct_passwd((
            "runtime", "x", self.uid + 100, self.gid, "", "/Users/runtime", "/usr/bin/false",
        ))
        existing = completed(
            ["launchctl", "bootstrap"], returncode=36,
            stderr="Bootstrap failed: 36: Operation already in progress\n",
        )
        ready = completed(["launchctl", "asuser"], stdout=f"{service.pw_uid}\n")
        with mock.patch.object(runtime, "run", return_value=existing), \
                mock.patch.object(runtime, "run_as_runtime", return_value=ready), \
                mock.patch.object(runtime.time, "sleep") as sleep:
            runtime.ensure_runtime_bootstrap(service)
        sleep.assert_not_called()

    def test_runtime_bootstrap_failure_reports_bounded_proof_diagnostic(self) -> None:
        service = pwd.struct_passwd((
            "runtime", "x", self.uid + 100, self.gid, "", "/Users/runtime", "/usr/bin/false",
        ))
        bootstrap = completed(["launchctl", "bootstrap"])
        failed = completed(
            ["launchctl", "asuser"], returncode=1,
            stderr="Failed\n\x00to get user context " + ("x" * 900),
        )
        error = io.StringIO()
        with mock.patch.object(runtime, "RUNTIME_BOOTSTRAP_PROOF_ATTEMPTS", 3), \
                mock.patch.object(runtime, "run", return_value=bootstrap), \
                mock.patch.object(runtime, "run_as_runtime", return_value=failed) as prove, \
                mock.patch.object(runtime.time, "sleep") as sleep, \
                contextlib.redirect_stderr(error), self.assertRaises(SystemExit):
            runtime.ensure_runtime_bootstrap(service)

        self.assertEqual(prove.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        diagnostic = error.getvalue()
        self.assertIn("bootstrap/asuser proof failed: asuser proof exit 1: Failed to get", diagnostic)
        self.assertNotIn("\x00", diagnostic)
        self.assertLess(len(diagnostic), 700)

    def test_runtime_context_uses_root_asuser_then_identical_isolated_trampoline(self) -> None:
        service = pwd.struct_passwd((
            "runtime", "x", self.uid + 100, self.gid, "", "/Users/runtime", "/usr/bin/false",
        ))
        target = ["/usr/bin/id", "-u"]
        self.assertEqual(runtime.RUNTIME_CONTEXT_TRAMPOLINE, runner.RUNTIME_CONTEXT_TRAMPOLINE)
        with mock.patch.object(
            runtime.subprocess, "run", return_value=completed(target),
        ) as execute:
            runtime.run_as_runtime(service, target, capture=True)

        invocation = execute.call_args.args[0]
        self.assertEqual(invocation[:8], [
            "/bin/launchctl", "asuser", str(service.pw_uid),
            "/usr/bin/python3", "-I", "-S", "-c", runtime.RUNTIME_CONTEXT_TRAMPOLINE,
        ])
        self.assertEqual(invocation[8:12], [
            service.pw_name, str(service.pw_uid), str(service.pw_gid), "077",
        ])
        self.assertEqual(invocation[12:], target)
        self.assertNotIn("preexec_fn", execute.call_args.kwargs)
        self.assertNotIn("/usr/bin/sudo", invocation)
        self.assertNotIn("/bin/sh", invocation)
        self.assertEqual(
            execute.call_args.kwargs["env"],
            runtime.runtime_environment(service, "/Users/runtime/.codex"),
        )
        self.assertNotIn("OPENAI_API_KEY", execute.call_args.kwargs["env"])
        self.assertNotIn("CODEX_ACCESS_TOKEN", execute.call_args.kwargs["env"])
        self.assertEqual(execute.call_args.kwargs["cwd"], service.pw_dir)
        self.assertTrue(execute.call_args.kwargs["capture_output"])
        with self.assertRaises(SystemExit):
            runtime.runtime_context_command(service, ["relative-command"], umask=0o077)

    def test_runtime_context_trampoline_drops_and_proves_before_exact_exec(self) -> None:
        service = pwd.struct_passwd((
            "runtime", "x", self.uid + 100, self.gid, "", "/Users/runtime", "/usr/bin/false",
        ))
        calls: list[tuple[object, ...]] = []

        class ExecReached(RuntimeError):
            pass

        def mark(name, *values):
            calls.append((name, *values))

        fake_os = types.SimpleNamespace(
            path=os.path,
            environ={"HOME": service.pw_dir, "CODEX_HOME": service.pw_dir + "/.codex"},
            initgroups=lambda name, gid: mark("initgroups", name, gid),
            setgid=lambda gid: mark("setgid", gid),
            setuid=lambda uid: mark("setuid", uid),
            getuid=lambda: service.pw_uid,
            geteuid=lambda: service.pw_uid,
            getgid=lambda: service.pw_gid,
            getegid=lambda: service.pw_gid,
            getgroups=lambda: [service.pw_gid],
            umask=lambda value: mark("umask", value),
            execve=lambda path, argv, env: (
                mark("execve", path, tuple(argv), dict(env)),
                (_ for _ in ()).throw(ExecReached()),
            )[-1],
        )
        fake_pwd = types.SimpleNamespace(
            getpwnam=lambda name: (mark("getpwnam", name), service)[-1],
            getpwuid=lambda uid: (mark("getpwuid", uid), service)[-1],
        )
        fake_sys = types.SimpleNamespace(
            argv=[
                "-c", service.pw_name, str(service.pw_uid), str(service.pw_gid), "077",
                "/usr/bin/id", "-u",
            ],
            stderr=io.StringIO(),
        )
        real_import = builtins.__import__

        def isolated_import(name, *args, **kwargs):
            if name == "os":
                return fake_os
            if name == "pwd":
                return fake_pwd
            if name == "sys":
                return fake_sys
            return real_import(name, *args, **kwargs)

        with mock.patch.object(builtins, "__import__", side_effect=isolated_import), \
                self.assertRaises(ExecReached):
            exec(runtime.RUNTIME_CONTEXT_TRAMPOLINE, {"__builtins__": builtins})

        names = [str(call[0]) for call in calls]
        self.assertLess(names.index("getpwnam"), names.index("initgroups"))
        self.assertLess(names.index("getpwuid"), names.index("initgroups"))
        self.assertLess(names.index("initgroups"), names.index("setgid"))
        self.assertLess(names.index("setgid"), names.index("setuid"))
        self.assertLess(names.index("setuid"), names.index("umask"))
        self.assertLess(names.index("umask"), names.index("execve"))
        self.assertEqual(calls[-1][1:3], ("/usr/bin/id", ("/usr/bin/id", "-u")))
        self.assertEqual(calls[-1][3], dict(fake_os.environ))

        calls.clear()
        fake_os.getgroups = lambda: [0, service.pw_gid]
        fake_sys.stderr = io.StringIO()
        with mock.patch.object(builtins, "__import__", side_effect=isolated_import), \
                self.assertRaises(SystemExit):
            exec(runtime.RUNTIME_CONTEXT_TRAMPOLINE, {"__builtins__": builtins})
        self.assertNotIn("execve", [str(call[0]) for call in calls])
        self.assertIn("credential proof", fake_sys.stderr.getvalue())

        calls.clear()
        fake_os.getgroups = lambda: [service.pw_gid]
        wrong = pwd.struct_passwd((
            "reused", "x", service.pw_uid, service.pw_gid, "", service.pw_dir,
            service.pw_shell,
        ))
        fake_pwd.getpwuid = lambda uid: (mark("getpwuid", uid), wrong)[-1]
        fake_sys.stderr = io.StringIO()
        with mock.patch.object(builtins, "__import__", side_effect=isolated_import), \
                self.assertRaises(SystemExit):
            exec(runtime.RUNTIME_CONTEXT_TRAMPOLINE, {"__builtins__": builtins})
        self.assertNotIn("initgroups", [str(call[0]) for call in calls])
        self.assertNotIn("execve", [str(call[0]) for call in calls])
        self.assertIn("directory identity", fake_sys.stderr.getvalue())

    def test_runner_children_use_trampoline_and_new_session_without_preexec(self) -> None:
        authority = {
            "runtime_user": "runtime", "runtime_uid": self.uid + 100,
            "runtime_primary_gid": self.gid, "operator_uid": self.uid,
            "node_path": "/fixed/node", "codex_script": "/fixed/codex.js",
        }
        child = mock.Mock()
        child.poll.return_value = 0
        child.wait.return_value = 0
        with mock.patch.object(runner, "prepare_runtime_dirs", return_value=None), \
                mock.patch.object(runner, "child_env", return_value={"HOME": "/Users/runtime"}), \
                mock.patch.object(runner.signal, "signal"), \
                mock.patch.object(runner.subprocess, "Popen", return_value=child) as popen:
            self.assertEqual(runner.run_child(authority, os.getpid(), "workspace", ["--version"]), 0)

        invocation = popen.call_args.args[0]
        self.assertEqual(invocation[:8], [
            "/bin/launchctl", "asuser", str(authority["runtime_uid"]),
            "/usr/bin/python3", "-I", "-S", "-c", runner.RUNTIME_CONTEXT_TRAMPOLINE,
        ])
        self.assertEqual(invocation[8:12], [
            authority["runtime_user"], str(authority["runtime_uid"]),
            str(authority["runtime_primary_gid"]), "002",
        ])
        self.assertEqual(invocation[12:], ["/fixed/node", "/fixed/codex.js", "--version"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertNotIn("preexec_fn", popen.call_args.kwargs)

    def test_app_server_child_inherits_stdio_and_stops_when_manager_parent_dies(self) -> None:
        authority = {
            "runtime_user": "runtime", "runtime_uid": self.uid + 100,
            "runtime_primary_gid": self.gid, "operator_uid": self.uid,
            "runtime_home": "/Users/runtime",
            "node_path": "/fixed/node", "codex_script": "/fixed/codex.js",
        }
        child = mock.Mock(pid=12345)
        child.poll.side_effect = [None, None, 0]
        child.wait.return_value = 0
        with mock.patch.object(runner, "prepare_runtime_dirs", return_value=None), \
                mock.patch.object(runner, "child_env", return_value={"HOME": "/Users/runtime"}), \
                mock.patch.object(runner, "parent_is_live", return_value=False), \
                mock.patch.object(runner.signal, "signal"), \
                mock.patch.object(runner.time, "sleep"), \
                mock.patch.object(runner.os, "killpg") as killpg, \
                mock.patch.object(runner.subprocess, "Popen", return_value=child) as popen:
            self.assertEqual(runner.run_child(
                authority, os.getpid(), "app-server", list(runner.APP_SERVER_ARGS),
            ), 0)

        invocation = popen.call_args.args[0]
        self.assertEqual(invocation[12:], [
            "/fixed/node", "/fixed/codex.js", *runner.APP_SERVER_ARGS,
        ])
        self.assertEqual(popen.call_args.kwargs["cwd"], authority["runtime_home"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        for stream in ("stdin", "stdout", "stderr"):
            self.assertNotIn(stream, popen.call_args.kwargs)
        killpg.assert_called_once_with(child.pid, runner.signal.SIGTERM)

    def test_runner_tool_probe_uses_same_new_session_trampoline(self) -> None:
        authority = {
            "runtime_user": "runtime", "runtime_uid": self.uid + 100,
            "runtime_primary_gid": self.gid, "operator_uid": self.uid,
        }
        stdout = mock.Mock()
        stdout.fileno.return_value = 91
        child = mock.Mock(stdout=stdout, pid=12345)
        child.poll.return_value = 0
        child.wait.return_value = 0
        with mock.patch.object(runner, "prepare_runtime_dirs", return_value="/private/tmp/runtime"), \
                mock.patch.object(runner, "child_env", return_value={"PATH": "/usr/bin"}), \
                mock.patch.object(runner, "trusted_tool_path", return_value="/usr/bin/bun"), \
                mock.patch.object(runner, "parent_is_live", return_value=True), \
                mock.patch.object(runner.signal, "signal"), \
                mock.patch.object(runner.select, "select", side_effect=[([stdout], [], []), ([stdout], [], [])]), \
                mock.patch.object(runner.os, "read", side_effect=[b"1.3.14\n", b""]), \
                mock.patch.object(runner.subprocess, "Popen", return_value=child) as popen, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.run_tool_checks(authority, os.getpid(), ["bun"]), 0)

        invocation = popen.call_args.args[0]
        self.assertEqual(invocation[8:12], [
            authority["runtime_user"], str(authority["runtime_uid"]),
            str(authority["runtime_primary_gid"]), "002",
        ])
        self.assertEqual(invocation[12:], ["/usr/bin/bun", "--version"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertNotIn("preexec_fn", popen.call_args.kwargs)

    def test_runner_fable_mcp_proof_is_exact_service_uid_sudo_and_no_spend(self) -> None:
        authority = {
            "runtime_user": "runtime", "runtime_uid": self.uid + 100,
            "runtime_primary_gid": self.gid, "operator_uid": self.uid,
            "runtime_home": "/Users/runtime", "codex_home": "/Users/runtime/.codex",
        }
        responses = "\n".join((
            json.dumps({
                "jsonrpc": "2.0", "id": 1,
                "result": {"serverInfo": {"name": "qofi-fable-reviewer", "version": "1.0.0"}},
            }),
            json.dumps({
                "jsonrpc": "2.0", "id": 2,
                "result": {"tools": [{"name": "adversarial_review"}]},
            }),
        )) + "\n"
        proof = completed(["/fixed/trampoline"], stdout=responses)
        with mock.patch.object(
            runner, "runtime_context_command", return_value=["/fixed/trampoline"],
        ) as trampoline, mock.patch.object(
            runner, "child_env", return_value={"HOME": "/Users/runtime"},
        ), mock.patch.object(runner.subprocess, "run", return_value=proof) as execute:
            runner.prove_fable_reviewer_mcp(authority)
        self.assertEqual(trampoline.call_args.args[1], [
            "/usr/bin/sudo", "-n", "-H", "-u", f"#{self.uid}", "--",
            "/usr/bin/python3", "-I", "-B", runner.FABLE_REVIEWER,
        ])
        rpc_input = execute.call_args.kwargs["input"]
        self.assertIn('"method":"initialize"', rpc_input)
        self.assertIn('"method":"tools/list"', rpc_input)
        self.assertNotIn('"method":"tools/call"', rpc_input)

    def test_runner_requires_exact_pnpm_version_output(self) -> None:
        authority = {
            "runtime_user": "runtime", "runtime_uid": self.uid + 100,
            "runtime_primary_gid": self.gid, "operator_uid": self.uid,
        }

        def probe(output: bytes) -> int:
            stdout = mock.Mock()
            stdout.fileno.return_value = 91
            child = mock.Mock(stdout=stdout, pid=12345)
            child.poll.return_value = 0
            child.wait.return_value = 0
            with mock.patch.object(runner, "prepare_runtime_dirs", return_value="/private/tmp/runtime"), \
                    mock.patch.object(runner, "child_env", return_value={"PATH": "/toolchain/bin"}), \
                    mock.patch.object(runner, "trusted_tool_path", return_value="/toolchain/bin/pnpm"), \
                    mock.patch.object(runner, "parent_is_live", return_value=True), \
                    mock.patch.object(runner.signal, "signal"), \
                    mock.patch.object(
                        runner.select, "select",
                        side_effect=[([stdout], [], []), ([stdout], [], [])],
                    ), \
                    mock.patch.object(runner.os, "read", side_effect=[output, b""]), \
                    mock.patch.object(runner.subprocess, "Popen", return_value=child), \
                    contextlib.redirect_stdout(io.StringIO()):
                return runner.run_tool_checks(authority, os.getpid(), ["pnpm"])

        self.assertEqual(probe(b"9.12.3\n"), 0)
        for output in (b"9.12.4\n", b"9.12.3\nextra\n", b" 9.12.3\n"):
            with self.subTest(output=output), self.assertRaises(SystemExit):
                probe(output)

    def test_partial_managed_directory_records_are_safely_reconciled_on_rerun(self) -> None:
        runtime_uid = self.uid + 100
        runtime_user = pwd.struct_passwd((
            "_qofi_codex", "x", runtime_uid, self.gid, "", "/Users/_qofi_codex",
            "/usr/bin/false",
        ))
        shared = grp.struct_group((
            "_qofi_codex_shared", "x", self.gid,
            [self.operator.pw_name, runtime_user.pw_name],
        ))
        commands: list[list[str]] = []

        def string_attribute(kind, _name, field):
            if kind == "Groups" and field == "RealName":
                return runtime.RUNTIME_GROUP_REALNAME
            if kind == "Users" and field == "RealName":
                return runtime.RUNTIME_USER_REALNAME
            return None

        def numeric_attribute(kind, _name, field):
            if kind == "Groups":
                return shared.gr_gid
            return runtime_uid if field == "UniqueID" else runtime_user.pw_gid

        with mock.patch.object(runtime, "ds_record", return_value=True), \
                mock.patch.object(runtime, "ds_string_attribute", side_effect=string_attribute), \
                mock.patch.object(runtime, "ds_numeric_attribute", side_effect=numeric_attribute), \
                mock.patch.object(runtime, "ds_boolean_attribute", return_value=True), \
                mock.patch.object(runtime.grp, "getgrnam", return_value=shared), \
                mock.patch.object(runtime.pwd, "getpwnam", return_value=runtime_user), \
                mock.patch.object(
                    runtime, "run", side_effect=lambda command, **_kwargs: (
                        commands.append(command), completed(command)
                    )[-1],
                ):
            self.assertEqual(runtime.ensure_group(shared.gr_name), shared)
            self.assertEqual(
                runtime.ensure_user(runtime_user.pw_name, runtime_user.pw_dir, shared.gr_gid),
                runtime_user,
            )

        self.assertFalse(any("-delete" in command for command in commands))
        self.assertIn([
            "/usr/bin/dscl", ".", "-create", f"/Users/{runtime_user.pw_name}",
            "NFSHomeDirectory", runtime_user.pw_dir,
        ], commands)
        self.assertIn([
            "/usr/bin/dscl", ".", "-create", f"/Users/{runtime_user.pw_name}",
            "IsHidden", "1",
        ], commands)

    @unittest.skipUnless(sys.platform == "darwin", "macOS Directory Services contract")
    def test_missing_directory_service_attribute_is_exact_absence(self) -> None:
        self.assertIsNone(runtime.ds_string_attribute("Users", "daemon", "AuthenticationAuthority"))
        self.assertEqual(runtime.ds_values_attribute("Users", "daemon", "AuthenticationAuthority"), [])
        self.assertIsNone(runtime.ds_numeric_attribute("Users", "daemon", "QofiMissingFixture"))
        self.assertIsNone(runtime.ds_boolean_attribute("Users", "daemon", "QofiMissingFixture"))
        self.assertIsNone(runner.ds_values("Users", "daemon", "AuthenticationAuthority"))

    def test_directory_service_boolean_accepts_native_yes_and_rejects_ambiguity(self) -> None:
        command = ["/usr/bin/dscl", ".", "-read", "/Users/daemon", "IsHidden"]
        for rendered in ("IsHidden: YES", "IsHidden: 1", "dsAttrTypeNative:IsHidden: YES"):
            with self.subTest(rendered=rendered), mock.patch.object(
                runtime, "run",
                return_value=completed(command, stdout=f"{rendered}\n"),
            ):
                self.assertIs(runtime.ds_boolean_attribute("Users", "daemon", "IsHidden"), True)
        for rendered in ("IsHidden: NO", "IsHidden: 0", "dsAttrTypeNative:IsHidden: NO"):
            with self.subTest(rendered=rendered), mock.patch.object(
                runtime, "run",
                return_value=completed(command, stdout=f"{rendered}\n"),
            ):
                self.assertIs(runtime.ds_boolean_attribute("Users", "daemon", "IsHidden"), False)
        for malformed in ("IsHidden: MAYBE", "dsAttrTypeStandard:IsHidden: YES"):
            with self.subTest(malformed=malformed), mock.patch.object(
                runtime, "run", return_value=completed(command, stdout=f"{malformed}\n"),
            ), self.assertRaises(SystemExit):
                runtime.ds_boolean_attribute("Users", "daemon", "IsHidden")

    def test_runner_directory_service_boolean_matches_lifecycle_exact_forms(self) -> None:
        command = ["/usr/bin/dscl", ".", "-read", "/Users/daemon", "IsHidden"]
        for rendered in (
            "IsHidden: YES", "IsHidden: 1",
            "dsAttrTypeNative:IsHidden: YES", "dsAttrTypeNative:IsHidden: 1",
        ):
            with self.subTest(rendered=rendered), mock.patch.object(
                runner.subprocess, "run",
                return_value=completed(command, stdout=f"{rendered}\n"),
            ):
                self.assertIs(runner.ds_boolean_attribute("Users", "daemon", "IsHidden"), True)
        for rendered in (
            "IsHidden: NO", "IsHidden: 0",
            "dsAttrTypeNative:IsHidden: NO", "dsAttrTypeNative:IsHidden: 0",
        ):
            with self.subTest(rendered=rendered), mock.patch.object(
                runner.subprocess, "run",
                return_value=completed(command, stdout=f"{rendered}\n"),
            ):
                self.assertIs(runner.ds_boolean_attribute("Users", "daemon", "IsHidden"), False)
        for malformed in (
            "IsHidden: MAYBE", "IsHidden: true",
            "dsAttrTypeStandard:IsHidden: YES",
            "dsAttrTypeNative:IsHidden: 1 extra",
        ):
            with self.subTest(malformed=malformed), mock.patch.object(
                runner.subprocess, "run",
                return_value=completed(command, stdout=f"{malformed}\n"),
            ), self.assertRaises(SystemExit):
                runner.ds_boolean_attribute("Users", "daemon", "IsHidden")

    def test_runner_noauth_validation_routes_ishidden_through_boolean_parser(self) -> None:
        runtime_user = pwd.struct_passwd((
            "runtime", "x", self.uid + 100, self.gid, "", "/Users/runtime",
            "/usr/bin/false",
        ))
        shared = grp.struct_group((
            "runtime_group", "x", self.gid,
            [self.operator.pw_name, runtime_user.pw_name],
        ))

        def values(kind, _name, field):
            if kind == "Users":
                return {
                    "UniqueID": [str(runtime_user.pw_uid)],
                    "PrimaryGroupID": [str(shared.gr_gid)],
                    "NFSHomeDirectory": [runtime_user.pw_dir],
                    "UserShell": [runtime_user.pw_shell],
                    "RealName": runner.RUNTIME_USER_REALNAME.split(),
                    "Password": ["*"],
                    "AuthenticationAuthority": None,
                }[field]
            return {
                "PrimaryGroupID": [str(shared.gr_gid)],
                "RealName": runner.RUNTIME_GROUP_REALNAME.split(),
                "GroupMembership": [self.operator.pw_name, runtime_user.pw_name],
                "NestedGroups": None,
            }[field]

        with mock.patch.object(runner.sys, "platform", "darwin"), \
                mock.patch.object(runner, "ds_values", side_effect=values), \
                mock.patch.object(runner, "ds_boolean_attribute", return_value=True) as boolean:
            runner.validate_noauth_directory_service(self.operator, runtime_user, shared)
        boolean.assert_called_once_with("Users", runtime_user.pw_name, "IsHidden")

        with mock.patch.object(runner.sys, "platform", "darwin"), \
                mock.patch.object(runner, "ds_values", side_effect=values), \
                mock.patch.object(runner, "ds_boolean_attribute", return_value=False), \
                self.assertRaises(SystemExit):
            runner.validate_noauth_directory_service(self.operator, runtime_user, shared)

    def test_existing_identity_mismatch_stops_before_directory_services(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer:
            repo = Path(outer) / "repo"
            repo.mkdir()
            args = argparse.Namespace(
                operator_user=self.operator.pw_name, repo=str(repo),
                runtime_home="/Users/_qofi_codex", runtime_group="_qofi_codex_shared",
                runtime_user="_qofi_codex",
            )
            existing = {
                "operator_uid": self.uid,
                "runtime_uid": self.uid + 100,
                "runtime_gid": self.gid,
                "runtime_user": "different-runtime",
                "runtime_group": args.runtime_group,
                "runtime_home": args.runtime_home,
                "launchd_canary_name": "OLD_CANARY",
            }
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "operator_record", return_value=self.operator))
                stack.enter_context(mock.patch.object(runtime, "validate_runtime_home_target"))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks", return_value=(93, 94),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "release_manager_mutation_locks",
                ))
                stack.enter_context(mock.patch.object(runtime.os.path, "lexists", side_effect=lambda path: path == runtime.ATTESTATION))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=existing))
                ensure_group = stack.enter_context(mock.patch.object(runtime, "ensure_group"))
                with self.assertRaises(SystemExit):
                    runtime.command_install(args, str(ROOT))
            ensure_group.assert_not_called()

    def test_refresh_lifecycle_is_explicit_attested_and_transactional(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            target = outer / "fixed-lifecycle"
            target.write_text("old helper\n")
            target.chmod(0o755)
            backup = Path(str(target) + f".old.{os.getpid()}")
            authority = {"operator_uid": self.uid}

            def install(source: str, operator_uid: int):
                self.assertEqual(operator_uid, self.uid)
                target.rename(backup)
                shutil.copyfile(source, target)
                target.chmod(0o755)
                return str(backup)

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "LIFECYCLE", str(target)))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=authority))
                stack.enter_context(mock.patch.object(
                    runtime,
                    "exact_runtime_identity",
                    return_value=(self.operator, self.operator, self.shared),
                ))
                stack.enter_context(mock.patch.object(runtime, "validate_source"))
                stack.enter_context(mock.patch.object(runtime, "validate_root_authority_file"))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_lifecycle_lock", return_value=76,
                ))
                release = stack.enter_context(mock.patch.object(runtime, "release_lifecycle_lock"))
                stack.enter_context(mock.patch.object(runtime, "install_lifecycle", side_effect=install))
                stack.enter_context(mock.patch.dict(
                    runtime.os.environ, {"SUDO_UID": str(self.uid)}, clear=False,
                ))
                runtime.command_refresh_lifecycle(str(ROOT))
            self.assertEqual(target.read_bytes(), SOURCE.read_bytes())
            self.assertFalse(backup.exists())
            release.assert_called_once_with(76)

            with mock.patch.object(runtime, "LIFECYCLE", str(target)), \
                    mock.patch.object(runtime, "require_macos"), \
                    mock.patch.object(runtime, "require_root"), \
                    mock.patch.object(runtime, "load_attestation", return_value=authority), \
                    mock.patch.object(
                        runtime, "exact_runtime_identity",
                        return_value=(self.operator, self.operator, self.shared),
                    ), mock.patch.dict(
                        runtime.os.environ, {"SUDO_UID": str(self.uid + 1)}, clear=False,
                    ), mock.patch.object(runtime, "install_lifecycle") as install_again, \
                    self.assertRaises(SystemExit):
                runtime.command_refresh_lifecycle(str(ROOT))
            install_again.assert_not_called()

    def test_verify_refuses_root_before_executing_toolchain(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            toolchain = outer / "toolchain"
            script = toolchain / "codex" / "bin" / "codex.js"
            script.parent.mkdir(parents=True)
            node = toolchain / "node"
            runner = outer / "runner"
            for path in (script, node, runner):
                path.write_text("authority\n")
                os.chmod(path, 0o755)
            value = {
                "runner_path": str(runner), "runner_sha256": runtime.sha256(str(runner)),
                "node_path": str(node), "node_sha256": runtime.sha256(str(node)),
                "codex_script": str(script), "codex_script_sha256": runtime.sha256(str(script)),
                "operator_uid": self.uid,
            }
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "RUNNER", str(runner)))
                stack.enter_context(mock.patch.object(runtime, "LIFECYCLE", str(runner)))
                stack.enter_context(mock.patch.object(runtime, "TOOLCHAIN", str(toolchain)))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(runtime.os, "geteuid", return_value=0))
                stack.enter_context(mock.patch.object(runtime.os, "getuid", return_value=0))
                execute = stack.enter_context(mock.patch.object(runtime.subprocess, "run"))
                with self.assertRaises(SystemExit):
                    runtime.verify_authority(None)
            execute.assert_not_called()

    def test_missing_dedicated_auth_is_actionable_and_never_followed(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            codex_home = outer / ".codex"
            codex_home.mkdir(mode=0o700)
            auth = codex_home / "auth.json"
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(outer), "/usr/bin/false",
            ))
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                runtime.dedicated_auth_info(
                    str(auth),
                    runtime_user,
                    missing_error=(
                        "dedicated auth.json is absent; run "
                        "bin/swarm-codex-runtime.sh login, then retry verify"
                    ),
                    require_hardened_mode=True,
                )
            self.assertEqual(raised.exception.code, 2)
            self.assertIn("bin/swarm-codex-runtime.sh login", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())

            target = outer / "operator-auth.json"
            target.write_text("do not follow\n")
            target.chmod(0o600)
            auth.symlink_to(target)
            with self.assertRaises(SystemExit):
                runtime.dedicated_auth_info(
                    str(auth), runtime_user,
                    missing_error="missing",
                    require_hardened_mode=True,
                )
            auth.unlink()
            auth.write_text("{}\n")
            auth.chmod(0o600)
            with mock.patch.object(runtime.os, "open") as opened:
                runtime.dedicated_auth_info(
                    str(auth), runtime_user,
                    missing_error="missing",
                    require_hardened_mode=True,
                )
            opened.assert_not_called()
            auth.chmod(0o640)
            with self.assertRaises(SystemExit):
                runtime.dedicated_auth_info(
                    str(auth), runtime_user,
                    missing_error="missing",
                    require_hardened_mode=True,
                )
            runtime.dedicated_auth_info(
                str(auth), runtime_user,
                missing_error="missing",
                require_hardened_mode=False,
            )
            alias = codex_home / "auth-alias.json"
            os.link(auth, alias)
            with self.assertRaises(SystemExit):
                runtime.dedicated_auth_info(
                    str(auth), runtime_user,
                    missing_error="missing",
                    require_hardened_mode=False,
                )
            with self.assertRaises(SystemExit):
                runner.validate_runtime_auth_file(str(codex_home), self.uid, self.gid)
            alias.unlink()
            auth.chmod(0o600)
            runner.validate_runtime_auth_file(str(codex_home), self.uid, self.gid)
            auth.unlink()
            runner_stderr = io.StringIO()
            with contextlib.redirect_stderr(runner_stderr), self.assertRaises(SystemExit):
                runner.validate_runtime_auth_file(str(codex_home), self.uid, self.gid)
            self.assertIn("bin/swarm-codex-runtime.sh login", runner_stderr.getvalue())
            self.assertNotIn("Traceback", runner_stderr.getvalue())

    def test_secure_runtime_home_never_copies_operator_auth(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            operator_home = outer / "operator"
            operator_codex = operator_home / ".codex"
            operator_codex.mkdir(parents=True, mode=0o700)
            operator_auth = operator_codex / "auth.json"
            operator_auth.write_text('{"operator":"secret-sentinel"}\n')
            operator_auth.chmod(0o600)
            runtime_home = outer / "runtime"
            operator_user = pwd.struct_passwd((
                "operator", "x", self.uid, self.gid, "", str(operator_home), "/bin/zsh",
            ))
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))
            sentinel = operator_auth.read_bytes()
            with mock.patch.object(runtime, "reset_runtime_acl"):
                runtime.secure_runtime_home(runtime_user, operator_user)
            self.assertFalse((runtime_home / ".codex/auth.json").exists())
            self.assertEqual(operator_auth.read_bytes(), sentinel)
            config = runtime_home / ".codex/config.toml"
            self.assertEqual(
                config.read_bytes(), runtime.rendered_codex_config(operator_user.pw_uid),
            )
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
            self.assertEqual(config.stat().st_nlink, 1)

    def test_operator_config_proof_is_metadata_only_for_distinct_runtime_uid(self) -> None:
        runtime_uid = self.uid + 100
        runtime_home = "/Users/_runtime_fixture"
        runtime_user = pwd.struct_passwd((
            "_runtime_fixture", "x", runtime_uid, self.gid, "", runtime_home,
            "/usr/bin/false",
        ))

        def info(*, mode, uid=runtime_uid, gid=self.gid, ino, size=0, nlink=1):
            return types.SimpleNamespace(
                st_dev=41, st_ino=ino, st_mode=mode, st_uid=uid, st_gid=gid,
                st_nlink=nlink, st_size=size, st_mtime_ns=101, st_ctime_ns=102,
            )

        parent = info(mode=stat.S_IFDIR | 0o700, ino=10, nlink=2)
        config = info(mode=stat.S_IFREG | 0o600, ino=11, size=479)
        with mock.patch.object(
            runtime.os, "lstat", side_effect=[parent, config, config, parent],
        ), mock.patch.object(
            runtime.os, "open", side_effect=AssertionError("private config was opened"),
        ) as opened:
            runtime.verify_runtime_codex_config_metadata(runtime_user)
        opened.assert_not_called()

        expected = hashlib.sha256(runtime.rendered_codex_config(self.uid)).hexdigest()
        runtime.verify_codex_config_render_hash(self.uid, expected)
        for invalid in (None, "f" * 64, "not-a-digest"):
            with self.assertRaises(SystemExit):
                runtime.verify_codex_config_render_hash(self.uid, invalid)

        bad_mode = info(mode=stat.S_IFREG | 0o640, ino=11, size=479)
        with mock.patch.object(
            runtime.os, "lstat", side_effect=[parent, bad_mode, bad_mode, parent],
        ), self.assertRaises(SystemExit):
            runtime.verify_runtime_codex_config_metadata(runtime_user)

        replaced = info(mode=stat.S_IFREG | 0o600, ino=12, size=479)
        with mock.patch.object(
            runtime.os, "lstat", side_effect=[parent, config, replaced, parent],
        ), self.assertRaises(SystemExit):
            runtime.verify_runtime_codex_config_metadata(runtime_user)

    def test_named_profile_home_is_derived_and_never_touches_default_auth(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            runtime_home = outer / "runtime"
            default_home = runtime_home / ".codex"
            default_home.mkdir(parents=True, mode=0o700)
            default_auth = default_home / "auth.json"
            default_auth.write_text('{"profile":"default-sentinel"}\n')
            default_auth.chmod(0o640)
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))
            operator_user = pwd.struct_passwd((
                "operator", "x", self.uid, self.gid, "", str(outer), "/bin/zsh",
            ))
            sentinel = default_auth.read_bytes()

            with mock.patch.object(runtime, "reset_runtime_acl"):
                runtime.secure_runtime_home(runtime_user, operator_user, "team-a")

            profiles = runtime_home / ".codex-profiles"
            selected = profiles / "team-a"
            self.assertTrue(profiles.is_dir())
            self.assertTrue(selected.is_dir())
            self.assertEqual(stat.S_IMODE(profiles.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(selected.stat().st_mode), 0o700)
            self.assertEqual(default_auth.read_bytes(), sentinel)
            self.assertEqual(stat.S_IMODE(default_auth.stat().st_mode), 0o640)
            self.assertFalse((selected / "auth.json").exists())
            self.assertEqual(
                (selected / "config.toml").read_bytes(),
                runtime.rendered_codex_config(operator_user.pw_uid),
            )
            runner.validate_runtime_codex_config(
                str(selected), runtime_user.pw_uid, runtime_user.pw_gid,
                operator_user.pw_uid,
                hashlib.sha256(
                    runtime.rendered_codex_config(operator_user.pw_uid),
                ).hexdigest(),
            )
            selected_config = selected / "config.toml"
            selected_config.write_text("drift\n")
            selected_config.chmod(0o600)
            with self.assertRaises(SystemExit):
                runner.validate_runtime_codex_config(
                    str(selected), runtime_user.pw_uid, runtime_user.pw_gid,
                    operator_user.pw_uid,
                    hashlib.sha256(
                        runtime.rendered_codex_config(operator_user.pw_uid),
                    ).hexdigest(),
                )
            self.assertEqual(
                runtime.profile_codex_home(str(runtime_home), "team-a"),
                str(selected),
            )
            self.assertEqual(
                runner.profile_codex_home(str(runtime_home), "team-a"),
                str(selected),
            )

    def test_all_profile_config_render_is_byte_exact_and_rolls_back_as_one_update(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            root = Path(outer_raw)
            runtime_home = root / "runtime"
            default_home = runtime_home / ".codex"
            named_home = runtime_home / ".codex-profiles/team-a"
            named_home.mkdir(parents=True, mode=0o700)
            default_home.mkdir(mode=0o700)
            for directory in (runtime_home, runtime_home / ".codex-profiles", named_home, default_home):
                directory.chmod(0o700)
            default_config = default_home / "config.toml"
            named_config = named_home / "config.toml"
            default_config.write_bytes(b"old-default\n")
            named_config.write_bytes(b"old-named\n")
            default_config.chmod(0o640)
            named_config.chmod(0o600)
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))
            operator_user = pwd.struct_passwd((
                "operator", "x", self.uid, self.gid, "", str(root), "/bin/zsh",
            ))
            real_render = runtime.render_runtime_codex_config

            def fail_named(record, operator_uid, profile=runtime.DEFAULT_PROFILE):
                if profile == "team-a":
                    raise RuntimeError("injected named render failure")
                return real_render(record, operator_uid, profile)

            with mock.patch.object(
                runtime, "render_runtime_codex_config", side_effect=fail_named,
            ), self.assertRaisesRegex(RuntimeError, "injected named"):
                runtime.render_all_runtime_codex_configs_transactionally(
                    runtime_user, operator_user,
                )
            self.assertEqual(default_config.read_bytes(), b"old-default\n")
            self.assertEqual(named_config.read_bytes(), b"old-named\n")
            self.assertEqual(stat.S_IMODE(default_config.stat().st_mode), 0o640)

            runtime.render_all_runtime_codex_configs_transactionally(
                runtime_user, operator_user,
            )
            expected = runtime.rendered_codex_config(operator_user.pw_uid)
            self.assertEqual(default_config.read_bytes(), expected)
            self.assertEqual(named_config.read_bytes(), expected)
            self.assertEqual(stat.S_IMODE(default_config.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(named_config.stat().st_mode), 0o600)

    def test_profile_handle_and_runner_selector_grammar_are_exact(self) -> None:
        parent_pid = os.getpid()
        valid = [
            str(RUNNER_SOURCE), "--mode", "app-server", "--profile", "team-a",
            "--parent-pid", str(parent_pid), "--", *runner.APP_SERVER_ARGS,
        ]
        with mock.patch.object(runner.sys, "argv", valid):
            mode, profile, observed_parent, argv = runner.parse_command()
        self.assertEqual((mode, profile, observed_parent), ("app-server", "team-a", parent_pid))
        self.assertEqual(argv, list(runner.APP_SERVER_ARGS))

        verify = [str(RUNNER_SOURCE), "--verify", "--profile", "team-a"]
        with mock.patch.object(runner.sys, "argv", verify):
            self.assertEqual(
                runner.parse_command(), ("verify", "team-a", 0, []),
            )
        with mock.patch.object(
            runner.sys, "argv", [str(RUNNER_SOURCE), "--verify-fable-reviewer"],
        ):
            self.assertEqual(
                runner.parse_command(), ("verify-fable-reviewer", "default", 0, []),
            )

        for handle in ("Team", "-team", "team.profile", "a" * 33, "../escape", ""):
            with self.subTest(handle=handle), self.assertRaises(SystemExit):
                runtime.profile_codex_home("/Users/runtime", handle)
            with self.subTest(runner_handle=handle), self.assertRaises(SystemExit):
                runner.profile_codex_home("/Users/runtime", handle)

        misplaced = [
            str(RUNNER_SOURCE), "--parent-pid", str(parent_pid),
            "--profile", "team-a", "--", "--version",
        ]
        with mock.patch.object(runner.sys, "argv", misplaced), self.assertRaises(SystemExit):
            runner.parse_command()

        telemetry = [
            str(RUNNER_SOURCE), "--telemetry", "--profile", "team-a",
            "--parent-pid", str(parent_pid),
        ]
        with mock.patch.object(runner.sys, "argv", telemetry):
            self.assertEqual(
                runner.parse_command(), ("telemetry", "team-a", parent_pid, []),
            )
        for refused in (
            [str(RUNNER_SOURCE), "--telemetry", "--parent-pid", str(parent_pid)],
            [*telemetry, "--", "--version"],
        ):
            with self.subTest(telemetry_argv=refused), \
                    mock.patch.object(runner.sys, "argv", refused), self.assertRaises(SystemExit):
                runner.parse_command()

    def test_fable_mcp_home_config_template_is_the_fixed_single_tool_capability(self) -> None:
        source = ROOT / "templates/_base/codex/config.toml.template"
        self.assertEqual(source.read_bytes(), runtime.CODEX_CONFIG_TEMPLATE)
        rendered = runtime.rendered_codex_config(self.uid).decode("utf-8")
        self.assertIn('[mcp_servers.fable_reviewer]\n', rendered)
        self.assertIn('command = "/usr/bin/sudo"\n', rendered)
        self.assertIn(
            f'args = ["-n", "-H", "-u", "#{self.uid}", "--", '
            '"/usr/bin/python3", "-I", "-B", '
            '"/usr/local/libexec/qofi-fable-reviewer-mcp.py"]\n',
            rendered,
        )
        self.assertEqual(rendered.count('enabled_tools = ["adversarial_review"]'), 1)
        self.assertEqual(
            rendered.count('[mcp_servers.fable_reviewer.tools.adversarial_review]'), 1,
        )
        self.assertIn('required = true\n', rendered)
        self.assertIn('startup_timeout_sec = 10\n', rendered)
        self.assertIn('tool_timeout_sec = 4300\n', rendered)
        self.assertEqual(rendered.count('approval_mode = "approve"'), 2)
        self.assertNotIn("__QOFI_OPERATOR_UID__", rendered)

    def test_named_profile_auth_is_bound_to_its_selected_home(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            runtime_home = Path(outer_raw) / "runtime"
            selected = runtime_home / ".codex-profiles/team-a"
            other = runtime_home / ".codex-profiles/team-b"
            selected.mkdir(parents=True, mode=0o700)
            other.mkdir(mode=0o700)
            runtime_home.chmod(0o700)
            (runtime_home / ".codex-profiles").chmod(0o700)
            for home in (selected, other):
                home.chmod(0o700)
                auth = home / "auth.json"
                auth.write_text("{}\n")
                auth.chmod(0o600)
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))

            runtime.dedicated_auth_info(
                str(selected / "auth.json"), runtime_user, profile="team-a",
                missing_error="missing", require_hardened_mode=True,
            )
            with self.assertRaises(SystemExit):
                runtime.dedicated_auth_info(
                    str(other / "auth.json"), runtime_user, profile="team-a",
                    missing_error="missing", require_hardened_mode=True,
                )

            (selected / "auth.json").unlink()
            selected.rmdir()
            selected.symlink_to(other, target_is_directory=True)
            with self.assertRaises(SystemExit):
                runtime.dedicated_auth_info(
                    str(selected / "auth.json"), runtime_user, profile="team-a",
                    missing_error="missing", require_hardened_mode=True,
                )

    def test_named_profile_switches_the_entire_codex_home_environment(self) -> None:
        runtime_user = pwd.struct_passwd((
            "runtime", "x", self.uid, self.gid, "", "/Users/runtime", "/usr/bin/false",
        ))
        selected = "/Users/runtime/.codex-profiles/team-a"
        with mock.patch.object(
            runtime, "runtime_context_command", return_value=["/fixed/command"],
        ), mock.patch.object(runtime.subprocess, "run", return_value=completed([])) as execute:
            runtime.run_as_runtime(
                runtime_user, ["/fixed/command"], codex_home=selected,
            )
        self.assertEqual(execute.call_args.kwargs["env"]["CODEX_HOME"], selected)
        self.assertEqual(execute.call_args.kwargs["env"]["HOME"], runtime_user.pw_dir)

        authority = {
            "runtime_home": runtime_user.pw_dir,
            "runtime_user": runtime_user.pw_name,
            "codex_home": selected,
            "node_path": "/fixed/node",
        }
        self.assertEqual(runner.child_env(authority)["CODEX_HOME"], selected)

    def test_telemetry_reads_newest_rollout_latest_count_and_redacts_everything_else(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            codex_home = Path(outer_raw) / "profile"
            sessions = codex_home / "sessions/2026/07/12"
            sessions.mkdir(parents=True, mode=0o700)
            old = sessions / "rollout-old.jsonl"
            newest = sessions / "rollout-new.jsonl"
            old.write_text(json.dumps({
                "timestamp": "2026-07-12T00:00:00Z", "type": "event_msg",
                "payload": {"type": "token_count", "info": {"secret": "OLD_SECRET"},
                            "rate_limits": None},
            }) + "\n")
            lines = [
                {"timestamp": "2026-07-12T01:00:00Z", "type": "response_item",
                 "payload": {"prompt": "PROMPT_SECRET token_count auth.json /private/path"}},
                {"timestamp": "2026-07-12T01:01:00Z", "type": "event_msg",
                 "payload": {"type": "token_count", "info": {"prompt": "INFO_SECRET"},
                             "rate_limits": {"limit_name": "LABEL_SECRET",
                                 "primary": {"used_percent": 20, "window_minutes": 300,
                                             "resets_at": 1_800_000_000}}}},
                {"timestamp": "2026-07-12T01:02:00.123Z", "type": "event_msg",
                 "payload": {"type": "token_count", "info": {"auth": "AUTH_SECRET"},
                             "rate_limits": {
                                 "primary": {"used_percent": 86.5, "window_minutes": 300,
                                             "resets_at": 1_800_000_001,
                                             "injected": "WINDOW_SECRET"},
                                 "secondary": {"used_percent": 40, "window_minutes": 10080,
                                               "resets_at": 1_800_000_002},
                                 "credits": {"balance": "CREDIT_SECRET"}}}},
            ]
            newest.write_text("".join(json.dumps(line) + "\n" for line in lines))
            os.utime(old, ns=(1_700_000_000_000_000_000,) * 2)
            os.utime(newest, ns=(1_700_000_001_000_000_000,) * 2)
            authority = {
                "runtime_uid": self.uid, "runtime_primary_gid": self.gid,
                "codex_home": str(codex_home),
            }
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(runner.emit_latest_telemetry(authority), 0)
            observed = json.loads(stdout.getvalue())
            self.assertEqual(observed, {
                "timestamp": "2026-07-12T01:02:00.123Z",
                "rate_limits": {
                    "primary": {"used_percent": 86.5, "window_minutes": 300,
                                "resets_at": 1_800_000_001},
                    "secondary": {"used_percent": 40, "window_minutes": 10080,
                                  "resets_at": 1_800_000_002},
                },
            })
            rendered = stdout.getvalue()
            for secret in (
                "PROMPT_SECRET", "INFO_SECRET", "AUTH_SECRET", "LABEL_SECRET",
                "WINDOW_SECRET", "CREDIT_SECRET", "OLD_SECRET", "auth.json", "/private/path",
            ):
                self.assertNotIn(secret, rendered)

    def test_telemetry_latest_valid_count_supersedes_earlier_malformed_candidate(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            codex_home = Path(outer_raw) / "profile"
            sessions = codex_home / "sessions"
            sessions.mkdir(parents=True, mode=0o700)
            rollout = sessions / "rollout-latest.jsonl"
            latest = {
                "timestamp": "2026-07-12T03:00:00Z", "type": "event_msg",
                "payload": {"type": "token_count", "rate_limits": {
                    "primary": {"used_percent": 42, "window_minutes": 300,
                                "resets_at": 1_800_000_001},
                    "secondary": None,
                }},
            }
            rollout.write_text(
                '{"type":"event_msg","payload":{"type":"token_count"\n'
                + json.dumps(latest) + "\n",
            )
            authority = {
                "runtime_uid": self.uid, "runtime_primary_gid": self.gid,
                "codex_home": str(codex_home),
            }
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(runner.emit_latest_telemetry(authority), 0)
            self.assertEqual(json.loads(stdout.getvalue()), {
                "timestamp": "2026-07-12T03:00:00Z",
                "rate_limits": {
                    "primary": {"used_percent": 42, "window_minutes": 300,
                                "resets_at": 1_800_000_001},
                    "secondary": None,
                },
            })

    def test_telemetry_null_and_unsafe_rollouts_return_only_sanitized_envelopes(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            codex_home = Path(outer_raw) / "profile"
            sessions = codex_home / "sessions"
            sessions.mkdir(parents=True, mode=0o700)
            rollout = sessions / "rollout-null.jsonl"
            rollout.write_text(json.dumps({
                "timestamp": "2026-07-12T02:00:00Z", "type": "event_msg",
                "payload": {"type": "token_count", "info": {"secret": "NULL_SECRET"},
                            "rate_limits": None},
            }) + "\n")
            authority = {
                "runtime_uid": self.uid, "runtime_primary_gid": self.gid,
                "codex_home": str(codex_home),
            }
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                runner.emit_latest_telemetry(authority)
            self.assertEqual(json.loads(stdout.getvalue()), {
                "timestamp": "2026-07-12T02:00:00Z", "rate_limits": None,
            })
            self.assertNotIn("NULL_SECRET", stdout.getvalue())

            rollout.unlink()
            target = Path(outer_raw) / "outside-rollout"
            target.write_text("OUTSIDE_SECRET\n")
            rollout.symlink_to(target)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                runner.emit_latest_telemetry(authority)
            self.assertEqual(json.loads(stdout.getvalue()), {
                "status": "unknown", "reason": "unsafe-rollout",
            })
            self.assertNotIn("OUTSIDE_SECRET", stdout.getvalue())

    def test_named_login_uses_only_selected_home_and_labels_output(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            runtime_home = Path(outer_raw) / "runtime"
            selected = runtime_home / ".codex-profiles/team-a"
            selected.mkdir(parents=True, mode=0o700)
            runtime_home.chmod(0o700)
            (runtime_home / ".codex-profiles").chmod(0o700)
            selected.chmod(0o700)
            auth = selected / "auth.json"
            auth.write_text("{}\n")
            auth.chmod(0o600)
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))
            value = {
                "runtime_home": str(runtime_home),
                "codex_home": str(runtime_home / ".codex"),
                "node_path": "/fixed/node",
                "codex_script": "/fixed/codex.js",
            }
            calls: list[tuple[list[str], dict[str, object]]] = []

            def execute(_record, command, **kwargs):
                calls.append((command, kwargs))
                if command[-1] == "status":
                    return completed(command, stdout="Logged in using ChatGPT\n")
                return completed(command)

            stdout = io.StringIO()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(
                    runtime, "exact_runtime_identity",
                    return_value=(self.operator, runtime_user, self.shared),
                ))
                stack.enter_context(mock.patch.object(runtime, "acquire_lifecycle_lock", return_value=76))
                stack.enter_context(mock.patch.object(runtime, "release_lifecycle_lock"))
                secure = stack.enter_context(mock.patch.object(runtime, "secure_runtime_home"))
                stack.enter_context(mock.patch.object(runtime, "ensure_runtime_bootstrap"))
                stack.enter_context(mock.patch.object(runtime, "establish_empty_keychain_search"))
                stack.enter_context(mock.patch.object(runtime, "run_as_runtime", side_effect=execute))
                stack.enter_context(mock.patch.object(runtime, "quiesce_service_uid"))
                stack.enter_context(mock.patch.object(runtime, "verify_runtime_keychain_search_empty"))
                stack.enter_context(mock.patch.object(runtime, "validate_runtime_keychain_storage"))
                stack.enter_context(mock.patch.object(runtime, "strip_extended_acl_fd"))
                stack.enter_context(mock.patch.object(runtime, "fd_has_extended_acl", return_value=False))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                runtime.command_login(argparse.Namespace(profile="team-a"))

            secure.assert_called_once_with(runtime_user, self.operator, "team-a")
            provider_calls = [(command, kwargs) for command, kwargs in calls if command[2:3] == ["login"]]
            self.assertEqual(len(provider_calls), 2)
            for _command, kwargs in provider_calls:
                self.assertEqual(kwargs["codex_home"], str(selected))
            self.assertTrue(provider_calls[-1][1]["capture"])
            self.assertIn("profile team-a", stdout.getvalue())
            self.assertNotIn("{}", stdout.getvalue())

    def test_successful_login_without_auth_fails_cleanly_and_releases_lock(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            runtime_home = Path(outer_raw) / "runtime"
            runtime_home.mkdir(mode=0o700)
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))
            value = {
                "codex_home": str(runtime_home / ".codex"),
                "node_path": "/fixed/node",
                "codex_script": "/fixed/codex.js",
            }
            lock = 73
            stderr = io.StringIO()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(
                    runtime,
                    "exact_runtime_identity",
                    return_value=(self.operator, runtime_user, self.shared),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_lifecycle_lock", return_value=lock,
                ))
                release = stack.enter_context(mock.patch.object(runtime, "release_lifecycle_lock"))
                stack.enter_context(mock.patch.object(runtime, "secure_runtime_home"))
                stack.enter_context(mock.patch.object(runtime, "ensure_runtime_bootstrap"))
                stack.enter_context(mock.patch.object(
                    runtime,
                    "run_as_runtime",
                    return_value=completed(["codex", "login"]),
                ))
                stack.enter_context(mock.patch.object(runtime, "quiesce_service_uid"))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                with self.assertRaises(SystemExit) as raised:
                    runtime.command_login()
            self.assertEqual(raised.exception.code, 2)
            self.assertIn(
                "login exited successfully but did not create the dedicated auth.json",
                stderr.getvalue(),
            )
            self.assertNotIn("Traceback", stderr.getvalue())
            release.assert_called_once_with(lock)

    def test_login_requires_exact_chatgpt_status_before_success(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            runtime_home = Path(outer_raw) / "runtime"
            codex_home = runtime_home / ".codex"
            codex_home.mkdir(parents=True, mode=0o700)
            runtime_home.chmod(0o700)
            auth = codex_home / "auth.json"
            auth.write_text("{}\n")
            auth.chmod(0o600)
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))
            value = {
                "codex_home": str(codex_home),
                "node_path": "/fixed/node",
                "codex_script": "/fixed/codex.js",
            }
            calls: list[tuple[list[str], bool]] = []

            def execute(_record, command, capture=False):
                calls.append((command, capture))
                if command[-1] == "status":
                    return completed(command, stdout="Logged in using an API key\n")
                return completed(command)

            stderr = io.StringIO()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(
                    runtime,
                    "exact_runtime_identity",
                    return_value=(self.operator, runtime_user, self.shared),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_lifecycle_lock", return_value=74,
                ))
                release = stack.enter_context(mock.patch.object(runtime, "release_lifecycle_lock"))
                stack.enter_context(mock.patch.object(runtime, "secure_runtime_home"))
                stack.enter_context(mock.patch.object(runtime, "ensure_runtime_bootstrap"))
                stack.enter_context(mock.patch.object(runtime, "run_as_runtime", side_effect=execute))
                stack.enter_context(mock.patch.object(runtime, "quiesce_service_uid"))
                stack.enter_context(mock.patch.object(runtime, "strip_extended_acl_fd"))
                stack.enter_context(mock.patch.object(runtime, "fd_has_extended_acl", return_value=False))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                with self.assertRaises(SystemExit):
                    runtime.command_login()
            provider_calls = [call for call in calls if call[0][2:3] == ["login"]]
            self.assertEqual(provider_calls[-1][0][-1], "status")
            self.assertIn('forced_login_method="chatgpt"', provider_calls[0][0])
            self.assertIn('cli_auth_credentials_store="file"', provider_calls[0][0])
            self.assertIn('forced_login_method="chatgpt"', provider_calls[-1][0])
            self.assertIn('cli_auth_credentials_store="file"', provider_calls[-1][0])
            self.assertTrue(provider_calls[-1][1])
            self.assertIn("not exact ChatGPT auth", stderr.getvalue())
            release.assert_called_once_with(74)

    def test_login_success_rebinds_auth_after_exact_status(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            runtime_home = Path(outer_raw) / "runtime"
            codex_home = runtime_home / ".codex"
            codex_home.mkdir(parents=True, mode=0o700)
            runtime_home.chmod(0o700)
            auth = codex_home / "auth.json"
            auth.write_text("{}\n")
            auth.chmod(0o600)
            runtime_user = pwd.struct_passwd((
                "runtime", "x", self.uid, self.gid, "", str(runtime_home), "/usr/bin/false",
            ))
            value = {
                "codex_home": str(codex_home),
                "node_path": "/fixed/node",
                "codex_script": "/fixed/codex.js",
            }
            calls: list[list[str]] = []

            def execute(_record, command, capture=False):
                calls.append(command)
                if command[-1] == "status":
                    return completed(command, stdout="Logged in using ChatGPT\n")
                return completed(command)

            stdout = io.StringIO()
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(
                    runtime,
                    "exact_runtime_identity",
                    return_value=(self.operator, runtime_user, self.shared),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_lifecycle_lock", return_value=75,
                ))
                release = stack.enter_context(mock.patch.object(runtime, "release_lifecycle_lock"))
                stack.enter_context(mock.patch.object(runtime, "secure_runtime_home"))
                stack.enter_context(mock.patch.object(runtime, "ensure_runtime_bootstrap"))
                stack.enter_context(mock.patch.object(runtime, "run_as_runtime", side_effect=execute))
                stack.enter_context(mock.patch.object(runtime, "quiesce_service_uid"))
                stack.enter_context(mock.patch.object(runtime, "strip_extended_acl_fd"))
                stack.enter_context(mock.patch.object(runtime, "fd_has_extended_acl", return_value=False))
                bound = stack.enter_context(mock.patch.object(
                    runtime,
                    "open_dedicated_auth",
                    wraps=runtime.open_dedicated_auth,
                ))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                runtime.command_login()
            self.assertEqual(bound.call_count, 2)
            provider_calls = [call for call in calls if call[2:3] == ["login"]]
            security_calls = [call for call in calls if call[:1] == ["/usr/bin/security"]]
            self.assertEqual(provider_calls[-1][-1], "status")
            self.assertIn('forced_login_method="chatgpt"', provider_calls[0])
            self.assertIn('cli_auth_credentials_store="file"', provider_calls[0])
            self.assertEqual(security_calls[0][-1], "-s")
            self.assertEqual(security_calls[-1], [
                "/usr/bin/security", "list-keychains", "-d", "user",
            ])
            self.assertIn("dedicated ChatGPT login stored", stdout.getvalue())
            release.assert_called_once_with(75)

    def test_missing_attestation_uninstall_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            missing = outer / "missing-attestation"
            runner = outer / "runner"
            runner.write_text("keep\n")
            args = argparse.Namespace(remove_account=True)
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(runtime, "ATTESTATION", str(missing)))
                stack.enter_context(mock.patch.object(runtime, "RUNNER", str(runner)))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                lock = stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks",
                ))
                with self.assertRaises(SystemExit):
                    runtime.command_uninstall(args)
            self.assertEqual(runner.read_text(), "keep\n")
            lock.assert_not_called()

    def test_global_acl_cleanup_removes_only_exact_shared_traversal_aces(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            home = Path(outer_raw)
            channels = home / ".codex" / "channels"
            channels.mkdir(parents=True)
            for path in (home, home / ".codex", channels):
                path.chmod(0o700)
            operator = types.SimpleNamespace(pw_dir=str(home), pw_uid=self.uid)
            expected = (
                "user:runtime allow "
                + runtime.PERSISTENT_RUNTIME_TRAVERSAL_PERMISSIONS
            )
            state = {
                str(path): [f"0: {expected}"]
                for path in (home, home / ".codex", channels)
            }
            removed: list[str] = []

            def fake_run(command, **_kwargs):
                self.assertEqual(command[:4], ["/bin/chmod", "-h", "-a", expected])
                path = command[4]
                self.assertEqual(state[path], [f"0: {expected}"])
                state[path] = []
                removed.append(path)
                return completed(command)

            with mock.patch.object(runtime, "acl_entries", side_effect=lambda path: list(state[path])), \
                    mock.patch.object(runtime, "run", side_effect=fake_run):
                runtime.cleanup_persistent_runtime_traversal_acls(operator, "runtime")

            self.assertEqual(removed, [str(channels), str(home / ".codex"), str(home)])
            self.assertTrue(all(entries == [] for entries in state.values()))

    def test_global_acl_cleanup_preflights_every_path_and_preserves_foreign_acl(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            home = Path(outer_raw)
            channels = home / ".codex" / "channels"
            channels.mkdir(parents=True)
            for path in (home, home / ".codex", channels):
                path.chmod(0o700)
            operator = types.SimpleNamespace(pw_dir=str(home), pw_uid=self.uid)
            expected = (
                "user:runtime allow "
                + runtime.PERSISTENT_RUNTIME_TRAVERSAL_PERMISSIONS
            )
            state = {
                str(home): [f"0: {expected}"],
                str(home / ".codex"): ["0: everyone allow read"],
                str(channels): [f"0: {expected}"],
            }
            mutate = mock.Mock()

            with mock.patch.object(runtime, "acl_entries", side_effect=lambda path: list(state[path])), \
                    mock.patch.object(runtime, "run", side_effect=mutate):
                with self.assertRaises(SystemExit):
                    runtime.cleanup_persistent_runtime_traversal_acls(operator, "runtime")

            mutate.assert_not_called()
            self.assertEqual(state[str(home / ".codex")], ["0: everyone allow read"])
            self.assertEqual(state[str(home)], [f"0: {expected}"])

    def test_global_acl_cleanup_detects_path_replacement_after_exact_removal(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            home = Path(outer_raw)
            channels = home / ".codex" / "channels"
            channels.mkdir(parents=True)
            for path in (home, home / ".codex", channels):
                path.chmod(0o700)
            operator = types.SimpleNamespace(pw_dir=str(home), pw_uid=self.uid)
            expected = (
                "user:runtime allow "
                + runtime.PERSISTENT_RUNTIME_TRAVERSAL_PERMISSIONS
            )
            state = {
                str(path): [f"0: {expected}"]
                for path in (home, home / ".codex", channels)
            }

            def replace_after_remove(command, **_kwargs):
                path = command[4]
                state[path] = []
                original = Path(path)
                moved = original.with_name("channels-detached")
                original.rename(moved)
                original.mkdir(mode=0o700)
                return completed(command)

            with mock.patch.object(runtime, "acl_entries", side_effect=lambda path: list(state[path])), \
                    mock.patch.object(runtime, "run", side_effect=replace_after_remove):
                with self.assertRaises(SystemExit):
                    runtime.cleanup_persistent_runtime_traversal_acls(operator, "runtime")

            self.assertTrue((home / ".codex" / "channels-detached").is_dir())

    def test_uninstall_keeps_attestation_until_last_and_uses_operator_domain(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            paths = {
                "ATTESTATION": outer / "attestation",
                "MANAGER_AUTHORITY": outer / "manager-authority",
                "SUDOERS": outer / "sudoers",
                "WORKSPACE_REGISTRY": outer / "registry",
                "RUNNER": outer / "runner",
                "LIFECYCLE": outer / "lifecycle",
                "MANAGER_LAUNCHER": outer / "manager-launcher",
                "MANAGER_BUNDLE": outer / "manager-bundle",
                "FABLE_REVIEWER": outer / "fable-reviewer",
                "FABLE_DOCTRINE": outer / "fable-doctrine",
                "FABLE_SCHEMA": outer / "fable-schema",
                "TOOLCHAIN": outer / "toolchain",
            }
            for key in (
                "ATTESTATION", "MANAGER_AUTHORITY", "SUDOERS",
                "WORKSPACE_REGISTRY", "RUNNER", "LIFECYCLE",
                "MANAGER_LAUNCHER", "MANAGER_BUNDLE",
                "FABLE_REVIEWER", "FABLE_DOCTRINE", "FABLE_SCHEMA",
            ):
                paths[key].write_text(key)
            paths["TOOLCHAIN"].mkdir()
            (paths["TOOLCHAIN"] / "tool").write_text("tool")
            runtime_uid = self.uid + 100
            value = {
                "operator_uid": self.uid, "runtime_uid": runtime_uid,
                "runtime_user": "runtime", "runtime_group": "shared",
                "runtime_home": "/Users/_qofi_codex_test_fixture",
                "launchd_canary_name": "QOFI_CODEX_RUNTIME_CANARY_TEST1234",
            }
            commands: list[list[str]] = []
            unlinked: list[str] = []
            original_unlink = os.unlink

            def fake_run(command, **_kwargs):
                commands.append(command)
                return completed(command, stdout="")

            def tracked_unlink(path, *args, **kwargs):
                path_string = os.fspath(path)
                if path_string in {str(item) for item in paths.values()}:
                    unlinked.append(path_string)
                return original_unlink(path, *args, **kwargs)

            fake_pwd = types.SimpleNamespace(
                getpwuid=lambda _uid: self.operator,
                getpwnam=lambda _name: (_ for _ in ()).throw(KeyError(_name)),
            )
            args = argparse.Namespace(remove_account=False)
            with contextlib.ExitStack() as stack:
                for name, path in paths.items():
                    stack.enter_context(mock.patch.object(runtime, name, str(path)))
                stack.enter_context(mock.patch.object(
                    runtime, "MANAGER_ADMISSION", str(outer / "manager-admission"),
                ))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(runtime, "validate_manager_authority"))
                stack.enter_context(mock.patch.object(
                    runtime, "exact_runtime_identity",
                    return_value=(self.operator, self.operator, self.shared),
                ))
                stack.enter_context(mock.patch.object(runtime, "pwd", fake_pwd))
                stack.enter_context(mock.patch.object(runtime, "workspace_registry", return_value={}))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks", return_value=(91, 92),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "release_manager_mutation_locks",
                ))
                stack.enter_context(mock.patch.object(runtime, "ds_record", return_value=True))
                stack.enter_context(mock.patch.object(runtime, "run", side_effect=fake_run))
                stack.enter_context(mock.patch.object(runtime.os, "unlink", side_effect=tracked_unlink))
                cleanup_acl = stack.enter_context(mock.patch.object(
                    runtime, "cleanup_persistent_runtime_traversal_acls",
                ))
                runtime.command_uninstall(args)

            self.assertEqual(unlinked[-2:], [str(paths["ATTESTATION"]), str(paths["LIFECYCLE"])])
            self.assertTrue(all(not path.exists() for path in paths.values()))
            self.assertIn(
                ["/bin/launchctl", "asuser", str(self.uid), "/bin/launchctl", "getenv",
                 value["launchd_canary_name"]],
                commands,
            )
            cleanup_acl.assert_called_once_with(self.operator, "runtime")

    def test_remove_account_failure_retains_fixed_helper_for_recovery(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as outer_raw:
            outer = Path(outer_raw)
            paths = {
                "ATTESTATION": outer / "attestation",
                "MANAGER_AUTHORITY": outer / "manager-authority",
                "SUDOERS": outer / "sudoers",
                "WORKSPACE_REGISTRY": outer / "registry",
                "RUNNER": outer / "runner",
                "LIFECYCLE": outer / "lifecycle",
                "MANAGER_LAUNCHER": outer / "manager-launcher",
                "MANAGER_BUNDLE": outer / "manager-bundle",
                "FABLE_REVIEWER": outer / "fable-reviewer",
                "FABLE_DOCTRINE": outer / "fable-doctrine",
                "FABLE_SCHEMA": outer / "fable-schema",
                "TOOLCHAIN": outer / "toolchain",
            }
            for key in (
                "ATTESTATION", "MANAGER_AUTHORITY", "SUDOERS",
                "WORKSPACE_REGISTRY", "RUNNER", "LIFECYCLE",
                "MANAGER_LAUNCHER", "MANAGER_BUNDLE",
                "FABLE_REVIEWER", "FABLE_DOCTRINE", "FABLE_SCHEMA",
            ):
                paths[key].write_text(key)
            paths["TOOLCHAIN"].mkdir()
            runtime_uid = self.uid + 100
            value = {
                "operator_uid": self.uid, "runtime_uid": runtime_uid,
                "runtime_user": "runtime", "runtime_group": "shared",
                "runtime_home": "/Users/_qofi_codex_test_fixture_nonexistent",
                "launchd_canary_name": "QOFI_CODEX_RUNTIME_CANARY_TEST1234",
            }

            def fake_run(command, **_kwargs):
                if command[:4] == ["/usr/bin/dscl", ".", "-delete", "/Users/runtime"]:
                    raise RuntimeError("injected Directory Services deletion failure")
                return completed(command, stdout="")

            args = argparse.Namespace(remove_account=True)
            with contextlib.ExitStack() as stack:
                for name, path in paths.items():
                    stack.enter_context(mock.patch.object(runtime, name, str(path)))
                stack.enter_context(mock.patch.object(
                    runtime, "MANAGER_ADMISSION", str(outer / "manager-admission"),
                ))
                stack.enter_context(mock.patch.object(runtime, "require_macos"))
                stack.enter_context(mock.patch.object(runtime, "require_root"))
                stack.enter_context(mock.patch.object(runtime, "require_fixed_lifecycle"))
                stack.enter_context(mock.patch.object(runtime, "load_attestation", return_value=value))
                stack.enter_context(mock.patch.object(runtime, "validate_manager_authority"))
                stack.enter_context(mock.patch.object(
                    runtime, "exact_runtime_identity",
                    return_value=(self.operator, self.operator, self.shared),
                ))
                stack.enter_context(mock.patch.object(runtime, "workspace_registry", return_value={}))
                stack.enter_context(mock.patch.object(
                    runtime, "acquire_manager_mutation_locks", return_value=(94, 95),
                ))
                stack.enter_context(mock.patch.object(
                    runtime, "release_manager_mutation_locks",
                ))
                stack.enter_context(mock.patch.object(runtime, "ds_record", return_value=True))
                stack.enter_context(mock.patch.object(runtime, "run", side_effect=fake_run))
                stack.enter_context(mock.patch.object(
                    runtime, "cleanup_persistent_runtime_traversal_acls",
                ))
                with self.assertRaisesRegex(RuntimeError, "Directory Services"):
                    runtime.command_uninstall(args)
            self.assertFalse(paths["ATTESTATION"].exists())
            self.assertTrue(paths["LIFECYCLE"].exists())
            self.assertFalse(paths["RUNNER"].exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
