# qofi-claude-engineering

Run Claude Code as an autonomous engineering org. You hold a product-design
conversation over Discord, say "go build," and a CTO agent turns the vision into
docs, coordinates a team that builds end-to-end, and pings you only for the
decisions that genuinely need a human. One Mac mini, one Claude Max subscription.

> **Status:** consolidated and ready for CC to build out v1. Start at
> [`PROJECT_SPEC.md`](./PROJECT_SPEC.md) and [`docs/adr/`](./docs/adr/) — the spec
> and the one-way-door decisions this system is built against.
> [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) is the full map.

## Two halves of the repo

This repo is the **swarm system** plus its **Discord bridge** as a subcomponent.

| Where | What | Read |
| --- | --- | --- |
| `./` (root) | The swarm orchestration system — payload templates, host scripts, governance docs, ADRs, the dogfooded gates. `$SWARM_HOME` points here. | [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md), [`PROJECT_SPEC.md`](./PROJECT_SPEC.md), [`CLAUDE.md`](./CLAUDE.md), [`ESCALATION.md`](./ESCALATION.md), [`docs/TEAM_LEAD.md`](./docs/TEAM_LEAD.md) |
| `./bridge/` | The `discord-b2b` Claude Code plugin — the chat transport / control plane the swarm uses. Self-contained Bun project. | [`bridge/README.md`](./bridge/README.md), [ADR-0002](./docs/adr/ADR-0002-discord-over-slack.md), [ADR-0007](./docs/adr/ADR-0007-monorepo-bridge-as-subcomponent.md) |

## How it works (90 seconds)

Five layers: your phone → the Discord bridge (`bridge/`) → a Mac mini running
tmux → one Agent Teams team per repo (a CTO lead + elastic teammates) →
guardrails and memory. Only two kinds of traffic leave a repo: directives down
to the CTO, escalations and approvals up to you. Everything else stays on the
host. See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

## Prerequisites

- macOS (Mac mini), `tmux`, and Claude Code **v2.1.32+**.
- A Claude **Max** login in Claude Code (`/status` should show the subscription,
  not an API key). Do not export `ANTHROPIC_API_KEY` in the launching shell.
- The Discord bridge installed from this repo (see `bridge/README.md`), with its
  `bun` runtime.
- Optional: `jq` (lets `swarm-init` merge into an existing `settings.json`).
- Agent Teams enabled — `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (the bundled
  `templates/settings.example.json` sets it).

## Setup

```sh
# 1. Clone this repo as the swarm root and point SWARM_HOME at it.
git clone <repo-url> ~/claude-swarm
export SWARM_HOME=~/claude-swarm

# 2. Install the Discord bridge (one-time, from inside a Claude Code session):
#    /plugin marketplace add ~/claude-swarm/bridge
#    /plugin install discord-b2b@bridge
#    See bridge/README.md for Discord bot setup + per-agent tokens.

# 3. Fill the host config (keep tokens out of git — see .gitignore).
cp swarm.conf.example  swarm.conf
cp tokens.env.example  tokens.env && chmod 600 tokens.env
#   edit both: one repo per swarm.conf line, one bot token per tokens.env entry

# 4. Stamp the payload into a product repo (idempotent; never clobbers a real spec).
bin/swarm-init.sh /path/to/your/product-repo

# 5. Bring up the CTO leads and supervise them.
bin/swarm-up.sh up        # start
bin/swarm-up.sh status    # list
bin/swarm-up.sh watch     # foreground supervisor: relaunch dead leads
bin/swarm-up.sh down      # stop all
```

## Adding swarms

To stand up a new swarm end-to-end, run `bin/swarm-add.sh <name> <repo>` and
follow the prompts — it walks you through Discord bot setup (portal, intents,
OAuth, invite, token) and ends with a verification checklist. For bringing the
swarm operating system into a pre-existing real codebase that isn't greenfield,
run `bin/swarm-onboard.sh <repo>` instead — it stamps doctrine + enforcement
with refuse-and-report collision handling and leaves swarm registration to
`swarm-add`.

## Using it

DM a product's Discord channel and spec with its CTO. When you're ready, say **"go
build."** The CTO writes `PROJECT_SPEC.md` and the one-way-door ADRs from your
conversation, confirms the summary with you, then decomposes and spawns the team.
It keeps docs reconciled with the implementation, gates every task on tests, and
pings you for one-way doors, v1/v2 scope, and any major spec decision. Approve tool
prompts from your phone with the `yes/no` reply intercept.

## The one real limit

Everything rides one Max pool, shared across your chat and code usage. Plan for
**1–2 concurrent teams**; 5–7 × 24/7 is API-scale ([ADR-0004](./docs/adr/ADR-0004-max-capacity-ceiling.md)).
Prove the loop on one repo, watch `/cost`, and let that number decide whether a
second team fits Max or wants metered API.

## For CC building this out

Read `PROJECT_SPEC.md` (esp. §3 scope and §4 acceptance) and every ADR before
touching code. Operate per `CLAUDE.md` and `ESCALATION.md`. v1 is the templates,
the two scripts, the bridge integration, the gates, and the CTO-authoring flow;
the deferred items (heartbeat health monitor, second team, headless SDK migration)
are v2 — don't pre-build them. To build the system the way it builds products,
you can run `bin/swarm-init.sh .` on this repo.

The bridge (`bridge/`) is treated as a stable subcomponent — changes there are
plugin work, not swarm work, and ship with their own README and skills.
