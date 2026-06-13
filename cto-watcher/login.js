// login.js — transient/terminal classification for the cto-watcher's INITIAL
// Discord login, with a capped-exponential retry loop. Mirrors the philosophy of
// queue.js's defaultIsRetryable (ADR-0011).
//
// WHY THIS EXISTS. The login used to treat EVERY failure as fatal
// (`client.login(TOKEN).catch(() => process.exit(1))`). On a transient network
// blip at startup — a captive-portal `getaddrinfo ENOTFOUND discord.com`, a
// wifi-portal cert-altname mismatch — it exited, pm2 restarted every 5s, and
// burned toward max_restarts:50, after which pm2 STOPS and the watcher is
// permanently dead until a manual `pm2 restart`. discord.js's own gateway
// auto-reconnect only engages AFTER a successful initial login, so the
// captive-portal case had no in-process recovery. (Evidence: cto-watcher-error
// log, 2026-06-10.)
//
// THE FIX. Retry the INITIAL login on clearly-network errors with capped
// backoff and NO terminal ceiling (a network gone for an hour must resolve by
// waiting, not dying). Auth/config errors — and, critically, ANY UNKNOWN error —
// stay TERMINAL: a bad token must still crash so the operator learns it's wrong,
// never loop silently forever. Fail loud on doubt.
//
// Pure: the classifier + backoff are pure functions; the retry loop is
// dependency-injected (login, sleep, onTerminal), so it's unit-testable without
// a live Discord client or a real network.

const TERMINAL_CODES = new Set(['TokenInvalid', 'TokenMissing', 'DisallowedIntents']);
const NETWORK_CODES = new Set(['ENOTFOUND', 'ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'EAI_AGAIN']);

/**
 * Classify an INITIAL-login error: transient (retry) vs terminal (crash).
 * CONSERVATIVE BY DESIGN — only clearly-network errors are transient; everything
 * else, INCLUDING UNKNOWN errors, defaults to TERMINAL (fail loud). A
 * misclassified bad token must still crash, never loop forever. Pure.
 * @param {any} err
 * @returns {boolean} true = transient (retry), false = terminal (crash)
 */
export function isTransientLoginError(err) {
  if (!err) return false;
  const code = err.code;
  const msg = String(err.message ?? err);

  // Terminal auth/config errors take precedence — never retry these.
  if (TERMINAL_CODES.has(code)) return false;
  if (/invalid token|disallowed intent|privileged intent/i.test(msg)) return false;

  // Clearly-network transient signals (by code or in the message).
  if (NETWORK_CODES.has(code)) return true;
  if (/\b(ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN)\b/.test(msg)) return true;
  if (/\b(abort(ed)?|timed[- ]?out|timeout)\b/i.test(msg)) return true;
  // Captive-portal cert interception (altname mismatch / bad certificate).
  if (/altnames?|certificate/i.test(msg)) return true;

  // Unknown → TERMINAL. Fail loud; do not loop on a mystery error.
  return false;
}

/**
 * Capped exponential backoff for login retries: attempt 1 → 5s, 2 → 10s, 3 → 20s,
 * 4 → 40s … doubling, capped at 300s. Pure.
 * @param {number} attempt 1-based attempt number
 * @returns {number} milliseconds to wait before the next attempt
 */
export function loginBackoffMs(attempt, { base = 5000, cap = 300000 } = {}) {
  const ms = base * 2 ** Math.max(0, (attempt | 0) - 1);
  return Math.min(cap, ms);
}

/**
 * Retry the initial login until it succeeds (transient errors) or fails loud
 * (terminal errors). Dependency-injected so it's testable without discord.js:
 *   - login()        -> Promise           the actual client.login(TOKEN)
 *   - sleep(ms)      -> Promise           backoff sleep
 *   - onTerminal(err, attempt)            crash handler (prod: log [fatal] + process.exit(1))
 *   - isTransient / backoffMs             overridable (default to the pure fns above)
 *   - maxAttempts    default Infinity     NO terminal ceiling in prod; finite only for tests
 */
export async function loginWithRetry({
  login, sleep, log = () => {}, onTerminal,
  isTransient = isTransientLoginError, backoffMs = loginBackoffMs, maxAttempts = Infinity,
}) {
  if (typeof login !== 'function') throw new Error('loginWithRetry requires a login() function');
  if (typeof onTerminal !== 'function') throw new Error('loginWithRetry requires an onTerminal(err) handler');
  let attempt = 0;
  for (;;) {
    attempt++;
    try {
      await login();
      if (attempt > 1) log(`[login] succeeded on attempt ${attempt} after transient retries`);
      return;
    } catch (err) {
      if (!isTransient(err)) {
        return onTerminal(err, attempt); // terminal — crash loud (prod exits here)
      }
      if (attempt >= maxAttempts) {
        return onTerminal(err, attempt); // only reachable with a finite injected ceiling (tests)
      }
      const wait = backoffMs(attempt);
      log(`[login] transient failure on attempt ${attempt}: ${err?.message ?? err} — retrying in ${Math.round(wait / 1000)}s (no terminal ceiling)`);
      await sleep(wait);
    }
  }
}
