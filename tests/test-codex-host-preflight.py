#!/usr/bin/python3 -I
"""Pure capability-contract tests for codex-host-preflight.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "qofi_codex_host_preflight", ROOT / "bin" / "codex-host-preflight.py",
)
assert SPEC and SPEC.loader
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)
assert HOST.SUPPORTED_PNPM_VERSION == "9.12.3"


def expect_failure(fn, text: str) -> None:
    stderr = io.StringIO()
    try:
        with contextlib.redirect_stderr(stderr):
            fn()
    except SystemExit as exc:
        assert exc.code == 2, exc.code
    else:
        raise AssertionError("expected fail-closed SystemExit")
    assert text in stderr.getvalue(), stderr.getvalue()


assert HOST.validated_codex_version("codex-cli 0.144.1\n") == "0.144.1"
assert HOST.validated_codex_version("codex 0.144.9+audited\r\n") == "0.144.9"
for version_output, message in (
    ("codex-cli 0.144.1\nextra\n", "exactly one normalized line"),
    ("Codex CLI 0.144.1\n", "audited exact form"),
    ("codex-cli 0.143.9\n", "must be >=0.144.1 and <0.145.0"),
    ("codex-cli 0.145.0\n", "must be >=0.144.1 and <0.145.0"),
):
    expect_failure(
        lambda value=version_output: HOST.validated_codex_version(value),
        message,
    )


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value), encoding="utf-8")


if sys.platform == "darwin":
    assert HOST.safe_executable(
        "/usr/bin/sudo", "trusted sudo executable", [],
    ) == "/usr/bin/sudo"
    sudo = os.lstat("/usr/bin/sudo")
    sudo_shape = {
        "st_mode": sudo.st_mode,
        "st_uid": sudo.st_uid,
        "st_gid": sudo.st_gid,
        "st_nlink": sudo.st_nlink,
        "st_size": sudo.st_size,
    }
    assert HOST.is_execute_only_macos_sudo(
        "/usr/bin/sudo", "/usr/bin/sudo", SimpleNamespace(**sudo_shape),
    )
    for drift in (
        {"st_uid": os.getuid()},
        {"st_gid": os.getgid()},
        {"st_mode": stat.S_IFREG | 0o0511},
        {"st_mode": stat.S_IFLNK | 0o4511},
        {"st_nlink": 2},
        {"st_size": 0},
        {"st_size": 16 * 1024 * 1024 + 1},
    ):
        changed = {**sudo_shape, **drift}
        assert not HOST.is_execute_only_macos_sudo(
            "/usr/bin/sudo", "/usr/bin/sudo", SimpleNamespace(**changed),
        )
    assert not HOST.is_execute_only_macos_sudo(
        "/usr/bin/sudo", "/private/tmp/sudo", SimpleNamespace(**sudo_shape),
    )


with tempfile.TemporaryDirectory(
    prefix="codex-host-unreadable-wrapper-", dir=Path.home(),
) as raw:
    wrapper = Path(raw) / "operator-wrapper"
    wrapper.write_text("#!/usr/bin/env sh\nexit 0\n", encoding="utf-8")
    wrapper.chmod(0o100)
    expect_failure(
        lambda: HOST.safe_executable(str(wrapper), "unreadable operator wrapper", []),
        "interpreter cannot be verified",
    )


with tempfile.TemporaryDirectory(
    prefix="codex-host-viewer-home-", dir=Path.home(),
) as raw:
    account_home = Path(os.path.realpath(raw))
    repo = account_home / "repo"
    repo.mkdir()
    viewer = Path(HOST.prepare_viewer_codex_home(str(account_home), str(repo)))
    assert viewer.parent == account_home / ".qofi-codex-viewers"
    assert viewer == Path(HOST.prepare_viewer_codex_home(str(account_home), str(repo)))
    assert stat.S_IMODE(viewer.stat().st_mode) == 0o700
    other = account_home / "other-repo"
    other.mkdir()
    assert Path(HOST.prepare_viewer_codex_home(str(account_home), str(other))) != viewer
    viewer.chmod(0o755)
    expect_failure(
        lambda: HOST.prepare_viewer_codex_home(str(account_home), str(repo)),
        "owner-private canonical directory",
    )


with tempfile.TemporaryDirectory(
    prefix="codex-host-viewer-authority-", dir=Path.home(),
) as raw:
    root = Path(os.path.realpath(raw))
    toolchain = root / "toolchain"
    node = toolchain / "node"
    codex = toolchain / "codex" / "bin" / "codex.js"
    reviewer = toolchain / "qofi-fable-reviewer-mcp.py"
    doctrine = toolchain / "fable-reviewer-doctrine.md"
    schema = toolchain / "adversarial-review-output.schema.json"
    codex.parent.mkdir(parents=True)
    node.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    node.chmod(0o700)
    codex.write_text("// fixture Codex CLI\n", encoding="utf-8")
    reviewer.write_text("#!/usr/bin/python3\n", encoding="utf-8")
    reviewer.chmod(0o700)
    doctrine.write_text("fixture doctrine\n", encoding="utf-8")
    schema.write_text("{}\n", encoding="utf-8")
    attestation_path = root / "runtime.json"
    attestation = {
        "schema": HOST.ATTESTATION_SCHEMA,
        "operator_uid": os.getuid(),
        "runtime_uid": 65001,
        "runtime_user": "_qofi_fixture",
        "runtime_gid": 65002,
        "runtime_group": "_qofi_shared",
        "runtime_home": "/Users/_qofi_fixture",
        "codex_home": "/Users/_qofi_fixture/.codex",
        "runner_path": "/usr/local/libexec/qofi-codex-runner",
        "runner_sha256": "1" * 64,
        "node_path": str(node),
        "node_sha256": HOST.bounded_file_sha256(str(node)),
        "codex_script": str(codex),
        "codex_script_sha256": HOST.bounded_file_sha256(str(codex)),
        "launchd_canary_name": "QOFI_FIXTURE",
        "launchd_canary_sha256": "2" * 64,
        "fable_reviewer_path": str(reviewer),
        "fable_reviewer_sha256": HOST.bounded_file_sha256(str(reviewer)),
        "fable_doctrine_path": str(doctrine),
        "fable_doctrine_sha256": HOST.bounded_file_sha256(str(doctrine)),
        "fable_schema_path": str(schema),
        "fable_schema_sha256": HOST.bounded_file_sha256(str(schema)),
        "fable_reviewer_config_sha256": "3" * 64,
        "codex_config_sha256": "4" * 64,
    }
    viewer_options = {
        "path": str(attestation_path), "toolchain_root": str(toolchain),
        "require_root_owner": False,
    }
    write_json(attestation_path, attestation)
    assert HOST.optional_viewer_native_authority(**viewer_options) == (str(node), str(codex))

    attestation["node_sha256"] = "0" * 64
    write_json(attestation_path, attestation)
    assert HOST.optional_viewer_native_authority(**viewer_options) is None
    attestation["node_sha256"] = HOST.bounded_file_sha256(str(node))
    attestation["node_path"] = str(root / "other-node")
    write_json(attestation_path, attestation)
    assert HOST.optional_viewer_native_authority(**viewer_options) is None
    attestation["node_path"] = str(node)
    write_json(attestation_path, attestation)
    doctrine.write_text("drifted doctrine\n", encoding="utf-8")
    assert HOST.optional_viewer_native_authority(**viewer_options) == (str(node), str(codex))
    doctrine.write_text("fixture doctrine\n", encoding="utf-8")
    attestation["fable_doctrine_sha256"] = HOST.bounded_file_sha256(str(doctrine))
    write_json(attestation_path, attestation)

    # The live viewer may outlast a privileged lifecycle revision.  Its root
    # attestation already binds the exact Node/Codex bytes, so unrelated Fable
    # fields from a newer installer are intentionally not viewer prerequisites.
    legacy_attestation = {
        key: value for key, value in attestation.items()
        if not key.startswith("fable_") and key != "codex_config_sha256"
    }
    write_json(attestation_path, legacy_attestation)
    assert HOST.optional_viewer_native_authority(**viewer_options) == (str(node), str(codex))
    attestation_path.chmod(0o666)
    assert HOST.optional_viewer_native_authority(**viewer_options) is None


with tempfile.TemporaryDirectory(prefix="codex-host-dedicated-auth-") as raw:
    auth = Path(raw) / "auth.json"
    expect_failure(
        lambda: HOST.validate_dedicated_auth_metadata(auth, os.getuid(), os.getgid()),
        "bin/swarm-codex-runtime.sh login",
    )
    auth.write_text("{}", encoding="utf-8")
    auth.chmod(0o600)
    HOST.validate_dedicated_auth_metadata(str(auth), os.getuid(), os.getgid())
    alias = Path(raw) / "auth-alias.json"
    os.link(auth, alias)
    expect_failure(
        lambda: HOST.validate_dedicated_auth_metadata(auth, os.getuid(), os.getgid()),
        "must be runtime-owned mode 0600",
    )


with tempfile.TemporaryDirectory(prefix="codex-host-requirements-") as raw:
    repo = Path(raw)
    write_json(repo / "package.json", {
        "packageManager": "npm@10.8.0",
        "scripts": {"audit": "npx audit-tool"},
    })
    (repo / "package-lock.json").write_text("{}", encoding="utf-8")
    assert HOST.detect_project_tool_requirements(str(repo)) == {"node", "npm", "npx"}

    (repo / "package.json").unlink()
    (repo / "package-lock.json").unlink()
    write_json(repo / "package.json", {
        "packageManager": "bun@1.3.0",
        "scripts": {"test": "bun test"},
    })
    (repo / "bun.lock").write_text("", encoding="utf-8")
    assert HOST.detect_project_tool_requirements(str(repo)) == {"node", "bun"}

    (repo / "bun.lock").unlink()
    write_json(repo / "package.json", {"scripts": {"test": "node test.js"}})
    assert HOST.detect_project_tool_requirements(str(repo)) == {"node", "npm", "npx"}
    write_json(repo / "package.json", {
        "packageManager": "pnpm@9.12.3",
        "scripts": {"tools": "bun test; pnpm test && uv run pytest; cargo check; xcrun swift --version"},
    })
    assert HOST.detect_project_tool_requirements(str(repo)) == {
        "bun", "cargo", "node", "pnpm", "python3", "rustc", "swift", "uv", "xcrun",
    }
    (repo / "pnpm-lock.yaml").write_text("lockfileVersion: '9.0'\n", encoding="utf-8")
    write_json(repo / "package.json", {"packageManager": "pnpm@10.0.0"})
    expect_failure(
        lambda: HOST.detect_project_tool_requirements(str(repo)),
        "must exactly pin",
    )
    write_json(repo / "package.json", {
        "packageManager": "pnpm@9.12.3+sha512.not-the-audited-integrity",
    })
    expect_failure(
        lambda: HOST.detect_project_tool_requirements(str(repo)),
        "must exactly pin",
    )
    write_json(repo / "package.json", {"scripts": {"test": "pnpm test"}})
    expect_failure(
        lambda: HOST.detect_project_tool_requirements(str(repo)),
        "must declare packageManager",
    )
    (repo / "pnpm-lock.yaml").unlink()
    (repo / "bun.lock").write_text("", encoding="utf-8")
    write_json(repo / "package.json", {"packageManager": "bun@1.3.0"})

    for name in ("uv.lock", "Cargo.toml", "go.mod", "deno.json", "Package.swift"):
        (repo / name).write_text("", encoding="utf-8")
    (repo / "App.xcodeproj").mkdir()
    assert HOST.detect_project_tool_requirements(str(repo)) == {
        "bun", "cargo", "deno", "go", "node", "python3", "rustc",
        "swift", "swiftc", "uv", "xcodebuild", "xcrun",
    }

    write_json(repo / "package.json", {"packageManager": "unknown@1.0.0"})
    expect_failure(
        lambda: HOST.detect_project_tool_requirements(str(repo)),
        "packageManager is unsupported",
    )


with tempfile.TemporaryDirectory(prefix="codex-host-tools-") as raw:
    root = Path(os.path.realpath(raw))
    repo = root / "repo"
    tools = root / "tools"
    swarm = root / "swarm"
    repo.mkdir()
    tools.mkdir()
    swarm.mkdir()
    write_json(repo / "package.json", {"packageManager": "npm@10.0.0"})
    for name in ("node", "npm", "npx"):
        path = tools / name
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(0o700)
    required = HOST.validate_project_tool_requirements(
        str(repo), str(tools), [], dedicated=False,
        swarm_home=str(swarm), owner_uid=os.getuid(),
    )
    assert required == ["node", "npm", "npx"]
    output = "".join(f"{name}\t{(tools / name).resolve()}\n" for name in required)
    assert HOST.validate_runner_tool_probe_output(output, required, str(tools)) == {
        name: str((tools / name).resolve()) for name in required
    }
    expect_failure(
        lambda: HOST.validate_runner_tool_probe_output(
            output + f"node\t{(tools / 'node').resolve()}\n", required, str(tools),
        ),
        "malformed output",
    )
    (tools / "npx").unlink()
    expect_failure(
        lambda: HOST.validate_project_tool_requirements(
            str(repo), str(tools), [], dedicated=True,
            swarm_home=str(swarm), owner_uid=os.getuid(),
        ),
        "baseline root tool 'npx'",
    )

    (tools / "npx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (tools / "npx").chmod(0o700)
    write_json(repo / "package.json", {"packageManager": "pnpm@9.12.3"})
    expect_failure(
        lambda: HOST.validate_project_tool_requirements(
            str(repo), str(tools), [], dedicated=True,
            swarm_home=str(swarm), owner_uid=os.getuid(),
        ),
        "baseline root tool 'pnpm'",
    )

    (repo / "package.json").unlink()
    (repo / "Cargo.toml").write_text("", encoding="utf-8")
    expect_failure(
        lambda: HOST.validate_project_tool_requirements(
            str(repo), str(tools), [], dedicated=True,
            swarm_home=str(swarm), owner_uid=os.getuid(),
        ),
        "does not provide a supported root provisioning route",
    )


assert HOST.runner_child_path("/usr/local/libexec/qofi-codex-toolchain/node") == (
    "/usr/local/libexec/qofi-codex-toolchain/bin:"
    "/usr/local/libexec/qofi-codex-toolchain:/usr/bin:/bin:/usr/sbin:/sbin"
)


canary = "fixture_operator_canary-1234567890"
canary_hash = HOST.hashlib.sha256(canary.encode("utf-8")).hexdigest()
assert HOST.validated_operator_canary_value(f"{canary}\n", canary_hash) == canary
expect_failure(
    lambda: HOST.validated_operator_canary_value(f"{canary}\nextra\n", canary_hash),
    "does not match the root attestation",
)
for unsafe_canary in (
    "short",
    "fixture|operator-canary-1234",
    "fixture operator canary 1234",
    "fixture\toperator-canary-1234",
    "x" * 257,
):
    unsafe_hash = HOST.hashlib.sha256(unsafe_canary.encode("utf-8")).hexdigest()
    expect_failure(
        lambda value=unsafe_canary, digest=unsafe_hash: HOST.validated_operator_canary_value(
            f"{value}\n", digest,
        ),
        "bounded safe ASCII",
    )


HOST.require_live_shared_group(42, [20, 42])
expect_failure(
    lambda: HOST.require_live_shared_group(42, [20]),
    "log out/in, restart the operator tmux server",
)


with tempfile.TemporaryDirectory(prefix="codex-host-workspace-boundary-") as raw:
    repo = Path(os.path.realpath(raw)) / "repo"
    repo.mkdir()
    (repo / ".git").mkdir()
    (repo / "nested" / ".git").mkdir(parents=True)
    expect_failure(
        lambda: HOST.assert_workspace_acl_git_boundary(str(repo)),
        "nested repository",
    )
    (repo / "nested" / ".git").rmdir()
    HOST.assert_workspace_acl_git_boundary(str(repo))
    if sys.platform == "darwin":
        target = repo / "target"
        target.write_text("data\n", encoding="utf-8")
        subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(target)], check=True)
        expect_failure(
            lambda: HOST.assert_workspace_acl_git_boundary(str(repo)),
            "unexpected ACL",
        )
        subprocess.run(["/bin/chmod", "-N", str(target)], check=True)


with tempfile.TemporaryDirectory(prefix="codex-host-runner-source-") as raw:
    swarm = Path(os.path.realpath(raw)) / "swarm"
    source = swarm / "bin" / "qofi-codex-runner"
    source.parent.mkdir(parents=True)
    source.write_text("#!/usr/bin/python3\n", encoding="utf-8")
    source.chmod(0o700)
    digest = HOST.bounded_file_sha256(str(source))
    assert HOST.verify_current_runner_source(str(swarm), os.getuid(), digest) == str(source)
    expect_failure(
        lambda: HOST.verify_current_runner_source(str(swarm), os.getuid(), "0" * 64),
        "differs from the current trusted repository source",
    )


with tempfile.TemporaryDirectory(prefix="codex-host-probe-cleanup-") as raw:
    pid_file = Path(raw) / "pid"
    old_timeout = HOST.PROBE_TIMEOUT
    HOST.PROBE_TIMEOUT = 0.15
    try:
        expect_failure(
            lambda: HOST.bounded_probe(
                "/bin/sh",
                ["-c", 'echo $$ > "$1"; trap "" TERM; while :; do sleep 1; done', "sh", str(pid_file)],
                {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                "hostile probe",
            ),
            "timed out",
        )
    finally:
        HOST.PROBE_TIMEOUT = old_timeout
    probe_pid = int(pid_file.read_text(encoding="utf-8").strip())
    try:
        os.kill(probe_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("hostile probe leader survived TERM/grace/KILL cleanup")


with tempfile.TemporaryDirectory(prefix="codex-operator-review-") as raw:
    codex_home = Path(os.path.realpath(raw)) / ".codex"
    codex_home.mkdir(mode=0o700)
    review = HOST.prepare_operator_review_workspace(str(codex_home))
    assert Path(review).is_dir()
    assert stat.S_IMODE(Path(review).stat().st_mode) == 0o700
    args = HOST.replace_review_cwd(
        ["exec", "--ephemeral", "-C", "/untrusted/repo", "-"], review,
    )
    assert args == ["exec", "--ephemeral", "-C", review, "-"]
    expect_failure(
        lambda: HOST.replace_review_cwd(["exec", "--ephemeral", "-"], review),
        "exactly one cwd option",
    )
    (Path(review) / "unexpected").write_text("drift\n", encoding="utf-8")
    expect_failure(
        lambda: HOST.prepare_operator_review_workspace(str(codex_home)),
        "ACL-free and empty",
    )


with tempfile.TemporaryDirectory(prefix="codex-operator-review-auth-") as raw:
    root = Path(os.path.realpath(raw))
    account_home = root / "home"
    codex_home = account_home / ".codex"
    account_home.mkdir(mode=0o700)
    codex_home.mkdir(mode=0o700)
    auth = codex_home / "auth.json"

    def write_auth(payload: bytes = b"{}\n") -> None:
        auth.write_bytes(payload)
        auth.chmod(0o600)

    write_auth()
    attested = HOST.attest_operator_review_auth(str(account_home), str(codex_home))
    assert attested.auth_path == str(auth)
    HOST.revalidate_operator_review_auth(attested)

    auth.chmod(0o644)
    expect_failure(
        lambda: HOST.attest_operator_review_auth(str(account_home), str(codex_home)),
        "regular mode 0600",
    )
    auth.unlink()
    write_auth(b"x" * (1024 * 1024 + 1))
    expect_failure(
        lambda: HOST.attest_operator_review_auth(str(account_home), str(codex_home)),
        "bounded to 1 MiB",
    )

    auth.unlink()
    target = codex_home / "real-auth.json"
    target.write_text("{}\n", encoding="utf-8")
    target.chmod(0o600)
    auth.symlink_to(target.name)
    expect_failure(
        lambda: HOST.attest_operator_review_auth(str(account_home), str(codex_home)),
        "canonical current-user regular",
    )
    auth.unlink()
    target.unlink()

    write_auth()
    attested = HOST.attest_operator_review_auth(str(account_home), str(codex_home))
    replacement = codex_home / "auth.json.replacement"
    replacement.write_text("{}\n", encoding="utf-8")
    replacement.chmod(0o600)
    os.replace(replacement, auth)
    expect_failure(
        lambda: HOST.revalidate_operator_review_auth(attested),
        "changed during preflight",
    )

    if sys.platform == "darwin":
        subprocess.run(
            ["/bin/chmod", "+a", "everyone deny delete", str(account_home)], check=True,
        )
        try:
            HOST.attest_operator_review_auth(str(account_home), str(codex_home))
        finally:
            subprocess.run(["/bin/chmod", "-N", str(account_home)], check=True)

        subprocess.run(
            ["/bin/chmod", "+a", "everyone allow read", str(auth)], check=True,
        )
        expect_failure(
            lambda: HOST.attest_operator_review_auth(str(account_home), str(codex_home)),
            "extended ACL",
        )
        subprocess.run(["/bin/chmod", "-N", str(auth)], check=True)

        subprocess.run(
            ["/bin/chmod", "+a", "everyone allow search", str(codex_home)], check=True,
        )
        expect_failure(
            lambda: HOST.attest_operator_review_auth(str(account_home), str(codex_home)),
            "extended ACL",
        )
        subprocess.run(["/bin/chmod", "-N", str(codex_home)], check=True)

print("codex host preflight capability contract: OK")
