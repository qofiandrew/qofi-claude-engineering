#!/usr/bin/env bash
# Keep Python-only regressions and syntax checks inside the canonical shell suite.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

/usr/bin/python3 -I -B "$ROOT/tests/test-trusted-cli.py"
/usr/bin/python3 -I -B "$ROOT/tests/test-qofi-review-normalize.py"
/usr/bin/python3 -I -B "$ROOT/tests/test-codex-host-preflight.py"
/usr/bin/python3 -I -B "$ROOT/tests/test-codex-manager-control.py"
/usr/bin/python3 -I -B "$ROOT/tests/test-codex-runtime-provisioning.py"

/usr/bin/python3 -I -B - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
sources = sorted((root / "bin").glob("*.py")) + sorted((root / "tests").glob("*.py"))
for source in sources:
    compile(source.read_bytes(), str(source), "exec")
print(f"python source syntax: OK ({len(sources)} files)")
PY
