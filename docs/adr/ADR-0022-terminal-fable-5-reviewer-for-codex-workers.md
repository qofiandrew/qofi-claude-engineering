# ADR-0022 — Expose Claude Fable 5 as a terminal adversarial reviewer to Codex workers

**Status:** draft — implemented and tested locally; not live
**Date:** 2026-07-13
**Depends on:** ADR-0020's root-attested App Server and ADR-0021's per-swarm
profile lease/task boundary.

## Context

Claude-authored work already has a foreign-model contrarian lane backed by
Codex. Codex-authored work needs the symmetric capability, but an active worker
cannot prove that its own invocation occurs at the controlled completion
boundary. The managed host must therefore ask Claude Fable 5 exactly once after
the worker's successful terminal result and review a bounded, host-captured
final payload. Registering `claude mcp serve` would be the wrong boundary
because it would expose a full Claude session and its tool surface.

The installed Claude Code 2.1.207 accepts the exact model identifier
`claude-fable-5`. In print mode, the reviewed material can be supplied on stdin
while the reviewer doctrine remains a separate system prompt. The relevant
lockdown is `--tools ""`, `--strict-mcp-config` with an empty server map,
`--permission-mode dontAsk`, `--disable-slash-commands`,
`--no-session-persistence`, and `--safe-mode`. The device-auth lane must not use
`--bare`, because that disables its OAuth/Keychain lookup; the API-key lane may
add `--bare`. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` suppresses unrelated
ancillary model traffic.

The installed Claude-to-Codex plugin predates the requested portable contract.
Its raw v1 result is `{verdict, summary, findings, next_steps}`, with verdicts
`approve | needs-attention` and findings shaped as
`{severity,title,body,file,line_start,line_end,confidence,recommendation}`. The
canonical cross-runtime result is therefore versioned as
`qofi-adversarial-review-output/v2`, and a deterministic compatibility adapter
maps that legacy result into v2 before comparison or artifact intake. The
adapter is a production boundary, not a test helper:
`bin/qofi-review-normalize.py run` invokes the installed companion in its
supported foreground JSON mode, while `ingest` consumes a previously exported
plugin result/job JSON. Both write a private
`qofi-legacy-codex-review-artifact/v1` sidecar whose nested result is v2. Raw v1
and v2 payloads must never be described as byte- or schema-identical.

## Decision

1. A root-installed Python shim exposes exactly one MCP tool,
   `adversarial_review(diff_or_files, context_refs, mode)`, and a fixed
   manager-only one-shot stdin mode over the same reviewer implementation. It
   accepts bounded text and named context only; it cannot open the repository.
   MCP initialize advertises the terminal nature of the server, `tools/list`
   returns only that tool, and every unknown tool or recursive invocation
   attempt is refused. The MCP registration remains byte-identical in every
   managed home, but an active worker's scope request is always refused and
   creates no artifact.
2. The hidden Codex runtime can start only the compatibility MCP shim through
   one exact sudo capability: runtime UID to the attested operator UID for
   `/usr/bin/python3 -I -B /usr/local/libexec/qofi-fable-reviewer-mcp.py`.
   That lane cannot acquire active-turn scope. The trusted manager launches the
   same attested file itself with fixed argv, `--one-shot --parent-fd 3`; no
   worker supplies an argv component. There is no shell, wildcard argument,
   general operator impersonation, credential copy, or repo/path/profile/task
   selector. The installed shim, doctrine, and schema are root-owned,
   mode/hash-attested files.
3. Each profile home receives a byte-identical rendered `config.toml` containing
   only `[mcp_servers.fable_reviewer]`, `required = true`, and the single enabled
   tool. Production App Server turns adopt that home-level configuration, while
   the manager's active-scope refusal ensures discovery is not invocation
   authority. Project MCP configuration remains refused. The internal Codex
   review lane continues to ignore user config and explicitly disables MCP,
   which makes a Codex -> Fable -> Codex review cycle mechanically unavailable.
4. In its trusted one-shot lane, the shim starts
   `claude -p --model claude-fable-5 --output-format json --json-schema ...`
   with the lockdown above. The repo-controlled doctrine is the system prompt;
   an envelope containing the diff/files, context references, and mode is sent
   only on stdin as untrusted data. Only `structured_output` is accepted, and
   process exit status plus Claude's `is_error` state are checked independently.
   A forked supervisor owns Claude's process group and the global invocation
   lock. A manager-liveness pipe plus the supervisor control pipe make manager
   loss, shim EOF, SIGTERM, and SIGKILL trigger bounded TERM-then-KILL cleanup of
   Claude and all descendants before another invocation can acquire that lock.
   Absence of the external Claude executable does not make the required MCP
   registration unavailable at Codex startup. A worker call remains a refused,
   artifact-free `review-unavailable`; a missing or changed installed reviewer
   at the trusted host boundary fails the manager closed without a receipt.
5. The v2 result has verdict
   `approve | needs-changes | block | review-unavailable` and findings
   `{severity,locus,claim,evidence,suggested_test}`. Approvals must name both
   what was and was not checked. Findings must be falsifiable and evidence
   based. A verdict is advisory input to ratification; it grants no commit,
   merge, push, or gate authority.
6. The manager's local `/v1/reviewer/scope` endpoint validates its peer and then
   always refuses active-worker calls; it returns no slot or artifact scope. A
   successful terminal App Server result first reaps the generation. The daemon
   then revokes the hidden runtime's per-turn ACLs and captures the exact final
   named-file payload, or the canonical no-change sentinel, while still holding
   the physical repository lease. Only then may it call the manager's
   lease-bound `begin` capability with the exact payload hash. The manager
   revalidates registration and lease, mints one opaque completion capability,
   derives swarm/profile/task/private state and policy itself, and invokes the
   fixed one-shot shim once. Duplicate exact `begin` calls return the same
   capability and never launch a second reviewer. `poll`, root-only `consume`,
   and `end` all bind that capability to the same registration and terminal
   lease. The manager retains the terminal lease and blocks cleanup throughout.
   Timeout or malformed/missing host-runner output moves it to an ambiguous
   fail-closed state instead of reopening the worker.
7. `fable-reviewer.json` controls a default or per-swarm auth lane, timeout, and
   budgets. Defaults are device auth, one ordinary completion call per task and
   twelve calls per one-hour window. Calls are serialized FIFO. Window
   exhaustion waits in the queue for the next budget window instead of being
   dropped; the per-task cap remains a hard bound. Policy windows are capped at
   one hour. The manager's terminal-review capability deadline is the configured
   window plus provider timeout and a fixed cleanup margin, and the managed
   Codex turn defaults to 75 minutes so one full queue wait plus the maximum
   ten-minute review and cleanup margin remain inside the normal boundary.
   The private budget ledger is versioned, migrates its v1 form, and retains a
   4,096-entry explicit task LRU so parked A/B/A task interleaving cannot reset
   A's per-task cap. Each task/profile scope admits at most 32 ordinary review
   artifacts plus one stable upserted budget sentinel; repeated exhausted or
   budget-error retries cannot crowd out an earlier block verdict.
8. Device auth deliberately uses Claude Code's device-global login and shares
   burn with all Claude swarms on the machine. The optional
   `anthropic-api-key` lane obtains its secret only for the child process and
   never places it in argv, artifacts, logs, Discord, or the Codex environment.
   This lane decouples reviewer burn but may create metered spend, so enabling it
   remains an explicit operator policy choice.
9. Provider timeout, rate limit, auth failure, and malformed provider output
   return and persist `review-unavailable`. The configured and only supported
   failure policy is `review-pending`: the worker remains terminal and may be
   reaped, but result/roadmap truth remains pending and the result is never
   rewritten as approval. Missing, changed, unlaunchable, timed-out, or malformed
   fixed host reviewer authority is different: it produces no manager receipt,
   moves the manager to ambiguous, and fails completion closed.
   Both canonical Fable output and normalized legacy output are rejected if
   they contain credential-like material. Rejection returns or records an
   unavailable result without reflecting the suspect bytes into MCP responses,
   artifacts, logs, or Discord.
10. The single host call writes an owner-private artifact beside the run result metadata:
    swarm/profile/task labels, mode, exact reviewed-input SHA-256, model, time,
    and the v2 result. The root lifecycle broker independently resolves the
    swarm's repository from its root registry, binds to the manager socket and
    admission identity, consumes the exact manager receipt using only the opaque
    completion capability plus task id, and durably records/delivers the stop
    outcome. Only after `delivered | queued` may the manager `end` capability
    return the lease to cleanup-pending. A `block` verdict announces on Discord
    using swarm and profile labels only; findings, reviewed content, account
    identifiers, and secret material stay local.
    This is the implemented target protocol, not a live authority claim: the
    root broker currently refuses lifecycle admission before receipt
    consumption because the atomic two-runtime conformance publisher and fixed
    root exec wrapper are absent. Manager protocol tests exercise the boundary;
    production adoption remains off.
11. The reverse, pre-existing Claude -> Codex plugin keeps its raw v1 jobs
    unchanged. Qofi's wrapper normalizes a successful v1 job/result into the
    same canonical v2 result contract and stores it under
    `~/.claude/qofi-review-result-sets/<repository-key>/`. The plugin does not
    expose an attested hash of the exact diff bytes it reviewed, so the legacy
    sidecar records `reviewed_diff_sha256: null` and
    `provenance_status: unavailable-legacy-plugin`. It never recaptures mutable
    repository state to manufacture provenance. Plugin or normalization
    failure remains loud advisory-down and can never become approval.
12. Review timing is a runtime-blind harness policy, not a prompt convention.
    Every task receives exactly one default completion review after substantive
    work and tests but before `stop` or `done`. On Codex, the trusted boundary is
    structural: proven successful terminal App Server result, generation reap,
    hidden-UID ACL revocation, exact host snapshot/material derivation, manager
    one-shot completion review, root-broker receipt consumption and durable
    delivery, then manager `end` and cleanup. A terminal transition without that
    canonical receipt is rejected. `review-unavailable` remains an
    artifact-backed `review-pending` result rather than approval. All active or
    mid-task worker calls are refused without an artifact. The pure
    standing-invariant/security exception classifier remains tested future
    policy only; neither installed runtime adapter has authority to exercise it.
    The manager and Python queue enforce the one-call default before durable
    budget charge. The exact final-input hash and artifact SHA-256 are carried in
    the manager-bound receipt; the daemon cannot supply a reviewed path, verdict,
    profile, or repository to the root broker.
13. Product grounding is bound to a deterministic product-context-pack cache.
    The cache key is the full source-corpus Git commit. Its inner pack separately
    binds the SHA-256 of the canonical ordered corpus descriptor, whose entries
    bind each named ref, repo-relative path, exact content hash, and byte count.
    A task brief must name at least one ref and the expected corpus hash. Before
    the first substantive edit, the harness requires one bounded read of every
    named available ref. Search is counted but defaults to no mandatory minimum;
    products may configure a nonzero minimum. Missing refs, unread available
    refs, configured search shortfall, or grounding-budget overrun require one
    stable sorted pack-gap report and content-free metric events, after which
    work proceeds. Primary preload order and warm-subagent context are generated
    deterministically; warm output with a different corpus hash or named-ref set
    is discarded rather than silently mixed into the task. Unchanged commits
    reuse exact bytes; changed bytes under the same commit fail provenance.

## Consequences

- Codex gains a first-class host-owned foreign-model completion challenge
  without giving an active worker a general bridge into Claude Code.
- The device lane is operationally simple but shares one machine-global Claude
  credential. Budgets serialize and limit pressure; they do not create account
  isolation. The API-key lane provides quota isolation at the cost of an
  explicitly governed billing path.
- A provider review failure is a visible, recoverable `review-pending` result.
  Loss or mismatch of the fixed host reviewer/broker authority blocks cleanup;
  neither failure can become silent success.
- Review timing and product grounding can be evaluated identically for Claude or
  Codex event streams. The policy modules are runtime-blind; repository tests do
  not claim the live daemon has adopted them.
- The classic direct-exec compatibility path continues without the Fable MCP;
  first-class reviewer support belongs to the managed, root-attested App Server
  path.

## Verification contract

Tests cover exact one-tool MCP discovery plus active-worker scope refusal with
no artifact, fixed one-shot manager invocation, a fixture diff producing a
v2-valid verdict, prompt injection inside reviewed data, production legacy-v1 job/result
ingestion into a private canonical-v2 sidecar with explicitly unavailable diff
provenance,
timeout/auth/rate-limit degradation to `review-unavailable`, recursive/unknown
tool refusal, FIFO window-budget waiting, v1-to-v2 budget migration, durable
per-task exhaustion across A/B/A interleaving, terminal-lease scope derivation,
one-shot manager-loss process-group reap, byte-identical profile-home configuration, root-file/sudoers
attestation, task/profile-bound artifact intake and diff hash provenance, a
two-attempt same-task profile-rotation simulation, same-profile delta intake,
task-budget preservation across rotation, active-worker and stale-scope refusal, crash/kill
descendant reaping with lock retention, credential-output rejection, redacted
block notification, continued MCP disablement in the internal Codex review
lane, completion-without-receipt refusal, exact begin/poll/consume/replay/end
capability binding, current-adapter early-review refusal,
future-policy one-exception-plus-completion cardinality, deterministic corpus
commit caching and content-hash tamper rejection, named-ref/budget gap reporting,
pre-edit grounding, and byte-stable primary/warm-subagent preload doctrine.

Moving this ADR from draft to accepted and calling the feature live requires an
operator-run privileged runtime reinstall plus a real managed Codex -> Fable
review shakedown. Adoption also stays off until the supervised `claude -p`
direction has equivalent exact-final provenance and both halves pass the same
root-certified conformance run; native Claude hooks are not authority for that
proof. Repository implementation and synthetic tests alone are not that proof.
