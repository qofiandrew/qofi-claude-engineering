#!/usr/bin/env python3
# swarm-status-emit.py — emit ONE SwarmStatus JSON object (one line) to stdout
# per the frozen swarm-status/v1 contract.
#
# Source of truth for the wire shape lives in the iOS-widget repo at
# docs/contracts/swarm-status-v1.md (frozen 2026-05-23). This helper exists so
# the per-swarm emit logic is unit-testable in isolation against the §8 schema
# examples — the same logic embedded in a swarm-watch.sh heredoc could not be
# exercised without standing up the whole watcher.
#
# Args (positional, all strings; empty string == "no value"):
#   1 name
#   2 channel       Discord channel snowflake (string)
#   3 guild_id      Discord guild snowflake (string) or "" for null
#                   (receiver tolerates null/absent during the transition
#                   window; goal is populated)
#   4 state         enum: working|ready|starting|stalled|silent|paused-limit|down
#   5 age           seconds since transcript last changed, or "" for null
#   6 reset         limit reset hint string, or "" for null
#   7 cto_reason    CTO open-escalation reason, or "" for no flag
#
# Stdout: one JSON object + newline. Stderr/exit nonzero on malformed input.

import json
import sys

WATCHER_ATTENTION_STATES = ("stalled", "silent", "paused-limit")
COMPOUND_SEP = " · "


def watcher_reason_for(state, reset):
    """Watcher's contribution to attention_reason. None when state is not in
    the watcher-attention set — `down` is intentionally NOT in the set
    (schema §5 + example 8.5: down alone is needs_attention=false)."""
    if state == "paused-limit":
        if reset:
            return "paused on usage limit (resets " + reset + ")"
        return "paused on usage limit"
    if state in ("stalled", "silent"):
        return state
    return None


def build(name, channel, guild_id, state, age, reset, cto_reason):
    out = {
        "name": name,
        "channel": channel,
        "guild_id": guild_id if guild_id else None,
        "state": state,
        "last_activity_age_seconds": int(age) if age else None,
        "limit_reset_hint": reset if reset else None,
    }

    has_cto = bool(cto_reason)
    watcher_reason = watcher_reason_for(state, reset)
    has_watcher = watcher_reason is not None

    if has_cto and has_watcher:
        # Schema §5: compound case. source=cto (CTO precedence),
        # reason = watcher_reason + " · " + cto_reason.
        reason = watcher_reason + COMPOUND_SEP + cto_reason
        source = "cto"
        needs = True
    elif has_cto:
        # CTO-only (covers e.g. state=ready or state=down with flag raised —
        # schema examples 8.3 and 8.6).
        reason = cto_reason
        source = "cto"
        needs = True
    elif has_watcher:
        reason = watcher_reason
        source = "watcher"
        needs = True
    else:
        reason = None
        source = None
        needs = False

    # Defensive single-line guard. Schema §3 + §6: attention_reason MUST NOT
    # contain embedded newlines. The watcher-side strings above never do; the
    # CTO reason is already control-char stripped by the caller. This belt-
    # and-suspenders flattening makes the contract guarantee local to the
    # emitter and survives future changes upstream.
    if reason is not None:
        reason = reason.replace("\r", " ").replace("\n", " ")

    out["needs_attention"] = needs
    out["attention_source"] = source
    out["attention_reason"] = reason
    return out


def main():
    if len(sys.argv) != 8:
        sys.stderr.write(
            "swarm-status-emit: expected 7 args "
            "(name channel guild_id state age reset cto_reason), got "
            + str(len(sys.argv) - 1) + "\n"
        )
        sys.exit(2)
    name, channel, guild_id, state, age, reset, cto_reason = sys.argv[1:8]
    obj = build(name, channel, guild_id, state, age, reset, cto_reason)
    sys.stdout.write(json.dumps(obj) + "\n")


if __name__ == "__main__":
    main()
