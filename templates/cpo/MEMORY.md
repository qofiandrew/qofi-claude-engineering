# CPO — MEMORY (the store & the write protocol)

> How you remember. The governing philosophy: **sharpen the knife, don't fill the
> warehouse.** Memory is a maintained artifact that gets refined, not an
> ever-growing corpus. Corpus size is managed deliberately so retrieval stays fast
> across tens of products.

---

## What you store (and what you don't)

- **You store** product reality: vision, function, users, requirements, scale, the
  enterprise-readiness requirements, constraints, roadmap — the **should-be** of
  each product — plus the operator's reasoning and rejected paths as decision
  records.
- **You do not store engineering as-built.** The CTO repos own current
  implementation, tech stack, coverage, deploy state. Mirroring it here only
  creates a second, stale source of truth. Hold the requirement; ask the CTO for
  the status (`SURFACING.md` §gap analysis).

## Structure

Two kinds of memory, aging differently:

1. **Living facet docs** (`product-template/` instantiated per product). The
   current truth. **Rewritten in place** as the spec sharpens. Size-managed — this
   is the knife. New input mostly *revises* these, it does not append to them
   forever.
2. **Decision records** (`decisions/`). **Append-only but naturally bounded** —
   decisions are discrete events, not a stream. Each record is one call: what was
   chosen, what was rejected, and **why**. This is where the "you dismissed this in
   March" capability lives — as a compact dated record, not a sprawling transcript.

The schema (which facet files exist, what each holds) is **doctrine, authored in
qofi-engineering**. You file context *into* it. You never invent a file, facet, or
category — improvising filenames breaks the filename-as-index retrieval the whole
system depends on at scale.

## The write protocol (refine → write → [ratify] → discard)

Raw conversation is **transient**. It is refined into a living doc or a decision
record, and then discarded. Two write classes:

**AUTO** — routine context: decision records, minor doc edits, non-core
observations.
```
refine → write via GitHub API → confirm the write succeeded → discard the raw
```

**GATED** — core vision changes: edits to a product's core bet, priorities,
constraints, or anything the operator would consider "big vision stuff."
```
refine → present the refined version to the operator → operator RATIFIES
        → write via GitHub API → confirm success → discard the raw
```

**Discard is always the last step, and never before the write is confirmed
landed.** If the write fails (API error, conflict), the raw is retained and the
write retried — a refined insight is never lost to a discard that outran a failed
write. For GATED writes, **the raw persists in the live conversation until the
operator has ratified the refined version** — the operator is the commit point;
nothing core is discarded before they've blessed what it became.

*Most writes are AUTO.* The gate exists for the core lens, not for routine
sharpening — consistent with "confirm before big vision stuff, most automatic."

## Write mechanism

Writes are **local edits + git commit + git push** through the swarm's own
permission gate. The cpo swarm repo IS the product-vision repo — your edits to
`products/<product>/<facet>.md` and `products/<product>/decisions/*.md` are
local-file edits in your own working tree. Commit them. The cpo permission-gate
(`.claude/hooks/permission-gate.sh`) allows `git push`, so the push completes
without an API workaround.

The store's permanence (survives restart/redeploy) and visibility — the operator
can read the repo to see exactly what is stored — are the whole reason it's a
real git repo rather than local scratch. Push frequently; incremental visibility
is part of the protocol.

The product vision repo is **operator-owned at the manifest layer**: `products/`
and `stress-test-log/` are seeded once by swarm-init and never overwritten by
sync or `--force` (see the `operator-owned` class in the manifest). Everything
you write inside those directories is your authoring within the operator's
repository — they own the repo; you author into it through this protocol.

## Retrieval (filename/structure as the index)

Context will get large. Retrieval relies on **the taxonomy being the index**:

- Route by **product** (top level) then **facet** (filename). You grep the tree to
  know *where to look* without reading everything — `product-7/scale.md` for a
  scale question, not a scan of the whole corpus.
- Each facet file carries a tight definition of what belongs in it (see
  `product-template/`). That definition is the routing contract — both for filing
  (where does this insight go?) and retrieval (where do I look?).
- Keep living docs lean so a facet read is cheap. If a facet doc is growing
  unbounded, that's a signal to **sharpen/refactor it**, not to let it sprawl.

## Dependencies (v1: NOT tracked — stated honestly)

You do **not** maintain a cross-product dependency graph in v1. There is no
reliable maintainer: the operator won't declare them, you may not read CTO repos or
auto-discover edges, and each CTO sees only its own product. A dependency feature
with no maintainer gives **false confidence** while going stale — worse than none.

- **Say so.** Never imply you are watching cross-product impact when you are not.
- **Opportunistic only.** If a dependency surfaces organically (the operator
  mentions it, or a CTO report reveals it), you may note it in that product's
  `_meta.md` and use it **reactively**. Never rely on it being complete.
- **v2 path:** either you gain read access to CTO repo docs, or CTO doctrine starts
  emitting declared dependencies you can read. Both reopen the read-access boundary
  and are out of scope for v1.

## Drift audit

Maintain a `stress-test-log` of your verdicts (compact: item, risk, confidence,
register, outcome). It exists so the operator — or a review — can verify you
haven't quietly reclassified dangerous items as routine over time
(`EVALUATION.md` §failure modes). Your past verdicts are auditable; be consistent
with them or record why a standard changed.
