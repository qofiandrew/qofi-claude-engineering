# Shakedown — first end-to-end run

> The first time the system is exercised as a whole, not part by part. Everything
> shipped so far proves the pieces are correctly *assembled*; this proves a
> directive actually *flows*. Run it on a throwaway repo. When every gate below
> passes, you may check `PROJECT_SPEC.md §4`'s end-to-end criterion — and not before.
>
> Each step states what to do and the **PASS** condition. If a step fails, stop and
> note which one — the failures are diagnostic (they tell you which layer broke).

## 0. Pick an engine and throwaway target

Run this shakedown once per engine you intend to operate. Set `ENGINE=claude` or
`ENGINE=codex`; do not infer Codex health from a successful Claude run.

Make an empty git repo you don't care about, e.g. `~/code/shakedown-todo`, with a
trivial real test command available (a `package.json` with a `test` script, or
`pytest` + a `tests/` dir). It must be a real git repo (`git init`) — the docs hook
checks `git status`.

- **PASS:** `cd <target> && git rev-parse --is-inside-work-tree` prints `true`.

For `ENGINE=codex`, prepare the dedicated runtime before registration. On the
first Codex host, run the full bootstrap:

```sh
if [ ! -e "$HOME/.codex" ]; then (umask 077; mkdir "$HOME/.codex"); fi
[ ! -L "$HOME/.codex" ] || { echo "refusing symlinked ~/.codex" >&2; exit 1; }
chmod -N "$HOME/.codex" 2>/dev/null || true
chmod 700 "$HOME/.codex"
$SWARM_HOME/bin/swarm-codex-runtime.sh install --repo "$HOME/code/shakedown-todo"
$SWARM_HOME/bin/swarm-codex-runtime.sh login
# Log out/in and restart tmux after the first install, then:
$SWARM_HOME/bin/swarm-codex-runtime.sh verify --repo "$HOME/code/shakedown-todo"
```

When the attested runtime/login already exists but this throwaway repo is new,
do not jump straight to `verify`; register its authority first (or let the
later `swarm-add` do these two steps transactionally):

```sh
$SWARM_HOME/bin/swarm-codex-runtime.sh prepare-workspace --repo "$HOME/code/shakedown-todo"
$SWARM_HOME/bin/swarm-codex-runtime.sh verify --repo "$HOME/code/shakedown-todo"
```

- **PASS (Codex):** verification proves the hidden service UID and exact
  ChatGPT subscription auth. Current-user `codex login status` is not accepted
  as a substitute. `bin/swarm-codex-manager.sh ready` also reports the installed
  root-attested global App Server manager ready.

## 1. Bootstrap the repo

```sh
export SWARM_HOME=/absolute/path/to/qofi-claude-engineering
$SWARM_HOME/bin/swarm-init.sh ~/code/shakedown-todo --engine "$ENGINE"
```

- **PASS:** stdout lists CLAUDE.md, AGENTS.md, ESCALATION.md, TEAM_LEAD.md, PROJECT_SPEC.md,
  docs/adr/ADR.template.md, .claude/hooks/{test-gate,docs-check}.sh,
  .claude/settings.json and `.claude/test-cmd`; with `ENGINE=codex` it also
  stamps the adopted `.codex` policy and `.agents/skills` surfaces. The closing line describes the
  design-conversation → "go build" → CTO-authoring flow (the reconciled message,
  not the old "run the spec phase" one).
- **PASS:** `.claude/test-cmd` contains your target's real test command (edit it now
  if the placeholder `npm test --silent` is wrong for this repo).
- **CHECK:** open `.claude/settings.json` — `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`
  is `"1"` and both hooks are wired.

## 2. Launch one CTO lead

Use the supported onboarding path so the engine-aware row and ACL cannot drift
(Codex writes field 7; historical Claude rows may retain the five-field shape):

```sh
$SWARM_HOME/bin/swarm-add.sh shakedown ~/code/shakedown-todo --engine "$ENGINE"
$SWARM_HOME/bin/swarm-up.sh up shakedown
$SWARM_HOME/bin/swarm-up.sh status
```

- **PASS:** `status` shows one `swarm-<name>` session.
- **PASS (subscription guard):** Claude: attach and run `/status`; it shows Max,
  not an API key. Codex: launch preflight prints a ChatGPT subscription login and
  `$SWARM_HOME/bin/swarm-view.sh shakedown` shows a fresh runtime. Before the
  first accepted channel message there is no persisted thread to resume, so the
  explicitly labeled `FALLBACK EVENT/STATUS VIEW` is expected at this point.
  API-key environments must cause launch to fail before a model turn.
- **PASS:** in the repo's Discord channel, the bot is online.

## 3. The design conversation (no build yet)

In the Discord channel, spec something tiny on purpose — e.g. "a CLI to-do app:
add, list, complete, persist to a JSON file. v1 only." Have a short back-and-forth.

- **PASS:** the CTO engages and asks clarifying questions but does **NOT** start
  writing code or spawning teammates. (If it starts building during the
  conversation, the handoff prompt didn't land — check `swarm-up.sh`'s send-keys
  brief.)
- **PASS (Codex native view):** after the first reply has persisted the configured
  channel's thread, rerun `$SWARM_HOME/bin/swarm-view.sh shakedown`. It prints
  `NATIVE CODEX TUI` and renders that conversation through the read-only
  per-swarm facade. The tmux client accepts no input; lifecycle and Discord
  remain the only control paths.

## 4. "go build" → author + confirm

Send: **go build**.

- **PASS:** the CTO's first action is to author `PROJECT_SPEC.md` and at least one
  ADR from the conversation, then post a summary back to the channel and **wait for
  your confirmation** — before any teammate spawns.
- **PASS:** `cat ~/code/shakedown-todo/PROJECT_SPEC.md` shows real content (scope,
  acceptance), not the template placeholders.
- Reply with a small correction ("also support a `--due` date") and confirm it
  **revises and re-confirms** rather than ignoring it.

## 5. Build + the file-ownership rule

Approve the spec. Let it decompose and spawn.

- **PASS:** the lead decomposes with disjoint ownership. Claude should spawn its
  Agent Teams teammates. Codex must use only team/subagent capabilities actually
  present in its installed CLI; serial execution is valid and false claims are not.
- **PASS:** Claude tool-permission prompts surface in Discord. Codex has no
  permission relay: its fixed custom permission profile, read-only capability
  boundaries, and disabled MCP/plugins/network reject forbidden actions and
  return failure without waiting for an invisible prompt. Unattended turns
  intentionally ignore project exec-policy rules.

## 6. The gate bites — the deliberately-broken test

This is the point of the whole run. While a teammate is working (or right after a
task lands), plant a failure and confirm completion is blocked.

```sh
cd ~/code/shakedown-todo
# add a test that cannot pass:
mkdir -p tests
printf 'test("intentional shakedown failure", () => { expect(true).toBe(false); });\n' > tests/_shakedown_fail.test.js
# (python: echo "def test_shakedown_fail(): assert False" > tests/test_shakedown_fail.py)
```

Now tell the CTO (or the teammate) to mark its current task complete.

- **PASS (Claude):** the existing TaskCompleted hook rejects completion.
- **PASS (Codex):** the agent runs `.claude/test-cmd` directly, reports the red
  command/result as incomplete, and fixes or escalates; CI remains red. The
  unattended Codex lane deliberately has no repo command-hook/Stop adapter,
  because those commands execute outside its tool sandbox.
- **FAIL looks like:** Claude closes the task, or Codex claims green/done without
  the direct command evidence. Check `.claude/settings.json` for Claude and the
  immutable bridge preamble/`AGENTS.md` route for Codex, then inspect
  `.claude/test-cmd` and CI.

Then remove the planted test so the run can proceed:

```sh
rm tests/_shakedown_fail.test.js   # (or the python one)
```

## 7. The docs floor bites

Have a teammate make a source-only change and try to go idle without touching docs.

- **PASS:** Claude's `TeammateIdle` hook blocks idle with the "you changed source
  but updated no docs" message. Codex has no renamed equivalent event: after a
  successful turn, have the allowlisted operator issue the exact Git-broker
  commit control. Trusted broker policy must reject a source-only commit until a
  non-deleted docs/build-log change is part of that latest-turn delta; it never
  executes the mutable repository hook.

## 8. Escalation reaches your phone

During the build, trigger a one-way door — e.g. ask for something that implies a
schema/persistence-format change, or just ask "should this persist to JSON or
SQLite?"

- **PASS:** the CTO does **not** decide it silently — it sends an escalation to
  Discord in the `ESCALATION.md` format (Decision / Options / Recommendation /
  Reversibility / Default), and waits (blocking) or proceeds on a stated default
  (non-blocking) per the policy.

## 9. Milestone + reconciliation

Let it finish the tiny v1.

- **PASS:** it reports a milestone with a reviewer pass against the spec, CI/tests
  green, and `PROJECT_SPEC.md §10` build log + any ADRs reflect what was actually
  built (docs reconciled with reality, not drifted).

## 10. Tear down

```sh
$SWARM_HOME/bin/swarm-up.sh down shakedown
$SWARM_HOME/bin/swarm-up.sh status   # → no sessions
$SWARM_HOME/bin/swarm-remove.sh shakedown
```

- **PASS:** clean shutdown, no orphaned `swarm-shakedown` or
  `codex-view-shakedown` session, no `shakedown` row, and (when it was the final
  Codex reference) the runtime reports service workspace authority released.
  The host-wide `qofi-codex-app-server-manager` session may remain by design for
  other/future Codex rows. The bot token/ACL prompts remain explicit operator
  choices; global runtime uninstall is not part of an ordinary shakedown.

---

## Scorecard

If steps 4 (author+confirm), 6 (the engine's documented test boundary bites), and 8 (escalation reaches phone)
all pass, the system's core promise is proven — the rest is polish. Only then check
`PROJECT_SPEC.md §4`'s end-to-end criterion, and add a §10 build-log entry recording
the shakedown date and which repo it ran against.

## If a step fails — where to look

- Builds during the conversation → `swarm-up.sh` handoff brief (step 3).
- Spec stays template-shaped after "go build" → CTO didn't author (TEAM_LEAD.md
  lifecycle step 1).
- Test gate doesn't block → `.claude/settings.json` hooks + test command (step 6).
- Escalation decided silently → `ESCALATION.md` / TEAM_LEAD plan-approval gate.
- `/status` shows API key → `ANTHROPIC_API_KEY` in the launching shell (step 2).
