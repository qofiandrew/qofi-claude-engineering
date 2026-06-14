# CI referee + promotion to `main` — per-product adoption checklist

This is the checklist a CTO follows to stand up the **independent CI referee** and
the **release-PR promotion** flow in a *product* repo (e.g. `reserve-backend-2`).
It is **not** a `swarm-update` artifact — it is per-product-repo adoption, run once
per repo, mostly by the **operator** (branch protection + secrets) with the CTO
authoring the workflow file.

It mechanizes the doctrine already in the stamped docs:
- `CLAUDE.md` §*Promotion to `main`* — GitHub Actions is ground truth; `main` is
  branch-protected; the release PR is the operator's one-tap merge.
- `CLAUDE.md` §*Clean-dev exit state* — the agent's objective ends at
  clean-pushed-`dev`; CI runs on every `dev` push.
- `TEAM_LEAD.md` §*Independent review & security gates* — coverage floor +
  gitleaks/semgrep run in CI.

**Floor that does not move:** no agent process ever pushes or merges `main`
(`CLAUDE.md` §*Scope & branches*). Everything below is *platform* enforcement
layered above that agent-side floor — it grants no new agent authority.

---

## Adoption checklist (per product repo)

Legend: **[CTO]** an agent may do it · **[OPERATOR]** human-only (agents cannot).

- [ ] **[CTO]** Add `.github/workflows/ci.yml` (reference below). Commit on `dev`.
      Adopt the **PORTABLE** scaffolding verbatim; tune only the **PER-REPO**
      run-commands and service containers (see the split below the reference).
- [ ] **[CTO]** Add `.gitleaks.toml` (reference below) — the content-only allowlist
      for verified test-fixture placeholders. Commit on `dev`.
- [ ] **[CTO]** Record the per-product **coverage floor** (default **80%**) in the
      repo's `quality-bar.md`, and wire the test step to enforce it.
- [ ] **[OPERATOR]** Install/confirm the deterministic scanners are available to
      CI (the workflow installs them per-run; for local runs:
      `brew install gitleaks semgrep`). `bin/security-scan.sh` is the same pass
      the CTO runs locally pre-DoD.
- [ ] **[OPERATOR]** Create a **Discord channel webhook** for the swarm's channel
      and store its URL as the repo secret `DISCORD_CI_WEBHOOK` (red-CI alert).
- [ ] **[OPERATOR]** Turn on **branch protection** for `main` (commands below):
      require the CI checks, block direct + force pushes for **everyone including
      the operator**, require the `dev`→`main` PR.
- [ ] **[OPERATOR]** Point **Railway staging** at the `dev` branch so staging
      tracks `dev` (manual verification happens in staging before promotion).
- [ ] **[CTO]** Confirm `dev`→`main` is the **only** path into `main`, and that
      the release PR is the operator's one-tap merge (no agent opens/merges it).

---

## Reference `.github/workflows/ci.yml`

This is the **proven shape** distilled from `reserve-backend-2`'s `ci.yml` — the
canonical reference. Read the **PORTABLE vs PER-REPO split** (below the YAML)
before adopting: take the security + structural scaffolding **verbatim**; tune
only the per-stack run-commands and service containers.

The **trigger split** keeps dev iteration cheap without weakening the deploy gate:

- **push → `dev`** runs a cheap `dev-smoke` job (typecheck + tests **only** — no
  coverage, gitleaks, semgrep, build, or migration-integrity): a fast
  "is `dev` broken?" signal on every push.
- **pull_request → `main`** (the `dev`→`main` release PR) runs the **full gate**:
  `verify` (typecheck, lint, coverage tests, gitleaks, semgrep, build) **and**
  `migration-integrity`. These two are the **required checks** branch protection
  enforces on `main` — their context strings `verify` and `migration-integrity`
  are **load-bearing; do not rename them.**

```yaml
name: ci

# CI referee (per docs/CI-PROMOTION.md). Split by event to keep dev iteration
# cheap without weakening the deploy gate:
#   - push to `dev`        -> `dev-smoke` ONLY (typecheck + tests): a fast
#                             "is dev broken?" signal. No gitleaks / semgrep /
#                             coverage / build / migration-integrity here.
#   - pull_request -> main -> the FULL deploy gate: `verify` (typecheck, lint,
#                             coverage tests, gitleaks, semgrep, build) AND
#                             `migration-integrity`. Those two are the required
#                             checks branch protection enforces on `main`; the
#                             context strings `verify` and `migration-integrity`
#                             are load-bearing — do NOT rename them.
on:
  push:
    branches: [dev]
  pull_request:
    branches: [main] # the dev->main release PR

# Cancel a superseded run on the same ref when a newer one starts, instead of
# letting both run to completion (keyed by workflow + ref).
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  # Cheap dev-push smoke: typecheck + tests ONLY — a fast "is dev broken?" signal.
  # The expensive suite (coverage, gitleaks, semgrep, build, migration-integrity)
  # runs on the dev->main PR below, not on every dev push.
  dev-smoke:
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    permissions:
      contents: read # least-privilege: checkout only, no PR/API scopes needed here
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20", cache: "npm" }
      - name: Install
        run: npm ci
      - name: Typecheck
        run: npm run typecheck # tsc --noEmit  [PER-REPO command]
      - name: Test
        run: npm test # vitest run, NO --coverage (the floor runs in `verify`)  [PER-REPO command]

  # The required gate (PR only). Name `verify` is load-bearing: branch protection
  # requires this check context. Tune the run-commands to the repo's stack.
  verify:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    # Least-privilege GITHUB_TOKEN. The repo default is read-only contents, which
    # 403s gitleaks' "list PR commits" API call on pull_request events. Grant only
    # what's needed: contents:read for checkout, pull-requests:read for that call.
    # A job-level block sets every unlisted scope to none (no write anywhere).
    permissions:
      contents: read
      pull-requests: read
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # full history so gitleaks can scan commits
      - uses: actions/setup-node@v4
        with: { node-version: "20", cache: "npm" }
      - name: Install
        run: npm ci
      - name: Typecheck
        run: npm run typecheck # [PER-REPO command]
      - name: Lint
        run: npm run lint # [PER-REPO command]
      - name: Test + coverage floor
        run: npm test -- --coverage # fails below the quality-bar.md floor (default 80%)  [PER-REPO command]
      - name: Secret scan (gitleaks)
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} # required by gitleaks-action@v2 to scan pull_request events
      - name: SAST (semgrep)
        uses: returntocorp/semgrep-action@v1
        with: { config: auto }
      - name: Build
        run: npm run build # [PER-REPO command]

  # migration-integrity — the guard against the "false green" class: a schema the
  # code depends on drifting out of the committed migrations while the unit suite
  # (run against an in-memory / hand-DDL'd DB) stays green. Spins up a REAL
  # Postgres, applies ONLY the committed migrations, then exercises real
  # write-paths end-to-end; a missing migration throws and fails this job.
  #
  # PER-REPO: present ONLY for repos that own migrations + a relational DB. A repo
  # with no migrations omits this whole job (and drops it from `notify-on-red`'s
  # `needs` and from branch protection's required checks). The service container,
  # env, and check scripts below are this repo's stack — tune them.
  migration-integrity:
    if: github.event_name == 'pull_request' # PR-only: the migration-drift gate, runs before every deploy
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: ci_migration
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
    env:
      DATABASE_URL: postgresql://postgres:postgres@localhost:5432/ci_migration
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20", cache: "npm" }
      - name: Install
        run: npm ci
      - name: Apply committed migrations to a fresh database
        run: npm run db:migrate # [PER-REPO command]
      - name: Verify real write-paths against the migrated schema
        run: npx tsx scripts/check-migrations.ts # [PER-REPO script]

  # Red CI -> Discord channel webhook (reaches the phone, not a dashboard).
  # Fires on BOTH dev-smoke failure (push) and verify / migration-integrity
  # failure (PR). Reads the operator-set repo secret DISCORD_CI_WEBHOOK; if the
  # secret is unset the step no-ops (exit 0) rather than failing the run.
  notify-on-red:
    needs: [dev-smoke, verify, migration-integrity]
    if: failure()
    runs-on: ubuntu-latest
    steps:
      - name: Discord alert (red CI reaches the phone, not a dashboard)
        env:
          HOOK: ${{ secrets.DISCORD_CI_WEBHOOK }}
          # Untrusted: a commit author / PR opener controls these. Pass through the
          # environment and reference as "$COMMIT_MSG" so the shell treats it as
          # data, never expanding it as code (de-injects run-shell-injection).
          COMMIT_MSG: ${{ github.event.head_commit.message || github.event.pull_request.title }}
        run: |
          [ -n "$HOOK" ] || { echo "no DISCORD_CI_WEBHOOK set"; exit 0; }
          # Build the JSON with jq so every value is correctly escaped — a quote,
          # backslash, or newline can no longer malform the payload and silently
          # drop the notification. jq is preinstalled on ubuntu runners.
          payload=$(jq -n \
            --arg repo "${{ github.repository }}" \
            --arg sha "${{ github.sha }}" \
            --arg ctx "${{ github.event_name == 'pull_request' && 'release gate (dev->main PR)' || 'dev push smoke' }}" \
            --arg msg "$COMMIT_MSG" \
            '{content: "🔴 CI FAILED — \($ctx) on `\($repo)` @ `\($sha)` — \($msg)"}')
          curl -fsS -H 'Content-Type: application/json' -d "$payload" "$HOOK"
```

### Reference `.gitleaks.toml`

`gitleaks/gitleaks-action@v2` honors a repo-root `.gitleaks.toml`. The canonical
form keeps the **entire built-in ruleset active** (`useDefault = true`) and adds a
**content-only** allowlist for verified test-fixture placeholders — the
`test-secret-*` shape that test code uses for things like a JWT-signing secret. A
real credential never matches `test-secret-*`, so a real-looking secret committed
anywhere — including under `tests/` — still trips. The allowlist never blinds a
path wholesale.

```toml
# .gitleaks.toml — reviewed allowlist for VERIFIED test-fixture placeholders.
# A REVIEWED ALLOWLIST OF VERIFIED TEST PLACEHOLDERS, not a suppression.
#
#  1. `[extend] useDefault = true` keeps the entire built-in gitleaks ruleset
#     active — every default rule (generic-api-key, aws-access-token, stripe,
#     etc.) still fires on non-allowlisted content.
#  2. The allowlist is CONTENT-BOUND: a finding is allowed ONLY when the detected
#     secret value announces itself as a throwaway placeholder by matching the
#     `test-secret-*` shape. A real credential never matches it, so a real-looking
#     secret committed anywhere — including under tests/ — STILL trips.
#
# WHY CONTENT-ONLY (no path bound) — version dependency, READ BEFORE EDITING:
# an earlier revision bounded this by path AND content via
#     [[allowlists]]
#     condition = "AND"
#     paths   = ['''tests/.*''']
#     regexes = ['''test-secret-[A-Za-z0-9_-]+''']
# That `[[allowlists]] condition = "AND"` (path + content) construct is honored
# by gitleaks 8.30.x but NOT by the version CI pins — gitleaks 8.24.3 via
# gitleaks-action@v2. There the AND allowlist did NOT suppress the fixtures and
# the `verify` check stayed red. The primitive `[allowlist] regexes` form below
# is honored by 8.24.3 (and is stable across versions), so the canonical template
# uses the content-only primitive. Trade-off: a `test-secret-*` literal outside
# tests/ would also be allowed — acceptable, because real credentials never match
# the placeholder shape. If/when CI's pinned gitleaks moves to >= 8.30.x, the
# tighter path+content AND form becomes available; until then, do NOT switch to it.

[extend]
useDefault = true

[allowlist]
regexes = [
  '''test-secret-[A-Za-z0-9_-]+''',
]
```

---

## PORTABLE vs PER-REPO — what to copy verbatim vs tune

The reference above mixes two kinds of content. Get the line right: copy the
security + structural scaffolding **verbatim** (changing it silently weakens a
gate or breaks the required-check contract); tune the run-commands to the stack.

### PORTABLE — adopt VERBATIM in every repo

This is the **security + structural scaffolding**. It is portable precisely
because it carries no stack assumptions — it is the safety and wiring contract,
identical everywhere:

- **Trigger split** — `push: [dev]` → `dev-smoke`; `pull_request: [main]` → full
  gate. Jobs gated by `if: github.event_name == 'push'` / `'pull_request'`.
- **`concurrency`** — `group: ${{ github.workflow }}-${{ github.ref }}`,
  `cancel-in-progress: true`. Stops a superseded run from burning minutes.
- **gitleaks token + permissions** — the `verify` job's job-level least-privilege
  `permissions: { contents: read, pull-requests: read }`, and the gitleaks step's
  `env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`. Both are required for
  `gitleaks-action@v2` to scan `pull_request` events without 403ing.
- **`.gitleaks.toml`** — the content-only `[allowlist] regexes` form (the 8.24.3
  version dependency above). Verbatim.
- **De-injected `notify-on-red` wiring** — untrusted values (`COMMIT_MSG`) passed
  through `env:` and referenced as `"$VAR"`, payload built with `jq -n --arg`, the
  empty-`HOOK` no-op (`exit 0`), and the `pull_request.title` fallback. This is
  the shell-injection-safe shape; do not inline `${{ ... }}` into the `run:`
  script.
- **Required-check context names** — `verify` and `migration-integrity` are
  **load-bearing**: branch protection requires these exact strings. Renaming a
  job silently de-gates `main`.

### PER-REPO — tune to the stack

These genuinely differ per stack and **must not** be copied blindly:

- **Test / build / typecheck / lint / migrate commands** — every line marked
  `[PER-REPO command]`. The reference shows an `npm` + `tsc` + `vitest` stack; a
  **pnpm monorepo** uses `pnpm -r ...` and workspace-scoped runs; a **Python /
  ruff** repo uses `ruff check`, `pytest --cov`, etc. The run-commands are **not**
  portable — only the job *structure* around them is.
- **Setup action + toolchain** — `setup-node` vs `setup-python` / `pnpm/action-setup`
  / `astral-sh/setup-uv`, and the version. Tune the cache key to the package
  manager.
- **Service containers** — the `postgres` service for `migration-integrity` is
  here only because this repo owns a relational DB + migrations. A repo with a
  different datastore (or none) changes or drops it.
- **Whether the repo even HAS `migration-integrity`** — present ONLY for repos
  that own migrations against a real DB. A repo without migrations **omits the
  whole job**, drops it from `notify-on-red`'s `needs:`, and drops its context
  from branch protection's required checks. Keeping a `needs:` on a job that
  doesn't exist is a config error.
- **Whether the repo even HAS `notify-on-red`** — the Discord red-CI alert
  depends on the operator having set `DISCORD_CI_WEBHOOK`. The step no-ops if the
  secret is unset, so it's safe to keep, but a repo outside the swarm's
  Discord-notify model may legitimately drop the job entirely.

Notes:
- **Coverage floor**: configure the test runner to exit non-zero below the
  threshold (vitest `coverage.thresholds`, jest `coverageThreshold`, pytest
  `--cov-fail-under`). The floor lives in the repo's `quality-bar.md`; CI enforces
  it. Never lower the floor to go green (`CLAUDE.md` §*Verification*).
- **Red CI → Discord**: CI runs in GitHub's cloud, so the alert posts to a Discord
  **channel webhook** (the `DISCORD_CI_WEBHOOK` secret) — *not* the on-Mac
  `cto-watcher` relay, which a GitHub runner can't reach.
- The same `gitleaks` + `semgrep` steps are what `bin/security-scan.sh` runs
  locally, so the CTO's pre-DoD pass and CI agree.

---

## Branch protection (operator-only, via `gh`)

Agents cannot set protection. The operator runs this once per repo. It binds even
the operator — the only way into `main` is a green release PR.

```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -f 'required_status_checks[strict]=true' \
  -f 'required_status_checks[checks][][context]=verify' \
  -f 'required_status_checks[checks][][context]=migration-integrity' \
  -f 'enforce_admins=true' \
  -f 'required_pull_request_reviews[required_approving_review_count]=0' \
  -f 'restrictions=' \
  -F 'allow_force_pushes=false' \
  -F 'allow_deletions=false'
```

- `enforce_admins=true` is the line that makes protection bind the operator too
  (`CLAUDE.md` §*Promotion to `main`*: "blocked at the platform for everyone,
  including the operator").
- `required_status_checks.checks[].context=verify` makes the CI `verify` job a
  required gate on the release PR. **Both `verify` and `migration-integrity` are
  required checks** — these context strings must match the job names in `ci.yml`
  exactly (they are PORTABLE / load-bearing). **PER-REPO:** drop the
  `migration-integrity` line for a repo that doesn't run that job (no migrations /
  no relational DB) — requiring a check that never reports leaves the PR
  permanently un-mergeable.

---

## Promotion flow (operator-run, per release)

A release = **green `dev` CI** **AND** **staging current** **AND** the operator
has **manually verified in staging**. Only then:

1. The operator opens (or the CTO assembles, per `CLAUDE.md` §*Conventional
   commits* — diff-vs-base + summary + test plan) the `dev`→`main` release PR.
2. CI's required `verify` check must be green on the PR.
3. The operator merges the PR by hand (one tap). **Deploy *is* the merge to
   `main`** — nothing else is.

No agent opens, approves, merges, or waits on the release PR. Migrations require a
staging run before promotion (`CLAUDE.md` §*Data migrations*).

---

## Recommendation — manifest-stamped artifact vs per-repo doc (analysis only)

**Question:** should the CI workflow (`ci.yml` + `.gitleaks.toml`) become a
**swarm-stamped manifest artifact** — propagated by `swarm-init` / `swarm-sync` /
`swarm-onboard` like `CLAUDE.md` and the hooks — or stay a **per-repo doc** the
CTO copies and tunes by hand (today's model: this doc's header explicitly states
it is "**not** a `swarm-update` artifact")?

This is a recommendation, **not** an implementation. No ADR is authored here.

### What the portable/per-repo split tells us

The split above is the crux. The manifest's behavior classes
(`templates/engineering-cto/manifest.tsv`) each assume a **single byte-stream the
swarm owns**: `refresh` overwrites unconditionally, `compose` concatenates fixed
sources, `seed` writes-if-absent. A CI workflow is **not** a single byte-stream —
it is **portable scaffolding + per-repo run-commands interleaved in one file.** No
existing class fits cleanly:

- **`refresh` (overwrite)** would clobber the PER-REPO run-commands on every sync
  — a pnpm-monorepo or Python/ruff repo would have its real test/build commands
  reverted to the `npm`/`tsc` reference on the next `swarm-sync`. Unacceptable:
  sync would routinely break working CI.
- **`seed` (write-if-absent)** propagates the file once, then **never updates it**
  — so a future hardening of the PORTABLE scaffolding (a new gitleaks-token fix, a
  concurrency tweak) would **not** reach already-stamped repos. That defeats the
  whole point of stamping; it's barely better than the per-repo doc.
- **`compose`** is the closest conceptually (a portable preamble + a per-repo
  overlay, like the `CLAUDE.preamble + _base + engineering-cto` chain) — but it
  joins **fixed** template sources, and the per-repo half here is **authored per
  stack**, not selected from a fixed fragment set. YAML also has no comment/section
  seam that survives a literal concatenation cleanly the way the markdown docs do.

### The genuine split is the blocker

The reason `CLAUDE.md` stamps cleanly and `ci.yml` does not: doctrine is
**100% swarm-owned** (every byte is the operating contract), so `refresh` is
correct. CI is **~60% swarm-owned scaffolding + ~40% repo-owned commands in the
same file** — and the stacks genuinely differ (npm vs pnpm-monorepo vs
Python/ruff; whether the repo even has `migration-integrity` / `notify-on-red`).
A single owner per file is exactly what every existing manifest class assumes, and
CI violates it.

### Recommendation

**Keep `ci.yml` per-repo (status quo) for now — do NOT add it to the manifest as a
single `refresh`/`seed` artifact.** The clean PORTABLE/PER-REPO split this doc now
draws is the right *interim* contract: the CTO copies the PORTABLE scaffolding
verbatim and tunes the PER-REPO commands, with this doc as the canonical source of
the portable half.

**BUT** there is a real, separable win worth a future decision: the **PORTABLE
half alone** — `.gitleaks.toml` (fully portable, zero per-repo content) and a
**partial / fragment** of `ci.yml` (the trigger split, `concurrency`, the
gitleaks token+permissions, the de-injected `notify-on-red` block) — *is*
swarm-ownable. The two candidate mechanisms:

1. **Stamp `.gitleaks.toml` as a `refresh` artifact now** (it has no per-repo
   content) and leave `ci.yml` per-repo. Smallest, lowest-risk step; closes the
   most error-prone copy (the 8.24.3 allowlist subtlety) without touching the
   split-ownership problem.
2. **Introduce a new manifest behavior class** (e.g. a *fragment-merge* /
   *managed-block* class that owns a marked region of a file and leaves the rest
   to the repo) so the PORTABLE `ci.yml` scaffolding can be swarm-managed while
   per-repo commands stay local. This is a **new class** — a structural addition
   to the manifest contract every archetype consumes.

### Does this warrant its own ADR?

**Option 1 (stamp `.gitleaks.toml` only): NO ADR.** Adding one fully-portable file
under the existing `refresh` class is a routine manifest addition ("add a new
artifact in ONE place: here"), not a one-way door — reversible by deleting the
manifest line.

**Option 2 (new fragment-merge / managed-block manifest class): YES — its own
ADR, and it is a one-way door.** A new behavior class changes the manifest
*contract* that `swarm-lib.sh` and every archetype's `manifest.tsv` depend on; it
introduces a managed-region marker convention into target files that, once
stamped across repos, is expensive to retract (every stamped file carries the
markers). That is precisely the ADR-worthy, escalate-the-one-way-door class
(`CLAUDE.md` §*Decisions*). **Flagged for the CTO/operator: I recommend Option 1
now (no ADR) and that Option 2, if pursued, open its own scoped ADR — I do not
author it here.**
