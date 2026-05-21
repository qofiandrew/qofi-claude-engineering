# ADR-0007 — Monorepo with the bridge as a `bridge/` subcomponent

**Status:** accepted
**Date:** 2026-05-21
**Reversibility:** one-way (within reason) — the structure shapes every install,
script path, and consumer reference from here on
**Escalated:** yes (blocking) — confirmed by the operator before any file moved

---

## Context

The repository contained two pieces developed separately:

1. A working Claude Code plugin (the `discord-b2b` Discord bridge) sitting at the
   repo root — `.claude-plugin/`, `.mcp.json`, `package.json`, `server.ts`,
   `skills/`, etc. — installed via the README's directory-scan marketplace flow.
2. A `claude-swarm/` subdirectory containing the orchestration system that
   *uses* that bridge — host scripts, templates, governance docs, ADRs, dogfood
   gates — entirely untracked at the time of consolidation.

Per [ADR-0002](./ADR-0002-discord-over-slack.md) and `docs/ARCHITECTURE.md`, the
bridge is the swarm's transport layer — a component of the swarm system, not a
peer to it. The repo name (`qofi-claude-engineering`) names the whole system, not
the bridge. The two halves needed to be organized into one coherent project
without breaking the working plugin.

The reorganization was treated as a one-way door: every install command, every
`$SWARM_HOME` reference, every doc cross-link and external consumer would key off
whatever layout was chosen. Choosing wrong meant churning through all of those
again.

## Decision

We will adopt a swarm-at-root layout with the bridge as a self-contained
`bridge/` subcomponent:

- The swarm system **is** the repo root (`bin/`, `templates/`, `docs/`,
  `.claude/`, `CLAUDE.md`, `ESCALATION.md`, `PROJECT_SPEC.md`, the example
  config files, the new top-level `README.md`). `$SWARM_HOME` points at the repo
  root.
- `bridge/` holds the plugin intact — `.claude-plugin/plugin.json`, `.mcp.json`,
  `package.json`, `server.ts`, `skills/`, `README.md`, `ACCESS.md`, `LICENSE` —
  grouped under a single directory so it remains a valid Claude Code plugin
  directory.
- Install switches from the directory-scan marketplace flow to **registering
  `bridge/` directly as a single-plugin marketplace** —
  `/plugin marketplace add <repo>/bridge` then
  `/plugin install discord-b2b@bridge`.

We will **not** introduce a `.claude-plugin/marketplace.json` manifest file at
the repo root. The bridge stays installable as a self-contained directory; no
new manifest schema is committed to.

## Reversibility & cost of change

One-way in practice. Reversing the move means another full pass through every
reference that just changed (the install instructions in `bridge/README.md`, the
on-disk-layout block in `docs/ARCHITECTURE.md`, the new top-level `README.md`,
this ADR's neighbors, and any external consumer that scripted against the new
layout). The git history for the bridge files is preserved across the move via
`git mv`, so a revert is mechanically clean — but every consumer doc would need
re-rewriting.

The decision deliberately avoids a separately-irreversible move: writing a
`.claude-plugin/marketplace.json` manifest would have committed the repo to a
schema we cannot verify without loading it in Claude Code, with no easy way to
prove later that we got it right. Registering `bridge/` directly as a marketplace
was verifiable by running a single slash command and reverting on failure.

## Verification

Both runtime gates were verified live on 2026-05-21 against the committed monorepo
(commit `3266f09`):

- `bun` boots the MCP server clean from `bridge/` (the plugin's
  `${CLAUDE_PLUGIN_ROOT}`-rooted `start` script resolves correctly at the new
  path).
- The A2 install path —
  `/plugin marketplace add <repo>/bridge` followed by
  `/plugin install discord-b2b@bridge` — loads the plugin, and
  `claude --channels plugin:discord-b2b` attaches as expected.

A3 (revert the bridge to repo root and nest the swarm under `swarm/` instead)
was not invoked. It remains documented in *Alternatives considered* below as the
zero-risk fallback if a future regression breaks A2.

## Consequences

Easier:
- The repo's identity matches the system: `qofi-claude-engineering` = the swarm
  system, with its Discord bridge living inside it.
- The operating contract (`CLAUDE.md`, `ESCALATION.md`, `PROJECT_SPEC.md`) loads
  from repo root with no `claude-swarm/` indirection.
- `$SWARM_HOME` = repo root is the natural identity; users who clone to
  `~/claude-swarm` get the documented default for free.
- The bridge stays a self-contained Bun project under `bridge/`; future bridge
  work doesn't touch swarm files and vice versa.
- The structural recursion described in `docs/ARCHITECTURE.md` (`templates/`
  deploys the same operating contract the repo root governs itself by) becomes
  cleaner because the contract lives at the root, not a directory deep.

Harder:
- The plugin's install command changed (`/plugin marketplace add ~/claude-plugins`
  → `/plugin marketplace add <repo>/bridge`). Anyone with the old install
  instructions cached will need to reinstall.
- The bridge no longer sits at a path independent of the swarm system — a
  consumer who only wanted the bridge would still clone the whole repo. This is
  acceptable because the bridge is already swarm-specific (the `bot-to-bot`
  messaging tweak exists *for* multi-agent orchestration).
- Anyone relying on the bridge's GitHub URL identity (`dsieczko/claude-discord-bot-to-bot`)
  is now consuming it as a subdirectory of a larger system repo.

## Alternatives considered

- **Two peer top-level directories (`swarm/` and `bridge/`)** — rejected: the
  architecture and ADR-0002 already frame the bridge as a *component of* the
  swarm, not a peer. A peer layout would understate the hierarchy and require
  `$SWARM_HOME` to point at a subdirectory.
- **Keep the bridge at the repo root and nest the swarm under `swarm/`
  (A3 fallback)** — rejected as the primary choice: it would invert the
  hierarchy (the smaller component framing the larger system) and leave the
  swarm's operating contract a directory deep. Held as the zero-risk fallback
  during A2 verification; with A2 verified live (see *Verification* above), A3
  remains documented as the fallback if a future regression breaks A2.
- **Add a `.claude-plugin/marketplace.json` manifest at repo root pointing at
  `bridge/` (A1)** — rejected: commits us to a manifest schema we cannot verify
  from the repo contents alone. A2 keeps the bridge installable by exactly the
  same mechanism it always was (a directory that is a plugin), just registered
  via its new path.
- **Leave the bridge at root, leave `claude-swarm/` untracked indefinitely** —
  rejected: untracked state is not a layout, and the two halves need to be one
  coherent project for the swarm to actually depend on the bridge cleanly.
