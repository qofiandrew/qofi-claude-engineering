---
name: watcher-control
description: Start, stop, restart, check, or tail logs of the cto-watcher — the long-lived Discord relay between the CTO channels and #cpo-cto-bus. Use when the operator says start/stop/restart the watcher, check the relay, watcher status, or watcher logs.
user-invocable: true
allowed-tools:
  - Read
  - Bash
---

# /watcher-control — the cto-watcher relay daemon

The **cto-watcher** (`cto-watcher/`) is a long-lived Node process that shuttles
Discord messages between the CTO channels and `#cpo-cto-bus`. It must run as a
**singleton** (two copies double-shuttle) under **pm2**. Token comes from the
repo `tokens.env` (`BOT_CPO_CTO_BUS`); routing from `cto-watcher/config.json`.

```sh
WATCH="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}/cto-watcher"
```

## Precheck — pm2 must be installed (run before any start)

pm2 is a global dependency. Verify, and install if missing:

```sh
command -v pm2 >/dev/null || npm install -g pm2
```

If `npm install -g pm2` fails with `EACCES`, the operator's global prefix needs
elevated perms — surface that, don't `sudo` silently.

## First-time start sequence (the canonical go-live)

```sh
command -v pm2 >/dev/null || npm install -g pm2      # 1. precheck
cd "$WATCH" && node smoke.js                          # 2. read-only verify (posts nothing) — STOP if it fails
cd "$WATCH" && pm2 start ecosystem.config.cjs          # 3. start the singleton relay
pm2 save                                              # 4. persist across reboots
pm2 logs cto-watcher --lines 30 --nostream            # 5. confirm "[ready] logged in as …"
```

If step 2 reports any BAD channel, **do not start** — fix invites/intent first.

## Command map (pm2 — the supervised path)

| Operator wants | Run | Alias |
| --- | --- | --- |
| **Status** | `pm2 describe cto-watcher` (or `pm2 list`) | `watcher-status` |
| **Start** | `cd "$WATCH" && pm2 start ecosystem.config.cjs` | `watcher-up` |
| **Stop** | `pm2 stop cto-watcher` | `watcher-down` |
| **Restart** (after config/code change) | `pm2 restart cto-watcher` | `watcher-restart` |
| **Tail logs** | `pm2 logs cto-watcher` (Ctrl-C to stop tailing) | `watcher-log` |
| **Persist across reboot** | `pm2 save` (and `pm2 startup` once, ever) | — |

> Shell aliases (`watcher-up/down/restart/status/log/smoke/disable/enable`) live
> in `bin/swarm-aliases.sh`, sourced from `~/.zshrc`. After editing that file,
> `source ~/.zshrc` to pick them up.

## Stop / disable — three levels (pick by intent)

The operator says "stop" or "disable" the watcher. They differ in whether it
comes back:

| Intent | Command(s) | Effect |
| --- | --- | --- |
| **Pause** (will restart it soon) | `pm2 stop cto-watcher` (`watcher-down`) | Stops the process; stays in pm2's list. `pm2 start cto-watcher` resumes. **Reverts on reboot** if the saved dump has it running. |
| **Disable** (off until I say otherwise, survives reboot) | `pm2 stop cto-watcher && pm2 save` (`watcher-disable`) | Stops it AND saves the stopped state, so a reboot / `pm2 resurrect` brings it back **stopped**, not running. |
| **Remove entirely** | `pm2 delete cto-watcher && pm2 save` | Drops it from pm2 altogether. Re-add later with `watcher-up`. |

Default to **Pause** (`watcher-down`) unless the operator says "disable" /
"permanently" / "don't let it come back" — then use **Disable**. While the
watcher is stopped, **no messages shuttle** in either direction (that's the
point), so confirm that's intended if a swarm conversation is active.

## If pm2 is not installed

pm2 may not be present on this machine. Check `command -v pm2`. If missing, tell
the operator to `npm i -g pm2` (a global install — their call), or run the watcher
in the **foreground** for a quick check: `cd "$WATCH" && node index.js` (Ctrl-C to
stop; not supervised, dies with the shell).

## Before (re)starting against live Discord — verify first

There's a **read-only smoke probe** that logs in, confirms the bot can see the 3
CTO channels + read/write the bus, and exits **without posting anything**:

```sh
cd "$WATCH" && node smoke.js
```

Run it after any config or permission change, or if shuttling looks broken. A
green smoke probe before `pm2 restart` catches missing intents / bad invites
without going live.

## Config & token reminders

- Routing config: `cto-watcher/config.json` (gitignored). Edit `ctoChannels` when a
  CTO is added/removed; it's validated at startup (a bad map aborts with a clear
  error — that's by design, fix it and restart).
- Token: `BOT_CPO_CTO_BUS` in the repo `tokens.env`. The watcher resolves it
  automatically; no `.env` copy needed.
- Required once in the Discord portal: **Message Content Intent** ON for the
  `cpo-cto-bus` bot, or every message body is empty and it silently shuttles
  nothing. See `cto-watcher/README.md`.

## Distinguish from the typing indicator

The watcher is **pm2**-managed. The typing indicator is a **separate** launchd job
— see the **typing-control** skill. They are unrelated processes.
