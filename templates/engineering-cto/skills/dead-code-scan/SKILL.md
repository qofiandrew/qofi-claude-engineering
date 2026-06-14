---
name: dead-code-scan
description: Operator-invoked, DETECTION-ONLY pass that surfaces dead-code and unused-dependency CANDIDATES on a TS/Node repo (knip / ts-prune / depcheck). It REPORTS; it NEVER deletes or auto-removes — it respects the doctrine's "mention, don't delete" rule (CLAUDE.md §Working with existing code). Invoke explicitly when an operator/CTO asks "what's dead here" or "what deps are unused"; it is NOT a gate and NOT a floor. Like ts-node-stack it is on-demand and inert (zero context) in repos whose stack doesn't match — if there is no package.json / tsconfig.json, this skill does not apply, output nothing.
---

# dead-code-scan — surface dead-code & unused-dep candidates (detection-only)

This is an **operator-invoked, detection-only companion** to the always-loaded
doctrine, not a replacement for it. It exists to answer one question on demand —
*"what looks dead in this repo?"* — and to answer it **without ever deleting
anything.** Where this skill and `CLAUDE.md` overlap, `CLAUDE.md` wins.

## When this skill applies (and when it is inert)
- **Applies** only to a TS/Node repo: a `package.json` (and usually a
  `tsconfig.json`) at the root. If those are absent, the stack doesn't match —
  **this skill is inert: produce no output, do not improvise a scanner for some
  other language.** (Same on-demand, zero-context-elsewhere posture as
  `ts-node-stack`.)
- It is **not** part of the test gate, the security pass, or the DoD. It never
  runs automatically; an operator or the CTO invokes it deliberately.

## The hard rule: SURFACE, never delete
This skill **mechanizes** `CLAUDE.md` §*Working with existing code* —
"**Pre-existing dead code: mention, don't delete**" — it does not relax it.

- **Output is a report of CANDIDATES, not an edit.** It lists what the tools
  flagged. It does **not** open files, does **not** remove exports, does **not**
  uninstall dependencies, does **not** stage a deletion.
- A "dead" export may be a **contract surface a peer consumes** (`CLAUDE.md`
  §*Modular design*) — an out-of-repo consumer, a dynamic import, a plugin
  entrypoint, a reflection/DI lookup the static tool can't see. Removal is a
  **separate, scoped decision** that goes to the CTO per §*Conflict handling*,
  with its own blast-radius review — never an automatic consequence of this scan.
- Treat every finding as a **candidate with a known false-positive rate**, not a
  verdict. The contribution is *naming* the candidates; deciding and removing is
  not this skill's job.

## What it runs (native tools, detection-only flags)
Use whatever the repo already declares; do **not** add a new dependency just to
run a scan (`CLAUDE.md` §*Dependencies*). Prefer `npx` against an
already-present tool; if none is present, say so and stop — don't install one as
a side effect.

- **`knip`** — unified dead-files / unused-exports / unused-deps detector
  (preferred when present; supersedes the two below for most repos):
  - `npx knip` — report only. Never pass a `--fix` / `--fix-type` flag from this
    skill; `--fix` mutates the tree and is exactly what "mention, don't delete"
    forbids here.
- **`ts-prune`** — unused TypeScript exports:
  - `npx ts-prune` — lists exports with no in-repo references. Cross-check each
    against `modules/<module>.md`: an export named as a contract surface there is
    **not** dead even if `ts-prune` can't see the consumer.
- **`depcheck`** — unused / missing dependencies in `package.json`:
  - `npx depcheck` — lists `dependencies` with no detected import and imports
    with no declared dependency. Type-only, build-tool, and config-referenced
    deps are common false positives — flag, don't conclude.

## Reading the output (false-positive discipline)
Before surfacing a candidate as "likely dead," sanity-filter the known
false-positive classes — naming them in the report is the point:

- **Contract surfaces**: anything documented in `modules/<module>.md` as OFFERED,
  or imported by another repo / a separately-deployed service — not dead.
- **Dynamic / indirect use**: dynamic `import()`, string-keyed registries,
  DI/reflection, framework entrypoints (route files, migration files, CLI bins),
  test-only helpers — static tools miss these.
- **Config-referenced deps**: tools named only in `package.json` scripts, CI, or
  a config file (eslint/prettier/tsconfig plugins, type packages) read as
  "unused" by `depcheck` but are load-bearing.

## Output shape (what to hand back)
A compact, grouped report — **candidates only**, with the false-positive caveat
attached, and an explicit handoff that removal is a CTO-scoped decision:

```
dead-code-scan (detection-only — candidates, NOT a delete list):
  Unused exports (ts-prune / knip):
    - path/to/file.ts:L — exportName   [check modules/*.md: is this a contract surface?]
  Dead files (knip):
    - path/to/orphan.ts                [confirm no dynamic import / entrypoint use]
  Unused dependencies (depcheck / knip):
    - some-pkg                          [confirm not config-/type-/build-only]
  Missing dependencies (depcheck):
    - imported-pkg (imported, not in package.json)

NOTE: These are CANDIDATES. Per CLAUDE.md §Working with existing code, dead code
is MENTIONED, not deleted. Removing any of these is a separate, CTO-scoped
decision (blast radius: a "dead" export may be a peer's contract surface).
This skill did not modify the tree.
```

## Definition of done for an invocation
This skill performed correctly when it produced the candidate report, attached
the false-positive caveat, made **no edits to the working tree**, and handed the
removal decision to the CTO. A scan that deleted, fixed, or uninstalled anything
is a doctrine violation, not a successful run.
