// liveness.js — per-CTO state + silence store for the AUTO-mode revival monitor.
//
// Pure: no discord.js, no real timers, no Date. index.js feeds it (state from
// parsed STATE lines, timer resets from CTO-channel activity and bus directives)
// and calls tick(now). It decides which DRIVING-but-quiet loops to ping.
//
// State changes ONLY from parsed STATE lines (never inferred from traffic).
// A CTO is pinged ONLY while DRIVING and silent past the threshold;
// WAITING_FOR_OPERATOR, STOOD_DOWN, and UNKNOWN are never pinged.
//
// USAGE-LIMIT OVERLAY (RATE_LIMITED). Separately from the CPO-declared state, a
// CTO may be paused on a Claude usage / 5-hour limit. That truth comes from the
// swarm-watch feed (see swarmstatus.js), NOT from the bus, so it is modelled as
// an OVERLAY on the CPO state rather than a fourth STATE-grammar value: the
// underlying DRIVING/WAITING/STOOD_DOWN is untouched and still owned solely by
// the CPO's STATE lines. While the overlay is on, the loop is never pinged
// (a throttled session can't act); when the cap lifts, a buffered resume nudge
// fires for loops that didn't come back on their own (see resumesDue).

export class LivenessMonitor {
  /** @param {{ctoNames: string[], silenceThresholdMs: number, pingCooldownMs: number}} opts */
  constructor({ ctoNames, silenceThresholdMs, pingCooldownMs }) {
    this.silenceThresholdMs = silenceThresholdMs;
    this.pingCooldownMs = pingCooldownMs;
    // name -> { state, lastStateAt, lastActivityAt, lastPingAt,
    //           limited, limitResetHint, limitSince, limitClearedAt, resumeNudgedAt }
    this.cto = new Map();
    for (const n of ctoNames) {
      this.cto.set(n, {
        state: 'UNKNOWN', lastStateAt: 0, lastActivityAt: 0, lastPingAt: 0,
        limited: false, limitResetHint: null, limitSince: 0, limitClearedAt: 0, resumeNudgedAt: 0,
      });
    }
  }

  has(name) { return this.cto.has(name); }

  /** Real activity in a CTO's own channel — its loop is alive; reset the clock. */
  noteChannelActivity(name, nowMs) {
    const c = this.cto.get(name);
    if (c) c.lastActivityAt = nowMs;
  }

  /** A "[name] …" directive on the bus names this CTO — reset its clock (we just fed it work). */
  noteDirective(name, nowMs) {
    const c = this.cto.get(name);
    if (c) c.lastActivityAt = nowMs;
  }

  /**
   * Apply a parsed STATE declaration. Sets the state and resets the clock (a
   * STATE line naming the CTO is also the heartbeat). Returns {changed, from, to}
   * or null for an unknown CTO (never tracked).
   */
  applyState(name, state, nowMs) {
    const c = this.cto.get(name);
    if (!c) return null;
    const from = c.state;
    c.state = state;
    c.lastStateAt = nowMs;
    c.lastActivityAt = nowMs; // heartbeat: re-emitting current state resets the clock
    return { changed: from !== state, from, to: state };
  }

  /**
   * Apply the swarm-watch usage-limit feed for one CTO. `paused` = its swarm is
   * currently paused on a Claude usage/5-hour limit (status.json state ===
   * "paused-limit"). This is an OVERLAY, not a STATE-grammar transition — the
   * CPO-declared state is left untouched. On the rising edge (→ limited) we stamp
   * limitSince; on the falling edge (limit lifted) we arm the resume buffer
   * (limitClearedAt) and reset the silence clock to NOW, so post-clear ping rules
   * start fresh rather than firing on silence accrued during the cap. Returns
   * {changed, from, to} in EFFECTIVE-state terms (RATE_LIMITED ⇄ underlying) for
   * logging, or null for an unknown CTO.
   */
  applyLimitFeed(name, paused, resetHint, nowMs) {
    const c = this.cto.get(name);
    if (!c) return null;
    const fromEff = c.limited ? 'RATE_LIMITED' : c.state;
    if (paused) {
      if (!c.limited) { c.limited = true; c.limitSince = nowMs; c.limitClearedAt = 0; c.resumeNudgedAt = 0; }
      c.limitResetHint = resetHint ?? null;
    } else if (c.limited) {
      c.limited = false;
      c.limitClearedAt = nowMs; // arm the resume buffer; resumesDue resolves it
      c.lastActivityAt = nowMs; // fresh silence clock for post-clear ping rules
      c.resumeNudgedAt = 0;
      // keep limitResetHint for the resume-nudge log; resumesDue clears it.
    }
    const toEff = c.limited ? 'RATE_LIMITED' : c.state;
    return { changed: fromEff !== toEff, from: fromEff, to: toEff };
  }

  /**
   * Resume nudges due right now. A CTO is "pending resume" once its usage cap
   * lifts (applyLimitFeed armed limitClearedAt). After bufferMs we resolve the
   * pending state and decide per loop:
   *   - fresh activity since the clear → it self-resumed: no nudge (reason
   *     'self-resumed'). The buffer is exactly this grace window — Claude Code
   *     auto-resumes the queued turn at reset, so most loops come back on their own.
   *   - underlying state WAITING_FOR_OPERATOR / STOOD_DOWN → an intentional
   *     non-driving state; a cap clearing must not shove it back to driving:
   *     no nudge (reason = that state).
   *   - otherwise (DRIVING / UNKNOWN, still quiet) → nudge (reason 'nudge'). The
   *     nudge counts as feeding it work, so the silence clock + lastPing reset.
   * Returns one entry per loop whose buffer elapsed this call (caller logs/acts).
   * @returns {{name:string, resetHint:string|null, nudge:boolean, reason:string}[]}
   */
  resumesDue(nowMs, bufferMs) {
    const out = [];
    for (const [name, c] of this.cto) {
      if (c.limited || c.limitClearedAt <= 0) continue;  // not pending a resume
      if (nowMs - c.limitClearedAt < bufferMs) continue; // still in the grace buffer
      const resetHint = c.limitResetHint;
      const selfResumed = c.lastActivityAt > c.limitClearedAt;
      const blockedState = c.state === 'WAITING_FOR_OPERATOR' || c.state === 'STOOD_DOWN';
      let nudge = false;
      let reason;
      if (selfResumed) reason = 'self-resumed';
      else if (blockedState) reason = c.state;
      else { nudge = true; reason = 'nudge'; }
      c.limitClearedAt = 0; // resolve the pending state either way
      c.limitResetHint = null;
      if (nudge) { c.resumeNudgedAt = nowMs; c.lastActivityAt = nowMs; } // nudging feeds work → reset clock
      out.push({ name, resetHint, nudge, reason });
    }
    return out;
  }

  /** "name=STATE name=STATE …" for logging (RATE_LIMITED reflects the overlay). */
  snapshot() {
    return [...this.cto.entries()]
      .map(([n, c]) => `${n}=${c.limited ? 'RATE_LIMITED' : c.state}`)
      .join(' ');
  }

  /** Public read-only view of the per-CTO map for diagnostics (no mutation). */
  entries() {
    return [...this.cto.entries()];
  }

  /** Read the declared state for one named loop; overlays remain observational. */
  stateOf(name) {
    return this.cto.get(name)?.state ?? null;
  }

  /**
   * tick() reserves a cooldown slot before the asynchronous delivery starts.
   * If policy rendering or the retry queue fails terminally, release that slot
   * so the next watcher interval retries instead of hiding the failed ping for
   * a full cooldown window.
   */
  releaseFailedPing(name) {
    const c = this.cto.get(name);
    if (c) c.lastPingAt = 0;
  }

  /**
   * Which DRIVING loops are due for a revival ping right now. Due iff DRIVING,
   * silent past the threshold, and not pinged within the cooldown. Records the ping.
   * @returns {{name: string, silenceMs: number}[]}
   */
  tick(nowMs) {
    const due = [];
    for (const [name, c] of this.cto) {
      if (c.limited) continue; // paused on a usage limit → pinging is useless; wait for the cap to clear
      if (c.state !== 'DRIVING') continue;
      const silence = nowMs - c.lastActivityAt;
      if (silence <= this.silenceThresholdMs) continue;
      if (c.lastPingAt && nowMs - c.lastPingAt <= this.pingCooldownMs) continue;
      c.lastPingAt = nowMs;
      due.push({ name, silenceMs: silence });
    }
    return due;
  }
}

// ── Read-only "!watcher state" readout ──────────────────────────────────────
// Pure formatting of the SAME in-memory map the monitor maintains. Changes
// NOTHING — no state mutation, no ping recording (unlike tick()).

/** Compact "Xh Ym ago"-style duration from elapsed milliseconds. */
export function relAgo(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h > 0) return m > 0 ? `${h}h${m}m` : `${h}h`;
  if (m > 0) return `${m}m`;
  return `${s}s`;
}

/** Middle field: relative last activity, or a "nothing seen yet" phrase. */
function activityPhrase(c, nowMs) {
  if (c.limited) return `paused on usage limit ${relAgo(nowMs - c.limitSince)}`;
  if (c.lastActivityAt > 0) return `active ${relAgo(nowMs - c.lastActivityAt)} ago`;
  if (c.state === 'UNKNOWN') return 'no state declared yet';
  return 'no activity seen';
}

/**
 * Ping-status field. A RATE_LIMITED loop reports "waiting for reset" (it is never
 * pinged while capped). Otherwise: DRIVING loops report "ok" within the silence
 * threshold, or "quiet … — ping due/sent" once past it (sent = pinged within the
 * cooldown). Every non-DRIVING state is "(not monitored)" — those are never pinged.
 */
function pingPhrase(c, nowMs, silenceThresholdMs, pingCooldownMs) {
  if (c.limited) return c.limitResetHint ? `waiting for reset (resets ${c.limitResetHint})` : 'waiting for reset';
  if (c.state !== 'DRIVING') return '(not monitored)';
  const silence = nowMs - c.lastActivityAt;
  if (silence <= silenceThresholdMs) return 'ok';
  const sentRecently = c.lastPingAt && nowMs - c.lastPingAt <= pingCooldownMs;
  return `quiet ${relAgo(silence)} — ping ${sentRecently ? 'sent' : 'due'}`;
}

/**
 * Build the full "!watcher state" reply. READ-ONLY: reads the monitor's map and
 * reports it; mutates nothing. One line per CTO: "<name>: <STATE> | <activity> |
 * <ping status>". When livenessEnabled is false, prepends a note so the readout
 * isn't mistaken for active monitoring. When no CTO is tracked, returns a plain
 * "nothing yet" line. Always footers with the source-of-truth caveat.
 */
export function renderStateReadout(monitor, nowMs, livenessEnabled, queueStats = null) {
  const entries = monitor ? monitor.entries() : [];
  if (entries.length === 0 && !queueStats) return 'No per-CTO state declared yet.';
  const lines = entries.map(
    ([name, c]) =>
      `${name}: ${c.limited ? 'RATE_LIMITED' : c.state} | ${activityPhrase(c, nowMs)} | ` +
      `${pingPhrase(c, nowMs, monitor.silenceThresholdMs, monitor.pingCooldownMs)}`,
  );
  const header = livenessEnabled
    ? null
    : 'liveness monitor OFF — states shown are last-declared, not actively monitored';
  const footer = "(states reflect the CPO's last declared STATE: line per CTO)";
  return [header, ...lines, renderQueueLine(queueStats), footer].filter(Boolean).join('\n');
}

/**
 * One-line delivery-queue health for the readout, or null to omit. `queueStats`
 * is a plain { depth, draining, stats:{enqueued,delivered,retried,dropped} }
 * snapshot — liveness.js stays pure (no queue import), it just formats numbers.
 * `dropped > 0` is called out loud: a dropped delivery is a message that never
 * reached its destination.
 */
function renderQueueLine(queueStats) {
  if (!queueStats) return null;
  const s = queueStats.stats ?? {};
  const enq = s.enqueued ?? 0, del = s.delivered ?? 0, ret = s.retried ?? 0, drp = s.dropped ?? 0;
  const inflight = queueStats.draining ? ' (draining)' : '';
  const droppedNote = drp > 0 ? ` | ⚠️ ${drp} DROPPED` : '';
  return `queue: depth ${queueStats.depth ?? 0}${inflight} | delivered ${del}/${enq} | retried ${ret}${droppedNote}`;
}
