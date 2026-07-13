#!/usr/bin/python3 -I
"""Normalize Codex Companion v1 adversarial reviews into Qofi's v2 contract.

The installed Claude -> Codex plugin remains the producer and owner of its raw
v1 job records.  This repo-controlled boundary consumes either the plugin's
foreground ``--json`` result or an exported ``result --json``/job record,
validates the legacy contract, and writes a private canonical-v2 sidecar.

The legacy plugin does not expose an attested hash of the bytes it reviewed.
This program deliberately does not recapture a mutable Git diff: its sidecars
therefore carry a null reviewed-diff hash and explicit unavailable provenance.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import pwd
import re
import secrets
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


ARTIFACT_SCHEMA = "qofi-legacy-codex-review-artifact/v1"
SOURCE_CONTRACT = "openai-codex-companion-adversarial-review/v1"
PROVENANCE_STATUS = "unavailable-legacy-plugin"
MAX_SOURCE_BYTES = 2 * 1024 * 1024
MAX_ARTIFACT_BYTES = 1024 * 1024
MAX_PLUGIN_REGISTRY_BYTES = 1024 * 1024
MAX_PLUGIN_FILE_BYTES = 4 * 1024 * 1024
SAFE_JOB = re.compile(r"^review-[a-z0-9-]{1,127}$")
SAFE_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+){2}(?:[-+][A-Za-z0-9.-]+)?$")
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_FABLE_CONTRACT = None


class NormalizeError(RuntimeError):
    """Fail-closed legacy review or local result-set error."""


@dataclass(frozen=True)
class LegacyReview:
    value: Dict[str, object]
    source_job_id: Optional[str]


def compact_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def exact_keys(value: Mapping[str, object], expected: Iterable[str]) -> bool:
    return set(value) == set(expected)


def valid_text(value: object, *, maximum: int, minimum: int = 1) -> bool:
    return (
        isinstance(value, str)
        and minimum <= len(value) <= maximum
        and len(value.encode("utf-8", "strict")) <= maximum * 4
        and CONTROL.search(value) is None
    )


def _load_fable_contract():
    global _FABLE_CONTRACT
    if _FABLE_CONTRACT is not None:
        return _FABLE_CONTRACT
    source = Path(__file__).resolve().with_name("qofi-fable-reviewer-mcp.py")
    spec = importlib.util.spec_from_file_location("qofi_fable_contract_for_legacy_normalizer", source)
    if spec is None or spec.loader is None:
        raise NormalizeError("canonical adversarial-review contract is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    _FABLE_CONTRACT = module
    return _FABLE_CONTRACT


def validate_v2_result(value: object) -> Dict[str, object]:
    """Use the same schema and confidentiality gate as the Fable MCP."""

    try:
        return _load_fable_contract().validate_v2_result(value)
    except Exception as exc:
        raise NormalizeError("invalid or confidential canonical review result") from exc


def legacy_v1_to_v2(value: object) -> Dict[str, object]:
    """Delegate to the single canonical mapper shared with the Fable shim."""

    try:
        mapped = _load_fable_contract().legacy_v1_to_v2(value)
    except Exception as exc:
        raise NormalizeError("invalid legacy review result") from exc
    return validate_v2_result(mapped)


def _legacy_from_payload(payload: object) -> Optional[Dict[str, object]]:
    if not isinstance(payload, dict) or payload.get("review") != "Adversarial Review":
        return None
    result = payload.get("result")
    return result if isinstance(result, dict) else None


def extract_legacy_review(value: object) -> LegacyReview:
    """Extract only known raw/foreground/exported/job v1 plugin shapes."""

    if isinstance(value, dict) and exact_keys(value, ("verdict", "summary", "findings", "next_steps")):
        return LegacyReview(value=value, source_job_id=None)

    payload = _legacy_from_payload(value)
    if payload is not None:
        return LegacyReview(value=payload, source_job_id=None)

    if isinstance(value, dict) and set(value) == {"job", "storedJob"}:
        job, stored = value.get("job"), value.get("storedJob")
        if not isinstance(job, dict) or not isinstance(stored, dict):
            raise NormalizeError("invalid exported plugin job")
        if job.get("kind") != "adversarial-review" or stored.get("kind") != "adversarial-review":
            raise NormalizeError("exported job is not an adversarial review")
        job_id = job.get("id")
        if not isinstance(job_id, str) or not SAFE_JOB.fullmatch(job_id) or stored.get("id") != job_id:
            raise NormalizeError("exported plugin job identity is invalid")
        if stored.get("status") != "completed":
            raise NormalizeError("exported plugin job is not complete")
        payload = _legacy_from_payload(stored.get("result"))
        if payload is None:
            raise NormalizeError("exported plugin job has no v1 review result")
        return LegacyReview(value=payload, source_job_id=job_id)

    if isinstance(value, dict) and value.get("kind") == "adversarial-review":
        job_id = value.get("id")
        if not isinstance(job_id, str) or not SAFE_JOB.fullmatch(job_id) or value.get("status") != "completed":
            raise NormalizeError("plugin job record is incomplete or malformed")
        payload = _legacy_from_payload(value.get("result"))
        if payload is None:
            raise NormalizeError("plugin job record has no v1 review result")
        return LegacyReview(value=payload, source_job_id=job_id)

    raise NormalizeError("input is not a recognized Codex Companion v1 review result")


def normalize_source(source: bytes) -> Tuple[Dict[str, object], Optional[str], str]:
    if not source or len(source) > MAX_SOURCE_BYTES:
        raise NormalizeError("legacy review source is empty or too large")
    try:
        decoded = source.decode("utf-8", "strict")
        parsed = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise NormalizeError("legacy review source is not valid JSON") from exc
    legacy = extract_legacy_review(parsed)
    return legacy_v1_to_v2(legacy.value), legacy.source_job_id, hashlib.sha256(source).hexdigest()


def _assert_directory(path: Path, *, private: bool) -> os.stat_result:
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise NormalizeError("review result-set directory is not an owner-real directory")
    mode = stat.S_IMODE(info.st_mode)
    if (private and mode != 0o700) or (not private and mode & 0o022):
        raise NormalizeError("review result-set directory has unsafe permissions")
    return info


def _ensure_private_child(parent: Path, name: str) -> Path:
    _assert_directory(parent, private=False)
    child = parent / name
    try:
        os.mkdir(child, 0o700)
    except FileExistsError:
        pass
    _assert_directory(child, private=True)
    return child


def default_result_root() -> Path:
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    _assert_directory(home, private=False)
    claude = home / ".claude"
    _assert_directory(claude, private=False)
    return _ensure_private_child(claude, "qofi-review-result-sets")


def result_set_directory(repo: Path, root: Optional[Path] = None) -> Tuple[Path, str]:
    try:
        canonical = repo.resolve(strict=True)
    except OSError as exc:
        raise NormalizeError("review repository does not exist") from exc
    if not canonical.is_dir():
        raise NormalizeError("review repository is not a directory")
    repository_key = hashlib.sha256(str(canonical).encode("utf-8", "strict")).hexdigest()
    selected = default_result_root() if root is None else root
    _assert_directory(selected, private=True)
    return _ensure_private_child(selected, repository_key[:16]), repository_key


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def build_artifact(
    result: Dict[str, object],
    *,
    repository_key: str,
    source_hash: str,
    source_job_id: Optional[str],
    now: Optional[dt.datetime] = None,
) -> Dict[str, object]:
    stamp = (now or utc_now()).astimezone(dt.timezone.utc)
    return {
        "schema": ARTIFACT_SCHEMA,
        "reviewer": "openai-codex",
        "source_contract": SOURCE_CONTRACT,
        "source_job_id": source_job_id,
        "repository_key": repository_key,
        "reviewed_diff_sha256": None,
        "provenance_status": PROVENANCE_STATUS,
        "source_payload_sha256": source_hash,
        "created_at": stamp.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "result": validate_v2_result(result),
    }


def write_artifact(directory: Path, artifact: Dict[str, object]) -> Path:
    _assert_directory(directory, private=True)
    payload = compact_json(artifact)
    if len(payload) > MAX_ARTIFACT_BYTES:
        raise NormalizeError("normalized review artifact is too large")
    timestamp = str(artifact["created_at"]).replace("-", "").replace(":", "").replace(".", "")
    name = "codex-review-%s-%s.json" % (timestamp, secrets.token_hex(8))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    path = directory / name
    fd = os.open(path, flags, 0o600)
    complete = False
    try:
        os.fchmod(fd, 0o600)
        written = 0
        while written < len(payload):
            written += os.write(fd, payload[written:])
        os.fsync(fd)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise NormalizeError("normalized review artifact is not private")
        complete = True
    finally:
        os.close(fd)
        if not complete:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
    return path


def ingest_source(source: bytes, repo: Path, *, result_root: Optional[Path] = None) -> Tuple[Dict[str, object], Path]:
    result, job_id, source_hash = normalize_source(source)
    directory, repository_key = result_set_directory(repo, result_root)
    artifact = build_artifact(
        result,
        repository_key=repository_key,
        source_hash=source_hash,
        source_job_id=job_id,
    )
    return artifact, write_artifact(directory, artifact)


def _safe_plugin_file(path: Path, root: Path, *, executable: bool = False) -> Path:
    raw_root = Path(os.path.abspath(root))
    raw_path = Path(os.path.abspath(path))
    try:
        relative = raw_path.relative_to(raw_root)
    except ValueError as exc:
        raise NormalizeError("plugin file escapes its install root") from exc
    current = raw_root
    for part in relative.parts:
        current = current / part
        info = os.lstat(current)
        if stat.S_ISLNK(info.st_mode) or info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022:
            raise NormalizeError("plugin install path has unsafe ownership or permissions")
    info = os.lstat(raw_path)
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_PLUGIN_FILE_BYTES:
        raise NormalizeError("plugin program is not a bounded regular file")
    if executable and not info.st_mode & 0o111:
        raise NormalizeError("plugin program is not executable")
    return raw_path


def discover_companion(home: Optional[Path] = None) -> Path:
    selected_home = Path(pwd.getpwuid(os.getuid()).pw_dir) if home is None else home
    plugin_root = selected_home / ".claude" / "plugins"
    registry = plugin_root / "installed_plugins.json"
    info = os.lstat(registry)
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o022
        or not 1 <= info.st_size <= MAX_PLUGIN_REGISTRY_BYTES
    ):
        raise NormalizeError("Claude plugin registry is unsafe")
    try:
        installed = json.loads(registry.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise NormalizeError("Claude plugin registry is unreadable") from exc
    records = installed.get("plugins", {}).get("codex@openai-codex") if isinstance(installed, dict) else None
    if not isinstance(records, list) or not records:
        raise NormalizeError("OpenAI Codex Companion is not installed")
    candidates = []
    cache_root = plugin_root / "cache" / "openai-codex" / "codex"
    for record in records:
        if not isinstance(record, dict) or record.get("scope") != "user":
            continue
        version, path = record.get("version"), record.get("installPath")
        if not isinstance(version, str) or not SAFE_VERSION.fullmatch(version) or not isinstance(path, str):
            continue
        candidate = Path(path)
        try:
            candidate.relative_to(cache_root)
        except ValueError:
            continue
        if candidate.name != version:
            continue
        candidates.append((str(record.get("installedAt", "")), version, candidate))
    if not candidates:
        raise NormalizeError("OpenAI Codex Companion registry entry is invalid")
    _, version, install = sorted(candidates)[-1]
    manifest = _safe_plugin_file(install / ".claude-plugin" / "plugin.json", cache_root)
    companion = _safe_plugin_file(install / "scripts" / "codex-companion.mjs", cache_root)
    try:
        metadata = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise NormalizeError("OpenAI Codex Companion manifest is invalid") from exc
    if metadata.get("name") != "codex" or metadata.get("version") != version:
        raise NormalizeError("OpenAI Codex Companion manifest does not match its registry")
    return companion


def _load_trusted_cli():
    source = Path(__file__).resolve().with_name("trusted-cli.py")
    spec = importlib.util.spec_from_file_location("qofi_trusted_cli_for_review_normalizer", source)
    if spec is None or spec.loader is None:
        raise NormalizeError("trusted CLI resolver is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_companion(repo: Path, *, base: Optional[str], scope: Optional[str], focus: Sequence[str]) -> bytes:
    for key in ("OPENAI_API_KEY", "CODEX_API_KEY"):
        if os.environ.get(key):
            raise NormalizeError("metered Codex credentials are not accepted")
    if base is not None and (not 1 <= len(base) <= 512 or CONTROL.search(base)):
        raise NormalizeError("invalid review base")
    if scope not in (None, "auto", "working-tree", "branch"):
        raise NormalizeError("invalid review scope")
    if len(focus) > 64 or any(not valid_text(item, maximum=1024) for item in focus):
        raise NormalizeError("invalid review focus")
    canonical_repo = repo.resolve(strict=True)
    if not canonical_repo.is_dir():
        raise NormalizeError("review repository is not a directory")
    companion = discover_companion()
    trusted_cli = _load_trusted_cli()
    try:
        node = trusted_cli.resolve_cli("node", workspace=canonical_repo, swarm_home=Path(__file__).resolve().parent.parent)
    except Exception as exc:
        raise NormalizeError("trusted Node runtime is unavailable") from exc
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    plugin_data = _ensure_private_child(home / ".claude", "qofi-review-plugin-data")
    runner = Path(__file__).resolve().with_name("review-runner.py")
    if runner.is_symlink() or not runner.is_file():
        raise NormalizeError("bounded review runner is unavailable")
    plugin_args = [str(node), str(companion), "adversarial-review", "--wait", "--json", "--model", "gpt-5.6-sol", "--cwd", str(canonical_repo)]
    if base is not None:
        plugin_args.extend(("--base", base))
    if scope is not None:
        plugin_args.extend(("--scope", scope))
    plugin_args.extend(focus)
    user = pwd.getpwuid(os.getuid()).pw_name
    path = "%s:/usr/bin:/bin:/usr/sbin:/sbin" % node.parent
    command = [
        "/usr/bin/python3", "-I", "-B", str(runner),
        "--cwd", str(canonical_repo), "--timeout", "600", "--max-input", "1024",
        "--max-output", str(MAX_SOURCE_BYTES), "--clean-env",
        "--set-env", "HOME=%s" % home, "--set-env", "PATH=%s" % path,
        "--set-env", "USER=%s" % user, "--set-env", "LOGNAME=%s" % user,
        "--set-env", "CLAUDE_PLUGIN_DATA=%s" % plugin_data,
        "--", *plugin_args,
    ]
    completed = subprocess.run(command, input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if completed.returncode != 0:
        raise NormalizeError("Codex Companion review failed")
    if completed.stderr or not completed.stdout or len(completed.stdout) > MAX_SOURCE_BYTES:
        raise NormalizeError("Codex Companion did not return bounded JSON")
    return completed.stdout


def _read_stdin() -> bytes:
    source = sys.stdin.buffer.read(MAX_SOURCE_BYTES + 1)
    if len(source) > MAX_SOURCE_BYTES:
        raise NormalizeError("legacy review source is too large")
    return source


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Normalize Codex Companion v1 adversarial reviews into Qofi v2 result sets.")
    sub = parser.add_subparsers(dest="command", required=True)
    ingest = sub.add_parser("ingest", help="ingest raw/foreground/exported plugin JSON from stdin")
    ingest.add_argument("--repo", default=".")
    run = sub.add_parser("run", help="run the installed plugin in foreground JSON mode, then ingest it")
    run.add_argument("--repo", default=".")
    run.add_argument("--base")
    run.add_argument("--scope", choices=("auto", "working-tree", "branch"))
    run.add_argument("focus", nargs="*")
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    try:
        args = parse_args(argv)
        repo = Path(args.repo)
        source = _read_stdin() if args.command == "ingest" else run_companion(
            repo, base=args.base, scope=args.scope, focus=args.focus,
        )
        artifact, path = ingest_source(source, repo)
        # The persisted path can include a local account name; return only the
        # non-secret artifact and basename to model-visible output.
        print(json.dumps({"artifact": artifact, "artifact_file": path.name}, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except (NormalizeError, OSError, ValueError) as exc:
        print("qofi-review-normalize: ADVISORY-DOWN — %s" % exc, file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
