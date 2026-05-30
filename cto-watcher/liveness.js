// liveness.js — per-CTO state + silence store for the AUTO-mode revival monitor.
//
// Pure: no discord.js, no real timers, no Date. index.js feeds it (state from
// parsed STATE lines, timer resets from CTO-channel activity and bus directives)
// and calls tick(now). It decides which DRIVING-but-quiet loops to ping.
//
// State changes ONLY from parsed STATE lines (never inferred from traffic).
// A CTO is pinged ONLY while DRIVING and silent past the threshold;
// WAITING_FOR_OPERATOR, STOOD_DOWN, and UNKNOWN are never pinged.

export class LivenessMonitor {
  /** @param {{ctoNames: string[], silenceThresholdMs: number, pingCooldownMs: number}} opts */
  constructor({ ctoNames, silenceThresholdMs, pingCooldownMs }) {
    this.silenceThresholdMs = silenceThresholdMs;
    this.pingCooldownMs = pingCooldownMs;
    this.cto = new Map(); // name -> { state, lastStateAt, lastActivityAt, lastPingAt }
    for (const n of ctoNames) {
      this.cto.set(n, { state: 'UNKNOWN', lastStateAt: 0, lastActivityAt: 0, lastPingAt: 0 });
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

  /** "name=STATE name=STATE …" for logging. */
  snapshot() {
    return [...this.cto.entries()].map(([n, c]) => `${n}=${c.state}`).join(' ');
  }

  /**
   * Which DRIVING loops are due for a revival ping right now. Due iff DRIVING,
   * silent past the threshold, and not pinged within the cooldown. Records the ping.
   * @returns {{name: string, silenceMs: number}[]}
   */
  tick(nowMs) {
    const due = [];
    for (const [name, c] of this.cto) {
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
