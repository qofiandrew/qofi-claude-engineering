---
name: swarm-new
description: Stand up a brand-new swarm — create the repo + GitHub remote, walk the Discord bot creation, register it in swarm.conf, and stamp doctrine. Also covers onboarding an existing codebase. Use when the operator says create/add/spin up a new swarm, add a CTO/product, or onboard a repo.
user-invocable: true
allowed-tools:
  - Read
  - Bash
---

# /swarm-new — stand up a new swarm

## Setup

```sh
export SWARM_HOME="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
```

## Pick the right entry point

| Situation | Command |
| --- | --- |
| **Greenfield** — new product, no repo yet | `"$SWARM_HOME/bin/swarm-new.sh" <name> [--public] [--type <archetype>]` |
| **Existing repo**, need the Discord/standup half only | `"$SWARM_HOME/bin/swarm-add.sh" <name> <repo_path> [<channel_id>] [flags]` |
| **Existing real codebase** — inject doctrine only, don't register a Discord swarm | `"$SWARM_HOME/bin/swarm-onboard.sh" <repo_path> [--force-*]` |

`--type` archetypes: `engineering-cto` (default), `cpo`, `company-brain`.

- `swarm-new` owns the GitHub half (fresh local repo at `~/qofirepos/<name>`,
  creates the GitHub repo, sets `origin`, first push) then **execs `swarm-add`** for
  the rest.
- `swarm-add` owns the Discord standup: bot-app creation walkthrough, the
  **Message Content Intent** toggle, OAuth invite, channel-ID capture, silent token
  paste, the `swarm.conf` row, `swarm-init` stamping, and `access.json`.

## ⚠️ These are INTERACTIVE operator flows

`swarm-new` / `swarm-add` walk through **manual Discord Developer Portal steps**
(the portal has no API for app creation) and do a **silent token paste**
(`read -s` — never echoed). I cannot complete those prompts for the operator.

So, when asked to create a new swarm:
1. Confirm the `<name>`, archetype (`--type`), and public/private with the operator.
2. Tell the operator to run it **interactively in their own terminal** (suggest the
   `! <command>` prefix so the output lands in this session), e.g.
   `! "$SWARM_HOME/bin/swarm-new.sh" acme --type engineering-cto`.
3. I can do the non-interactive, scriptable parts and verification around it (read
   `swarm.conf`, confirm the row landed, run `swarm-up.sh status`), but the bot
   creation + token paste are the operator's hands.

## After it's registered

- New bot token must be in `tokens.env` (swarm-add handles the paste; or
  `"$SWARM_HOME/bin/swarm-provision-tokens.sh"` to (re)provision this machine's
  tokens from the password manager).
- Start it: `"$SWARM_HOME/bin/swarm-up.sh" up <name>` (see the **swarm-control** skill).
- If this new swarm is a CTO that the CPO must reach, add it to the watcher's
  `cto-watcher/config.json` `ctoChannels` map (channel id + bot user id) and restart
  the watcher (the **watcher-control** skill), and add its name to the CPO's
  `CPO_BUS_PROTOCOL.md` CTO list.

Each script's header comment is the authoritative reference for its flags.
