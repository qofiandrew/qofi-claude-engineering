// login.test.js — the initial-login transient/terminal classifier + retry loop.
// No live Discord, no real timers: the classifier + backoff are pure; the retry
// loop is driven with injected login/sleep/onTerminal. Pins the conservative
// default-to-terminal rule (a bad/unknown token still crashes) and the 300s
// backoff cap. Per ADR-0011.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isTransientLoginError, loginBackoffMs, loginWithRetry } from './login.js';

test('isTransientLoginError: clearly-network errors are TRANSIENT', () => {
  assert.equal(isTransientLoginError({ code: 'ENOTFOUND' }), true);
  assert.equal(isTransientLoginError(new Error('getaddrinfo ENOTFOUND discord.com')), true); // captive-portal DNS
  assert.equal(isTransientLoginError({ code: 'EAI_AGAIN' }), true);
  assert.equal(isTransientLoginError({ code: 'ECONNREFUSED' }), true);
  assert.equal(isTransientLoginError({ code: 'ECONNRESET' }), true);
  assert.equal(isTransientLoginError({ code: 'ETIMEDOUT' }), true);
  assert.equal(isTransientLoginError(new Error('connect ETIMEDOUT 1.2.3.4:443')), true);
  assert.equal(isTransientLoginError(new Error('request aborted')), true);
  // captive-portal cert interception (altname mismatch / unverifiable cert)
  assert.equal(isTransientLoginError(new Error("Hostname/IP does not match certificate's altnames: host: discord.com")), true);
  assert.equal(isTransientLoginError(new Error('unable to verify the first certificate')), true);
});

test('isTransientLoginError: auth/config AND unknown errors are TERMINAL (conservative default)', () => {
  assert.equal(isTransientLoginError({ code: 'TokenInvalid' }), false);
  assert.equal(isTransientLoginError(new Error('An invalid token was provided.')), false);
  assert.equal(isTransientLoginError({ code: 'DisallowedIntents' }), false);
  assert.equal(isTransientLoginError(new Error('Privileged intent provided is not enabled or whitelisted.')), false);
  // unknown / unclassified -> TERMINAL (fail loud; never loop on a mystery error)
  assert.equal(isTransientLoginError(new Error('something weird happened')), false);
  assert.equal(isTransientLoginError({}), false);
  assert.equal(isTransientLoginError(null), false);
});

test('loginBackoffMs: 5s, 10s, 20s, 40s … doubling, capped at 300s', () => {
  assert.equal(loginBackoffMs(1), 5000);
  assert.equal(loginBackoffMs(2), 10000);
  assert.equal(loginBackoffMs(3), 20000);
  assert.equal(loginBackoffMs(4), 40000);
  assert.equal(loginBackoffMs(5), 80000);
  assert.equal(loginBackoffMs(6), 160000);
  assert.equal(loginBackoffMs(7), 300000);  // 320000 -> capped
  assert.equal(loginBackoffMs(20), 300000); // stays capped, never grows past 300s
});

test('loginWithRetry: a transient failure retries, then succeeds — never terminal', async () => {
  let calls = 0;
  let terminal = false;
  await loginWithRetry({
    login: async () => { calls++; if (calls < 3) throw new Error('getaddrinfo ENOTFOUND discord.com'); },
    sleep: async () => {},
    onTerminal: () => { terminal = true; },
  });
  assert.equal(calls, 3, 'retried through two transient failures then succeeded');
  assert.equal(terminal, false, 'onTerminal NOT called on eventual success');
});

test('loginWithRetry: a terminal error crashes loud on the FIRST attempt — no retry, no sleep', async () => {
  let calls = 0;
  let terminalErr = null;
  await loginWithRetry({
    login: async () => { calls++; const e = new Error('An invalid token was provided.'); e.code = 'TokenInvalid'; throw e; },
    sleep: async () => { throw new Error('must NOT sleep on a terminal error'); },
    onTerminal: (err, attempt) => { terminalErr = { msg: err.message, attempt }; },
  });
  assert.equal(calls, 1, 'a bad token is tried once, never retried');
  assert.equal(terminalErr.attempt, 1);
  assert.match(terminalErr.msg, /invalid token/i);
});

test('loginWithRetry: a finite ceiling (tests only) hands off to terminal; prod uses Infinity', async () => {
  let calls = 0;
  let terminal = false;
  await loginWithRetry({
    login: async () => { calls++; throw new Error('ENOTFOUND'); }, // always transient
    sleep: async () => {},
    maxAttempts: 3,
    onTerminal: () => { terminal = true; },
  });
  assert.equal(calls, 3);
  assert.equal(terminal, true);
});
