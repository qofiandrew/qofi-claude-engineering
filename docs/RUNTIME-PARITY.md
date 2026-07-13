# Swarm runtime parity matrix

**Contract:** ADR-0023
**Installed target runtimes:** Claude Code 2.1.207; Codex CLI 0.144.1
**Rollout state:** implemented/tested locally; not live

`Harness` is the default enforcement layer. `Adapter` means a thin native-event
translation into harness policy. `Doctrine` informs the worker but is never the
compliance authority. “Implemented/tested” does not mean enabled: ADR-0023
adoption switches remain off for both runtimes until ratification and live
shakedown.

| Capability | Claude | Codex | Layer | Evidence |
|---|---|---|---|---|
| Normalized lifecycle ingestion | implemented/tested | implemented/tested | Harness + adapter | `swarm-harness/events.test.ts` |
| Completion review required before done | supervised runner not shipped; exact-final Codex reviewer absent, so completion certification is restricted; native TUI restricted | host-owned terminal manager review + root receipt implemented/tested; atomic adoption off | Harness + root broker | manager/daemon lifecycle tests, root-broker tests, completion-review policy tests, parity suite |
| Mid-task review refused | new lifecycle implemented/tested; adoption off; legacy manual lane is outside the gate | implemented/tested; manager refuses active-worker scope without an artifact | Harness + reviewer boundary | completion-review policy tests, manager terminal-capability tests, parity suite |
| Reviewer injection remains untrusted data | implemented/tested | implemented/tested | Reviewer terminal shim | Claude-review and Fable-reviewer fixtures, parity suite |
| Stop summary Discord delivery | supervised runner not shipped; completion remains restricted before delivery; raw native hook is non-authoritative | implemented/tested daemon coordinator; atomic adoption off | Harness | `swarm-harness/stop-delivery.test.ts`, runtime integration tests |
| Stop delivery retry/dead-letter/audit | implemented/tested | implemented/tested | Harness | `swarm-harness/stop-delivery.test.ts` |
| Idle ping structured check-in | implemented/tested; watcher flag off | implemented/tested; watcher flag off | Harness + adapter | `swarm-harness/checkin.test.ts`, watcher coordinator tests, parity suite |
| Bare idle acknowledgment rejected | implemented/tested | implemented/tested | Harness | `swarm-harness/checkin.test.ts`, parity suite |
| Derived roadmap and digest | derivation/display/same-owner CAS tested; watcher flags off; privileged repo publication restricted | derivation/display/same-owner CAS tested; watcher flags off; privileged repo publication restricted | Harness | roadmap cross-owner refusal, event-store, watcher coordinator tests |
| Corpus-commit-addressed context packs | implemented/tested | implemented/tested | Harness | `swarm-harness/product-context-cache.test.ts`, product-context-pack tests |
| Grounding budget and gap result | implemented/tested; adoption off | implemented/tested; adoption off | Harness + adapter | grounding-budget and product-context-pack tests, parity suite |
| Shared doctrine fragment trace | implemented/tested | implemented/tested | Doctrine render + verifier | doctrine-compose and parity tests |
| Root-certified upgrade-before-rotation conformance gate | supervised runner/reviewer/root exec wrapper absent; native TUI fails closed | diagnostic suite tested; atomic manifest and root exec wrapper absent; launch admission fails closed | Root broker design + operator diagnostics | root-broker hardblock/reap/ancestry tests, `swarm-harness/runtime-conformance.test.ts`, `tests/test-runtime-conformance-launch-gate.sh` |

## Known-divergence register

| ID | Surface | Divergence | Disposition |
|---|---|---|---|
| KD-001 | Command hooks | Raw Claude hook payloads are same-UID forgeable; Codex 0.144.1 hooks execute outside the tool sandbox and require separately trusted mutable definitions. Neither is lifecycle authority. | Codex repo hooks remain empty and `hooks` stays disabled. A future Claude enforcement lane must use a root-assigned, harness-supervised `claude -p` process; native hooks are visibility evidence only. |
| KD-002 | Lead UI | Claude is a long-lived native TUI. Codex Discord work is manager/App-Server supervised and its operator TUI is a filtered facade. | Visibility comes from normalized state/result artifacts for both. The native Claude TUI remains historical/default-off and cannot join governed parity tasks; UI presentation is never lifecycle evidence. |
| KD-003 | Delegation/Git | Claude Agent Teams use isolated teammate worktrees. Codex supervised delegates share one checkout and cannot use the Claude Git lifecycle. | Overlapping-writer/autonomous merge task classes remain restricted; the Codex broker/operator handoff in ADR-0019/0020 applies. |
| KD-004 | Credential scope | Claude device OAuth is machine-global. Codex homes and leases are per swarm/profile. | Reviewer budgets serialize device-global Claude use; Codex rotation stays per swarm. No adapter claims credential parity. |
| KD-005 | Native transcript format | Claude emits transcript JSONL; Codex emits exec and rollout JSONL with different event names and shapes. | Both are translated into `qofi-swarm-event/v1`; downstream consumers are runtime-blind. |
| KD-006 | Completion-review provenance | The existing Claude -> Codex companion v1 artifact does not attest the reviewed bytes. Managed Codex -> Fable now uses a host-owned terminal phase: successful App Server terminal result, generation reap, ACL revocation, exact host snapshot, one manager invocation, and root-broker receipt consumption. Active-worker calls are refused. | Codex provenance is implemented/tested, but the completion gate remains adoption-off on both runtimes until the supervised Claude direction has attested exact-input provenance and both live adapters pass the same root-certified shakedown; native Claude hooks do not substitute and neither side receives silent approval. |
| KD-007 | Early-review boundary | Neither installed adapter exposes a symmetric trusted signal that can grant a doctrine exception at the right in-session boundary. | Early review is disabled on both current adapters. The tested exception classifier is future policy only; workers cannot self-grant it. |
| KD-008 | Privileged roadmap publication | Root lifecycle state and an operator-writable repository have different owners; Bun lacks descriptor-bound `renameat` publication and mutable child-path reopening is raceable. | Cross-owner `RoadmapStore` construction is hardblocked for both runtimes. Derivation/display remain testable; repository publication waits for a fixed root helper that binds the directory descriptor and revokes worker mutation through commit. |

Any new divergence must be registered before one runtime is enabled. If a safe
harness substitute does not exist, disable the capability on both runtimes or
restrict the affected task class explicitly.
