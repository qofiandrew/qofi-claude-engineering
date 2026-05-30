#!/usr/bin/env bash
# test-swarm-up-preflight-gates.sh — regression tests for the swarm-up.sh
# launch_one() preflight gates that refuse to launch a swarm which hasn't
# been fully configured by swarm-add.
#
# THE BUG CLASS THIS PINS. On this mini's first standup three swarms were
# `swarm-up`-ed before `swarm-add` had run for them. The bots showed online
# in Discord and silently dropped every message — because:
#   (a) enabledPlugins["discord-b2b@qofi-swarm"] wasn't true so the bridge
#       MCP never spawned (the original reserve-backend-2 trap, §3.4);
#   (b) ~/.claude/channels/discord/access.json had no groups.<channel>
#       entry so the ACL silently dropped channel traffic;
#   (c) the doctrine triad (CLAUDE.md / ESCALATION.md / TEAM_LEAD.md)
#       wasn't stamped so the CTO had no operating manual;
#   (d) the env block lacked CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 so
#       the lead launched but teammate spawning was silently disabled.
# Each of those is a cheap disk read — turning the silent half-launches
# into loud refusals is the structural fix. These tests pin each refusal
# path AND the SWARM_UP_SKIP_SANITY=1 bypass.
#
# Run from $SWARM_HOME:  bash tests/test-swarm-up-preflight-gates.sh
# Exit 0 = all pass. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; FAILURES=""
assert_eq() { # expected got label
  if [ "$1" = "$2" ]; then printf '  PASS  %s\n' "$3"; PASS=$((PASS+1))
  else printf '  FAIL  expected=[%s] got=[%s]  %s\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $3 (expected=[$1] got=[$2])"; fi
}
assert_contains() { # file needle label
  if grep -qF -- "$2" "$1"; then printf '  PASS  %s\n' "$3"; PASS=$((PASS+1))
  else printf '  FAIL  missing [%s] in %s  %s\n' "$2" "$1" "$3" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $3 (missing [$2])"; fi
}
assert_absent() { # file pattern label
  if grep -qF -- "$2" "$1"; then printf '  FAIL  unexpected [%s] in %s  %s\n' "$2" "$1" "$3" >&2; FAIL=$((FAIL+1)); FAILURES="${FAILURES}
  - $3 (found [$2])"
  else printf '  PASS  %s\n' "$3"; PASS=$((PASS+1)); fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/swarm-up-gates.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fixture SWARM_HOME — needs templates/ and swarm.conf to pass swarm-up's
# initial guard. Symlink to real templates (no copy needed).
FAKE_SH="$TMP/swarmhome"
mkdir -p "$FAKE_SH/bin"
ln -s "$ROOT/templates" "$FAKE_SH/templates"
ln -s "$ROOT/bin/swarm-lib.sh" "$FAKE_SH/bin/swarm-lib.sh"
cp "$ROOT/bin/swarm-up.sh" "$FAKE_SH/bin/swarm-up.sh"
chmod +x "$FAKE_SH/bin/swarm-up.sh"

# The test swarm.
NAME="testgate"
REPO="$TMP/repo"
mkdir -p "$REPO/.claude"
CHANNEL="999111222333444555"
cat > "$FAKE_SH/swarm.conf" <<EOF
$NAME | $REPO | BOT_TEST | $CHANNEL | 777666555444333222
EOF
cat > "$FAKE_SH/tokens.env" <<'EOF'
export BOT_TEST=fake-token-value-not-real
EOF

# Fake HOME — controls where access.json is read from. Starts empty.
FAKE_HOME="$TMP/userhome"
mkdir -p "$FAKE_HOME/.claude/channels/discord"

# tmux stub: `has-session` exits 1 (no session), every other invocation
# exits 0 with no output. Keeps the launch path FAST (no real tmux) when
# the bypass case proceeds past the gates.
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  has-session) exit 1 ;;
  capture-pane) printf 'auto mode\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/stubbin/tmux"

# Helpers to seed/unseed the four gate inputs. _settings_with_plugin is
# the "fully-good settings.json" seed used by every other gate's tests —
# it must satisfy BOTH gate (a) (enabledPlugins) AND gate (d) (env block
# with CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1) so that the test under
# scrutiny is the ONLY thing failing.
_settings_with_plugin() {
  cat > "$REPO/.claude/settings.json" <<'EOF'
{
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "enabledPlugins": { "discord-b2b@qofi-swarm": true }
}
EOF
}
_settings_without_plugin() {
  cat > "$REPO/.claude/settings.json" <<'EOF'
{
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "enabledPlugins": { "some-other-plugin": true }
}
EOF
}
# Gate (d) variants — flip ONLY the env block; keep enabledPlugins good
# so gate (a) doesn't fire first and mask gate (d).
_settings_plugin_no_env_block() {
  cat > "$REPO/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": { "discord-b2b@qofi-swarm": true }
}
EOF
}
_settings_plugin_env_block_no_key() {
  cat > "$REPO/.claude/settings.json" <<'EOF'
{
  "env": { "CLAUDE_TEST_CMD": "npm test --silent" },
  "enabledPlugins": { "discord-b2b@qofi-swarm": true }
}
EOF
}
_settings_plugin_env_block_wrong_value() {
  cat > "$REPO/.claude/settings.json" <<'EOF'
{
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "0" },
  "enabledPlugins": { "discord-b2b@qofi-swarm": true }
}
EOF
}
_access_with_group() {
  python3 - "$FAKE_HOME/.claude/channels/discord/access.json" "$CHANNEL" <<'PY'
import json, sys
p, ch = sys.argv[1], sys.argv[2]
json.dump({"groups": {ch: {"requireMention": False, "allowFrom": []}}}, open(p, "w"))
PY
}
_access_without_group() {
  python3 - "$FAKE_HOME/.claude/channels/discord/access.json" <<'PY'
import json, sys
json.dump({"groups": {}}, open(sys.argv[1], "w"))
PY
}
_doctrine_stamp() {
  for f in CLAUDE.md ESCALATION.md TEAM_LEAD.md; do
    printf 'stamp\n' > "$REPO/$f"
  done
}
_doctrine_unstamp() {
  rm -f "$REPO/CLAUDE.md" "$REPO/ESCALATION.md" "$REPO/TEAM_LEAD.md"
}

# Run swarm-up.sh up <NAME> in the fixture env. Returns rc; merged stderr
# in $TMP/last.err and stdout in $TMP/last.out.
run_up() {
  local extra_env="${1:-}"
  rm -f "$TMP/last.out" "$TMP/last.err"
  env -i PATH="$TMP/stubbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    HOME="$FAKE_HOME" \
    SWARM_HOME="$FAKE_SH" \
    ${extra_env:+SWARM_UP_SKIP_SANITY=$extra_env} \
    bash "$FAKE_SH/bin/swarm-up.sh" up "$NAME" >"$TMP/last.out" 2>"$TMP/last.err"
  echo $?
}

# ---------------------------------------------------------------------------
# Gate (a) — enabledPlugins
# ---------------------------------------------------------------------------
echo "=== gate (a): enabledPlugins ==="

# (a.1) no settings.json at all
rm -f "$REPO/.claude/settings.json"
_access_with_group
_doctrine_stamp
rc=$(run_up "")
assert_contains "$TMP/last.err" ".claude/settings.json missing" "no settings.json → gate (a) fires"
assert_contains "$TMP/last.err" "swarm-add.sh $NAME $REPO --skip-walkthrough" "no settings.json → remediation printed"
assert_contains "$TMP/last.err" "bypass with SWARM_UP_SKIP_SANITY=1" "no settings.json → bypass hint printed"

# (a.2) settings.json present but enabledPlugins missing/false
_settings_without_plugin
rc=$(run_up "")
assert_contains "$TMP/last.err" "enabledPlugins[\"discord-b2b@qofi-swarm\"] not true" "settings missing flag → gate (a) fires"

# ---------------------------------------------------------------------------
# Gate (b) — access.json group for this channel
# ---------------------------------------------------------------------------
echo "=== gate (b): access.json group ==="

_settings_with_plugin
_doctrine_stamp

# (b.1) no access.json at all
rm -f "$FAKE_HOME/.claude/channels/discord/access.json"
rc=$(run_up "")
assert_contains "$TMP/last.err" "access.json" "no access.json → gate (b) fires"
assert_contains "$TMP/last.err" "swarm-add.sh $NAME $REPO --skip-walkthrough" "no access.json → remediation printed"

# (b.2) access.json present but no group for this channel
_access_without_group
rc=$(run_up "")
assert_contains "$TMP/last.err" "no groups.$CHANNEL entry" "missing group → gate (b) fires"

# ---------------------------------------------------------------------------
# Gate (c) — doctrine stamp
# ---------------------------------------------------------------------------
echo "=== gate (c): doctrine triad (engineering-cto default — no swarm-type marker) ==="

_settings_with_plugin
_access_with_group
_doctrine_unstamp
rc=$(run_up "")
assert_contains "$TMP/last.err" "doctrine missing" "no doctrine → gate (c) fires"
assert_contains "$TMP/last.err" "CLAUDE.md" "no doctrine → names CLAUDE.md"
assert_contains "$TMP/last.err" "ESCALATION.md" "no doctrine → names ESCALATION.md"
assert_contains "$TMP/last.err" "TEAM_LEAD.md" "no doctrine → names TEAM_LEAD.md (engineering triad required)"

# ---------------------------------------------------------------------------
# Gate (c) — per-archetype dispatch (cpo requires only CLAUDE+ESCALATION;
# unknown / future markers fall back to the engineering triad fail-safe).
# Lock both behaviors so a future archetype edit can't silently break the
# cpo path OR weaken the fail-safe for an unknown marker.
# ---------------------------------------------------------------------------
echo "=== gate (c): cpo archetype requires CLAUDE+ESCALATION only ==="

# Make the test repo a cpo swarm by stamping the type marker. swarm_type_of
# reads this and the gate dispatches via swarm_required_doctrine.
echo "cpo" > "$REPO/.claude/swarm-type"

# (c.cpo.1) cpo with the engineering triad fully stamped — passes the gate
# trivially (extra files don't fail it; only missing required ones do).
_doctrine_stamp
rc=$(run_up "")
assert_absent "$TMP/last.err" "doctrine missing" "cpo with full triad → gate (c) passes"

# (c.cpo.2) cpo with ONLY CLAUDE+ESCALATION stamped (no TEAM_LEAD) — the
# blocking case the cpo standup hit before this fix. Must pass now.
_doctrine_unstamp
printf 'stamp\n' > "$REPO/CLAUDE.md"
printf 'stamp\n' > "$REPO/ESCALATION.md"
rc=$(run_up "")
assert_absent "$TMP/last.err" "doctrine missing" "cpo without TEAM_LEAD → gate (c) passes (cpo doesn't require it)"

# (c.cpo.3) cpo missing ESCALATION (which IS required for cpo) — must fire;
# error must name ESCALATION; error must NOT name TEAM_LEAD (cpo doesn't
# require it, so the error message shouldn't pretend it does).
rm -f "$REPO/ESCALATION.md"
rc=$(run_up "")
assert_contains "$TMP/last.err" "doctrine missing" "cpo missing ESCALATION → gate (c) fires"
assert_contains "$TMP/last.err" "ESCALATION.md" "cpo missing ESCALATION → error names ESCALATION.md"
assert_absent   "$TMP/last.err" "TEAM_LEAD.md" "cpo error must NOT name TEAM_LEAD.md (cpo doesn't require it)"
assert_contains "$TMP/last.err" "type=cpo" "cpo error names the resolved type"

echo "=== gate (c): unknown / future marker falls back to engineering triad (fail-safe) ==="

# An unknown marker must fall back to the engineering triad, so a
# misclassified swarm gets refused (with a clear TEAM_LEAD.md message)
# rather than silently launched with no doctrine. This is the explicit
# fail-safe direction documented in swarm_required_doctrine.
echo "future-archetype" > "$REPO/.claude/swarm-type"
_doctrine_unstamp
printf 'stamp\n' > "$REPO/CLAUDE.md"
printf 'stamp\n' > "$REPO/ESCALATION.md"
rc=$(run_up "")
assert_contains "$TMP/last.err" "doctrine missing" "unknown type → gate (c) fires (fail-safe)"
assert_contains "$TMP/last.err" "TEAM_LEAD.md" "unknown type → falls back to engineering triad, names TEAM_LEAD.md"
assert_contains "$TMP/last.err" "type=future-archetype" "unknown type → error names the resolved type"

# Restore engineering-cto default for the downstream gate (d) / bypass /
# pass-path tests (they were written against the default-type behavior;
# leaving the cpo / unknown marker would break their assumptions).
rm -f "$REPO/.claude/swarm-type"

# ---------------------------------------------------------------------------
# Gate (d) — CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS in the env block.
#
# Without this, claude launches but teammate spawning is silently
# disabled — the lead boots, Discord shows it online, and the team
# never materializes. Same silent-failure shape as (a)/(b)/(c); same
# loud-refuse treatment. All three sub-cases hold gate (a) green (good
# enabledPlugins) so the failure under test is the ONLY thing firing.
# ---------------------------------------------------------------------------
echo "=== gate (d): CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS env block ==="

_access_with_group
_doctrine_stamp

# (d.1) no env block at all
_settings_plugin_no_env_block
rc=$(run_up "")
assert_contains "$TMP/last.err" "missing CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" "no env block → gate (d) fires"
assert_contains "$TMP/last.err" "Agent Teams (teammate spawning) will be silently disabled" "no env block → silent-disable warning printed"
assert_contains "$TMP/last.err" "bypass with SWARM_UP_SKIP_SANITY=1" "no env block → bypass hint printed"

# (d.2) env block present but the key is absent
_settings_plugin_env_block_no_key
rc=$(run_up "")
assert_contains "$TMP/last.err" "missing CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" "env block missing key → gate (d) fires"

# (d.3) env block present but the key is the wrong value
_settings_plugin_env_block_wrong_value
rc=$(run_up "")
assert_contains "$TMP/last.err" "missing CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" "env block key wrong value → gate (d) fires"

# ---------------------------------------------------------------------------
# SWARM_UP_SKIP_SANITY=1 — bypass with everything failing
# ---------------------------------------------------------------------------
echo "=== bypass: SWARM_UP_SKIP_SANITY=1 ==="

rm -f "$REPO/.claude/settings.json" "$FAKE_HOME/.claude/channels/discord/access.json"
_doctrine_unstamp
rc=$(run_up "1")
# Bypass means: no gate ERROR lines (none of the gate messages appear) AND
# the function proceeds to the "launching:" notice. tmux is stubbed so the
# launch is a no-op past that point.
assert_absent "$TMP/last.err" "gate: enabledPlugins" "bypass → enabledPlugins gate suppressed"
assert_absent "$TMP/last.err" "gate: access.json" "bypass → access.json gate suppressed"
assert_absent "$TMP/last.err" "gate: doctrine-stamp" "bypass → doctrine gate suppressed"
assert_absent "$TMP/last.err" "gate: agent-teams-env" "bypass → agent-teams-env gate suppressed"
assert_contains "$TMP/last.out" "launching: swarm-$NAME" "bypass → proceeds to launch"

# ---------------------------------------------------------------------------
# Pass path — all four configured, no bypass needed
# ---------------------------------------------------------------------------
echo "=== pass: fully configured swarm launches without gate refusal ==="

_settings_with_plugin
_access_with_group
_doctrine_stamp
rc=$(run_up "")
assert_absent "$TMP/last.err" "gate: enabledPlugins" "configured → enabledPlugins gate passes"
assert_absent "$TMP/last.err" "gate: access.json" "configured → access.json gate passes"
assert_absent "$TMP/last.err" "gate: doctrine-stamp" "configured → doctrine gate passes"
assert_absent "$TMP/last.err" "gate: agent-teams-env" "configured → agent-teams-env gate passes"
assert_contains "$TMP/last.out" "launching: swarm-$NAME" "configured → proceeds to launch"

echo ""
echo "=== Summary ==="
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:%b\n' "$FAILURES" >&2
  echo ""
  echo "Last run stderr:"
  sed 's/^/  /' < "$TMP/last.err" >&2 2>/dev/null || true
  exit 1
fi
exit 0
