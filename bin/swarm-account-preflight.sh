#!/usr/bin/env bash
# swarm-account-preflight.sh [--quiet]
#
# The readiness check the operator runs BEFORE flipping anything live (ADR-0018).
# It answers one question loudly: "is this tree safe to provision a real account
# token into and restart onto?" It is READ-ONLY — it asserts state, changes nothing.
#
# ── WHAT IT ASSERTS ──────────────────────────────────────────────────────────
#   [F1] The ON-DISK launch_one IS the F1 (per-pane token isolation) version. This
#        is the load-bearing one: provisioning a real OAUTH_TOKEN_* into the vault
#        BEFORE F1 is live would let a pre-F1 launcher leak every account's token
#        into every pane (the exact gap F1 closes). We grep bin/swarm-up.sh for
#        BOTH F1 fingerprints and REFUSE if either is missing:
#          - the inherited-vault SCRUB loop  (unset IFS; … do unset "$v"; done)
#          - the SCOPED token derive          (DISCORD_BOT_TOKEN="$(. …)")
#        and we REFUSE if the pre-F1 blanket auto-export (set -a) is present.
#   [SUB] The partition substrate is present: swarm_account_resolve (sole path
#        constructor), the 6th ACCOUNT field in the parser, swarm_conf_set_account
#        (the swap's atomic rewrite), and the swap actuator bin/swarm-account.sh.
#   [VAULT] tokens.env holds NO OAUTH_TOKEN_* yet — checked by NAME pattern only,
#        the value is NEVER read or printed. (Once the operator adds a token this
#        flips to a NOTE, not a failure — the check exists to catch a token added
#        BEFORE F1/labels, not to forbid one forever; see --allow-tokens.)
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  PASS — safe to proceed (provision tokens, label, restart)
#   1  usage / SWARM_HOME unset-or-wrong
#   2  FAIL — at least one readiness assertion failed (details printed)
#
# ── FLAGS ────────────────────────────────────────────────────────────────────
#   --quiet         only print the final PASS/FAIL line + any failures
#   --allow-tokens  treat an OAUTH_TOKEN_* already in the vault as OK (NOTE not
#                   FAIL) — for re-running preflight AFTER the operator has begun
#                   provisioning. F1/substrate checks are unaffected.
#
# ── SEAMS (tests inject these) ───────────────────────────────────────────────
#   SWARM_TOKENS_ENV  the vault path checked for OAUTH_TOKEN_* names (default
#                     $SWARM_HOME/tokens.env). Absent file = vacuously clean.
#
# Run from $SWARM_HOME:  bin/swarm-account-preflight.sh
# bash 3.2-safe (macOS default).

set -uo pipefail

PROG="swarm-account-preflight"

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "$PROG: SWARM_HOME unset or wrong — export SWARM_HOME=/Users/aschettino/qofirepos/qofi-claude-engineering" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SWARM_HOME"
UP="$ROOT/bin/swarm-up.sh"
LIB="$ROOT/bin/swarm-lib.sh"
ACCT="$ROOT/bin/swarm-account.sh"
TOKENS="${SWARM_TOKENS_ENV:-$ROOT/tokens.env}"

QUIET=0
ALLOW_TOKENS=0
for arg in "$@"; do
  case "$arg" in
    --quiet)        QUIET=1 ;;
    --allow-tokens) ALLOW_TOKENS=1 ;;
    -h|--help)      sed -n '1,45p' "$0"; exit 0 ;;
    *)              echo "$PROG: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

FAILS=0
say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
passln() { say "  PASS  $1"; }
failln() { printf '  FAIL  %s\n' "$1" >&2; FAILS=$((FAILS+1)); }
noteln() { say "  NOTE  $1"; }

# has FILE SUBSTRING -> 0 if the literal substring is present in FILE.
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
# hasre FILE REGEX
hasre() { grep -qE -- "$2" "$1" 2>/dev/null; }

say "=== $PROG: is this tree safe to activate? ==="
say ""
say "[F1] per-pane token isolation is LIVE on disk (bin/swarm-up.sh)"

if [ ! -f "$UP" ]; then
  failln "bin/swarm-up.sh missing — cannot verify the launcher"
else
  # Fingerprint 1: the inherited-vault scrub loop. (Anchors are escaping-stable:
  # the markers live inside an escaped tmux send-keys string, so we match the
  # backslash-agnostic fragments — the scrub-loop header, the `unset`, and the
  # sed var-name pattern — rather than the fully-unescaped form.)
  if has "$UP" 'unset IFS; for v in' && has "$UP" 'do unset ' && has "$UP" 'BOT_[A-Za-z0-9_]'; then
    passln "scrub loop present (panes drop inherited BOT_*/OAUTH_TOKEN_*)"
  else
    failln "F1 scrub loop MISSING in swarm-up.sh — a pre-F1 launcher leaks the vault into panes. DO NOT provision a token. Restart onto the F1 launcher first."
  fi
  # Fingerprint 2: the scoped subshell derive — the DISCORD_BOT_TOKEN export is a
  # subshell SOURCE `(. tokens.env; printf …)`, not a blanket auto-export. The
  # `(. ` substring on the same line as DISCORD_BOT_TOKEN= proves the scoped shape.
  if grep -F 'DISCORD_BOT_TOKEN=' "$UP" 2>/dev/null | grep -qF '(. '; then
    passln "scoped token derive present (DISCORD_BOT_TOKEN via subshell source)"
  else
    failln "F1 scoped derive MISSING in swarm-up.sh — token would be a literal in scrollback. Restart onto the F1 launcher first."
  fi
  # Anti-fingerprint: the pre-F1 blanket auto-export must be gone from launch code.
  # (Comment lines mentioning 'set -a' as the thing F1 removed are fine; a live
  # `set -a` in launch_one is not.) We check for an active auto-export statement.
  if hasre "$UP" '^[[:space:]]*set -a' || hasre "$UP" ';[[:space:]]*set -a'; then
    failln "a live 'set -a' blanket auto-export is present in swarm-up.sh — that is the pre-F1 vault leak. Refusing."
  else
    passln "no live 'set -a' blanket vault auto-export in the launcher"
  fi
fi

say ""
say "[SUB] partition substrate present"
if has "$LIB" 'swarm_account_resolve()'; then passln "swarm_account_resolve (sole path constructor)"; else failln "swarm_account_resolve MISSING in swarm-lib.sh"; fi
if has "$LIB" 'SWARM_CONF_F_ACCOUNT'; then passln "parser exposes the 6th ACCOUNT field"; else failln "SWARM_CONF_F_ACCOUNT MISSING — parser does not read field 6"; fi
if has "$LIB" 'swarm_conf_set_account()'; then passln "swarm_conf_set_account (atomic field-6 rewrite)"; else failln "swarm_conf_set_account MISSING — no swap persistence"; fi
if [ -f "$ACCT" ] && has "$ACCT" 'swarm_account_resolve'; then passln "bin/swarm-account.sh swap actuator present"; else failln "bin/swarm-account.sh swap actuator MISSING or not resolver-threaded"; fi

say ""
say "[VAULT] tokens.env holds no account token yet (name pattern only — value never read)"
if [ ! -f "$TOKENS" ]; then
  passln "no tokens.env at $TOKENS (vacuously clean)"
else
  # Match the NAME at the start of an assignment/export only. Never capture the value.
  OAUTH_NAMES="$(grep -oE '(^|[[:space:]]|export[[:space:]])OAUTH_TOKEN_[A-Za-z0-9_]+' "$TOKENS" 2>/dev/null \
                  | grep -oE 'OAUTH_TOKEN_[A-Za-z0-9_]+' | sort -u || true)"
  if [ -z "$OAUTH_NAMES" ]; then
    passln "no OAUTH_TOKEN_* variable present in the vault"
  elif [ "$ALLOW_TOKENS" -eq 1 ]; then
    noteln "vault already defines: $(printf '%s ' $OAUTH_NAMES) (--allow-tokens: NOTE, not a failure)"
  else
    failln "vault already defines an account token NAME: $(printf '%s ' $OAUTH_NAMES). If F1 is live and you are mid-activation, re-run with --allow-tokens. Otherwise REMOVE it until F1 is confirmed live."
  fi
fi

say ""
if [ "$FAILS" -eq 0 ]; then
  printf '%s: PASS — safe to provision accounts, label rows, and restart onto F1.\n' "$PROG"
  exit 0
else
  printf '%s: FAIL (%d) — DO NOT activate. Fix the items above first.\n' "$PROG" "$FAILS" >&2
  exit 2
fi
