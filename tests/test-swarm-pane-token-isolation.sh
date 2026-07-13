#!/usr/bin/env bash
# test-swarm-pane-token-isolation.sh — F1, the per-pane token isolation property
# (ADR-0018). bin/swarm-up.sh launch_one must give each swarm's pane ONLY its own
# tokens: this swarm's DISCORD_BOT_TOKEN, plus (labeled accounts only) its account's
# CLAUDE_CODE_OAUTH_TOKEN — NEVER another swarm's bot token or another account's
# OAUTH token, and NEVER the literal token value in the send-keys string / scrollback.
#
# F1 has TWO layers and this test exercises BOTH:
#   (1) the pane derives only its own tokens via a SCOPED subshell source (no blanket
#       `set -a; . tokens.env`);
#   (2) the pane SCRUBS any inherited BOT_*/OAUTH_TOKEN_* first — because a tmux pane
#       inherits the server's env, and on a cold start that server is a child of the
#       launcher. The earlier version of this test ran the pane string under `env -i`,
#       which strips inherited env and therefore could NOT see an inheritance leak
#       (adversarial finding ISO-1/ISO-2). This version runs it BOTH ways:
#         - exec_clean        (env -i)         — proves the string sets the right tokens;
#         - exec_contaminated (vault inherited)— the REAL cold-start path: the parent
#           has the whole vault exported and the pane is run WITHOUT env -i, so the
#           scrub is what must keep siblings/other-accounts out. THIS is the F1 proof.
#
# FAITHFULNESS: the pane string is EXTRACTED from bin/swarm-up.sh (not hand-copied),
# so a regression (blanket source, or dropping the scrub) fails the assertions.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-pane-token-isolation.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UP="$ROOT/bin/swarm-up.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pane-token-iso.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fixture vault: this swarm's bot token, a SIBLING's bot token, and TWO accounts'
# OAUTH tokens. The F1 property: only THIS swarm's own tokens reach the pane.
cat > "$TMP/tokens.env" <<'EOF'
export BOT_ALPHA=alpha-bot-SECRET-111
export BOT_SIBLING=sibling-bot-SECRET-222
export OAUTH_TOKEN_MAXA=maxa-oauth-SECRET-333
export OAUTH_TOKEN_MAXB=maxb-oauth-SECRET-444
EOF

# --- Extract the REAL expressions from swarm-up.sh (one line each). ---
SENDKEYS_LINE="$(grep 'tmux send-keys' "$UP" | grep 'DISCORD_BOT_TOKEN')"
ACCT_ENV_LINE="$(grep 'acct_env=' "$UP" | grep 'CLAUDE_CODE_OAUTH_TOKEN')"
[ -n "$SENDKEYS_LINE" ] || { echo "FATAL: could not find the DISCORD_BOT_TOKEN send-keys line in $UP" >&2; exit 2; }
[ -n "$ACCT_ENV_LINE" ] || { echo "FATAL: could not find the CLAUDE_CODE_OAUTH_TOKEN acct_env line in $UP" >&2; exit 2; }
PANE_ASSIGN="$(printf '%s' "$SENDKEYS_LINE" | sed -E 's/^[[:space:]]*tmux send-keys -t "\$sess" /PANE=/; s/ C-m$//')"

# build_pane default|labeled [claude|codex] -> sets PANE to the exact string.
build_pane() {
  local mode="$1" engine="${2:-claude}"
  local SWARM_HOME="$TMP" TOKENS="$TMP/tokens.env" tokvar="BOT_ALPHA"
  local bound_exports="export DISCORD_BOUND_CHANNEL='111'"
  local SWARM_ACCT_TOKEN_VAR="OAUTH_TOKEN_MAXA" SWARM_ACCT_CONFIG_DIR="$TMP/.claude-accounts/maxa"
  local acct_env=""
  local codex_key_scrub=""
  [ "$engine" = "codex" ] && codex_key_scrub="unset OPENAI_API_KEY CODEX_API_KEY; "
  if [ "$mode" = labeled ]; then eval "$ACCT_ENV_LINE"; fi
  eval "$PANE_ASSIGN"
}

# exec_clean      -> run PANE from an EMPTY env (proves the string itself is scoped).
exec_clean() { env -i /bin/bash --noprofile --norc -c "$PANE
env"; }
# exec_contaminated -> the REAL cold-start path: the WHOLE vault is exported into the
# parent (as a vault-laden tmux server would have), and PANE runs WITHOUT env -i, so
# only the in-pane SCRUB can keep siblings/other-accounts out.
exec_contaminated() {
  ( set -a; . "$TMP/tokens.env"; set +a
    export NONVAULT_SECRET=keepme-SECRET-000     # a non-vault secret: scrub must NOT touch it
    /bin/bash --noprofile --norc -c "$PANE
env" )
}
# Same, but with a HOSTILE IFS set first (a shell rc could do this). The scrub must
# still word-split the var-name list on the default separator (it `unset IFS` first).
exec_contaminated_badifs() {
  ( set -a; . "$TMP/tokens.env"; set +a
    /bin/bash --noprofile --norc -c "IFS=':'; $PANE
env" )
}

# ---------------------------------------------------------------------------
echo "=== the pane string is scoped + scrubbed (structure) ==="
build_pane labeled
assert_lacks "$PANE" "SECRET" "no literal token value anywhere in the send-keys string"
assert_lacks "$PANE" "set -a" "no blanket auto-export (set -a) in the pane string"
assert_has  "$PANE" 'DISCORD_BOT_TOKEN="$(. ' "bot token is a SCOPED subshell source"
assert_has  "$PANE" 'CLAUDE_CODE_OAUTH_TOKEN="$(. ' "OAUTH token is a SCOPED subshell source"
assert_has  "$PANE" "do unset " "the pane SCRUBS inherited vault vars (unset loop present)"
assert_lacks "$PANE" "unset OPENAI_API_KEY CODEX_API_KEY" "Claude pane bytes do not gain Codex-only provider scrubs"
build_pane default codex
assert_has "$PANE" "unset OPENAI_API_KEY CODEX_API_KEY" "Codex pane scrubs both metered provider-key routes"

# ---------------------------------------------------------------------------
echo "=== CLEAN env (env -i): default pane has ONLY its own bot token ==="
build_pane default
OUT="$(exec_clean)"
assert_has  "$OUT" "DISCORD_BOT_TOKEN=alpha-bot-SECRET-111" "DISCORD_BOT_TOKEN = this swarm's bot token"
assert_lacks "$OUT" "sibling-bot-SECRET-222" "sibling bot token absent (clean env)"
assert_lacks "$OUT" "OAUTH_TOKEN_"           "no OAUTH var on a default pane (clean env)"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'SECRET')" "exactly ONE secret var (default, clean env)"

echo "=== CONTAMINATED env (vault inherited, NO env -i): default pane SCRUBS siblings ==="
build_pane default
OUT="$(exec_contaminated)"
assert_has  "$OUT" "DISCORD_BOT_TOKEN=alpha-bot-SECRET-111" "DISCORD_BOT_TOKEN still correct under inheritance"
assert_lacks "$OUT" "sibling-bot-SECRET-222" "INHERITED sibling bot token is SCRUBBED"
assert_lacks "$OUT" "BOT_SIBLING="           "inherited BOT_SIBLING var scrubbed by name"
assert_lacks "$OUT" "maxa-oauth-SECRET-333"  "inherited account OAUTH token (maxa) scrubbed off a default pane"
assert_lacks "$OUT" "maxb-oauth-SECRET-444"  "inherited account OAUTH token (maxb) scrubbed off a default pane"
assert_lacks "$OUT" "OAUTH_TOKEN_MAXA="      "inherited OAUTH_TOKEN_MAXA var scrubbed by name"
assert_has  "$OUT" "NONVAULT_SECRET=keepme-SECRET-000" "the scrub targets ONLY BOT_*/OAUTH_TOKEN_*, not other env vars"
assert_eq "2" "$(printf '%s\n' "$OUT" | grep -c 'SECRET')" "default pane keeps exactly its bot token + the non-vault var (siblings gone)"

# ---------------------------------------------------------------------------
echo "=== CONTAMINATED env: LABELED pane keeps own bot+OAUTH, scrubs the rest ==="
build_pane labeled
OUT="$(exec_contaminated)"
assert_has  "$OUT" "DISCORD_BOT_TOKEN=alpha-bot-SECRET-111"        "labeled: own bot token correct"
assert_has  "$OUT" "CLAUDE_CODE_OAUTH_TOKEN=maxa-oauth-SECRET-333" "labeled: own account OAUTH token correct (re-derived after scrub)"
assert_has  "$OUT" "CLAUDE_CONFIG_DIR=$TMP/.claude-accounts/maxa"  "labeled: CLAUDE_CONFIG_DIR points at the account dir"
assert_lacks "$OUT" "sibling-bot-SECRET-222" "labeled: inherited sibling bot token scrubbed"
assert_lacks "$OUT" "maxb-oauth-SECRET-444"  "labeled: ANOTHER account's inherited OAUTH token scrubbed"
assert_lacks "$OUT" "OAUTH_TOKEN_MAXB="      "labeled: other account's raw OAUTH var scrubbed by name"
assert_lacks "$OUT" "OAUTH_TOKEN_MAXA="      "labeled: even THIS account's raw vault var is gone (only CLAUDE_CODE_OAUTH_TOKEN survives)"

# ---------------------------------------------------------------------------
echo "=== HOSTILE IFS + contaminated env: scrub still removes inherited vault vars ==="
build_pane default
OUT="$(exec_contaminated_badifs)"
assert_has  "$OUT" "DISCORD_BOT_TOKEN=alpha-bot-SECRET-111" "own bot token correct even with a hostile IFS"
assert_lacks "$OUT" "sibling-bot-SECRET-222" "inherited sibling token scrubbed despite IFS=':' (unset IFS in the scrub)"
assert_lacks "$OUT" "maxb-oauth-SECRET-444"  "inherited other-account OAUTH token scrubbed despite a hostile IFS"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
