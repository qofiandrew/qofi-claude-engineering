// swarmstatus.test.js — parse the swarm-watch status.json feed. Pure, no I/O:
// we feed raw JSON text + a fixed `now` and assert the per-name limit map (or
// null when the snapshot is unusable). The fail-SAFE contract is the point:
// anything we can't trust → null → caller leaves the overlay unchanged.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSwarmLimitStates } from './swarmstatus.js';

const NOW = 1_700_000_000_000;
const MAX_AGE = 120_000; // 2m
// generated_at fresh relative to NOW (1s ago), in swarm-status/v1's UTC "…Z" form.
const FRESH_TS = new Date(NOW - 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

const snap = (swarms, generated_at = FRESH_TS) =>
  JSON.stringify({ schema: 'swarm-status/v1', generated_at, swarms });

test('paused-limit swarm → paused:true with reset hint; others → paused:false', () => {
  const m = parseSwarmLimitStates(
    snap([
      { name: 'reserve-backend-2', state: 'paused-limit', limit_reset_hint: '11pm' },
      { name: 'qofi-ios-app', state: 'working', limit_reset_hint: null },
      { name: 'press-backend', state: 'ready' },
    ]),
    NOW,
    MAX_AGE,
  );
  assert.deepEqual(m.get('reserve-backend-2'), { paused: true, resetHint: '11pm' });
  assert.deepEqual(m.get('qofi-ios-app'), { paused: false, resetHint: null });
  assert.deepEqual(m.get('press-backend'), { paused: false, resetHint: null });
});

test('malformed JSON → null', () => {
  assert.equal(parseSwarmLimitStates('{not json', NOW, MAX_AGE), null);
});

test('wrong shape (no swarms array) → null', () => {
  assert.equal(parseSwarmLimitStates(JSON.stringify({ schema: 'swarm-status/v1' }), NOW, MAX_AGE), null);
  assert.equal(parseSwarmLimitStates('null', NOW, MAX_AGE), null);
  assert.equal(parseSwarmLimitStates('[]', NOW, MAX_AGE), null);
});

test('stale snapshot (generated_at older than maxAge) → null', () => {
  const old = new Date(NOW - MAX_AGE - 1).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const m = parseSwarmLimitStates(snap([{ name: 'reserve-backend-2', state: 'paused-limit' }], old), NOW, MAX_AGE);
  assert.equal(m, null);
});

test('absent / unparseable generated_at → null (distrust)', () => {
  const noTs = JSON.stringify({ schema: 'swarm-status/v1', swarms: [{ name: 'x', state: 'working' }] });
  assert.equal(parseSwarmLimitStates(noTs, NOW, MAX_AGE), null);
  assert.equal(parseSwarmLimitStates(snap([{ name: 'x', state: 'working' }], 'not-a-date'), NOW, MAX_AGE), null);
});

test('staleness guard skipped when maxAgeMs omitted (old timestamp still parses)', () => {
  const old = new Date(NOW - 10 * MAX_AGE).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const m = parseSwarmLimitStates(snap([{ name: 'x', state: 'paused-limit', limit_reset_hint: '3pm' }], old), NOW);
  assert.deepEqual(m.get('x'), { paused: true, resetHint: '3pm' });
});

test('swarm entries without a string name are skipped', () => {
  const m = parseSwarmLimitStates(snap([{ state: 'paused-limit' }, { name: 'ok', state: 'working' }]), NOW, MAX_AGE);
  assert.equal(m.size, 1);
  assert.ok(m.has('ok'));
});

test('non-string limit_reset_hint normalizes to null', () => {
  const m = parseSwarmLimitStates(snap([{ name: 'x', state: 'paused-limit', limit_reset_hint: 123 }]), NOW, MAX_AGE);
  assert.deepEqual(m.get('x'), { paused: true, resetHint: null });
});
