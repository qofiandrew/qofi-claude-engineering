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

Runs on every push to `dev` and on the `dev`→`main` release PR. The same jobs are
the **required checks** branch protection enforces on `main`. Tune tool versions
and the test/build commands to the repo's stack.

```yaml
name: ci
on:
  push:
    branches: [dev]
  pull_request:
    branches: [main]   # the dev->main release PR

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }   # full history for the secret scan
      - uses: actions/setup-node@v4
        with: { node-version: '22', cache: 'npm' }
      - run: npm ci
      - name: Typecheck
        run: npm run typecheck        # e.g. tsc --noEmit
      - name: Lint
        run: npm run lint
      - name: Test + coverage floor
        run: npm test -- --coverage   # fail under the quality-bar.md threshold (default 80%)
      - name: Secret scan (gitleaks)
        uses: gitleaks/gitleaks-action@v2
      - name: SAST (semgrep)
        uses: returntocorp/semgrep-action@v1
        with: { config: auto }
      - name: Build
        run: npm run build

  notify-on-red:
    needs: verify
    if: failure() && github.ref == 'refs/heads/dev'
    runs-on: ubuntu-latest
    steps:
      - name: Discord alert (red dev CI reaches the phone, not a dashboard)
        env:
          HOOK: ${{ secrets.DISCORD_CI_WEBHOOK }}
        run: |
          [ -n "$HOOK" ] || { echo "no DISCORD_CI_WEBHOOK set"; exit 0; }
          curl -fsS -H 'Content-Type: application/json' \
            -d "{\"content\":\"🔴 dev CI FAILED on \`${{ github.repository }}\` @ \`${{ github.sha }}\` — ${{ github.event.head_commit.message }}\"}" \
            "$HOOK"
```

Notes:
- **Coverage floor**: configure the test runner to exit non-zero below the
  threshold (vitest `coverage.thresholds`, jest `coverageThreshold`). The floor
  lives in the repo's `quality-bar.md`; CI enforces it. Never lower the floor to
  go green (`CLAUDE.md` §*Verification*).
- **Red `dev` CI → Discord**: CI runs in GitHub's cloud, so the alert posts to a
  Discord **channel webhook** (the `DISCORD_CI_WEBHOOK` secret) — *not* the
  on-Mac `cto-watcher` relay, which can't be reached from a GitHub runner.
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
  required gate on the release PR.

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
