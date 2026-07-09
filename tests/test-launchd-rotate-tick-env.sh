#!/usr/bin/env bash
# test-launchd-rotate-tick-env.sh — regression tests for the rotate-tick
# OPERATOR ENV FILE seam in bin/swarm-launchd-install.sh (--render-only path).
#
# WHAT THIS PROTECTS. The rotate-tick plist ships UNARMED (no SWARM_CREDSWAP_CMD
# — the actuator refuses a live swap); arming happens by merging a GITIGNORED
# KEY=value file into the plist's EnvironmentVariables at render time. This pins:
#   - INERT BY DEFAULT: absent or comments-only env file -> the rotate-tick
#     render is BYTE-IDENTICAL to a plain template substitution (ADR-0018
#     discipline: the seam must not exist until the operator wires it).
#   - the merge lands INSIDE the EnvironmentVariables dict, template keys intact,
#     other templates untouched, and the result still lints.
#   - VALUES ARE DATA, NEVER STRUCTURE: & < > are XML-escaped (round-tripped via
#     plistlib to prove the exact original bytes come back), and a value can
#     never inject plist elements.
#   - LOUD RENDER FAILURES: bad key, missing '=', empty value, duplicate key,
#     and a collision with a template-owned key each fail the run BEFORE any
#     plist is rendered.
#   - SWARM_TICK_OBSERVE is a reserved toggle: 1 renders --observe into
#     ProgramArguments (calibration mode), it never lands in the env dict, and
#     a process-env value overrides the file's.
#
# Run from $SWARM_HOME:  bash tests/test-launchd-rotate-tick-env.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $1"; }
assert_eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected=[$1] got=[$2])"; fi; }
assert_has()   { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
assert_file_has()   { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
assert_file_lacks() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rotate-tick-env-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

INSTALL="$ROOT/bin/swarm-launchd-install.sh"
TICK_TMPL="$ROOT/launchd/com.qofi.swarm-rotate-tick.plist.template"
TICK_BASE="com.qofi.swarm-rotate-tick.plist"
FAKE_TMUX="/fake/prefix/bin/tmux"

# render ENVFILE OUTDIR [extra env...] — run the installer --render-only with a
# controlled env-file path. Captures $OUT + $rc. Process-env SWARM_TICK_OBSERVE
# is explicitly UNSET unless a test injects it, so the file's value governs;
# SWARM_TICK_INTERVAL is PINNED to 300 (the reference render hardcodes it, and
# an operator's exported interval must not leak in and fail the byte-identity
# pins spuriously).
render() {
  local envfile="$1" outdir="$2"; shift 2
  OUT="$(
    unset SWARM_TICK_OBSERVE
    env "$@" HOME="$HOME" SWARM_HOME="$ROOT" SWARM_TMUX_BIN="$FAKE_TMUX" \
      SWARM_TICK_INTERVAL=300 \
      SWARM_ROTATE_TICK_ENV="$envfile" \
      bash "$INSTALL" --render-only "$outdir" 2>&1
  )"; rc=$?
}

# render_home SWARMHOME ENVFILE|DEFAULT OUTDIR — like render() but against a
# synthetic SWARM_HOME (its own launchd/ templates). ENVFILE=DEFAULT leaves
# SWARM_ROTATE_TICK_ENV unset so the installer resolves the DEFAULT path
# ($SWARM_HOME/launchd/rotate-tick.env.local).
render_home() {
  local home="$1" envfile="$2" outdir="$3"; shift 3
  if [ "$envfile" = "DEFAULT" ]; then
    OUT="$(
      unset SWARM_TICK_OBSERVE SWARM_ROTATE_TICK_ENV
      env "$@" HOME="$HOME" SWARM_HOME="$home" SWARM_TMUX_BIN="$FAKE_TMUX" \
        SWARM_TICK_INTERVAL=300 \
        bash "$INSTALL" --render-only "$outdir" 2>&1
    )"; rc=$?
  else
    OUT="$(
      unset SWARM_TICK_OBSERVE
      env "$@" HOME="$HOME" SWARM_HOME="$home" SWARM_TMUX_BIN="$FAKE_TMUX" \
        SWARM_TICK_INTERVAL=300 \
        SWARM_ROTATE_TICK_ENV="$envfile" \
        bash "$INSTALL" --render-only "$outdir" 2>&1
    )"; rc=$?
  fi
}

# The independent reference render: what the plain template substitution
# produces with NO seam involvement at all. Byte-identity against this is the
# inertness proof.
REF="$TMP/reference.plist"
sed -e "s#@@SWARM_HOME@@#$ROOT#g" \
    -e "s#@@HOME@@#$HOME#g" \
    -e "s#@@TMUX_BIN@@#$FAKE_TMUX#g" \
    -e "s#@@TICK_INTERVAL@@#300#g" \
    "$TICK_TMPL" > "$REF"

# env_extract PLIST KEY — read one EnvironmentVariables value back through a
# REAL plist parser (round-trip proof: escaping must decode to the original).
env_extract() {
  python3 -c 'import plistlib,sys
d = plistlib.load(open(sys.argv[1], "rb"))
print(d["EnvironmentVariables"].get(sys.argv[2], "<ABSENT>"))' "$1" "$2"
}

echo "=== 1) INERT: absent env file -> byte-identical render ==="
render "$TMP/does-not-exist" "$TMP/out-absent"
assert_eq 0 "$rc" "render-only exits 0 with no env file"
if cmp -s "$TMP/out-absent/$TICK_BASE" "$REF"; then
  ok "rotate-tick render is BYTE-IDENTICAL to the plain template substitution"
else
  bad "rotate-tick render differs from the plain substitution (seam not inert)"
fi

echo ""
echo "=== 2) INERT: comments/blank-only env file -> still byte-identical ==="
printf '# only comments here\n\n   \n# SWARM_CREDSWAP_CMD=commented out\n' > "$TMP/empty.env"
render "$TMP/empty.env" "$TMP/out-empty"
assert_eq 0 "$rc" "render-only exits 0 with a comments-only env file"
if cmp -s "$TMP/out-empty/$TICK_BASE" "$REF"; then
  ok "comments-only env file changes nothing (byte-identical)"
else
  bad "comments-only env file altered the render"
fi

echo ""
echo "=== 3) MERGE happy path ==="
cat > "$TMP/arm.env" <<'EOF'
# arming
SWARM_CREDSWAP_CMD=/x/bin/swarm-login-relay.sh
SWARM_ROTATE_THRESHOLD_PCT=95
SWARM_ACCOUNTS=max-a max-b
EOF
render "$TMP/arm.env" "$TMP/out-arm"
assert_eq 0 "$rc" "render-only exits 0 with a valid env file"
P="$TMP/out-arm/$TICK_BASE"
assert_eq "/x/bin/swarm-login-relay.sh" "$(env_extract "$P" SWARM_CREDSWAP_CMD)" "merged key lands in EnvironmentVariables (parsed back via plistlib)"
assert_eq "95" "$(env_extract "$P" SWARM_ROTATE_THRESHOLD_PCT)" "second merged key lands"
assert_eq "max-a max-b" "$(env_extract "$P" SWARM_ACCOUNTS)" "value with spaces survives verbatim"
assert_eq "$ROOT" "$(env_extract "$P" SWARM_HOME)" "template-owned SWARM_HOME still present and correct"
assert_eq "$FAKE_TMUX" "$(env_extract "$P" SWARM_TMUX_BIN)" "template-owned SWARM_TMUX_BIN untouched"
assert_has "$OUT" "3 operator env key" "reports the merge count"
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$P" >/dev/null 2>&1; then ok "merged plist passes plutil -lint"; else bad "merged plist fails plutil -lint"; fi
fi
# Other templates are untouched by the seam.
if cmp -s "$TMP/out-arm/com.qofi.swarm-typing.plist" "$TMP/out-absent/com.qofi.swarm-typing.plist"; then
  ok "other templates (swarm-typing) render identically with and without the env file"
else
  bad "the env file leaked into a non-rotate-tick template"
fi

echo ""
echo "=== 4) XML ESCAPING: & < > and a literal \"\$1\" round-trip exactly ==="
RAW='bin/swarm-checkpoint.sh "$1" <weird> & co'
printf 'SWARM_CHECKPOINT_CMD=%s\n' "$RAW" > "$TMP/esc.env"
render "$TMP/esc.env" "$TMP/out-esc"
assert_eq 0 "$rc" "render-only exits 0 with escapable characters in the value"
P="$TMP/out-esc/$TICK_BASE"
assert_eq "$RAW" "$(env_extract "$P" SWARM_CHECKPOINT_CMD)" "plistlib decodes the EXACT original value (escaping is lossless)"
assert_file_has "$P" '&lt;weird&gt; &amp; co' "raw & < > were entity-escaped in the XML"
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$P" >/dev/null 2>&1; then ok "escaped plist passes plutil -lint"; else bad "escaped plist fails plutil -lint"; fi
fi
# A value trying to smuggle plist STRUCTURE arrives as inert text, not elements.
printf 'EVIL=</string></dict><key>Sneaky</key><string>x\n' > "$TMP/inject.env"
render "$TMP/inject.env" "$TMP/out-inject"
assert_eq 0 "$rc" "structure-smuggling value still renders (as data)"
P="$TMP/out-inject/$TICK_BASE"
assert_eq '</string></dict><key>Sneaky</key><string>x' "$(env_extract "$P" EVIL)" "smuggled markup survives ONLY as literal string data"
assert_eq "<ABSENT>" "$(env_extract "$P" Sneaky)" "no injected key materialized"

echo ""
echo "=== 5) LOUD REJECTIONS (render fails, nothing rendered) ==="
reject_case() {  # label envfile-content expected-msg-substring
  printf '%s\n' "$2" > "$TMP/bad.env"
  rm -rf "$TMP/out-bad"
  render "$TMP/bad.env" "$TMP/out-bad"
  if [ "$rc" -ne 0 ]; then ok "$1 -> render fails"; else bad "$1 -> render unexpectedly succeeded"; fi
  assert_has "$OUT" "$3" "$1 -> names the problem"
  if [ -f "$TMP/out-bad/$TICK_BASE" ]; then
    bad "$1 -> a plist was rendered despite the failure"
  else
    ok "$1 -> no plist rendered (failed before any output)"
  fi
}
reject_case "bad key (leading digit)"     "9BAD=x"                      "invalid key"
reject_case "bad key (hyphen)"            "BAD-KEY=x"                   "invalid key"
reject_case "missing '='"                 "JUSTAWORD"                   "not a KEY=value line"
reject_case "empty value"                 "SWARM_CREDSWAP_CMD="         "empty value"
reject_case "duplicate key"               "A_KEY=one
A_KEY=two"                                                              "duplicate key"
reject_case "template-owned collision"    "SWARM_HOME=/elsewhere"       "collides with a template-owned"

echo ""
echo "=== 6) OBSERVE toggle (reserved key; ProgramArguments, not env dict) ==="
printf 'SWARM_TICK_OBSERVE=1\n' > "$TMP/obs.env"
render "$TMP/obs.env" "$TMP/out-obs"
assert_eq 0 "$rc" "observe-only env file renders"
P="$TMP/out-obs/$TICK_BASE"
assert_file_has "$P" "<string>--observe</string>" "--observe rendered into ProgramArguments"
assert_file_lacks "$P" "<key>SWARM_TICK_OBSERVE</key>" "reserved key never lands in the plist env dict"
assert_has "$OUT" "observe" "announces calibration mode"
# The --observe string must FOLLOW the tick-script argument (arg order matters).
script_line="$(grep -n 'swarm-rotate-tick\.sh</string>' "$P" | head -n 1 | cut -d: -f1)"
observe_line="$(grep -n -- '--observe' "$P" | head -n 1 | cut -d: -f1)"
if [ -n "$script_line" ] && [ -n "$observe_line" ] && [ "$observe_line" -eq $((script_line + 1)) ]; then
  ok "--observe is the argument immediately after the tick script"
else
  bad "--observe misplaced (script line=$script_line, observe line=$observe_line)"
fi
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$P" >/dev/null 2>&1; then ok "observe plist passes plutil -lint"; else bad "observe plist fails plutil -lint"; fi
fi
echo "--- process-env override beats the file ---"
render "$TMP/obs.env" "$TMP/out-obs0" SWARM_TICK_OBSERVE=0
assert_eq 0 "$rc" "override render exits 0"
assert_file_lacks "$TMP/out-obs0/$TICK_BASE" "--observe" "SWARM_TICK_OBSERVE=0 in the process env overrides the file's 1"
echo "--- invalid observe value refuses ---"
printf 'SWARM_TICK_OBSERVE=maybe\n' > "$TMP/obsbad.env"
render "$TMP/obsbad.env" "$TMP/out-obsbad"
if [ "$rc" -ne 0 ]; then ok "non-0/1 observe value -> render fails"; else bad "non-0/1 observe value accepted"; fi
assert_has "$OUT" "SWARM_TICK_OBSERVE" "names the bad toggle"

echo ""
echo "=== 7) FIRST-'=' SPLIT: a value containing '=' round-trips whole ==="
printf 'ARMING_FLAGS=--threshold=95 --mode=observe\n' > "$TMP/eq.env"
render "$TMP/eq.env" "$TMP/out-eq"
assert_eq 0 "$rc" "value with embedded '=' renders"
assert_eq "--threshold=95 --mode=observe" "$(env_extract "$TMP/out-eq/$TICK_BASE" ARMING_FLAGS)" "value split on the FIRST '=' only (everything after it survives verbatim)"

echo ""
echo "=== 8) PRODUCTION COMBO: arming keys AND SWARM_TICK_OBSERVE=1 in one file ==="
cat > "$TMP/combo.env" <<'EOF'
SWARM_TICK_OBSERVE=1
SWARM_CREDSWAP_CMD=/x/bin/swarm-login-relay.sh
SWARM_CHECKPOINT_CMD=/x/bin/swarm-checkpoint.sh "$1"
EOF
render "$TMP/combo.env" "$TMP/out-combo"
assert_eq 0 "$rc" "combined arming + observe file renders"
P="$TMP/out-combo/$TICK_BASE"
assert_eq "/x/bin/swarm-login-relay.sh" "$(env_extract "$P" SWARM_CREDSWAP_CMD)" "arming key lands alongside the observe toggle"
assert_eq '/x/bin/swarm-checkpoint.sh "$1"' "$(env_extract "$P" SWARM_CHECKPOINT_CMD)" "checkpoint hook with literal \"\$1\" lands"
assert_file_has "$P" "<string>--observe</string>" "--observe rendered in the same run"
assert_file_lacks "$P" "<key>SWARM_TICK_OBSERVE</key>" "reserved key still not in the env dict"
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$P" >/dev/null 2>&1; then ok "combo plist passes plutil -lint"; else bad "combo plist fails plutil -lint"; fi
fi

echo ""
echo "=== 9) MORE LOUD REJECTIONS ==="
reject_case "duplicate SWARM_TICK_OBSERVE (silent calibration->live flip)" "SWARM_TICK_OBSERVE=1
SWARM_TICK_OBSERVE=0"                                                   "duplicate key"
reject_case "control character in value"  "BAD_VAL=has$(printf '\t')tab" "control character"

echo ""
echo "=== 10) OBSERVE via process env with NO env file ==="
render "$TMP/does-not-exist" "$TMP/out-envobs" SWARM_TICK_OBSERVE=1
assert_eq 0 "$rc" "process-env observe with no file renders"
P="$TMP/out-envobs/$TICK_BASE"
assert_file_has "$P" "<string>--observe</string>" "--observe lands from process env alone"
assert_eq "<ABSENT>" "$(env_extract "$P" SWARM_TICK_OBSERVE)" "no env-dict entry appears"

echo ""
echo "=== 11) SYNTHETIC SWARM_HOME: default path, template-absent, atomic install ==="
echo "--- 11a) DEFAULT env-file path (\$SWARM_HOME/launchd/rotate-tick.env.local) resolves ---"
FH1="$TMP/fakehome-default"
mkdir -p "$FH1/templates" "$FH1/launchd"
: > "$FH1/swarm.conf"
cp "$ROOT"/launchd/*.plist.template "$FH1/launchd/"
printf 'DEFAULT_PATH_KEY=it-landed\n' > "$FH1/launchd/rotate-tick.env.local"
render_home "$FH1" DEFAULT "$TMP/out-default"
assert_eq 0 "$rc" "default-path render exits 0"
assert_eq "it-landed" "$(env_extract "$TMP/out-default/$TICK_BASE" DEFAULT_PATH_KEY)" "env file at the DEFAULT path is picked up without SWARM_ROTATE_TICK_ENV"
echo "--- 11b) populated env file + missing rotate-tick template -> refuse loud ---"
FH2="$TMP/fakehome-notick"
mkdir -p "$FH2/templates" "$FH2/launchd"
: > "$FH2/swarm.conf"
cp "$ROOT/launchd/com.qofi.swarm-typing.plist.template" "$FH2/launchd/"
printf 'SWARM_CREDSWAP_CMD=/x/relay.sh\n' > "$TMP/orphan.env"
render_home "$FH2" "$TMP/orphan.env" "$TMP/out-notick"
if [ "$rc" -ne 0 ]; then ok "arming env with no rotate-tick template -> render fails"; else bad "arming env silently evaporated (no rotate-tick template, render succeeded)"; fi
assert_has "$OUT" "nowhere to land" "explains the missing template"
echo "--- 11c) ATOMIC INSTALL: a failing re-render never clobbers the installed plist ---"
FH3="$TMP/fakehome-atomic"
mkdir -p "$FH3/templates" "$FH3/launchd"
: > "$FH3/swarm.conf"
cp "$ROOT"/launchd/*.plist.template "$FH3/launchd/"
render_home "$FH3" "$TMP/does-not-exist" "$TMP/out-atomic"
assert_eq 0 "$rc" "good first render succeeds (the 'installed' state)"
cp "$TMP/out-atomic/$TICK_BASE" "$TMP/installed-before.plist"
printf '  <!-- @@BOGUS_PLACEHOLDER@@ -->\n' >> "$FH3/launchd/${TICK_BASE}.template"
render_home "$FH3" "$TMP/does-not-exist" "$TMP/out-atomic"
if [ "$rc" -ne 0 ]; then ok "doctored template (unsubstituted placeholder) fails the render"; else bad "doctored template rendered successfully"; fi
if cmp -s "$TMP/out-atomic/$TICK_BASE" "$TMP/installed-before.plist"; then
  ok "previously installed plist SURVIVES a failed re-render byte-for-byte (atomic install)"
else
  bad "failed re-render clobbered the installed plist"
fi
if ls "$TMP/out-atomic"/*.new.* >/dev/null 2>&1; then
  bad "work-file residue left behind after the failed render"
else
  ok "no work-file residue after the failed render"
fi

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nFailures:%b\n' "$FAILURES" >&2; exit 1; fi
exit 0
