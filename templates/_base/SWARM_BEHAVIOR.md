
## Harness-enforced lifecycle and evidence

Swarm lifecycle compliance belongs to the runtime-blind harness, not to an
agent's promise to comply. Claude and Codex workers produce runtime-specific
events, but the harness normalizes those events before applying policy. Status,
roadmap movement, check-ins, review gates, stop delivery, and grounding metrics
derive from normalized events, result sets, decision records, and durable state
transitions. Agent prose is data and may explain an event; it is never proof
that the event happened.

- A task is not done until its completion-gate adversarial-review artifact is
  present and bound to the reviewed diff. The default is exactly one review,
  after implementation and verification and before the stop pipeline. Mid-task
  review loops are forbidden. The policy model reserves a future early-review
  class only for doctrine-listed standing-invariant or security-sensitive
  paths, but the currently installed Claude and Codex adapters disable it: no
  trusted in-session completion boundary can grant it symmetrically. A worker
  cannot grant itself an exception. If a future harness boundary admits one,
  the completion review is still required.
- A worker is not stopped until the harness-owned Discord delivery pipeline
  records the final summary as delivered or durably queued. The worker does not
  perform or attest delivery. Retry, dead-letter, fallback escalation, and the
  stop audit record are harness responsibilities.
- A watcher idle ping requires a structured CTO check-in carrying the current
  task, one state-vocabulary status, progress since the prior check-in,
  blockers, next action, and a boolean `needs_input`. A greeting, heartbeat, or
  bare acknowledgment is invalid. The watcher records ping-to-check-in latency
  and re-pings invalid or absent responses with escalation.
- Roadmap state and Discord digests are derived from task start/finish, state
  transition, and result-set events. They carry only labels and states: never
  credentials, provider tokens, account identifiers, prompts, or reviewed
  content. Manual roadmap edits are operator-only.

## Deterministic context packs and grounding budget

Read the task brief's named context references before exploratory search. A
product context pack contains the module map, key-file inventory, invariant
registry, and task-relevant named references. Its identity is the source-corpus
commit hash; the harness regenerates it when that corpus changes, never merely
because a new task starts.

The harness counts read/search operations before the first substantive edit.
Crossing the configured budget does not block useful work: it emits a pack-gap
artifact naming the missing context, then allows the worker to proceed. Grounding
time and pack-gap events are derived metrics for the roadmap digest, not values
the worker can self-report.

Where one runtime lacks an in-session control point that the harness cannot
replace, the capability is disabled for both runtimes or the task class is
explicitly restricted and entered in the known-divergence register. Runtime
adapters translate events and decisions only; they never define policy.
