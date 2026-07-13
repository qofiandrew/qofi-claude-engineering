#!/usr/bin/env bash
# Canonical no-spend wrapper for the capability-minimal Fable reviewer suite.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec /usr/bin/python3 -I -B "$ROOT/tests/test-fable-reviewer-mcp.py" -v
