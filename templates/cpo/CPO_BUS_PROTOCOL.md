# CPO ↔ CTO bus protocol

You (the CPO) reach the engineering CTOs through the shared **bus** channel
(`#cpo-cto-bus`). In **AUTO** mode an automated relay (`cto-watcher`) shuttles both
directions; in **MANUAL** mode the operator relays by hand. You never post in a
CTO's own channel. **Everything-in-bus**: directives, STATE declarations, watcher
revival pings, and shuttled CTO traffic all share this one channel — there is no
separate state channel.

> **Register.** The bus puts you in **CTO register** — driver, gated, silent by
> default (trigger-gate, anti-loop terminator, per-CTO state machine in
> `CLAUDE.md` §"The CTO loop"). #qofi-product is the separate **operator register**
> (conversational). This file is the wire protocol; the behavioral law lives in
> `CLAUDE.md`.

## The two rigid grammars (the watcher is a dumb, deterministic parser)

Everything you send on the bus is one of exactly two shapes. A message matching
neither carries no meaning to the watcher (not a directive, not a state signal,
not a timer reset) — never rely on prose to communicate with it.

### 1. DIRECTIVE — drive a CTO

```
[<cto-name>] <the directive>
```

- `[<cto-name>]` — destination, an exact key from the `ctoChannels` map (authority
  below). (No `@mention` needed — routing is by author + grammar. The watcher adds
  the destination CTO's mention on delivery.)
- `<the directive>` — **just the directive, nothing else.** The clean instruction
  the CTO acts on: no preamble, no narration, no "I'm going to have cto-7…", no
  operator-facing status, no meta. Operator context belongs in #qofi-product.
- Everything after `[name] ` is delivered to that CTO verbatim.

**Valid `<cto-name>` (exact, case-sensitive) — authority: `cto-watcher/config.json`
`ctoChannels`.** The roster is **not** restated here: the single source of truth
is the `ctoChannels` map in `cto-watcher/config.json` (seeded from `swarm.conf`),
the *exact* map the watcher routes against. Use a key from that map verbatim — it
is case-sensitive. A name absent from `ctoChannels` fails closed (see *Rules that
keep this safe*). Adding or removing a CTO is an operator config change to
`swarm.conf` → `ctoChannels` (via `bin/swarm-add.sh`), never a doc edit. (See
ADR-0014: doctrine points to the routing config, it never duplicates it.)

Example:

```
[qofi-ios-app] Bump the minimum deploy target to iOS 17 and confirm CI is green before merging.
```

### 2. STATE — declare/maintain a CTO loop's state (never shuttled)

```
STATE: <cto-name> DRIVING
STATE: <cto-name> WAITING_FOR_OPERATOR
STATE: <cto-name> STOOD_DOWN
```

- Exact enum spelling. **State described in prose is NOT a declaration** — the
  watcher acts as if no transition happened.
- **Declare before acting** (HARD LAW): emit the STATE line BEFORE changing what
  you do on that loop. A message may carry several STATE lines (one per CTO).
- **Heartbeat = re-emit current state — NOT a revival-ping answer.** A bare
  `STATE: <cto-name> <its-current-state>` re-emit (e.g. `STATE: cto-7 DRIVING`) is
  true, resets that loop's clock, and changes nothing — valid only while you are
  **actively driving** that loop (maintaining a state you already evaluated), never
  as the answer to a revival ping. A heartbeat is emitted **because** you're
  driving, not **instead** of driving. On a ping see §*Liveness* below: the answer
  is a driving action or a real transition, never a bare re-emit. There is **no**
  freeform "still working" — the watcher can't read prose.

## Reading what a CTO says back

In AUTO, CTO messages arrive on the bus from the watcher, prefixed with the
originating CTO's name (and @mentioning you):

```
[reserve-backend-2] Migration applied on staging; awaiting your go for prod.
```

Treat any bus message prefixed `[<name>]` from the relay (AUTO) or the operator
(MANUAL) as that CTO speaking. Your own directives are not echoed back.

## Rules that keep this safe

- **Exact names only.** A name not in `cto-watcher/config.json` `ctoChannels`
  fails closed — the watcher does not route it, logs the miss, and DMs the
  operator. You cannot invent CTO names; adding one is an operator config change
  (`swarm.conf` → `ctoChannels`).
- **DIRECTIVE before noise.** If a message contains a STATE line it is treated as
  state and never shuttled, so a STATE line can never leak into a CTO channel.
- **One directive per message**, directive-only body (see grammar 1).
- The watcher ignores its own messages and anything not authored by the CPO bot —
  a stray human post on the bus is not routed.

## Liveness (AUTO only)

If a DRIVING loop's bus traffic goes quiet past the watcher's threshold, the
watcher posts a revival ping on the bus (@mentioning you, naming the CTO). Answer
by **resolving the loop per the revival-loop guard**: re-read that CTO's next
drivable step and either issue the next directive (a real driving action) or make a
real transition to WAITING_FOR_OPERATOR. A bare heartbeat re-emit
(`STATE: <name> DRIVING` unchanged) is **NOT** a valid ping answer — that is the
"silent-DRIVING" the guard forbids. It never pings WAITING_FOR_OPERATOR or
STOOD_DOWN loops. **You never wait on the ping** — a DRIVING loop with nothing to
push self-resolves to WAITING_FOR_OPERATOR and surfaces to the operator (see
`CLAUDE.md` §"The liveness guarantee is YOUR discipline").

**Usage-limit pauses (RATE_LIMITED) — handled for you.** When a CTO's swarm hits
its Claude usage / 5-hour limit it goes silent because it is *throttled*, not
stuck. The watcher detects this out-of-band (it does **not** come from your STATE
lines — it's not a fourth state you declare), stops pinging that loop, and waits
for the cap to clear. You do **not** re-drive a capped loop; a directive can't be
acted on while throttled. When the cap clears and the loop didn't auto-resume, the
watcher posts a **resume nudge** (`▶️ … usage limit cleared — resume driving`,
@mentioning you, naming the CTO). Treat it exactly like a revival ping: re-read
that CTO's next drivable step and resolve to a definite state — issue the next
directive (`STATE: <name> DRIVING` + the directive) or `WAITING_FOR_OPERATOR` if
there's nothing left to push.
