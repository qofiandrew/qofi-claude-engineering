#!/usr/bin/env bash
# swarm-account-verify.sh [--baseline [FILE]] [--check [FILE]] [--moved LABEL] [--dry-run] [--quiet]
#
# The independence CANARY (ADR-0018). After the operator provisions accounts,
# labels rows, and restarts, this confirms the partition is REALLY isolated: each
# labeled account reads usage from its OWN config dir, and exercising one account
# moves ONLY that account's usage — the others stay flat. It is READ-ONLY: it
# reads each account's usage signal and writes (at most) a baseline snapshot file;
# it never touches a swarm, a token value, or swarm.conf.
#
# ── THREE MODES ──────────────────────────────────────────────────────────────
#   (default, no flag)   STRUCTURAL probe. For every DISTINCT labeled account in
#                        swarm.conf: resolve its config dir (sole constructor),
#                        confirm the dir EXISTS and is DISTINCT from every other
#                        account's (and from the default ~/.claude), confirm a
#                        token is provisioned (NAME present in vault — value never
#                        read), and read its current usage signal. Per-account
#                        PASS / FAIL / SKIP(no token). This proves CONFIG isolation
#                        without needing an activity window.
#   --baseline [FILE]    Snapshot every labeled account's usage to FILE (default
#                        $SWARM_HOME/.swarm-account-usage-baseline). Run this, then
#                        drive activity on ONE account, then --check.
#   --check [FILE]       Re-read usage and diff vs the baseline FILE. With --moved
#                        LABEL, PASS iff ONLY that account's usage advanced and every
#                        other stayed flat (the dynamic independence proof). Without
#                        --moved, just report each account's delta.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  PASS (or --baseline written, or --dry-run)
#   1  usage / SWARM_HOME unset-or-wrong / no labeled accounts to verify
#   2  FAIL — an independence assertion failed (shared dir, or wrong account moved,
#      or an expected account did not move)
#   3  INCONCLUSIVE — usage signal unavailable for one or more accounts (UNKNOWN);
#      structural checks still reported. Re-run once a usage source is wired.
#
# ── SEAMS (tests inject these) ───────────────────────────────────────────────
#   SWARM_ACCOUNT_USAGE_CMD  command run via `sh -c "$cmd" _ "<label>"` with
#                            CLAUDE_CONFIG_DIR exported to that account's dir; its
#                            STDOUT must be a single integer (tokens used in the
#                            window) or empty/non-numeric => UNKNOWN. Default reads
#                            ccusage keyed on the config dir (degrades to UNKNOWN if
#                            ccusage is absent — the structural checks still run).
#   SWARM_TOKENS_ENV         vault path checked for OAUTH_TOKEN_<LABEL> NAME
#                            presence (value never read). Default $SWARM_HOME/tokens.env.
#   HOME                     the resolver builds the account dirs under $HOME.
#   SWARM_CONF               override the swarm.conf read for the label set.
#
# Run from $SWARM_HOME:  bin/swarm-account-verify.sh
# bash 3.2-safe (macOS default).

set -uo pipefail

PROG="swarm-account-verify"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=swarm-lib.sh
. "$SCRIPT_DIR/swarm-lib.sh"

CONF="${SWARM_CONF:-$SWARM_HOME/swarm.conf}"
TOKENS="${SWARM_TOKENS_ENV:-$SWARM_HOME/tokens.env}"
DEFAULT_BASELINE="$SWARM_HOME/.swarm-account-usage-baseline"

MODE="probe"
BASELINE_FILE=""
MOVED=""
DRY=0
QUIET=0
expect_file=""
expect_moved=0
for arg in "$@"; do
  if [ "$expect_file" = "baseline" ]; then BASELINE_FILE="$arg"; expect_file=""; continue; fi
  if [ "$expect_file" = "check" ]; then BASELINE_FILE="$arg"; expect_file=""; continue; fi
  if [ "$expect_moved" -eq 1 ]; then MOVED="$arg"; expect_moved=0; continue; fi
  case "$arg" in
    --baseline) MODE="baseline"; expect_file="baseline" ;;
    --check)    MODE="check"; expect_file="check" ;;
    --moved)    expect_moved=1 ;;
    --dry-run)  DRY=1 ;;
    --quiet)    QUIET=1 ;;
    -h|--help)  sed -n '1,46p' "$0"; exit 0 ;;
    --*)        echo "$PROG: unknown flag: $arg" >&2; exit 1 ;;
    *)          echo "$PROG: unexpected arg: $arg" >&2; exit 1 ;;
  esac
done
# A flag that expects a value but got none (e.g. trailing --baseline) -> use default.
[ -n "$BASELINE_FILE" ] || BASELINE_FILE="$DEFAULT_BASELINE"

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# Distinct non-empty ACCOUNT labels in swarm.conf (field 6).
LABELS="$(awk -F'|' '
  /^[[:space:]]*(#|$)/ { next }
  { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); if ($6 != "") print $6 }
' "$CONF" | sort -u)"

if [ -z "$LABELS" ]; then
  echo "$PROG: no labeled accounts in $CONF (every swarm is on the default account)." >&2
  echo "$PROG: nothing to verify — the partition is inert. Label rows first (see ACTIVATION-RUNBOOK)." >&2
  exit 1
fi

# token_provisioned LABEL_TOKENVAR -> 0 if the NAME is present in the vault.
token_provisioned() {
  [ -f "$TOKENS" ] || return 1
  grep -qE "(^|[[:space:]]|export[[:space:]])$1=" "$TOKENS" 2>/dev/null
}

# usage_of CONFIG_DIR LABEL -> echoes an integer or "UNKNOWN".
usage_of() {
  local cdir="$1" label="$2" out
  if [ -n "${SWARM_ACCOUNT_USAGE_CMD:-}" ]; then
    out="$(CLAUDE_CONFIG_DIR="$cdir" sh -c "$SWARM_ACCOUNT_USAGE_CMD" _ "$label" 2>/dev/null)"
  else
    # Default: ccusage keyed on this account's config dir. Degrade to UNKNOWN if
    # ccusage is not installed — the structural checks still stand on their own.
    if command -v ccusage >/dev/null 2>&1; then
      out="$(CLAUDE_CONFIG_DIR="$cdir" ccusage blocks --active --json 2>/dev/null \
              | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); b=(d.get("blocks") or [{}])[0]
    print(int(b.get("totalTokens") or b.get("tokens") or 0))
except Exception:
    pass' 2>/dev/null)"
    else
      out=""
    fi
  fi
  case "$out" in
    ''|*[!0-9]*) printf 'UNKNOWN' ;;
    *)           printf '%s' "$out" ;;
  esac
}

if [ "$DRY" -eq 1 ]; then
  say "=== $PROG --dry-run (mode: $MODE) ==="
  say "  labeled accounts: $(printf '%s ' $LABELS)"
  say "  would read usage per account (read-only) keyed on each isolated config dir"
  [ "$MODE" = baseline ] && say "  would WRITE baseline snapshot: $BASELINE_FILE"
  [ "$MODE" = check ]    && say "  would READ baseline snapshot:  $BASELINE_FILE"
  say "  (no swarm touched, no token value read)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve each label -> config dir + token var, detect shared dirs.
# ---------------------------------------------------------------------------
RC=0
INCONCLUSIVE=0
DIRS_SEEN=""        # "dir\tlabel" lines, to catch collisions
declare_curr=""     # "label<TAB>usage" lines for baseline/check

# The DEFAULT account dir — from the resolver (sole constructor), never hand-built.
swarm_account_resolve "" || true
DEFAULT_DIR="$SWARM_ACCT_CONFIG_DIR"

say "=== $PROG: account independence canary (mode: $MODE) ==="
say ""

for label in $LABELS; do
  if ! swarm_account_resolve "$label"; then
    say "  FAIL  $label — invalid label (resolver rejected it)"; RC=2; continue
  fi
  cdir="$SWARM_ACCT_CONFIG_DIR"; tvar="$SWARM_ACCT_TOKEN_VAR"
  usage="$(usage_of "$cdir" "$label")"
  declare_curr="${declare_curr}${label}	${usage}
"

  # Structural: config dir distinct from every other account's AND from default.
  collision=""
  [ "$cdir" = "$DEFAULT_DIR" ] && collision="the DEFAULT account dir"
  prev="$(printf '%s' "$DIRS_SEEN" | awk -F'\t' -v d="$cdir" '$1==d {print $2; exit}')"
  [ -n "$prev" ] && collision="account '$prev'"
  DIRS_SEEN="${DIRS_SEEN}${cdir}	${label}
"

  if [ "$MODE" != "probe" ]; then
    continue  # baseline/check only need the usage numbers gathered above
  fi

  # --- probe mode: per-account PASS/FAIL/SKIP ---
  if [ -n "$collision" ]; then
    say "  FAIL  $label — config dir is NOT isolated (shares with $collision): $cdir"; RC=2; continue
  fi
  if [ ! -d "$cdir" ]; then
    say "  SKIP  $label — config dir not provisioned yet: $cdir (run swarm-account-provision.sh $label)"; continue
  fi
  if ! token_provisioned "$tvar"; then
    say "  SKIP  $label — no token in vault (\$$tvar absent); account not yet live. Provision the credential."; continue
  fi
  if [ "$usage" = "UNKNOWN" ]; then
    say "  PASS* $label — isolated dir + token present; usage signal UNKNOWN (no ccusage/seam wired)"; INCONCLUSIVE=1; continue
  fi
  say "  PASS  $label — isolated dir ($cdir), token \$$tvar present, usage=$usage tokens"
done

# ---------------------------------------------------------------------------
# baseline / check modes operate on the gathered usage numbers.
# ---------------------------------------------------------------------------
if [ "$MODE" = "baseline" ]; then
  tmp="$BASELINE_FILE.tmp.$$"
  printf '%s' "$declare_curr" > "$tmp" && mv "$tmp" "$BASELINE_FILE" \
    || { echo "$PROG: FATAL — could not write baseline $BASELINE_FILE" >&2; exit 1; }
  say "  baseline written: $BASELINE_FILE"
  say "$(printf '%s' "$declare_curr" | sed 's/^/    /')"
  say ""
  say "  next: drive activity on ONE account, then: $PROG --check ${BASELINE_FILE} --moved <label>"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  [ -f "$BASELINE_FILE" ] || { echo "$PROG: no baseline at $BASELINE_FILE — run --baseline first." >&2; exit 1; }
  say "  comparing current usage to baseline: $BASELINE_FILE"
  [ -n "$MOVED" ] && say "  expectation: ONLY '$MOVED' should have advanced"
  say ""
  for label in $LABELS; do
    base="$(awk -F'\t' -v l="$label" '$1==l {print $2; exit}' "$BASELINE_FILE")"
    curr="$(printf '%s' "$declare_curr" | awk -F'\t' -v l="$label" '$1==l {print $2; exit}')"
    [ -n "$base" ] || base="(none)"
    if [ "$base" = "UNKNOWN" ] || [ "$curr" = "UNKNOWN" ] || [ "$base" = "(none)" ]; then
      say "  ?     $label — base=$base curr=$curr (usage signal unavailable)"; INCONCLUSIVE=1; continue
    fi
    if [ "$curr" -gt "$base" ]; then
      delta=$(( curr - base ))
      if [ -n "$MOVED" ] && [ "$label" != "$MOVED" ]; then
        say "  FAIL  $label — advanced by $delta but was NOT the exercised account (leak: shared usage?)"; RC=2
      else
        say "  MOVED $label — +$delta tokens (base=$base curr=$curr)"
      fi
    else
      if [ -n "$MOVED" ] && [ "$label" = "$MOVED" ]; then
        say "  FAIL  $label — was exercised but did NOT advance (base=$base curr=$curr); usage not isolated/landing?"; RC=2
      else
        say "  flat  $label — unchanged (base=$base curr=$curr)"
      fi
    fi
  done
fi

say ""
if [ "$RC" -eq 2 ]; then
  printf '%s: FAIL — accounts are NOT independent. See the failures above.\n' "$PROG" >&2
  exit 2
fi
if [ "$INCONCLUSIVE" -eq 1 ]; then
  printf '%s: INCONCLUSIVE — structural isolation holds, but the usage signal was unavailable for some accounts. Wire SWARM_ACCOUNT_USAGE_CMD (or ccusage) and re-run for the dynamic proof.\n' "$PROG"
  exit 3
fi
printf '%s: PASS — every labeled account is isolated and independent.\n' "$PROG"
exit 0
