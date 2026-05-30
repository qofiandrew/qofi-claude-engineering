---
name: swarm-control
description: Start, stop, restart, update, check status of, or attach to running swarms (the per-repo Claude Code leads in tmux). Use when the operator says start/stop/bring up/take down/restart/update/cycle/reload a swarm, "what's running", swarm status, or attach to a swarm.
user-invocable: true
allowed-tools:
  - Read
  - Bash
---

# /swarm-control — swarm lifecycle

Swarms are per-repo Claude Code leads running in tmux on this machine, one per
row of `swarm.conf`. This skill maps an operator request to the exact script.

## Setup (every command)

All scripts require `SWARM_HOME` = this repo's root:

```sh
export SWARM_HOME="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
```

`<name>` is a swarm's session name from `swarm.conf` (e.g. `reserve-backend-2`,
`qofi-ios-app`, `press-backend`, `qofi-product`). Run `cat "$SWARM_HOME/swarm.conf"`
if you need the current list.

## Command map

| Operator wants | Run |
| --- | --- |
| **Status** / what's running | `"$SWARM_HOME/bin/swarm-up.sh" status` |
| **Start all** not-yet-running | `"$SWARM_HOME/bin/swarm-up.sh" up` |
| **Start one** | `"$SWARM_HOME/bin/swarm-up.sh" up <name>` |
| **Stop all** | `"$SWARM_HOME/bin/swarm-up.sh" down` |
| **Stop one** | `"$SWARM_HOME/bin/swarm-up.sh" down <name>` |
| **Restart one** (reload session from disk, no template sync) | `"$SWARM_HOME/bin/swarm-restart.sh" <name>` |
| **Update one** (sync latest templates → disk, then restart) | `"$SWARM_HOME/bin/swarm-update.sh" <name>` |
| **Update all** | `"$SWARM_HOME/bin/swarm-update.sh" --all` |
| **Sync doctrine only** (write templates to disk, NO restart) | `"$SWARM_HOME/bin/swarm-sync.sh" [<name>]` |
| **Dry-run drift report** | `"$SWARM_HOME/bin/swarm-sync.sh" [<name>] --check` |
| **Attach** a terminal to watch/interact live | `"$SWARM_HOME/bin/swarm-up.sh" attach <name>` (Ctrl-b d detaches) |

## Safety rails — surface, don't override

- **restart / update refuse a BUSY swarm.** Both check the liveness signal; if the
  swarm produced a transcript write within `SWARM_STALE_SECONDS` (default 300s) it
  is WORKING, and the command refuses to avoid losing uncommitted in-process
  teammate work. If you hit this, **report it to the operator** with the swarm name
  — do not blindly add `--force`. Only pass `--force` when the operator explicitly
  says to restart the busy swarm anyway.
- **sync refuses a dirty working tree** in the target repo (won't stash or commit
  over). Report the dirty repo; pass `--force` only on explicit operator say-so.
- **`--all` update is resilient, not atomic** — it continues past a failed swarm
  and exits non-zero if any failed. Read the per-swarm summary it prints and relay
  which ones failed and why.

## Distinctions to keep straight

- **restart** = reload the live session from the current on-disk state. Use after
  the operator edited the repo and wants the lead to pick it up.
- **update** = `sync` (pull latest templates into the repo) **then** restart. Use
  to push new doctrine/hooks/gate changes into a running swarm. (SYNC alone does
  not affect the running lead — it holds the old doctrine in memory until cycled;
  that's why update bundles the restart.)
- To create a brand-new swarm, that's the **swarm-new** skill, not this one.

Run any script with no args / a bad arg to see its own usage; the header comment
of each `bin/swarm-*.sh` is the authoritative reference.
