---
name: typing-control
description: Start, stop, or check the swarm typing indicator — the always-on launchd job that keeps the Discord "typing…" bubble alive while swarms work. Use when the operator says start/stop the typing indicator, the typing bubble, or asks whether it's running.
user-invocable: true
allowed-tools:
  - Read
  - Bash
---

# /typing-control — the typing-indicator daemon

**Yes, it's a constant process.** `bin/swarm-typing.sh` runs under **launchd**
with `KeepAlive=true` and loops every ~8s forever, keeping the Discord "typing…"
bubble alive so the operator can see a swarm is active. launchd relaunches it if
it exits. Label: **`com.qofi.swarm-typing`**; rendered plist lives at
`~/Library/LaunchAgents/com.qofi.swarm-typing.plist`.

```sh
export SWARM_HOME="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
DOMAIN="gui/$(id -u)"
LABEL="com.qofi.swarm-typing"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
```

## Command map

| Operator wants | Run |
| --- | --- |
| **Status** (loaded?) | `launchctl list \| grep com.qofi`  → also `launchctl print "$DOMAIN/$LABEL"` for detail |
| **Start / load** (install + load, idempotent) | `"$SWARM_HOME/bin/swarm-launchd-install.sh"` |
| **Start** (already rendered) | `launchctl bootstrap "$DOMAIN" "$PLIST"` |
| **Stop / unload** | `launchctl bootout "$DOMAIN/$LABEL"` |
| **Restart** (kick) | `launchctl kickstart -k "$DOMAIN/$LABEL"` |
| **Tail logs** | check the plist's `StandardOutPath`/`StandardErrorPath` (`launchctl print "$DOMAIN/$LABEL"` shows them), then `tail -f <that path>` |

## Notes

- **Preferred start/reload is `swarm-launchd-install.sh`** — it renders the plist
  template for this machine (launchd needs absolute literal paths, no `$VARS`) and
  does a `bootout` + `bootstrap`. Use it after any edit to the typing script or the
  plist template, or after a `SWARM_HOME` move. Older macOS without `bootstrap`
  falls back to `launchctl load -w` automatically.
- **Stopping** with `bootout` unloads it until the next load/login; KeepAlive will
  NOT relaunch a booted-out job (that's the correct way to stop it). Do not just
  `kill` the process — launchd's KeepAlive would immediately relaunch it.
- There is a sibling **swarm-watch** launchd job, currently shipped **disabled**
  (`launchd/com.qofi.swarm-watch.plist.template.disabled`). It is not the typing
  indicator; don't load it unless the operator asks.
- This is unrelated to the **cto-watcher** (pm2) — see the **watcher-control** skill.
