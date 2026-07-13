# Supervised grounding runtime seam

**State:** implemented and tested; adoption off; not live

`bin/swarm-grounding-gate.ts` is the production process boundary for grounding
policy. It accepts either a native Claude `PreToolUse` record or a native Codex
pre-dispatch rollout record on stdin. Exit `0` admits the tool; exit `2` means
the supervising runtime must withhold tool execution. Both records pass through
the existing transcript/rollout normalizers before the shared harness policy
runs. The runtime adapters translate only; all preload, budget, persistence,
and edit decisions live in `swarm-harness/grounding-runtime-wrapper.ts`.

The process is a no-op unless the lifecycle owner supplies a validated
`qofi-harness-parity-adoption/v1` operator receipt whose exact runtime set is
`["claude","codex"]`. There is no one-runtime enable flag. On adoption, the
lifecycle owner also supplies the task identity and runtime in the supervised
process environment. Context authorities are not worker-selectable paths:

- `<state_root>/grounding-authority/product-context-cache.json` is a canonical,
  owner-private `qofi-product-context-cache/v1` record.
- `<state_root>/grounding-authority/task-briefs/<sha256(task-id)>.json` is the
  canonical owner-private task brief.
- The gate compares the cache's full corpus commit with the workspace's current
  Git commit, then verifies each named ref's descriptor-bound bytes against the
  inner pack hash before counting the ref as consumed.

For every task, the wrapper writes immutable, fsynced state transitions beneath
`<state_root>/grounding/<runtime>/<receipt-and-task-digest>/`. It appends every
accepted structural event to the shared owner-private normalized event store.
Raw commands, paths, queries, prompts, source bytes, account identifiers, and
tokens are never written there. A per-task monotonic `source_seq` and logical
millisecond timestamp are assigned at the harness boundary, so repeated
identical operations from equal-timestamp records cannot digest-collapse.

Named context refs must be read in the deterministic preload order before
exploratory reads or searches. An opaque shell/exec call is refused until the
first explicit substantive edit has passed the gate; it cannot hide the first
write from the structural classifier. At operation `N+1`, reads/searches remain
admissible but the first edit is held. The worker files one bounded gap result
by invoking the same process with:

```json
{"action":"file-pack-gap","missing_context_refs":["database-schema"]}
```

The gate fsyncs `pack-gap.json`, appends `grounding.gap_reported`, and only then
admits the retried edit. A journaled transition whose normalized-event append
was interrupted is reconciled before the next decision; an in-process failure
poisons that wrapper instance and fails shut.

## Exact activation seams

- Claude: register the process as a blocking `PreToolUse` adapter and pass the
  native hook JSON on stdin. Registration is intentionally not stamped into a
  live template yet.
- Codex: call the same process from a manager-owned hold-before-tool-dispatch
  stream. The current daemon's summary-only `onEvent` callback and a completed
  rollout file are too late to enforce an edit decision, so neither is treated
  as grounding evidence and no event is fabricated from them.

The installed Codex surface does not currently provide that trusted
hold-before-dispatch record to the daemon. Therefore the entrypoint is an
implemented activation seam, **not registered or wrapped into either live
runtime**. Parity policy requires both sides to remain off until the Codex
manager control point exists and the same production-entrypoint fixtures pass
there. A task lease/serialized workspace owner is also required during the
ref-byte check and subsequent native tool dispatch.

Conformance is exercised in
`swarm-harness/grounding-gate-cli.test.ts` (the actual process entrypoint) and
`swarm-harness/grounding-runtime-wrapper.test.ts` (durable state, ref ordering,
gap gating, replay, content exclusion, and collision-safe event identity).
