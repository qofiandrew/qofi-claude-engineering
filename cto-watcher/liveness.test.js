// liveness.test.js — dry-run of the per-CTO monitor. No Discord, no real timers:
// we drive `now` by hand and assert which DRIVING-but-quiet loops are due.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LivenessMonitor } from './liveness.js';

const CTOS = ['cto-7', 'cto-3', 'press-backend'];
const SILENCE = 1000;
const COOLDOWN = 1000;
const mk = () => new LivenessMonitor({ ctoNames: CTOS, silenceThresholdMs: SILENCE, pingCooldownMs: COOLDOWN });

test('UNKNOWN by default → never pinged', () => {
  const m = mk();
  assert.deepEqual(m.tick(100 * SILENCE), []);
});

test('applyState DRIVING then silence past threshold → due once; cooldown suppresses; then due again', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);               // declaring resets clock to t=0
  assert.deepEqual(m.tick(SILENCE), []);             // == threshold → not yet
  assert.deepEqual(m.tick(SILENCE + 1).map((d) => d.name), ['cto-7']); // past → due
  assert.deepEqual(m.tick(SILENCE + 2), []);         // within cooldown → suppressed
  assert.deepEqual(m.tick(SILENCE + COOLDOWN + 2).map((d) => d.name), ['cto-7']); // cooldown elapsed → due again
});

test('heartbeat: re-emit DRIVING while DRIVING → no state change, resets clock, suppresses next ping', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  const r = m.applyState('cto-7', 'DRIVING', SILENCE - 1); // heartbeat just before window closes
  assert.equal(r.changed, false);
  assert.deepEqual(m.tick(SILENCE + SILENCE - 1), []);     // clock reset at SILENCE-1 → not due
});

test('real CTO-channel activity resets the clock', () => {
  const m = mk();
  m.applyState('cto-3', 'DRIVING', 0);
  m.noteChannelActivity('cto-3', SILENCE);
  assert.deepEqual(m.tick(SILENCE + SILENCE), []);          // quiet only SILENCE since activity → not due
  assert.deepEqual(m.tick(SILENCE + SILENCE + 1).map((d) => d.name), ['cto-3']);
});

test('a directive naming the CTO resets the clock', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  m.noteDirective('cto-7', SILENCE);
  assert.deepEqual(m.tick(SILENCE + SILENCE), []);          // reset by the directive
});

test('WAITING_FOR_OPERATOR, STOOD_DOWN never pinged (legitimate silence)', () => {
  const m = mk();
  m.applyState('cto-7', 'WAITING_FOR_OPERATOR', 0);
  m.applyState('cto-3', 'STOOD_DOWN', 0);
  assert.deepEqual(m.tick(100 * SILENCE), []);
});

test('transition out of DRIVING stops the pings', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  assert.deepEqual(m.tick(SILENCE + 1).map((d) => d.name), ['cto-7']);
  m.applyState('cto-7', 'WAITING_FOR_OPERATOR', SILENCE + 2);
  assert.deepEqual(m.tick(100 * SILENCE), []);
});

test('applyState on an unknown CTO → null (never tracked)', () => {
  const m = mk();
  assert.equal(m.applyState('cto-x', 'DRIVING', 0), null);
  assert.deepEqual(m.tick(100 * SILENCE), []);
});

test('snapshot reflects current states', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  assert.match(m.snapshot(), /cto-7=DRIVING/);
  assert.match(m.snapshot(), /cto-3=UNKNOWN/);
});
