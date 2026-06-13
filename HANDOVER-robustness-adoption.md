# HANDOVER — Engineering Robustness Program, final adoption

**To:** the Claude Code session that can execute (run bash, compose, test).
**From:** the advisory chat session (no exec against the repo; MCP filesystem only).
**Date:** 2026-06-12 → handover.
**Repo:** `qofi-claude-engineering` (the swarm-system / `$SWARM_HOME`).

---

## 0. The one-paragraph picture

Six operator-ratified decision records (2026-06-12) define a first-party
robustness upgrade to the engineering-cto archetype. The **doctrine prose is now
written into the composed fragments**. What remains is the **mechanism** (hooks,
scanners, CI, manifest lines, fixtures, tests) plus the **fixture regeneration**
that makes the byte-identity test green again — none of which the chat session
could execute. Your job: regenerate fixtures, get the compose test green, build
the mechanism, then hand back to the operator for review → propagate.

**Do NOT `swarm-update` / propagate anything until the operator has reviewed the
full diff AND the compose test is green.** Propagating now ships a RED-test state.

---

## 1. STATE: what is already on disk (done by the chat session)

### 1a. Product-vision facets (in `qofi-product`, NOT this repo)
Path: `qofi-product/products/qofi-claude-engineering/`
- `requirements.md` — verified UNCHANGED (a prior timed-out edit rolled back clean).
- `quality-bar.md`, `reliability.md`, `roadmap.md`, `constraints.md` — EDITED to
  reflect the six decisions. These are CPO product-vision docs; they do **not**
  stamp into swarms. No test gates them. Informational for you.

### 1b. Composed doctrine fragments (THIS repo — these DO stamp)
Path: `templates/engineering-cto/`
All edits below are LANDED on disk. They change composed output, so the
fixtures are now STALE → `test-doctrine-compose.sh` is currently RED until §2.

- `CLAUDE.md` (teammate-facing). New/changed sections:
  - §Scope & branches — "No PRs" bullet → release-PR-on-`main` model.
  - NEW §Promotion to `main` (CI referee + release PR).
  - §Clean-dev exit state — "`main` stays the operator's" para updated.
  - NEW §Test-driven by default.
  - NEW §Search first — research and reuse.
  - NEW §Conventional commits.
  - NEW §Session summary on stop (resume aid, never evidence).
  - NEW §Learnings (repo-local, evidence-cited).
  - §Definition of done — item 7 gained a reference to the new gates.
    **The `[DoD-1..6]` block was deliberately NOT touched** (it is scanned by
    `dod-affirm.sh` — do not renumber or reword those six lines).
- `TEAM_LEAD.md` (CTO-facing). NEW sections after §Verification:
  - §Independent review & security gates (mandatory, pre-DoD).
  - §Codex contrarian review lane (advisory, never gating).
  - §Learning loop (two tiers, operator-gated).
  - (§Integration branch & merge ownership was already updated to the release-PR
    model in the earlier CI/promotion pass.)
- `ESCALATION.md`. Changed:
  - §CTO → Operator triggers — "Pushing to `main`" → "Promotion to `main`"
    (release-PR framing); NEW "Doctrine-generalization proposal (Tier 2 learning)"
    trigger.

### 1c. INVARIANTS preserved (verify these held — they are the floor)
- **Operator-only-`main` floor unchanged.** "No agent process ever pushes or
  merges `main`" appears verbatim in CLAUDE.md §Scope & branches, §Promotion,
  §Clean-dev; TEAM_LEAD merge-ownership; ESCALATION trigger. The release PR is
  the OPERATOR's button — additive platform enforcement, NOT a new agent
  permission. If any edit reads as granting an agent a main-push/merge, that's a
  defect — flag it, don't propagate.
- **Real-spend / Type-2 floor unchanged** (CLAUDE.md §Real spend & money
  movement). The Codex lane is the ONE consciously-approved recurring spend, and
  the doctrine pins it to subscription auth with a never-fall-back-to-metered
  guard.
- **Permission-gate policy UNCHANGED.** I did not edit
  `engineering-cto/hooks/permission-gate-policy.sh`. It still denies `git push`
  entirely. That stays correct: the release PR is merged by the operator in
  GitHub, not by an agent `git push`. So the permission-gate fixtures
  (`permission-gate.engineering-cto.expected.sh`) are NOT stale — leave them.

---

## 2. FIRST: regenerate the 3 stale fixtures, get the compose test green

The compose test (`tests/test-doctrine-compose.sh`) is byte-identity against
FROZEN fixtures. It does NOT auto-regenerate. Exactly THREE fixtures are stale
(the three fragments I edited). Regenerate each by composing the SAME source
order the test uses, then write to the fixture path:

```bash
cd "$SWARM_HOME"   # qofi-claude-engineering root

# CLAUDE.md fixture = preamble + base + engineering-cto (this order, no separator)
cat templates/engineering-cto/CLAUDE.preamble.md \
    templates/_base/CLAUDE.md \
    templates/engineering-cto/CLAUDE.md \
    > tests/fixtures/CLAUDE.engineering-cto.expected.md

# ESCALATION.md fixture = preamble + base + engineering-cto
cat templates/engineering-cto/ESCALATION.preamble.md \
    templates/_base/ESCALATION.md \
    templates/engineering-cto/ESCALATION.md \
    > tests/fixtures/ESCALATION.engineering-cto.expected.md

# TEAM_LEAD.md is a single-file refresh (NOT composed) — fixture = the file verbatim
cp templates/engineering-cto/TEAM_LEAD.md \
   tests/fixtures/TEAM_LEAD.engineering-cto.expected.md
```

Then run the test. The round-trip + single-file sections must pass:
```bash
bash tests/test-doctrine-compose.sh
```
Expect: the round-trip and single-file blocks say `ok`. The **live-swarm
coverage block will report MISMATCH** for reserve-backend-2 and qofi-ios-app —
that is EXPECTED and correct pre-sync (the swarms still carry old doctrine; the
mismatch is exactly the change being landed). It is informational, not a FAIL.

**Trailing-newline invariant:** the test asserts every non-final compose source
ends in `\n`. My edits preserved final newlines, but if the test flags a source
lacking a trailing newline, fix that source (add the newline) and re-regenerate.

**Also run the full suite** to confirm nothing else regressed:
```bash
for t in tests/test-*.sh; do echo "== $t"; bash "$t" || echo "  ^ FAILED"; done
```

---

## 3. THEN: build the mechanism (the parts chat could not execute)

The prose now DESCRIBES gates/hooks that don't physically exist. Build them so
the doctrine is true, not aspirational. Each new file needs a `manifest.tsv`
entry or it won't stamp. Each fragment edit needs a fixture regen + green test.

Sequenced by the decision records:

### 3a. Independent review & security gates
- **Reviewer + security-reviewer teammates** are doctrine/role, not files — they
  are spawned per the TEAM_LEAD doctrine. No new file unless you template a
  reviewer brief. Decide: is a `reviewer`/`security-reviewer` launch brief worth
  a seed file? (Optional.)
- **Deterministic scanners**: wire `gitleaks` + `semgrep` into the gate. This is
  real tooling — confirm they're installed on the host (`command -v gitleaks
  semgrep`); if not, that's an operator install step (flag it). Add their
  invocation to the appropriate hook or CI workflow, NOT the permission gate.
- **Coverage floor (80% default)**: enforced in CI (per product repo), recorded
  per-product in that repo's `quality-bar.md`. Not a swarm-system hook.
- **Harness-audit preflight**: a fail-loud first-party check (qofi-authored, in
  the `swarm-up.sh launch_one()` preflight style) auditing stamped CLAUDE.md /
  settings.json / hook registrations / MCP configs. NEW script + manifest line +
  a `tests/test-*.sh`. Model it on `test-swarm-up-preflight-gates.sh`.

### 3b. Engineering doctrine expansion — the HOOKS
- **Quality PostToolUse hook(s)** (per-stack typecheck/lint on edit). NEW hook
  file(s) under `templates/engineering-cto/hooks/`, registered via
  `settings.example.json` (the `settings` manifest class merges it), + manifest
  line(s) + test(s).
- **Stop-phase session-summary hook**. NEW hook writing a timestamped summary to
  a doctrine-defined IN-REPO path (never `~/.claude` — cross-swarm
  contamination). Manifest line + test.
- **Hook runtime controls** `QOFI_HOOK_PROFILE` / `QOFI_DISABLED_HOOKS`: gate
  QUALITY hooks only. **HARD CONSTRAINT: the permission gate is NEVER
  env-switchable** — no env var may disable/weaken/bypass it. A disabled quality
  hook must be LOUD (printed at swarm-up preflight, visible in heartbeat). Add a
  test that asserts the permission gate ignores these env vars.
- **Per-stack rules fragments** (TS/Node, testing, coding-style; BullMQ/Drizzle/
  Postgres first). NEW fragments. Decide composition: into `engineering-cto/
  CLAUDE.md` (then it's always-loaded — costs context every session) vs an
  on-demand skill (preferred per the bloat-guard doctrine). Recommend skill.

### 3c. Two-tier learning loop
- **`LEARNINGS.md` seed** — NEW manifest line, class `seed` (write-if-absent;
  CTO authors per-repo). Add a short seed template.
- **Tier-2 CPO-curator** doctrine lives in the cpo archetype + the
  product-template; coordinate with the CPO side if you template it. (Out of this
  repo's engineering-cto scope except for the LEARNINGS.md seed + the doctrine
  prose already landed.)

### 3d. Codex contrarian lane
- Advisory pipe of the integrated diff to the OpenAI Codex CLI. NEW integration
  (script or hook). **Pin to SUBSCRIPTION AUTH. Never fall back to metered
  API-key billing on auth failure** — that flip is unapproved Type-2 spend; fail
  loud and go advisory-down instead. Codex credential via §Secrets (silent
  prompt, chmod 600, never in argv/scrollback) — extend `swarm-provision-
  tokens.sh` / `tokens.env` handling. Lands AFTER 3a's reviewer lane is live.

### 3e. CI referee + promotion (per PRODUCT repo, not this repo)
- GitHub Actions workflow (typecheck/lint/test+coverage/secret-scan/build) on
  every `dev` push, required on `dev`→`main` release PR. Branch protection on
  `main` (operator applies — agents cannot). Railway staging tracks `dev`. These
  are per-product-repo adoption steps, mostly operator-run; document them as a
  checklist the CTO follows per repo. Red `dev` CI → Discord notification.

---

## 4. Every new fragment/hook: the definition-of-done loop

For each file added in §3:
1. Add the `manifest.tsv` line (behavior | template-path | target-path [| covers]).
2. If it composes into an existing file, regenerate that fixture (§2 pattern) and
   keep the trailing-newline invariant.
3. If it's a new standalone artifact, add a frozen fixture only if a test checks
   it; otherwise a `tests/test-*.sh` exercising its behavior (fail-loud-and-tested
   is the precedent — see `test-swarm-up-preflight-gates.sh`).
4. `bash tests/test-doctrine-compose.sh` green (round-trip + single-file blocks).
5. Full suite green: `for t in tests/test-*.sh; do bash "$t"; done`.

---

## 5. HANDBACK to operator, THEN propagate (do not skip)

1. Operator reviews the FULL diff (doctrine + mechanism). This is a safety-floor-
   adjacent change (push/merge model); operator sign-off is required.
2. Compose test green (round-trip + single-file). Live-swarm block still MISMATCH
   pre-sync — expected.
3. Propagate via the normal path: compose → byte-identity test →
   **canary on reserve-backend-2** → `swarm-update`. After sync, the live-swarm
   coverage block must return to all-match (DRIFT back to zero).
4. Per-product-repo adoption (CI workflow, branch protection, staging) is a
   separate operator-run checklist (§3e), not a `swarm-update`.

---

## 6. Watch-outs (things that will bite)

- **Don't touch `permission-gate-policy.sh`** unless a decision requires it; it
  still denying push entirely is CORRECT under the release-PR model.
- **Don't renumber/reword the `[DoD-1..6]` block** in CLAUDE.md — `dod-affirm.sh`
  scans it.
- **Permission gate is never env-switchable** — if you wire hook runtime
  controls, exclude it explicitly and test that exclusion.
- **Session summaries + LEARNINGS.md are per-repo, never `~/.claude`** (one-user
  host → cross-swarm contamination).
- **Codex lane: subscription auth only**, never silent metered fallback.
- **`$SWARM_HOME` never gets a swarm.conf row / never sync against itself** —
  unchanged anti-roadmap rule.
- The chat session verified all reads but ran NO tests against the repo. Treat
  every "done" above as "written, not yet verified by execution" until you run
  the suite.
