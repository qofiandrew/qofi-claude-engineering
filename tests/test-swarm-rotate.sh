#!/usr/bin/env bash
# test-swarm-rotate.sh — regression tests for bin/swarm-rotate.sh, the
# single-account ROTATION path: checkpoint -> credential swap -> fleet relaunch.
#
# CRITICAL SAFETY PROPERTY OF THIS TEST FILE. It NEVER swaps a real credential,
# NEVER touches the keychain, NEVER restarts a real fleet, and makes NO network
# calls. Every side effect is delivered through swarm-rotate's pluggable hooks,
# each pointed at a STUB that only appends a line to a witness file:
#   - SWARM_CREDSWAP_CMD        -> records "swap:<account>"
#   - SWARM_CHECKPOINT_CMD      -> records "checkpoint:<repo>"
#   - SWARM_FLEET_RELAUNCH_CMD  -> records "relaunch"
# and SWARM_TMUX_BIN / CLAUDE_PROJECTS_DIR are pointed at stubs/empty dirs so the
# clean-boundary probe never sees a real session.
#
# WHAT THIS PROTECTS:
#   1. NEXT-ACCOUNT ring math: rotates active->next, wraps at the end, cold-starts
#      to the first, honors --to, refuses a --to outside the ring, refuses an
#      empty ring. (--next prints the computed account without doing anything.)
#   2. ORDER: when it does rotate, checkpoint runs BEFORE swap runs BEFORE relaunch.
#   3. CLEAN-BOUNDARY guard: a WORKING swarm (fresh transcript) REFUSES rotation
#      (exit 3) unless --force. (The discipline: rotation = fleet restart = RAM loss.)
#   4. CHECKPOINT discipline: a failing checkpoint ABORTS (exit 4) unless --force;
#      with no checkpoint hook it WARNS but proceeds.
#   5. CREDSWAP guard: a live run with NO SWARM_CREDSWAP_CMD REFUSES (exit 2) — the
#      script never guesses how to swap creds. A failing swap does NOT relaunch
#      (exit 5) — we never boot the fleet on an unknown credential.
#   6. --dry-run executes NO hook (no witness lines) but prints the plan.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-rotate.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROTATE="$ROOT/bin/swarm-rotate.sh"

PASS=0; FAIL=0; FAILURES=""
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-rotate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── Fixture SWARM_HOME: templates/ + swarm.conf satisfy swarm-rotate's guard ──
FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh"   "$FAKE_SH/bin/swarm-lib.sh"
cp "$ROOT/bin/swarm-rotate.sh"   "$FAKE_SH/bin/swarm-rotate.sh"
chmod +x "$FAKE_SH/bin/swarm-rotate.sh"
ROTATE="$FAKE_SH/bin/swarm-rotate.sh"

cat > "$FAKE_SH/swarm.conf" <<EOF
alpha | $TMP/repo-alpha | BOT_ALPHA | 111 | 999
beta  | $TMP/repo-beta  | BOT_BETA  | 222 | 999
EOF
mkdir -p "$TMP/repo-alpha" "$TMP/repo-beta"

# ── Stub side effects: witness file records what fired, in order ──────────────
# Each hook is a real stub SCRIPT (not an inline command) so the witness wiring
# survives every layer of quoting/eval the tests put it through. swarm-rotate
# invokes each as `sh -c "<hook>" _ <arg>`, so the hook receives the account/repo
# in $1; the stubs append a witness line and exit 0. No real swap/restart ever
# happens — the stubs only write to the witness file.
WITNESS="$TMP/witness.log"
: > "$WITNESS"
mkdir -p "$TMP/hooks"
cat > "$TMP/hooks/credswap.sh"   <<EOF
#!/usr/bin/env bash
printf 'swap:%s\n' "\$1" >> "$WITNESS"
EOF
cat > "$TMP/hooks/checkpoint.sh" <<EOF
#!/usr/bin/env bash
printf 'checkpoint:%s\n' "\$1" >> "$WITNESS"
EOF
cat > "$TMP/hooks/relaunch.sh"   <<EOF
#!/usr/bin/env bash
printf 'relaunch\n' >> "$WITNESS"
EOF
# A checkpoint stub that RECORDS the attempt then FAILS (exit 1) — for the
# checkpoint-abort test.
cat > "$TMP/hooks/checkpoint-fail.sh" <<EOF
#!/usr/bin/env bash
printf 'checkpoint-attempt:%s\n' "\$1" >> "$WITNESS"
exit 1
EOF
# A credential-swap stub that simply FAILS (exit 9) — for the no-relaunch test.
cat > "$TMP/hooks/credswap-fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
# A credential-swap stub that reports RING EXHAUSTION (exit 7): the swap TOOK and
# the new credential AUTHENTICATES, but the account it points at is itself
# rate-limited (see swarm-credswap-keychain.sh exit 7). The actuator must NOT
# relaunch on a capped account and must escalate.
cat > "$TMP/hooks/credswap-capped.sh" <<EOF
#!/usr/bin/env bash
printf 'swap-capped:%s\n' "\$1" >> "$WITNESS"
exit 7
EOF
# An attention stub: records the escalation reason it was raised with.
cat > "$TMP/hooks/attention.sh" <<EOF
#!/usr/bin/env bash
printf 'attention:%s\n' "\$1" >> "$WITNESS"
EOF
chmod +x "$TMP"/hooks/*.sh
# The hook env values are inline commands that forward the positional arg
# swarm-rotate passes (`sh -c "$hook" _ <arg>`) into the stub — exactly the
# documented contract (SWARM_CREDSWAP_CMD='your-cmd "$1"'). The literal $1 is
# built with a single-quoted suffix so it reaches the stub UNEXPANDED. Q is the
# three-character string  "$1"  (dquote, dollar, one, dquote).
Q='"$1"'
CREDSWAP="$TMP/hooks/credswap.sh $Q"
CHECKPOINT="$TMP/hooks/checkpoint.sh $Q"
RELAUNCH="$TMP/hooks/relaunch.sh"
CHECKPOINT_FAIL="$TMP/hooks/checkpoint-fail.sh $Q"
CREDSWAP_FAIL="$TMP/hooks/credswap-fail.sh"
CREDSWAP_CAPPED="$TMP/hooks/credswap-capped.sh $Q"
ATTENTION="$TMP/hooks/attention.sh $Q"

# tmux stub: has-session always exits 1 (NO live session) so the clean-boundary
# probe sees an idle fleet by default. Tests that need a "working" swarm point
# CLAUDE_PROJECTS_DIR at a dir with a fresh transcript AND flip this to exit 0.
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/tmux-idle" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in has-session) exit 1 ;; *) exit 0 ;; esac
EOF
cat > "$TMP/stubbin/tmux-live" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in has-session) exit 0 ;; *) exit 0 ;; esac
EOF
chmod +x "$TMP/stubbin/tmux-idle" "$TMP/stubbin/tmux-live"

# Empty Claude projects dir => repo_activity returns the no-transcript sentinel
# => never "working". Used by the idle-path tests.
EMPTY_PROJ="$TMP/proj-empty"; mkdir -p "$EMPTY_PROJ"

# run_rotate ARGS...  — invoke the script with the common base env (fake home,
# idle tmux, empty projects, all hooks stubbed) plus per-test overrides taken
# from these OPTIONAL pre-set shell variables (set them before the call, they
# default sensibly and are cleared by reset_rr). Using real variables — not an
# eval'd string — keeps the hook commands (which contain a literal "$1") intact.
#   RR_ACCOUNTS   SWARM_ACCOUNTS        (default 'max-a max-b')
#   RR_ACTIVE     SWARM_ACTIVE_ACCOUNT  (default 'max-a')
#   RR_CKPT       SWARM_CHECKPOINT_CMD  (default $CHECKPOINT; "-" = unset/unwired)
#   RR_CRED       SWARM_CREDSWAP_CMD    (default $CREDSWAP;  "-" = unset/unwired)
#   RR_TMUX       SWARM_TMUX_BIN        (default idle stub)
#   RR_PROJ       CLAUDE_PROJECTS_DIR   (default empty projects dir)
# Remaining args pass through to swarm-rotate. Captures $OUT + $rc.
reset_rr() { RR_ACCOUNTS='max-a max-b'; RR_ACTIVE='max-a'; RR_CKPT=''; RR_CRED=''; RR_TMUX=''; RR_PROJ=''; RR_ATTN=''; }
reset_rr
# _rr_hook DEFAULT OVERRIDE — resolve a hook value: empty override => DEFAULT,
# "-" override => empty (unwired), else the override. Done OUTSIDE the $(...)
# capture below (bash 3.2 can mis-terminate a $(...) on a `case` pattern's `)`).
_rr_hook() {
  if [ -z "$2" ]; then printf '%s' "$1"
  elif [ "$2" = "-" ]; then printf '%s' ""
  else printf '%s' "$2"; fi
}
run_rotate() {
  local _ckpt _cred _tmux _proj
  _ckpt="$(_rr_hook "$CHECKPOINT" "$RR_CKPT")"
  _cred="$(_rr_hook "$CREDSWAP"   "$RR_CRED")"
  _tmux="${RR_TMUX:-$TMP/stubbin/tmux-idle}"
  _proj="${RR_PROJ:-$EMPTY_PROJ}"
  OUT="$(
    export SWARM_HOME="$FAKE_SH"
    export SWARM_TMUX_BIN="$_tmux"
    export CLAUDE_PROJECTS_DIR="$_proj"
    export SWARM_FLEET_RELAUNCH_CMD="$RELAUNCH"
    export SWARM_ACCOUNTS="$RR_ACCOUNTS"
    export SWARM_ACTIVE_ACCOUNT="$RR_ACTIVE"
    # An empty hook value means "leave it UNWIRED" — only export when non-empty.
    [ -n "$_ckpt" ] && export SWARM_CHECKPOINT_CMD="$_ckpt"
    [ -n "$_cred" ] && export SWARM_CREDSWAP_CMD="$_cred"
    [ -n "$RR_ATTN" ] && export SWARM_ATTENTION_CMD="$RR_ATTN"
    bash "$ROTATE" "$@" 2>&1
  )"; rc=$?
  reset_rr
}

# ---------------------------------------------------------------------------
echo "=== 1) ring math: active -> next, --next prints only ==="
: > "$WITNESS"
RR_ACCOUNTS='max-a max-b max-c'; RR_ACTIVE='max-a'; run_rotate --next
assert_eq 0 "$rc" "--next exits 0"
assert_eq "max-b" "$(printf '%s' "$OUT" | tail -n1)" "next after max-a is max-b"
assert_eq "" "$(cat "$WITNESS")" "--next fires NO hooks (no swap/checkpoint/relaunch)"

RR_ACCOUNTS='max-a max-b max-c'; RR_ACTIVE='max-c'; run_rotate --next
assert_eq "max-a" "$(printf '%s' "$OUT" | tail -n1)" "next after last (max-c) WRAPS to max-a"

RR_ACCOUNTS='max-a max-b'; RR_ACTIVE=''; run_rotate --next
assert_eq "max-a" "$(printf '%s' "$OUT" | tail -n1)" "cold start (no active) -> first account"

RR_ACCOUNTS='max-a max-b max-c'; RR_ACTIVE='max-a'; run_rotate --to max-c --next
assert_eq "max-c" "$(printf '%s' "$OUT" | tail -n1)" "--to overrides computed next"

# FIX 5) ring self-rotation: a DUPLICATED active handle must NOT rotate to itself.
# "a a b" with active a previously picked the SECOND "a" (a no-op swap that still
# restarts the fleet). De-dup during normalization makes next != active.
RR_ACCOUNTS='a a b'; RR_ACTIVE='a'; run_rotate --next
NX="$(printf '%s' "$OUT" | tail -n1)"
assert_eq "b" "$NX" "duplicated active in ring ('a a b', active a) -> next is 'b', NOT 'a' (no self-rotate)"

# ---------------------------------------------------------------------------
echo "=== 2) refusals: empty ring, --to outside ring, single-account ring ==="
RR_ACCOUNTS=''; RR_ACTIVE=''; run_rotate --next
assert_eq 2 "$rc" "empty ring -> exit 2"
RR_ACCOUNTS='max-a max-b'; RR_ACTIVE='max-a'; run_rotate --to nope
assert_eq 2 "$rc" "--to outside ring -> exit 2"
assert_has "$OUT" "not in SWARM_ACCOUNTS ring" "explains the --to refusal"
RR_ACCOUNTS='only-one'; RR_ACTIVE='only-one'; run_rotate
assert_eq 2 "$rc" "single usable account -> nowhere to rotate (exit 2)"

# ---------------------------------------------------------------------------
echo "=== 3) full happy path: checkpoint BEFORE swap BEFORE relaunch ==="
: > "$WITNESS"
run_rotate   # defaults: ring max-a/max-b, active max-a, all hooks wired, idle
assert_eq 0 "$rc" "idle fleet + all hooks wired -> rotates (exit 0)"
W="$(cat "$WITNESS")"
assert_has "$W" "checkpoint:$TMP/repo-alpha" "checkpoint ran for repo-alpha"
assert_has "$W" "checkpoint:$TMP/repo-beta"  "checkpoint ran for repo-beta"
assert_has "$W" "swap:max-b"                 "credential swap ran to max-b"
assert_has "$W" "relaunch"                   "fleet relaunch ran"
# Order check: first checkpoint line precedes the swap line precedes relaunch.
cp_line="$(grep -n '^checkpoint:' "$WITNESS" | head -n1 | cut -d: -f1)"
sw_line="$(grep -n '^swap:'       "$WITNESS" | head -n1 | cut -d: -f1)"
rl_line="$(grep -n '^relaunch'    "$WITNESS" | head -n1 | cut -d: -f1)"
if [ -n "$cp_line" ] && [ -n "$sw_line" ] && [ -n "$rl_line" ] && \
   [ "$cp_line" -lt "$sw_line" ] && [ "$sw_line" -lt "$rl_line" ]; then
  ok "ORDER: checkpoint < swap < relaunch"
else
  bad "ORDER wrong (checkpoint=$cp_line swap=$sw_line relaunch=$rl_line)"
fi

# ---------------------------------------------------------------------------
echo "=== 4) CLEAN-BOUNDARY guard: a WORKING swarm refuses (exit 3) unless --force ==="
# Build a Claude-projects dir with a FRESH transcript for repo-alpha so
# repo_activity reports it as working. Claude encodes the repo path by replacing
# every '/' and '.' with '-' and prepending '-'.
PROJ="$TMP/proj-working"; mkdir -p "$PROJ"
enc_alpha="$(printf '%s' "$TMP/repo-alpha" | sed -e 's/[/.]/-/g')"
mkdir -p "$PROJ/$enc_alpha"
: > "$PROJ/$enc_alpha/live.jsonl"   # mtime = now => age 0 => WORKING
# tmux-live so the session is considered alive (working only counts for live sessions).
: > "$WITNESS"
RR_TMUX="$TMP/stubbin/tmux-live"; RR_PROJ="$PROJ"; run_rotate
assert_eq 3 "$rc" "working swarm -> REFUSED (exit 3)"
assert_has "$OUT" "NOT a clean phase boundary" "explains the clean-boundary refusal"
assert_eq "" "$(cat "$WITNESS")" "no hook fired while refusing (no swap/relaunch)"

# Same situation WITH --force: proceeds.
: > "$WITNESS"
RR_TMUX="$TMP/stubbin/tmux-live"; RR_PROJ="$PROJ"; run_rotate --force
assert_eq 0 "$rc" "working swarm + --force -> rotates (exit 0)"
assert_has "$(cat "$WITNESS")" "swap:max-b" "--force lets the swap through"

# ---------------------------------------------------------------------------
echo "=== 4b) FAIL-SAFE: a malformed-account row FOLLOWING a good-account row blocks rotation ==="
# The WORKING-rail landmine, account edition (adversarial-review Finding 1). Row 1
# ('good') has a VALID labeled account 'maxa' → swarm_account_resolve SUCCEEDS and
# sets SWARM_ACCT_PROJECTS_DIR to maxa's dir. Row 2 ('risky') has a MALFORMED
# account ('bad/slash') → the resolver REJECTS it and returns WITHOUT building a
# path, leaving the global STALE at row 1's value. Without the per-row rc-check,
# row 2 would be evaluated against row 1's (foreign) projects dir — which reads as
# IDLE either way (if the foreign dir is absent → "dir not found → idle"; if it
# exists → repo_activity finds no transcript for row 2's repo → NO_TRANSCRIPT
# sentinel → idle). Either path lets rotation tear down the WHOLE fleet, including
# a maybe-working swarm on the bad account. WITH the rc-check, row 2 fails SAFE →
# treated as WORKING → rotation REFUSES (exit 3) and fires no hooks. tmux-live so
# both rows are probed (only live swarms reach the resolve). In this fixture row
# 1's account ('maxa') has no on-disk dir, so the pre-fix path is the "dir not
# found → idle" one — and the test asserts exit 3, which only row 2's bad-account
# branch can produce, so it genuinely fails if the rc-check is removed.
ORIG_CONF="$(cat "$FAKE_SH/swarm.conf")"
cat > "$FAKE_SH/swarm.conf" <<EOF
good  | $TMP/repo-alpha | BOT_G | 111 | 999 | maxa
risky | $TMP/repo-beta  | BOT_R | 222 | 999 | bad/slash
EOF
: > "$WITNESS"
RR_TMUX="$TMP/stubbin/tmux-live"; run_rotate
assert_eq 3 "$rc" "malformed-account row (after a good row) -> rotation REFUSED (exit 3)"
assert_has "$OUT" "risky(bad-account)"          "the refusal names the bad-account swarm as blocking"
assert_has "$OUT" "invalid account 'bad/slash'" "warns about the specific invalid account label"
assert_eq "" "$(cat "$WITNESS")"                "no hook fired (no swap/checkpoint/relaunch) while refusing"
# --force still lets the operator override (consistent with the WORKING refusal).
: > "$WITNESS"
RR_TMUX="$TMP/stubbin/tmux-live"; run_rotate --force
assert_eq 0 "$rc" "malformed-account row + --force -> proceeds (exit 0)"
assert_has "$(cat "$WITNESS")" "swap:max-b" "--force lets the swap through despite the bad-account row"
# Restore the canonical 2-row conf for the remaining sections.
printf '%s\n' "$ORIG_CONF" > "$FAKE_SH/swarm.conf"

# ---------------------------------------------------------------------------
echo "=== 5) CHECKPOINT discipline: failing checkpoint aborts (exit 4) unless --force ==="
: > "$WITNESS"
RR_CKPT="$CHECKPOINT_FAIL"; run_rotate
assert_eq 4 "$rc" "checkpoint failure -> ABORT (exit 4)"
assert_lacks "$(cat "$WITNESS")" "swap:" "no swap after a failed checkpoint"
# --force overrides the checkpoint failure.
: > "$WITNESS"
RR_CKPT="$CHECKPOINT_FAIL"; run_rotate --force
assert_eq 0 "$rc" "checkpoint failure + --force -> proceeds (exit 0)"
assert_has "$(cat "$WITNESS")" "swap:max-b" "--force swaps despite failed checkpoint"

echo "=== 5b) no checkpoint hook: WARNS but proceeds ==="
: > "$WITNESS"
RR_CKPT='-'; run_rotate   # '-' = leave SWARM_CHECKPOINT_CMD unset
assert_eq 0 "$rc" "no checkpoint hook -> still rotates (exit 0)"
assert_has "$OUT" "no SWARM_CHECKPOINT_CMD wired" "warns that no checkpoint hook is wired"

# ---------------------------------------------------------------------------
echo "=== 6) CREDSWAP guard: live run with no credswap REFUSES (2); failing swap no-relaunches (5) ==="
: > "$WITNESS"
RR_CRED='-'; run_rotate   # '-' = leave SWARM_CREDSWAP_CMD unset
assert_eq 2 "$rc" "no SWARM_CREDSWAP_CMD on a live run -> REFUSED (exit 2)"
assert_lacks "$(cat "$WITNESS")" "relaunch" "no relaunch when the swap is refused"

: > "$WITNESS"
RR_CRED="$CREDSWAP_FAIL"; run_rotate
assert_eq 5 "$rc" "failing credential swap -> exit 5"
assert_lacks "$(cat "$WITNESS")" "relaunch" "no relaunch when the swap FAILED (don't boot on unknown creds)"

# ---------------------------------------------------------------------------
echo "=== 6b) RING EXHAUSTION: credswap exit 7 (authed-but-capped) -> exit 6, NO relaunch, escalate ==="
# The swap TOOK and the new credential AUTHENTICATES, but the target account is
# itself rate-limited (credswap exit 7). Every reachable account is capped, so
# rotation has nowhere fresh to go. The actuator must:
#   - NOT relaunch the fleet on a capped account,
#   - exit 6 (distinct from a swap FAILURE's exit 5),
#   - escalate via SWARM_ATTENTION_CMD if wired.
: > "$WITNESS"
RR_CRED="$CREDSWAP_CAPPED"; RR_ATTN="$ATTENTION"; run_rotate
assert_eq 6 "$rc" "authed-but-capped swap (credswap 7) -> rotate exit 6 (ring exhausted)"
assert_has "$(cat "$WITNESS")" "swap-capped:max-b" "the swap hook ran (the credential WAS installed/authenticated)"
assert_lacks "$(cat "$WITNESS")" "relaunch" "ring exhaustion: fleet NOT relaunched on a capped account"
assert_has "$OUT" "RING EXHAUSTED" "ring exhaustion is announced loudly"
assert_has "$OUT" "TERMINAL" "it is a terminal stop, not a retry"
assert_has "$(cat "$WITNESS")" "attention:" "ring exhaustion RAISED the attention escalation hook"
assert_has "$(cat "$WITNESS")" "RING EXHAUSTED" "the attention reason names ring exhaustion"

# Ring exhaustion with NO attention hook wired: still exit 6, surfaced on stderr.
: > "$WITNESS"
RR_CRED="$CREDSWAP_CAPPED"; RR_ATTN=''; run_rotate
assert_eq 6 "$rc" "ring exhaustion without attention hook -> still exit 6 (terminal)"
assert_lacks "$(cat "$WITNESS")" "relaunch" "still no relaunch on a capped account"
assert_has "$OUT" "no SWARM_ATTENTION_CMD wired" "honestly reports the escalation hook is unwired"

# ---------------------------------------------------------------------------
echo "=== 7) --dry-run: prints the plan, executes NO hook ==="
: > "$WITNESS"
run_rotate --dry-run
assert_eq 0 "$rc" "--dry-run exits 0"
assert_has "$OUT" "DRY-RUN complete" "dry-run reports completion"
assert_has "$OUT" "max-b" "dry-run names the next account"
assert_eq "" "$(cat "$WITNESS")" "--dry-run fires NO hook (no swap/checkpoint/relaunch)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
