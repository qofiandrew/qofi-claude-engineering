#!/usr/bin/env bash
# swarm-launchd-install.sh — render the launchd plist TEMPLATES for THIS
# machine and (re)load the agents.
#
# WHY THIS EXISTS. launchd does not expand $VARS or ~ inside plist path
# strings — ProgramArguments / StandardOutPath / EnvironmentVariables must be
# absolute literals. So a single committed plist cannot be username- or
# host-agnostic. We commit TEMPLATES (launchd/*.plist.template) with @@…@@
# placeholders and render the real plists here, per machine, at install time.
# The repo therefore carries ZERO hardcoded /Users/<name> paths, and every
# Mac mini in the fleet renders its own copy (sharding-correct by construction).
#
# Substitutions:
#   @@SWARM_HOME@@     -> $SWARM_HOME
#   @@HOME@@           -> $HOME
#   @@TMUX_BIN@@       -> $SWARM_TMUX_BIN if set, else `command -v tmux`
#   @@TICK_INTERVAL@@  -> $SWARM_TICK_INTERVAL if set, else 60 (seconds between
#                         rotation-orchestrator ticks; only the rotate-tick plist
#                         uses it — harmless no-op for templates without it)
#
# ── OPERATOR ENV FILE (rotate-tick only; INERT by default — ADR-0018 style) ──
# The rotate-tick plist deliberately ships WITHOUT the arming variables
# (SWARM_CREDSWAP_CMD etc.) — "the operator adds it out-of-band". This is the
# out-of-band channel: a GITIGNORED local env file whose KEY=value lines are
# merged into com.qofi.swarm-rotate-tick's EnvironmentVariables dict at render
# time. Hand-editing the rendered plist doesn't survive a re-render; this does.
#
#   SWARM_ROTATE_TICK_ENV   path to the env file. Default:
#                           $SWARM_HOME/launchd/rotate-tick.env.local
#                           (see rotate-tick.env.local.example for every knob).
#   Format: KEY=value, one per line; '#' comments and blank lines ignored.
#   Values are taken LITERALLY (no quoting, no expansion) and XML-escaped
#   (& < >) into the plist. Render FAILS loud — BEFORE any file is written —
#   on: a KEY that is not a valid identifier, an empty value, a value with a
#   control character, a duplicate KEY (SWARM_TICK_OBSERVE included), a
#   missing '=', a KEY that collides with a template-owned
#   EnvironmentVariables key (the template owns SWARM_HOME,
#   CLAUDE_PROJECTS_DIR, SWARM_STALE_SECONDS, SWARM_TMUX_BIN), or a populated
#   env file with no rotate-tick template to land in. Every plist is rendered
#   and validated in a temp file and only installed after ALL checks pass, so
#   a failed run never replaces a previously installed agent.
#   Absent or empty file -> the render is BYTE-IDENTICAL to an unwired one.
#
#   SWARM_TICK_OBSERVE      reserved key (consumed by THIS installer, never
#                           merged into the plist): 1 renders the rotate-tick
#                           ProgramArguments with --observe (calibration mode —
#                           the tick logs burn-vs-budget and rotates NOTHING);
#                           0/absent renders it live. A process-env
#                           SWARM_TICK_OBSERVE overrides the file's value.
#
# Usage:
#   swarm-launchd-install.sh                 # render to ~/Library/LaunchAgents + (re)load
#   swarm-launchd-install.sh --render-only DIR   # render into DIR, no launchctl (tests/dry-run)
#   swarm-launchd-install.sh -h | --help
#
# Idempotent: safe to re-run after a template edit or a SWARM_HOME move — it
# bootout's the old agent and bootstrap's the freshly rendered one.
#
# bash 3.2-safe. CWD-independent.

set -uo pipefail

if [ -z "${SWARM_HOME:-}" ] || [ ! -d "${SWARM_HOME:-}/templates" ] || [ ! -f "${SWARM_HOME:-}/swarm.conf" ]; then
  echo "swarm-launchd-install: SWARM_HOME unset or wrong — export SWARM_HOME=/path/to/qofi-claude-engineering" >&2
  exit 1
fi

usage() { sed -n '2,59p' "$0"; exit "${1:-0}"; }

RENDER_ONLY_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --render-only) RENDER_ONLY_DIR="${2:-}"; [ -z "$RENDER_ONLY_DIR" ] && { echo "swarm-launchd-install: --render-only needs a DIR" >&2; exit 1; }; shift 2 ;;
    -h|--help)     usage 0 ;;
    *)             echo "swarm-launchd-install: unknown arg: $1" >&2; usage 1 ;;
  esac
done

# Resolve tmux's absolute path (launchd's PATH is minimal). Allow an override
# so render-only/test runs don't depend on tmux being installed.
TMUX_BIN="${SWARM_TMUX_BIN:-$(command -v tmux 2>/dev/null || true)}"
if [ -z "$TMUX_BIN" ]; then
  echo "swarm-launchd-install: tmux not found on PATH — 'brew install tmux' or set SWARM_TMUX_BIN" >&2
  exit 1
fi

# Cadence for the rotation-orchestrator tick (StartInterval, seconds). Only the
# rotate-tick template carries @@TICK_INTERVAL@@; for every other template the
# substitution below finds nothing to replace. Validate it's a positive integer
# so we never render a malformed StartInterval into the plist.
TICK_INTERVAL="${SWARM_TICK_INTERVAL:-60}"
case "$TICK_INTERVAL" in
  ''|*[!0-9]*) echo "swarm-launchd-install: SWARM_TICK_INTERVAL must be a positive integer (seconds); got '$TICK_INTERVAL'" >&2; exit 1 ;;
esac
if [ "$TICK_INTERVAL" -lt 1 ]; then
  echo "swarm-launchd-install: SWARM_TICK_INTERVAL must be >= 1 second; got '$TICK_INTERVAL'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Operator env file for the rotate-tick plist (see header). Parsed + validated
# UP FRONT so a bad file fails the whole run before anything is rendered or
# loaded. Inert when absent/empty: no transform is applied at all, so the
# rotate-tick render stays byte-identical to an unwired one.
# ---------------------------------------------------------------------------
ROTATE_TICK_ENV="${SWARM_ROTATE_TICK_ENV:-$SWARM_HOME/launchd/rotate-tick.env.local}"
ROTATE_TICK_BASE="com.qofi.swarm-rotate-tick.plist"
TICK_MERGE_FILE=""     # rendered <key>/<string> lines to splice into the env dict
TICK_MERGE_KEYS=""     # space-separated merged key names (collision/presence checks)
TICK_OBSERVE_FILE=""   # SWARM_TICK_OBSERVE value from the env file, if any
trap 'rm -f "${TICK_MERGE_FILE:-}"' EXIT

env_err() { echo "swarm-launchd-install: $ROTATE_TICK_ENV:$1" >&2; exit 1; }

if [ -f "$ROTATE_TICK_ENV" ]; then
  TICK_MERGE_FILE="$(mktemp "${TMPDIR:-/tmp}/rotate-tick-env.XXXXXX")" || {
    echo "swarm-launchd-install: mktemp failed" >&2; exit 1; }
  _ln=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _ln=$((_ln+1))
    _line="${_line%$'\r'}"                       # tolerate CRLF
    # Strip leading whitespace for the blank/comment test only — a KEY must
    # start at any column but is validated strictly below either way.
    _t="${_line#"${_line%%[![:space:]]*}"}"
    case "$_t" in ''|'#'*) continue ;; esac
    case "$_line" in
      *=*) ;;
      *) env_err "$_ln: not a KEY=value line: '$_line'" ;;
    esac
    _key="${_line%%=*}"
    _val="${_line#*=}"
    case "$_key" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) env_err "$_ln: invalid key '$_key' (need [A-Za-z_][A-Za-z0-9_]*)" ;;
    esac
    [ -z "$_val" ] && env_err "$_ln: empty value for '$_key' — omit the line instead (an empty env var is almost always a typo)"
    # Control characters (incl. tab) are illegal in XML 1.0 text or would
    # smuggle invisible bytes into a hook command — reject, don't escape.
    case "$_val" in
      *[[:cntrl:]]*) env_err "$_ln: value for '$_key' contains a control character (tab/escape/...) — not representable in a plist string" ;;
    esac
    if [ "$_key" = "SWARM_TICK_OBSERVE" ]; then
      # Reserved: consumed by this installer (ProgramArguments toggle), never
      # merged into the plist env dict. Duplicates fail loud like any other
      # key — a silent last-wins here could flip calibration mode to LIVE.
      [ -n "$TICK_OBSERVE_FILE" ] && env_err "$_ln: duplicate key 'SWARM_TICK_OBSERVE'"
      TICK_OBSERVE_FILE="$_val"
      continue
    fi
    case " $TICK_MERGE_KEYS " in
      *" $_key "*) env_err "$_ln: duplicate key '$_key'" ;;
    esac
    TICK_MERGE_KEYS="$TICK_MERGE_KEYS $_key"
    # XML-escape the value (& first, then < >): the value must never be able
    # to inject plist structure. Keys are identifier-safe by the check above.
    # Escaping deliberately runs in sed, NOT ${var//pat/rep}: the replacement
    # string's quoting/'&' semantics differ across bash versions (5.2's
    # patsub_replacement expands an unquoted '&' to the matched text; 3.2
    # keeps quotes literally) — both directions silently corrupt the value.
    # sed's replacement rules are identical everywhere ('\&' = literal '&').
    _val="$(printf '%s' "$_val" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
    printf '    <key>%s</key>\n    <string>%s</string>\n' "$_key" "$_val" >> "$TICK_MERGE_FILE"
  done < "$ROTATE_TICK_ENV"
fi

# Observe toggle: process env overrides the file's value; default 0 (live).
TICK_OBSERVE="${SWARM_TICK_OBSERVE:-${TICK_OBSERVE_FILE:-0}}"
case "$TICK_OBSERVE" in
  0|1) : ;;
  *) echo "swarm-launchd-install: SWARM_TICK_OBSERVE must be 0 or 1 (got '$TICK_OBSERVE')" >&2; exit 1 ;;
esac

TEMPLATE_DIR="$SWARM_HOME/launchd"
shopt -s nullglob 2>/dev/null || true
TEMPLATES=( "$TEMPLATE_DIR"/*.plist.template )
if [ "${#TEMPLATES[@]}" -eq 0 ]; then
  echo "swarm-launchd-install: no *.plist.template in $TEMPLATE_DIR" >&2
  exit 1
fi

# An env file (or observe toggle) with NO rotate-tick template to land in is
# an arming request that would silently evaporate — fail loud instead.
if { [ -n "$TICK_MERGE_KEYS" ] || [ -n "$TICK_OBSERVE_FILE" ]; } && [ ! -f "$TEMPLATE_DIR/${ROTATE_TICK_BASE}.template" ]; then
  echo "swarm-launchd-install: $ROTATE_TICK_ENV is populated but ${ROTATE_TICK_BASE}.template is missing/disabled in $TEMPLATE_DIR — the arming env has nowhere to land. Refusing." >&2
  exit 1
fi

# Collision pre-check, BEFORE anything renders: a merged key must not shadow a
# key the rotate-tick TEMPLATE owns (SWARM_HOME etc.). Checked against the
# template's own EnvironmentVariables dict (key NAMES are literal there), so a
# bad env file fails the whole run with zero files written — a partial render
# left on disk could silently overwrite a loaded agent's plist with an UNARMED
# copy.
if [ -n "$TICK_MERGE_KEYS" ] && [ -f "$TEMPLATE_DIR/${ROTATE_TICK_BASE}.template" ]; then
  _tmpl_keys="$(awk '
    /<key>EnvironmentVariables<\/key>/ { seen=1 }
    seen==1 && /<dict>/ && indict==0  { indict=1; next }
    indict==1 && /<\/dict>/           { indict=0; seen=2 }
    indict==1 && match($0, /<key>[^<]*<\/key>/) {
      s=substr($0, RSTART+5, RLENGTH-11); print s
    }
  ' "$TEMPLATE_DIR/${ROTATE_TICK_BASE}.template")"
  for _k in $TICK_MERGE_KEYS; do
    if printf '%s\n' "$_tmpl_keys" | grep -qx "$_k"; then
      echo "swarm-launchd-install: $ROTATE_TICK_ENV: key '$_k' collides with a template-owned EnvironmentVariables key — the template owns it; remove the line." >&2
      exit 1
    fi
  done
fi

# Decide output dir.
if [ -n "$RENDER_ONLY_DIR" ]; then
  OUT_DIR="$RENDER_ONLY_DIR"
  mkdir -p "$OUT_DIR" || { echo "swarm-launchd-install: cannot create $OUT_DIR" >&2; exit 1; }
else
  OUT_DIR="$HOME/Library/LaunchAgents"
  # The agents write logs here; create it now so a first launch doesn't fail.
  mkdir -p "$HOME/.config/swarm" "$OUT_DIR" || { echo "swarm-launchd-install: mkdir failed" >&2; exit 1; }
fi

# merge_rotate_tick RENDERED_PLIST — splice the operator env keys into the
# EnvironmentVariables dict and/or add --observe to ProgramArguments. Fails
# LOUD (return 1) on a key collision or if the splice provably didn't land —
# a silently-unmerged arming variable would read as "armed" while the tick
# runs unwired.
merge_rotate_tick() {
  local out="$1" k
  # Collision check against the keys the TEMPLATE rendered into the env dict
  # (detected from the rendered file, not a hardcoded list, so a future
  # template key is automatically protected).
  if [ -n "$TICK_MERGE_KEYS" ]; then
    local existing
    existing="$(awk '
      /<key>EnvironmentVariables<\/key>/ { seen=1 }
      seen==1 && /<dict>/ && indict==0  { indict=1; next }
      indict==1 && /<\/dict>/           { indict=0; seen=2 }
      indict==1 && match($0, /<key>[^<]*<\/key>/) {
        s=substr($0, RSTART+5, RLENGTH-11); print s
      }
    ' "$out")"
    for k in $TICK_MERGE_KEYS; do
      if printf '%s\n' "$existing" | grep -qx "$k"; then
        echo "swarm-launchd-install: $ROTATE_TICK_ENV: key '$k' collides with a template-owned EnvironmentVariables key — the template owns it; remove the line." >&2
        return 1
      fi
    done
  fi
  # Splice. The env-dict state machine tolerates comments inside the dict; the
  # observe arg lands directly after the tick script's <string> element.
  awk -v mergefile="${TICK_MERGE_FILE:-}" -v observe="$TICK_OBSERVE" '
    /<key>EnvironmentVariables<\/key>/ && seen==0 { seen=1 }
    seen==1 && /<dict>/ && indict==0 { indict=1; print; next }
    indict==1 && /<\/dict>/ {
      if (mergefile != "") { while ((getline l < mergefile) > 0) print l; close(mergefile) }
      indict=0; seen=2
      print; next
    }
    observe=="1" && /swarm-rotate-tick\.sh<\/string>/ {
      print
      print "    <string>--observe</string>"
      next
    }
    { print }
  ' "$out" > "$out.tmp" || { echo "swarm-launchd-install: env merge failed for $out" >&2; rm -f "$out.tmp"; return 1; }
  mv "$out.tmp" "$out" || return 1
  # Construction proof: every merged key and the observe flag must actually be
  # in the final plist (guards against a template shape the splice missed).
  for k in $TICK_MERGE_KEYS; do
    grep -q "<key>$k</key>" "$out" || {
      echo "swarm-launchd-install: env merge did not land for key '$k' in $out — refusing." >&2
      return 1
    }
  done
  if [ "$TICK_OBSERVE" = "1" ]; then
    grep -q -- '--observe' "$out" || {
      echo "swarm-launchd-install: --observe did not land in $out ProgramArguments — refusing." >&2
      return 1
    }
    echo "  observe:  $ROTATE_TICK_BASE renders with --observe (calibration mode; rotates NOTHING)"
  fi
  if [ -n "$TICK_MERGE_KEYS" ]; then
    echo "  merged:  $ROTATE_TICK_BASE +$(echo $TICK_MERGE_KEYS | wc -w | tr -d ' ') operator env key(s) from $ROTATE_TICK_ENV"
  fi
  return 0
}

render_one() {  # template_path -> renders to $OUT_DIR/<basename minus .template>
  local tmpl="$1"
  local base out work
  base="$(basename "$tmpl")"; base="${base%.template}"
  out="$OUT_DIR/$base"
  # ATOMIC INSTALL: render + merge + validate a WORK file and only mv it into
  # place after every check passes. Rendering straight into $out would replace
  # a previously installed plist with the failed copy — and gui-domain
  # LaunchAgents are auto-bootstrapped at next login, so a bad render left on
  # disk becomes a loaded agent even though THIS run refused to load it.
  work="$out.new.$$"
  # sed with '#' delimiters since the values are paths containing '/'.
  sed -e "s#@@SWARM_HOME@@#${SWARM_HOME}#g" \
      -e "s#@@HOME@@#${HOME}#g" \
      -e "s#@@TMUX_BIN@@#${TMUX_BIN}#g" \
      -e "s#@@TICK_INTERVAL@@#${TICK_INTERVAL}#g" \
      "$tmpl" > "$work" || { echo "swarm-launchd-install: render failed for $base" >&2; rm -f "$work"; return 1; }

  # Rotate-tick only: splice the operator env keys into EnvironmentVariables
  # and/or render --observe into ProgramArguments. Applied ONLY when there is
  # something to apply, so an unwired render stays byte-identical.
  if [ "$base" = "$ROTATE_TICK_BASE" ]; then
    if [ -n "$TICK_MERGE_FILE" ] && [ -s "$TICK_MERGE_FILE" ] || [ "$TICK_OBSERVE" = "1" ]; then
      merge_rotate_tick "$work" || { rm -f "$work"; return 1; }
    fi
  fi

  # Belt-and-suspenders: no placeholder may survive, and the result must be a
  # valid plist. Either failure means a malformed agent — refuse to load it,
  # and leave any previously installed plist exactly as it was.
  # Match the actual @@NAME@@ placeholder shape (not a bare '@@', so prose can
  # mention the delimiters without false-tripping).
  if grep -qE '@@[A-Za-z_][A-Za-z0-9_]*@@' "$work"; then
    echo "swarm-launchd-install: unsubstituted placeholder left in render of $base" >&2
    grep -nE '@@[A-Za-z_][A-Za-z0-9_]*@@' "$work" >&2
    rm -f "$work"
    return 1
  fi
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$work" >/dev/null || { echo "swarm-launchd-install: render of $base failed plutil -lint" >&2; rm -f "$work"; return 1; }
  fi
  mv "$work" "$out" || { echo "swarm-launchd-install: could not install $out" >&2; rm -f "$work"; return 1; }
  echo "  rendered: $out"
}

label_of() {  # basename com.qofi.swarm-watch.plist -> com.qofi.swarm-watch
  local b="$1"; b="$(basename "$b")"; echo "${b%.plist}"
}

rc=0
for tmpl in "${TEMPLATES[@]}"; do
  render_one "$tmpl" || rc=1
done
[ "$rc" -ne 0 ] && { echo "swarm-launchd-install: one or more templates failed to render — not loading." >&2; exit 1; }

if [ -n "$RENDER_ONLY_DIR" ]; then
  echo "swarm-launchd-install: render-only complete ($OUT_DIR) — launchctl skipped."
  exit 0
fi

# (Re)load each rendered agent. bootout is best-effort (it errors if the agent
# isn't currently loaded, which is fine on a first install).
DOMAIN="gui/$(id -u)"
for tmpl in "${TEMPLATES[@]}"; do
  base="$(basename "$tmpl")"; base="${base%.template}"
  out="$OUT_DIR/$base"
  label="$(label_of "$base")"
  launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  if launchctl bootstrap "$DOMAIN" "$out" 2>/dev/null; then
    echo "  loaded:   $label"
  else
    # Older macOS lacks bootstrap; fall back to load -w.
    if launchctl load -w "$out" 2>/dev/null; then
      echo "  loaded:   $label (via load -w)"
    else
      echo "swarm-launchd-install: failed to load $label — check 'launchctl print $DOMAIN/$label'" >&2
      rc=1
    fi
  fi
done

echo ""
echo "swarm-launchd-install: done. Verify with:  launchctl list | grep com.qofi"
exit "$rc"
