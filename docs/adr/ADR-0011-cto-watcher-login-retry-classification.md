# ADR-0011 — cto-watcher: initial-login retry with transient/terminal classification

**Status:** accepted
**Date:** 2026-06-13
**Reversibility:** two-way (control-flow change; no persistent surface).
**Escalated:** yes (blocking) — operator-prompted; ratified before merge.

---

## Context

The cto-watcher's initial Discord login treated **every** failure as fatal:

```js
client.login(TOKEN).catch((err) => { console.error(`[fatal] login failed…`); process.exit(1); });
```

On a **transient network failure at startup** — a captive-portal
`getaddrinfo ENOTFOUND discord.com`, or a wifi-portal **cert-altname mismatch** —
this exits. pm2 then restarts every 5s (`restart_delay`) and burns toward
`max_restarts: 50`, after which **pm2 stops restarting and the watcher is
permanently dead** until a manual `pm2 restart`. discord.js's own gateway
auto-reconnect (`ShardReconnecting`/`ShardResume`, already wired) only engages
**after a successful initial login**, so the captive-portal case had **no
in-process recovery**. (Evidence: `cto-watcher-error` log, 2026-06-10.)

A relay daemon must survive a network blip at startup by waiting, not by dying.
But the opposite failure is just as important: a genuinely **bad token** must
still crash loudly so the operator learns the token is wrong — it must never loop
silently forever.

## Decision

**We will retry the initial login on clearly-network errors with capped backoff
and no terminal ceiling, and crash loud on auth/config — and any UNKNOWN —
errors.** Implemented as `cto-watcher/login.js`:

1. **Transient/terminal classification policy** (`isTransientLoginError`, a pure
   exported function — same pattern as `queue.js`'s `defaultIsRetryable`):
   - **TRANSIENT (retry):** clearly-network errors only — `ENOTFOUND`,
     `ECONNREFUSED`, `ECONNRESET`, `ETIMEDOUT`, `EAI_AGAIN` (by `err.code` or in
     the message), abort/timeout, and captive-portal cert interception (message
     matches `altnames`/`certificate`).
   - **TERMINAL (crash):** auth/config errors — `TokenInvalid`/`TokenMissing`/
     `DisallowedIntents` by code, or a message indicating an invalid token /
     disallowed intent — **and everything else.**

2. **Conservative default-to-terminal rule (the load-bearing discipline):** only
   errors that are *clearly* network are transient. **Any unknown/unclassified
   error defaults to TERMINAL.** When unsure, crash. A misclassified bad token
   must still bring the process down so the operator learns it's wrong — never
   loop forever on a mystery error. This matches the swarm-system's fail-loud
   doctrine.

3. **Backoff:** capped exponential — attempt 1 → 5s, 2 → 10s, 3 → 20s, 4 → 40s …
   doubling, **capped at 300s**. The transient path has **no terminal ceiling**
   (prod `maxAttempts = Infinity`): a network gone for an hour resolves by
   waiting, not by dying. A finite ceiling exists only as an injectable test seam.

4. **`ecosystem.config.cjs` is unchanged.** `autorestart` / `max_restarts: 50` /
   `restart_delay: 5000` remain correct for genuine crashes — this fix just stops
   a transient network blip from *counting* as a crash.

The classifier and backoff are pure functions; the retry loop is
dependency-injected (`login`, `sleep`, `onTerminal`), so all of it is unit-tested
without a live Discord client (`login.test.js`).

## Reversibility & cost of change

Two-way. Reverting restores the one-line exit-on-failure login; there is no
persistent state or data format to migrate. The only judgment surface is the
classifier's transient set — additive and revertible.

## Consequences

- **Easier:** a captive-portal / DNS / cert blip at startup self-heals by waiting
  instead of exhausting pm2's restart budget and dying permanently.
- **Harder / accepted costs:** if the classifier ever mislabels a *terminal*
  error as transient, the watcher would retry it forever — which is why the
  default is terminal and the transient set is deliberately narrow (fail loud on
  doubt). A genuinely bad token still crashes immediately and loudly, unchanged.
- **Committed to:** the classification policy + the conservative default are now
  documented behavior; widening the transient set is another decision.

## Alternatives considered

- **Raise pm2 `max_restarts`** — rejected: it doesn't distinguish a transient
  network blip from a real crash-loop, still treats a blip as a crash, and only
  delays the permanent-death failure mode.
- **Retry *all* login errors** — rejected: a bad token would loop forever and
  silently, hiding a misconfiguration; violates fail-loud.
- **Status quo (exit on any failure)** — rejected: the bug under repair.
