# ADR-0010 — cto-watcher relay: overflow-to-attachment, retry classification, and dead-letter persistence

**Status:** accepted
**Date:** 2026-06-13
**Reversibility:** two-way (code/behavior is revertible) — but the dead-letter introduces a **data-at-rest** surface, which is the decision-class part below.
**Escalated:** yes (blocking) — operator-prompted; ratified before merge.

---

## Context

A production relay delivery (`CTO->bus src="reserve-backend-2"`) failed and was
dropped. Two stacked defects:

1. **Overflow.** The cto-watcher relay posts message bodies straight into
   Discord's `content` field, which has a hard **2000-character** cap. Any
   relayed message over 2000 chars is undeliverable — Discord rejects it with
   `Invalid Form Body content[BASE_TYPE_MAX_LENGTH]`. There was no chunking, no
   overflow handling anywhere in the watcher.
2. **Indiscriminate retry + lossy drop.** The in-flight `DeliveryQueue` retried
   **every** failure up to 4 attempts, including this *deterministic* 400 — four
   guaranteed failures — then surfaced an operator DM ("re-send by hand") that
   **did not preserve the message body anywhere**. A deterministic error is not
   retryable, and a drop that loses the content is a silent data loss dressed up
   as a notice.

The gap is in the **shared** `relay()`/`relayMessage()` path, which serves *both*
`shuttle` (CTO→bus) and `route` (bus→CTO, i.e. the CPO-over-bus relay). It is
systemic across every watcher relay direction. (The bridge's own MCP `reply`
tool already chunks; it is a separate path and unaffected.)

A non-obvious constraint shaped the fix: the **mention prefix** (`<@id> `) the
relay prepends is what triggers the recipient bot to act. Splitting an over-cap
body into N `content` messages would either lose that trigger or fire the
recipient N times. And recipients do **not** auto-inline attachments — the bridge
lists an attachment's metadata and the recipient must call `download_attachment`
to read it (`bridge/server.ts`); this is the same mechanism the §Message-length
"long → file" convention and the existing `.md`/`.txt` shuttling already rely on.

## Decision

**We will deliver an over-cap relay body as a `.md` file attachment (not chunked
content), classify retries by error determinism, and persist any terminally-
undeliverable message to a recoverable, secret-grade dead-letter file.**

Concretely:

1. **Overflow → attachment, at the shared relay choke point** (covers both
   directions). When the body (counting the mention prefix) exceeds the 2000-char
   `content` cap, the relay posts a **carrier message** with the full body
   attached as `relay-overflow-<ts>.md`. The carrier is, in order:
   - the **mention** (so the single trigger is preserved — one mention, one fire);
   - an explicit **instruction**: *"full body attached as `<name>` — call
     `download_attachment` then Read it"*;
   - a **head excerpt** of the body (so an unfetched message still delivers the
     gist and is meaningful in scrollback — not an opaque `(attachment)`);
   - an explicit **truncation marker**.
   The excerpt is **budgeted against the real 2000 ceiling with the mention +
   instruction + marker counted first** (a long mention or long filename shrinks
   the excerpt rather than overflowing), so the carrier itself can never recreate
   the 400. Chunking is deliberately **not** used.

2. **Retry classifier** (`defaultIsRetryable`, pure, injected into the queue):
   - **Deterministic client errors** — 4xx other than 429 (incl. **400**
     BASE_TYPE_MAX_LENGTH and **413** payload-too-large) — are **terminal**: tried
     once, never retried, routed straight to the dead-letter.
   - **Transient errors** — 429, 5xx, and errors with no HTTP status
     (network/timeout/abort) — **retry with backoff** as before.

3. **Dead-letter on terminal failure** (in addition to the existing operator DM):
   the full job (`channelId`, `body`, `mention`, `label`, `error`, `attempts`,
   `ts`) is written to a recoverable file. **Data-at-rest hygiene, per §Secrets**
   (relay bodies can carry sensitive content — same tier as `tokens.env`):
   - **Location:** `cto-watcher/.deadletter/<ts>-<label-slug>-<rand>.json`
     (one file per dropped delivery; co-located with the watcher).
   - **Permissions:** each file **chmod 600**; the directory `0700`.
   - **Gitignored:** `.deadletter/` is in `cto-watcher/.gitignore` — never committed.
   - **Retention:** **operator-cleared.** No auto-prune in v1 — a dropped
     delivery already paged a human (the DM), and the file persists until the
     operator reads and deletes it. (Revisit only if volume ever makes manual
     clearing impractical.)

## Reversibility & cost of change

Two-way. The overflow and classifier are pure functions + queue wiring — revert
is a code change. The dead-letter is the only persistent surface: reverting it
means deleting the writer and any `.deadletter/` files; the format is internal
(consumed by a human, not a program), so there are no downstream consumers to
migrate. The data-at-rest decision is what makes this decision-class, not the
control flow.

## Consequences

- **Easier:** no relay message is undeliverable for length; the recipient still
  gets one mention/one trigger plus an inline gist; a deterministic failure no
  longer burns 4 attempts; a terminal drop's content is recoverable, not lost.
- **Harder / accepted costs:** an over-cap message now requires the recipient to
  fetch the attachment to read the *full* body (mitigated by the inline head
  excerpt; consistent with the existing long→file convention). The dead-letter is
  a new at-rest surface the operator must periodically clear, and which must keep
  its 600/gitignore hygiene (now test-enforced).
- **Committed to:** the carrier shape and the dead-letter location/perms/retention
  are now documented behavior; changing them is another decision.

## Alternatives considered

- **Chunk into N ordered `[i/n]` content messages** — rejected: the mention
  trigger would be lost or fire the recipient N times, and re-fencing code blocks
  across chunks is fragile. The file approach keeps one mention/one trigger.
- **Keep retrying all errors** — rejected: a deterministic 400/413 fails
  identically every time; retrying is four guaranteed failures and delays the
  dead-letter.
- **Operator-DM only (status quo)** — rejected: it surfaces the drop but loses
  the body; "re-send by hand" is impossible if the operator never had the content.
- **Auto-prune the dead-letter** — deferred: unnecessary at current volume and
  risks deleting an unread failure record; operator-cleared is simpler and safe.
