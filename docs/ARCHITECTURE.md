# Architecture

`claude-swarm` runs Claude Code as an autonomous engineering org. It is five
layers, but the load-bearing idea is simple: **only two kinds of traffic ever
leave a repo** — directives coming down to the CTO, and escalations or approvals
going up to the operator. Everything else (teammate coordination, file edits, test
runs, integration) stays inside that repo on the host. That confinement is what
keeps several products legible from a phone.

## The five layers

1. **Control plane — you, on your phone.** One Discord channel per product. You
   send vision and directives; you receive batched escalations, blocking
   questions, and tool-permission prompts.
2. **Bridge — the `discord-b2b` plugin.** Relays chat text both ways into a
   persistent Claude Code session. One bot identity per repo so channels stay
   distinct. The permission-reply intercept (`yes abcde` / `no abcde`) lets you
   approve tool prompts remotely.
3. **Host — a Mac mini running tmux.** One persistent session per repo, brought up
   and supervised by `swarm-up.sh`. In-process teammate mode (no tmux split-pane
   dependency for the agents themselves).
4. **Orchestration — one Agent Teams team per repo.** A **lead (the CTO)** holds
   the spec and the channel; **teammates** (3–5, elastic) are spawned for parallel
   phases and torn down after. They coordinate through the native shared task list
   and mailbox, and deconflict by **file ownership** on a shared working tree
   (ADR-0003) — not by per-teammate branches.
5. **Guardrails + memory.** A plan-approval gate (one-way doors escalate instead of
   proceeding), two deterministic hooks (test gate, docs check), and a CI + review
   gate before merge. Memory is the repo's `PROJECT_SPEC.md`, the ADRs, and the
   build log — which is what lets a resumed lead pick up where it left off.

## Lifecycle of a single directive

1. You message a channel; it lands on that repo's CTO lead.
2. You hold the **design conversation**. Docs need not exist yet.
3. You say **"go build."** The CTO's first act is to **author** `PROJECT_SPEC.md`
   and the one-way-door ADRs from the conversation, then **confirm** the summary
   with you. No teammate spawns until you sign off.
4. The CTO **decomposes** into file-ownership-disjoint tasks with declared
   dependencies, and **spawns** 3–5 teammates for the parallel slices.
5. Each teammate **plans first.** Tasks brushing a one-way door are escalated to
   you rather than approved; two-way doors proceed.
6. Teammates **build** in the shared tree, each owning its files. The
   `TaskCompleted` hook blocks any task closing on red tests; the `TeammateIdle`
   hook blocks idle when source changed but docs didn't.
7. The CTO **integrates** in dependency order, **reconciles** docs against the real
   implementation, runs CI plus a reviewer pass, and reports the milestone.
8. Blocking items wait for you; non-blocking ones move on a stated default.
   Permission prompts surface in the channel and you approve from your phone.

## On-disk layout

```
<repo>/                     # the swarm system IS the repo root
  README.md                 # whole-system overview (swarm + bridge)
  CLAUDE.md                 # operating manual governing CC building THE SYSTEM
  ESCALATION.md             # escalation policy (applies here too)
  PROJECT_SPEC.md           # the system's own spec — what CC builds against
  swarm.conf.example        # repo → session → token map
  tokens.env.example        # per-repo Discord bot tokens (keep out of git)
  bin/
    swarm-init.sh           # stamp the payload into a product repo
    swarm-up.sh             # launch + supervise one CTO lead per repo
  templates/                # PAYLOAD — copied into product repos by swarm-init
    CLAUDE.md  ESCALATION.md  TEAM_LEAD.md
    PROJECT_SPEC.template.md  ADR.template.md  settings.example.json
    hooks/test-gate.sh  hooks/docs-check.sh
  docs/
    ARCHITECTURE.md         # this file
    TEAM_LEAD.md            # CTO brief — fed to a launched lead session
    adr/                    # the system's own one-way-door decisions
  .claude/                  # dogfood: the system repo runs under the same gates
    settings.json  test-cmd  hooks/{test-gate.sh,docs-check.sh}
  bridge/                   # SUBCOMPONENT — the discord-b2b Claude Code plugin
    .claude-plugin/plugin.json
    .mcp.json  package.json  server.ts
    skills/  README.md  ACCESS.md  LICENSE
```

The recursion is deliberate: `templates/` is what the system *deploys*; the repo
root is the system *governing its own construction*. To build the system the same
way it builds products, you can even run `bin/swarm-init.sh .` on this repo.

`bridge/` is the Discord control-plane plugin (ADR-0002) and the repo's only Bun
project. It is a self-contained Claude Code plugin directory — `.claude-plugin/`,
`.mcp.json`, `package.json`, and `server.ts` are all grouped under it — so it
installs directly via `/plugin marketplace add <repo>/bridge` (see ADR-0007).

## Capacity model — the real constraint

The whole thing rides one Claude Max pool, shared across your chat and code usage.
The architecture scales to N repos cleanly on paper, but the subscription caps live
concurrency at roughly one or two teams (ADR-0004). Prove the loop on one repo,
watch `/cost`, and let that number decide whether a second team is viable on Max or
wants metered API.
