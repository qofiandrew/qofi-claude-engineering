# Shakedown — first end-to-end run

> The first time the system is exercised as a whole, not part by part. Everything
> shipped so far proves the pieces are correctly *assembled*; this proves a
> directive actually *flows*. Run it on a throwaway repo. When every gate below
> passes, you may check `PROJECT_SPEC.md §4`'s end-to-end criterion — and not before.
>
> Each step states what to do and the **PASS** condition. If a step fails, stop and
> note which one — the failures are diagnostic (they tell you which layer broke).

## 0. Pick a throwaway target

Make an empty git repo you don't care about, e.g. `~/code/shakedown-todo`, with a
trivial real test command available (a `package.json` with a `test` script, or
`pytest` + a `tests/` dir). It must be a real git repo (`git init`) — the docs hook
checks `git status`.

- **PASS:** `cd <target> && git rev-parse --is-inside-work-tree` prints `true`.

## 1. Bootstrap the repo

```sh
export SWARM_HOME=<repo>          # the consolidated monorepo root
$SWARM_HOME/bin/swarm-init.sh ~/code/shakedown-todo
```

- **PASS:** stdout lists CLAUDE.md, ESCALATION.md, TEAM_LEAD.md, PROJECT_SPEC.md,
  docs/adr/ADR.template.md, .claude/hooks/{test-gate,docs-check}.sh,
  .claude/settings.json, .claude/test-cmd — and the closing line describes the
  design-conversation → "go build" → CTO-authoring flow (the reconciled message,
  not the old "run the spec phase" one).
- **PASS:** `.claude/test-cmd` contains your target's real test command (edit it now
  if the placeholder `npm test --silent` is wrong for this repo).
- **CHECK:** open `.claude/settings.json` — `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`
  is `"1"` and both hooks are wired.

## 2. Launch one CTO lead

Add a single line to `$SWARM_HOME/swarm.conf` and the matching token to
`tokens.env`, then:

```sh
$SWARM_HOME/bin/swarm-up.sh up
$SWARM_HOME/bin/swarm-up.sh status
```

- **PASS:** `status` shows one `swarm-<name>` session.
- **PASS (the Max guard):** attach to the session (`tmux attach -t swarm-<name>`),
  run `/status` in Claude Code — it shows your **Max subscription**, not an API key.
  If it shows an API key, `ANTHROPIC_API_KEY` leaked into the shell; fix before
  continuing or you'll bill metered API.
- **PASS:** in the repo's Discord channel, the bot is online.

## 3. The design conversation (no build yet)

In the Discord channel, spec something tiny on purpose — e.g. "a CLI to-do app:
add, list, complete, persist to a JSON file. v1 only." Have a short back-and-forth.

- **PASS:** the CTO engages and asks clarifying questions but does **NOT** start
  writing code or spawning teammates. (If it starts building during the
  conversation, the handoff prompt didn't land — check `swarm-up.sh`'s send-keys
  brief.)

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

- **PASS:** it spawns 3–5 teammates with **disjoint file ownership** (no two tasks
  own the same path). Spot-check the task list.
- **PASS:** tool-permission prompts surface **in Discord**; approving with the
  `yes/no` reply intercept from your phone unblocks the work.

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

- **PASS:** the `TaskCompleted` hook **blocks** it — the agent reports the task
  cannot close, surfaces the failing test output, and either fixes/removes the
  planted test or escalates. It must NOT mark the task done with a red suite.
- **FAIL looks like:** the task closes anyway → the test gate isn't wired; check
  `.claude/settings.json` hooks block and `CLAUDE_TEST_CMD` / `.claude/test-cmd`.

Then remove the planted test so the run can proceed:

```sh
rm tests/_shakedown_fail.test.js   # (or the python one)
```

## 7. The docs floor bites

Have a teammate make a source-only change and try to go idle without touching docs.

- **PASS:** the `TeammateIdle` hook blocks idle with the "you changed source but
  updated no docs" message, and clears once docs / the build log are updated.

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
$SWARM_HOME/bin/swarm-up.sh down
$SWARM_HOME/bin/swarm-up.sh status   # → no sessions
```

- **PASS:** clean shutdown, no orphaned tmux sessions.

---

## Scorecard

If steps 4 (author+confirm), 6 (test gate bites), and 8 (escalation reaches phone)
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
