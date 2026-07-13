# ADR-0023 — Enforce swarm lifecycle, evidence visibility, and runtime parity in the harness

**Status:** draft — implemented and tested locally; not live
**Date:** 2026-07-13
**Depends on:** ADR-0010's recoverable delivery queue, ADR-0019/ADR-0020's
runtime boundary and truthful-view rules, and ADR-0022's symmetric review
artifact contract.
**Amends:** ADR-0005 (quality gates), ADR-0010 (delivery scope), and ADR-0022
(review trigger and budget policy).

## Context

Several operational guarantees were still prompt-trusted or runtime-specific.
The Claude `Stop` hook inspected the transcript and, at most, asked the model to
use the Discord reply tool. It always exited successfully, did not prove that a
send succeeded, did not retry or dead-letter a failed send, and did not cover
`SubagentStop`. A worker could consequently end after producing terminal text
without any delivered operator message. The Codex bridge sent its final reply
itself, but some ancillary sends swallowed exceptions and no common stop audit
proved a delivered-or-queued outcome.

The watcher revival path posted a free-form prompt on `#cpo-cto-bus`, mentioning
the CPO bot for a named CTO loop. State lines and CTO-channel activity reset its
clock. Existing CPO doctrine correctly rejects a bare unchanged
`STATE: <name> DRIVING` as a useful revival response, but it defines no
machine-validatable CTO check-in object with current task, progress, blockers,
next action, and `needs_input`. The contract requested here is therefore a new
draft for operator ratification, not a claim about existing doctrine.

Roadmap visibility was spread across prose, decision records, transcript
freshness, Codex runtime state, and result artifacts. Agent status prose could
look complete while those sources disagreed. Earlier reviewer policy encouraged
bounded mid-task challenge calls and budgeted two calls per ordinary task. That
optimized iterative challenge rather than a deterministic completion gate; this
record supersedes it with one host-owned terminal call. Finally, the
warm-subagent doctrine named a fixed preload order, but did
not version reusable product packs by corpus commit or measure how much
exploratory grounding occurred before useful work.

The installed runtimes do not have identical control surfaces. Claude Code
2.1.207 exposes its hook lifecycle. Codex CLI 0.144.1 also reports stable
`PreToolUse`, `PostToolUse`, `SessionStart`, `UserPromptSubmit`, `SubagentStart`,
`SubagentStop`, and `Stop` hooks, plus the legacy `notify` command. However,
Codex command hooks execute as host processes outside the worker's tool
sandbox, require a separate trust decision, and can reference mutable workspace
scripts. The unattended Codex bridge therefore deliberately stamps an empty
`.codex/hooks.json` and invokes Codex with the `hooks` feature disabled. Native
surface similarity is not an acceptable reason to weaken that boundary.

## Decision

### 1. One policy layer, two event adapters

Lifecycle policy is harness-owned by default. The runtime-blind policy defines
one task boundary for a future harness-spawned `claude -p` lane and the
implemented supervised Codex process; the Claude runner itself is not shipped.
Runtime adapters may parse events and return decisions; they may not carry
policy. A native interactive Claude hook is same-UID input and can be forged by
the worker, so it is visibility evidence only, never completion or launch
authority. The native Claude TUI remains available on the historical
default-off lane, but it is ineligible for parity adoption; requesting
conformance enforcement on that lane fails closed. Installed/live workers do
not enter the new boundary until the supervised Claude print lane and Codex
host lane both pass root certification and section 8 is ratified.

The normalized event envelope is `qofi-swarm-event/v1` and contains only a
bounded timestamp, runtime, swarm/task/DR labels, event kind, state, and
content-free metrics or artifact references allowed for that event kind.
Claude transcript records and Codex exec/rollout JSONL records normalize into
that envelope at ingestion. Downstream stop delivery, roadmap derivation,
check-in validation, review gating, and grounding metrics accept normalized
events only and do not branch on runtime.

Where in-session prevention is necessary, the single adapter interface receives
an event and returns an allow/refuse decision with a policy reason. A future
supervised Claude process adapter and the Codex host-review boundary translate
their native inputs into this interface; native Claude hooks remain
non-authoritative visibility evidence. Codex repo command hooks remain
empty/disabled. Its manager refuses active-worker MCP review scope; the
host-owned terminal manager capabilities and harness task state provide the
required control without turning an editable repository into host execution
authority.

### 2. Stop means completion-gated and delivered-or-queued

The harness stop pipeline performs the Discord send. Agent-composed text is a
bounded summary input; a tool-use claim is not delivery evidence. Before
delivery, the pipeline requires a completion review artifact bound to the task
and reviewed diff. For managed Codex, a root lifecycle broker independently
consumes the exact manager receipt and owns the durable send/queue transition.
Absence or mismatch refuses the terminal transition and leaves the task in a
fail-closed cleanup or review-pending state; it never manufactures completion.

Delivery uses bounded retry with backoff. A successful Discord response is
recorded as `delivered`. Exhausted attempts first append an owner-private,
recoverable dead-letter record, then attempt a separate fallback escalation
that contains only swarm/task labels and the dead-letter reference. A durable
dead-letter is `queued` even if fallback notification is temporarily
unavailable. Failure to deliver *and* failure to durably queue refuses stop.
Every attempt and terminal outcome is appended to the private stop audit. A
worker is stopped only after `delivered | queued` is recorded.

This amends ADR-0010 by applying the same no-silent-drop principle to worker
completion, not just watcher relay traffic. The queue and audit contain no
provider token, account identifier, reviewed content, or raw prompt.

### 3. Proposed CTO check-in contract

Until ratified, the following is the implementation contract and is explicitly
marked proposed in rendered doctrine:

- **Request channel and addressee:** the watcher sends directly to exactly one
  bound CTO channel and mentions that channel's configured CTO bot identity.
  Delivery does not depend on the CPO agent choosing to forward a bus message,
  and a different loop cannot satisfy the request.
- **Response surface:** the named CTO replies in its bound CTO channel. The
  existing authenticated watcher relay places the response on
  `#cpo-cto-bus`, addressed to the CPO. A direct untrusted bus post is not a CTO
  check-in.
- **Shape:** one bounded `qofi.cto-checkin/v1` object with `ping_id`,
  `addressee`, `current_task`, `status`, `progress_since_last_checkin`,
  `blockers[]`, `next_action`, and boolean `needs_input`. `status` uses the
  standing state vocabulary
  `DRIVING | WAITING_FOR_OPERATOR | STOOD_DOWN`; `RATE_LIMITED` remains a
  watcher-derived overlay and `UNKNOWN` remains diagnostics, not self-reported
  state.
- **Evidence and validation:** the watcher binds the response to its outstanding
  ping and authenticated CTO channel identity, validates every field, and
  measures ping-to-valid-check-in latency. Empty progress/next action, unknown
  state, a bare acknowledgment, or an unchanged state heartbeat is invalid.
  Invalid/late replies cause a bounded re-ping followed by operator escalation.

Validation proves shape and provenance, not the truth of free-text progress.
Roadmap and completion state continue to derive from harness events and result
sets rather than the check-in's claims.

### 4. A derived living roadmap and phone-sized Discord views

The repository roadmap is a versioned artifact keyed by decision-record id.
Each item carries only its label, state-vocabulary status, owning swarm, last
activity time, artifact/result-set references, dependencies, and parity-matrix
link. The harness derives it with compare-and-swap updates from task start,
task finish, state transition, result-set landing, grounding metric, and review
events. Agents cannot manually edit it. An existing manually authored artifact
must be explicitly adopted by the operator before automatic derivation begins.

The event derivation, validation, same-owner CAS store, and display surfaces are
implemented. Privileged publication from root authority into an
operator-writable repository is deliberately unavailable: Bun does not expose
the required descriptor-bound `openat`/`renameat` commit, and reopening mutable
absolute child paths would permit a worker race. `RoadmapStore` therefore
hard-refuses cross-owner construction. A future fixed root helper must bind the
directory descriptor and revoke worker mutation for the entire publication;
until then scheduled repository publication stays off and no root boundary may
claim to have updated the living artifact.

On-demand roadmap output and the scheduled digest consume the same derived
document. Each renders short label/state lines: what moved, what is blocked,
what is next, and before/after grounding time. Prompt text, findings, tokens,
account identifiers, and credentials are prohibited. A digest scheduling
failure is observable and retried through the existing watcher delivery queue.

### 5. One adversarial review at the completion gate

ADR-0022's default trigger and budget paragraphs are superseded as follows.
An ordinary task receives exactly one adversarial review after implementation
and verification and before stop. A worker cannot invoke a mid-task review.
Doctrine owns the only exception classes: a change intersecting the immutable
standing-invariant registry or a configured security-sensitive path may receive
one early review. The harness—not the worker—classifies that exception. An
early verdict never replaces the completion verdict.

The installed App Server cannot prove that an in-session reviewer call is
semantically at task completion, so the manager refuses every active-worker
scope request and creates no artifact. After a proven successful terminal App
Server result, generation reap, hidden-runtime ACL revocation, and capture of
the exact final changed-file payload (or canonical no-change sentinel), the
daemon asks the manager to begin one lease-bound host review. The manager
derives swarm/profile/task/state/policy, invokes the fixed attested one-shot
Fable shim once, and retains the terminal lease through poll. The daemon then
releases the physical repository lease, and a fixed no-argv root broker resolves
the registered repository independently, consumes the opaque manager receipt,
and records `delivered | queued`; only then may manager `end` return the lease to
cleanup-pending. Duplicate begin and consume recovery are exact and idempotent,
never a second review. Missing reviewer authority or an unconsumed/mismatched
receipt fails closed.

The managed Claude and Codex lifecycle policies both set early review to
`disabled-no-trusted-boundary`. The legacy Claude companion command remains
outside that gate and cannot grant an exception. The exception classifier is a
tested future policy surface, not permission a worker or current adapter can
exercise. This is the parity-safe disposition required when no trusted control
point exists.

The reviewer queue admits one completion call per task by default. No current
exception path can consume or increase that budget. `review-unavailable`
remains explicit and never becomes approval. Provider timeout, rate-limit, auth,
or malformed-output failure persists that verdict and permits process reap while
roadmap/result truth remains `review-pending`; absence of its exact manager/root
receipt still refuses stop. This retains ADR-0022's advisory/no-merge-authority
rule while making host-owned artifact and delivery evidence a lifecycle gate.

### 6. Corpus-addressed context packs and grounding gaps

Each product has a deterministic context-pack cache containing a module map,
key-file inventory, standing-invariant registry, and named context references.
The cache is keyed to the full source-corpus Git commit; its inner pack also
binds the canonical named-ref descriptor and exact content hashes. Generation
is deterministic and occurs only when the corpus commit changes; changed bytes
under the same commit are a provenance failure, and task creation alone never
regenerates it. Warm-subagent preloads use this pack, and every task brief must
name the references required for that task. Workers consume available named
references before exploratory read/search operations.

The harness counts read/grep operations before the first substantive edit and
records grounding duration. If the configurable budget is exceeded, it
requires one bounded pack-gap result naming what the pack lacked, then permits
work to continue. A missing required ref similarly appears in that result and
does not deadlock the edit gate after all available named refs are read. Search
is not mandatory when the pack is sufficient; a configured nonzero search
minimum is supported for products that need it. A gap is evidence for the next
corpus-driven pack regeneration; it is not a worker-authored roadmap state.
Digests report aggregate grounding time before/after pack coverage without
prompt or source content.

### 7. Parity proof and divergence policy

The same fixture scenarios run through both adapters: stop without a bound
verdict/receipt is refused; a valid idle ping produces a schema-valid check-in; a bare
reply is rejected; grounding budget emits a gap; non-exception mid-task review
is refused; and embedded reviewer instructions remain untrusted data in both
review directions. Runtime upgrades must pass this conformance suite before
that runtime rejoins rotation. Launch is check-only: it cannot run the suite,
mint a receipt, or certify an unknown/changed CLI. The fixed root lifecycle
broker can validate a root-owned atomic Claude+Codex manifest, but a JSON
decision cannot bind the later same-UID execution across concurrent root
replacement. The current broker therefore always returns
`root-exec-wrapper-unavailable`; it never returns an allowed execution path.
A future fixed root wrapper must consume the manifest generation and execute an
already-opened binary. Native interactive Claude launch cannot consume that
proof. A missing wrapper, failed suite, changed, linked, or stale identity
quarantines launch before tmux exists.

Only a future explicit root runtime installer may certify. It must first
install and attest immutable bundle bytes, execute tests after dropping to the
registered operator or isolated service UID, and only then atomically publish
the root-owned manifest. Executing mutable checkout tests as root is forbidden.
The manifest will bind both executable identities and versions, every policy/
adapter/broker/wrapper/fixture byte used by the suite, and the shared
completion-receipt contract. The repository CLI exposes operator diagnostics
only, refuses root execution, and is never launch authority. No production
manifest minting path is implemented in this draft; enforcement remains off.

The proposed supervised Claude process runner is not shipped, and its
completion half is deliberately restricted as
`restricted-no-attested-exact-final-reviewer`. No root-attested invocation yet
reviews Claude's exact final bytes with Codex. A fabricated
`review-unavailable` artifact is not failure evidence and cannot satisfy the
gate. Claude certification therefore fails deterministically and the installer
cannot mint the atomic Claude+Codex pass manifest; Codex is not silently enabled
alone.

The repository parity matrix records capability, Claude status, Codex status,
enforcement layer, and evidence. A known-divergence register records every
unavoidable missing control point and its disposition. If the harness cannot
substitute safely, the capability is disabled for both runtimes or the affected
task class is restricted to the capable runtime. Silent asymmetry is forbidden.

`CLAUDE.md` and `AGENTS.md` compose from an identical ordered set of shared
doctrine fragments plus their runtime-specific routing material. Compose
verification compares the declared fragment trace and rendered shared bytes;
drift in either target fails verification.

### 8. Implementation and adoption boundary

This record is implemented and tested, not live:

- The Claude Stop adapter and harness-owned sender are present in the rendered
  template, but no installed project receives them until operator template
  sync. Its exact-final-input completion gate remains adoption-off until the
  legacy Claude-to-Codex artifact gains attested reviewed-byte provenance
  (KD-006).
- Codex daemon lifecycle integration requires the exact
  `CODEX_BRIDGE_HARNESS_ADOPTION=claude-codex-v1` contract plus canonical state
  paths. It defaults off and rejects partial activation. Even a manually
  created registration cannot bypass this boundary: the root broker checks the
  unpublished atomic lifecycle admission before consuming a manager receipt
  and currently refuses it.
- Watcher structured check-ins, roadmap queries, and scheduled digests have
  separate explicit booleans; all default false. Structured check-in adoption
  also requires every monitored CTO to bind a direct channel, delivery bot,
  and authenticated response identity.
- Context-pack generation and grounding accounting are library/policy surfaces;
  no current live transcript/rollout ingestion enables them.
- Runtime upgrade quarantine exists in the common launch wrapper, but
  `SWARM_RUNTIME_CONFORMANCE_ENFORCE` defaults to `0`; setting it to `1` with
  the current missing root exec wrapper fails closed.

Because KD-006 blocks symmetric exact-input provenance, the completion gate is
adoption-off for both runtimes. Enabling only the Codex gate would be the silent
asymmetry this decision forbids. Existing live Claude lifecycle and reviewer
behavior therefore remain unchanged until the operator ratifies and activates
the complete parity contract.

## Consequences

- Discord completion becomes a transport outcome with durable recovery, not a
  behavioral reminder. Disk failure can now block stopping, which is intentional:
  the system must not claim recoverability it failed to persist.
- Check-ins become useful and measurable, while roadmap truth remains protected
  from self-report. The proposed channel/addressee contract still requires
  operator ratification before activation.
- One host-owned completion review reduces shared reviewer pressure and produces
  a stable gate artifact. Security/invariant exceptions remain future-policy,
  bounded, and auditable rather than worker-selectable.
- Context packs trade a small corpus-change build cost for lower repeated
  search cost. Gap reports make missing preload coverage actionable.
- Codex native hooks remain disabled despite their apparent event parity. The
  shared harness and manager-owned reviewer boundary provide parity without
  expanding host authority.

## Verification contract

Tests cover stop delivery success, retry, dead-letter/fallback, private audit,
secret removal from both successful outcome and dead-letter bytes, and refusal
when neither delivery nor durable queue succeeds; strict check-in
validation, bare-ack rejection, escalation, and ping latency; deterministic
roadmap derivation from normalized task/state/result-set events and refusal of
unadopted manual content; completion refusal without the bound verdict/receipt,
active-worker review refusal with no artifact, terminal manager
begin/poll/consume/idempotent-replay/end binding, missing-reviewer and
liveness-timeout fail-closed behavior, future-policy doctrine-controlled early
admission, current-adapter early refusal, and ordinary per-task budget one;
corpus-hash pack reuse/regeneration, named-ref validation,
grounding budget trip, gap result, and grounding metrics.

The parity suite executes each required scenario through Claude and Codex
fixtures and compares policy decisions, not raw runtime event bytes. Compose
tests prove the identical shared-fragment trace and bytes for both rendered
doctrine targets. The parity matrix and divergence register are checked for
every implemented capability and linked from the derived roadmap.

Root-boundary tests additionally prove state-root ancestry rejection for a
linked leaf and worker-writable parent, hardblock lifecycle before manager
receipt consumption, kill and reap an attested coordinator process group on
timeout, preserve client timeout margin, refuse cross-owner roadmap
publication, and deny conformance without a descriptor-bound root exec wrapper.

Moving this ADR from draft to accepted and calling the behavior live requires
operator ratification of the CTO check-in contract, template sync/runtime
restart, a real delivered and forced-dead-letter stop shakedown, one scheduled
roadmap digest, and runtime conformance on a future installed supervised Claude
print runner plus the Codex host lane. Native Claude hook/TUI behavior cannot
supply that proof. Repository implementation and synthetic tests are not that
proof.
