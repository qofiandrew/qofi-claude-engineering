#!/usr/bin/env bash
# Canonical shell-suite bridge for root lifecycle authority regressions.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for test_path in \
  tests/test-harness-lifecycle-broker.py \
  tests/test-claude-runtime-authority.py
do
  if [ ! -f "$ROOT/$test_path" ]; then
    echo "test-harness-root-authority: required regression is missing: $test_path" >&2
    exit 1
  fi
  /usr/bin/python3 -I -B "$ROOT/$test_path"
done
