// queue.js — a serial, retrying delivery queue for the cto-watcher relay.
//
// WHY THIS EXISTS. routing.js decides correctly for ONE message, but the relay's
// side effect (download + Discord send) is async and was fired straight from the
// `messageCreate` handler. discord.js dispatches events in order, but an async
// handler that `await`s yields the event loop, so a BURST of messages across
// several channels ran their deliveries CONCURRENTLY — N in-flight fetch/send
// chains racing on discord.js's REST + channel cache. When one of them hit a
// transient failure (a 429 rate-limit, a momentarily-uncached channel.fetch, a
// gateway hiccup) the old code merely `log`ged it and moved on: that directive
// was dropped permanently while the other channels, on different rate-limit
// buckets, went through. Symptom: under a rapid multi-channel burst a single
// channel's message goes missing, intermittently. A lone message almost never
// trips a transient error, so it was invisible outside bursts.
//
// THE FIX, in two parts, both pure and unit-testable here:
//   1. SERIALIZE. Every delivery is enqueued and drained ONE AT A TIME, in FIFO
//      order. No two deliveries are ever in flight at once, so the burst race is
//      gone and discord.js's REST layer is never hit concurrently by the relay.
//   2. RETRY then ESCALATE. A failed delivery is retried with backoff up to a
//      bound; only after the final attempt fails is it surfaced (via an injected
//      onDropped callback → operator alert) instead of vanishing into a log line.
//
// Pure: no discord.js, no real timers (the sleep fn is injected), no Date. The
// actual send and the backoff sleep are dependency-injected so the whole drain
// loop — ordering, retry, give-up, escalate — is testable without a network.

/**
 * @typedef {Object} DeliveryQueueDeps
 * @property {(job: any) => Promise<void>} send   - performs ONE delivery; throws on failure.
 * @property {(ms: number) => Promise<void>} [sleep] - backoff sleep (injectable for tests).
 * @property {(...a: any[]) => void} [log]
 * @property {(job: any, err: Error, attempts: number) => (void|Promise<void>)} [onDropped]
 *           - called once when a job is given up on after exhausting retries.
 * @property {number} [maxAttempts]   - total attempts per job (default 4: 1 try + 3 retries).
 * @property {number} [baseBackoffMs] - first backoff; doubles each retry (default 250).
 * @property {number} [maxBackoffMs]  - backoff ceiling (default 5000).
 * @property {(err:any)=>boolean} [isRetryable] - classify an error transient (retry) vs terminal.
 */

/**
 * Default retry classifier. A deterministic client error — a 4xx OTHER than 429,
 * e.g. 400 BASE_TYPE_MAX_LENGTH (body too long) or 413 payload-too-large — fails
 * identically on every retry, so it is TERMINAL: don't burn attempts on it, route
 * it straight to the dead-letter. Rate limits (429), server errors (5xx), and
 * errors with NO http status (network / timeout / abort) are TRANSIENT → retry
 * with backoff. Pure: reads duck-typed fields off the error; no discord.js import.
 * @param {any} err
 * @returns {boolean} true = retry, false = terminal
 */
export function defaultIsRetryable(err) {
  const status = err?.status ?? err?.httpStatus ?? err?.response?.status ?? err?.statusCode;
  if (typeof status === 'number') {
    if (status === 429) return true;   // rate limited → retry
    if (status >= 500) return true;    // server error → retry
    if (status >= 400) return false;   // deterministic client error → terminal
  }
  return true; // no http status → network / timeout / abort → transient → retry
}

export class DeliveryQueue {
  /** @param {DeliveryQueueDeps} deps */
  constructor({
    send,
    sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
    log = () => {},
    onDropped = () => {},
    isRetryable = defaultIsRetryable,
    maxAttempts = 4,
    baseBackoffMs = 250,
    maxBackoffMs = 5000,
  }) {
    if (typeof send !== 'function') throw new Error('DeliveryQueue requires a send(job) function');
    this._send = send;
    this._sleep = sleep;
    this._log = log;
    this._onDropped = onDropped;
    this._isRetryable = typeof isRetryable === 'function' ? isRetryable : defaultIsRetryable;
    this._maxAttempts = Math.max(1, maxAttempts | 0);
    this._baseBackoffMs = Math.max(0, baseBackoffMs | 0);
    this._maxBackoffMs = Math.max(this._baseBackoffMs, maxBackoffMs | 0);

    /** @type {{job:any,label:string}[]} */
    this._q = [];
    this._draining = false;
    /** Resolves when the queue next goes idle — for tests/shutdown. */
    this._idleWaiters = [];

    // Lightweight counters for diagnostics / "!watcher status".
    this.stats = { enqueued: 0, delivered: 0, retried: 0, dropped: 0 };
  }

  /** Number of jobs waiting (excludes the one currently being delivered). */
  get depth() { return this._q.length; }
  get draining() { return this._draining; }

  /**
   * Enqueue one delivery. Returns immediately; the job drains in FIFO order behind
   * any already queued. `label` is for logging only.
   */
  enqueue(job, label = '') {
    this._q.push({ job, label });
    this.stats.enqueued++;
    if (!this._draining) this._drain(); // fire-and-forget; _drain self-guards re-entry
  }

  /** Resolves once the queue is fully drained and idle. */
  onIdle() {
    if (!this._draining && this._q.length === 0) return Promise.resolve();
    return new Promise((resolve) => this._idleWaiters.push(resolve));
  }

  async _drain() {
    if (this._draining) return;
    this._draining = true;
    try {
      while (this._q.length > 0) {
        const { job, label } = this._q.shift();
        await this._deliverWithRetry(job, label);
      }
    } finally {
      this._draining = false;
      // A job may have been enqueued during the final await; if so, keep going.
      if (this._q.length > 0) { this._drain(); return; }
      const waiters = this._idleWaiters.splice(0);
      for (const w of waiters) w();
    }
  }

  async _deliverWithRetry(job, label) {
    let lastErr;
    let attempt = 0;
    while (attempt < this._maxAttempts) {
      attempt++;
      try {
        await this._send(job);
        this.stats.delivered++;
        return;
      } catch (err) {
        lastErr = err;
        // A deterministic (non-retryable) error fails identically every time —
        // don't waste the remaining attempts, go straight to dead-letter.
        if (!this._isRetryable(err)) {
          this._log(`[queue] non-retryable error${label ? ` (${label})` : ''} on attempt ${attempt}: ${err?.message ?? err} — terminal, not retrying`);
          break;
        }
        if (attempt >= this._maxAttempts) break; // transient but out of attempts
        this.stats.retried++;
        const backoff = Math.min(this._maxBackoffMs, this._baseBackoffMs * 2 ** (attempt - 1));
        this._log(`[queue] delivery failed${label ? ` (${label})` : ''} attempt ${attempt}/${this._maxAttempts}: ${err?.message ?? err} — retrying in ${backoff}ms`);
        await this._sleep(backoff);
      }
    }
    // Terminal — give up LOUDLY (dead-letter + escalate), never silently. `attempt`
    // is the real number of tries made (1 for a non-retryable first failure).
    this.stats.dropped++;
    this._log(`[queue] DROPPED${label ? ` (${label})` : ''} after ${attempt} attempt(s): ${lastErr?.message ?? lastErr}`);
    try {
      await this._onDropped(job, lastErr, attempt);
    } catch (escErr) {
      this._log(`[queue] onDropped handler threw: ${escErr?.message ?? escErr}`);
    }
  }
}
