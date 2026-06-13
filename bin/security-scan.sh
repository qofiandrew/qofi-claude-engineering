#!/usr/bin/env bash
# security-scan.sh — deterministic security pass (gitleaks + semgrep).
#
# The deterministic FIRST line of the security gate (TEAM_LEAD.md §Independent
# review & security gates). Deterministic scanners run before the security-
# reviewer teammate precisely because they don't hallucinate: a clean run is
# evidence, a dirty one is a hard stop. This is the SECURITY pass — it FAILS
# CLOSED: a scanner that isn't installed is a config defect, not "nothing to
# scan", so it blocks LOUDLY with the install step rather than passing silently.
# (This mirrors test-gate.sh's no-test-command-is-a-defect posture.)
#
# This is NOT a permission-gate hook and is NOT subject to the QOFI_* quality
# runtime controls — it is the CTO's pre-DoD security pass (run locally) and the
# same invocation the CI workflow runs (docs/CI-PROMOTION.md). gitleaks + semgrep
# are the operator install step:  brew install gitleaks semgrep
#
# Usage:  bin/security-scan.sh [--range <git-range>]   (default: whole working tree)
# Exit:   0 clean · 1 findings · 2 a scanner is missing (install step) or errored.
#
# NOTE: the exact scanner flags below are sensible defaults; validate them on the
# host where the tools are installed (semgrep --config auto fetches the registry
# ruleset — pin SEMGREP_CONFIG to a local ruleset to run offline). The
# orchestration (missing → block, clean → pass, findings → fail) is what
# tests/test-security-scan.sh pins.

set -uo pipefail
RANGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --range) [ $# -ge 2 ] || { echo "security-scan: --range requires a value" >&2; exit 2; }; RANGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "security-scan: unknown arg: $1" >&2; exit 2 ;;
  esac
done

GITLEAKS="${GITLEAKS_BIN:-gitleaks}"
SEMGREP="${SEMGREP_BIN:-semgrep}"

missing=""
command -v "$GITLEAKS" >/dev/null 2>&1 || missing="$missing gitleaks"
command -v "$SEMGREP"  >/dev/null 2>&1 || missing="$missing semgrep"
if [ -n "$missing" ]; then
  {
    echo "security-scan: BLOCKED — required scanner(s) not installed:$missing"
    echo "  This is the deterministic security pass; it fails CLOSED. Install:"
    echo "    brew install gitleaks semgrep         # macOS"
    echo "  (or pin them in the repo's CI per docs/CI-PROMOTION.md). A missing"
    echo "  scanner is a config defect, never a silent pass."
  } >&2
  exit 2
fi

rc=0
echo "== gitleaks (secret scan) =="
if [ -n "$RANGE" ]; then
  "$GITLEAKS" detect --no-banner --redact --log-opts="$RANGE" || rc=1
else
  "$GITLEAKS" detect --no-banner --redact || rc=1
fi
echo "== semgrep (vulnerability patterns) =="
"$SEMGREP" scan --error --quiet --config "${SEMGREP_CONFIG:-auto}" || rc=1

if [ "$rc" -ne 0 ]; then
  echo "security-scan: FINDINGS — review and resolve before the DoD gate." >&2
  echo "  Never weaken or skip the scan to go green (that is the §Verification" >&2
  echo "  regression rule). A real finding is a stop; a false positive is an" >&2
  echo "  explicit, reviewed allowlist entry, not a silenced scanner." >&2
  exit 1
fi
echo "security-scan: clean (gitleaks + semgrep)."
exit 0
