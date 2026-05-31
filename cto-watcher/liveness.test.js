// liveness.test.js — dry-run of the per-CTO monitor. No Discord, no real timers:
// we drive `now` by hand and assert which DRIVING-but-quiet loops are due.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LivenessMonitor, renderStateReadout, relAgo } from './liveness.js';
import { KillSwitch } from './killswitch.js';

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

// ── RATE_LIMITED usage-limit overlay (fed from swarm-watch's status.json) ────

const BUFFER = 1000;

test('limited DRIVING loop is NOT pinged (waits for the cap), even long past the silence threshold', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  m.applyLimitFeed('cto-7', true, '11pm', 10);            // swarm hit a usage limit
  assert.deepEqual(m.tick(100 * SILENCE), []);            // never pinged while capped
});

test('applyLimitFeed reports effective-state transitions (RATE_LIMITED ⇄ underlying), idempotent while held', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  assert.deepEqual(m.applyLimitFeed('cto-7', true, '11pm', 10), { changed: true, from: 'DRIVING', to: 'RATE_LIMITED' });
  assert.deepEqual(m.applyLimitFeed('cto-7', true, '11pm', 20), { changed: false, from: 'RATE_LIMITED', to: 'RATE_LIMITED' });
  assert.match(m.snapshot(), /cto-7=RATE_LIMITED/);
  assert.deepEqual(m.applyLimitFeed('cto-7', false, null, 30), { changed: true, from: 'RATE_LIMITED', to: 'DRIVING' });
  assert.match(m.snapshot(), /cto-7=DRIVING/);             // underlying CPO state survived the overlay
});

test('applyLimitFeed on an unknown CTO → null (never tracked)', () => {
  const m = mk();
  assert.equal(m.applyLimitFeed('cto-x', true, '11pm', 0), null);
});

test('cap clears → after the buffer a still-quiet DRIVING loop is due for a resume nudge (once)', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  m.applyLimitFeed('cto-7', true, '11pm', 100);
  m.applyLimitFeed('cto-7', false, '11pm', 200);          // cap lifted at t=200
  assert.deepEqual(m.resumesDue(200 + BUFFER - 1, BUFFER), []);            // still in the grace buffer
  const due = m.resumesDue(200 + BUFFER, BUFFER);
  assert.equal(due.length, 1);
  assert.equal(due[0].name, 'cto-7');
  assert.equal(due[0].nudge, true);
  assert.equal(due[0].resetHint, '11pm');
  assert.deepEqual(m.resumesDue(200 + BUFFER + 1, BUFFER), []);            // resolved → not nudged again
});

test('cap clears but the loop self-resumed (activity after the clear) → no nudge', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  m.applyLimitFeed('cto-7', true, '11pm', 100);
  m.applyLimitFeed('cto-7', false, '11pm', 200);
  m.noteChannelActivity('cto-7', 250);                    // it came back on its own
  const due = m.resumesDue(200 + BUFFER, BUFFER);
  assert.equal(due.length, 1);
  assert.equal(due[0].nudge, false);
  assert.equal(due[0].reason, 'self-resumed');
});

test('cap clears but the loop is WAITING_FOR_OPERATOR / STOOD_DOWN → no nudge (intentional non-driving)', () => {
  const m = mk();
  m.applyState('cto-7', 'WAITING_FOR_OPERATOR', 0);
  m.applyState('cto-3', 'STOOD_DOWN', 0);
  m.applyLimitFeed('cto-7', true, null, 100);
  m.applyLimitFeed('cto-3', true, null, 100);
  m.applyLimitFeed('cto-7', false, null, 200);
  m.applyLimitFeed('cto-3', false, null, 200);
  const due = m.resumesDue(200 + BUFFER, BUFFER).sort((a, b) => a.name.localeCompare(b.name));
  assert.deepEqual(due.map((d) => [d.name, d.nudge, d.reason]), [
    ['cto-3', false, 'STOOD_DOWN'],
    ['cto-7', false, 'WAITING_FOR_OPERATOR'],
  ]);
});

test('after a resume nudge, normal ping rules resume (clock reset, not instantly due)', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  m.applyLimitFeed('cto-7', true, '11pm', 100);
  m.applyLimitFeed('cto-7', false, '11pm', 200);
  const t = 200 + BUFFER;
  assert.equal(m.resumesDue(t, BUFFER)[0].nudge, true);   // nudged at t (resets the silence clock)
  assert.deepEqual(m.tick(t + SILENCE), []);              // within threshold of the nudge → not due
  assert.deepEqual(m.tick(t + SILENCE + 1).map((d) => d.name), ['cto-7']); // past it → normal ping
});

test('clock reset on clear: silence accrued DURING the cap does not trigger an immediate ping', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', 0);
  m.applyLimitFeed('cto-7', true, '11pm', 10);
  m.applyLimitFeed('cto-7', false, '11pm', 100 * SILENCE); // cleared after a long cap
  assert.deepEqual(m.tick(100 * SILENCE + SILENCE), []);   // clock reset to clear time → not instantly due
});

// ── "!watcher state" read-only readout ──────────────────────────────────────

test('relAgo: compact h/m/s rendering matching the readout examples', () => {
  assert.equal(relAgo(4 * 60_000), '4m');
  assert.equal(relAgo(72 * 60_000), '1h12m');
  assert.equal(relAgo(120 * 60_000), '2h');
  assert.equal(relAgo(32 * 60_000), '32m');
  assert.equal(relAgo(5_000), '5s');
});

// Base at a realistic epoch: lastActivityAt's 0 also doubles as the "never seen"
// sentinel, so declaring at t=0 (impossible in production where now>>0) would read
// back as "no activity". Drive all readout tests off a nonzero BASE.
const BASE = 1_700_000_000_000;

test('renderStateReadout: populated map → one line per CTO with state + activity + ping status', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', BASE); // declared + active
  m.applyState('cto-3', 'WAITING_FOR_OPERATOR', BASE);
  // press-backend left UNKNOWN, never declared.
  const now = BASE + 4 * 60_000; // 4m later; SILENCE is only 1000ms so cto-7 is past threshold
  const out = renderStateReadout(m, now, true);
  const lines = out.split('\n');

  // DRIVING + past silence threshold + never pinged → "ping due"
  assert.equal(lines[0], 'cto-7: DRIVING | active 4m ago | quiet 4m — ping due');
  // non-DRIVING → "(not monitored)"
  assert.equal(lines[1], 'cto-3: WAITING_FOR_OPERATOR | active 4m ago | (not monitored)');
  // UNKNOWN, never declared → "no state declared yet"
  assert.equal(lines[2], 'press-backend: UNKNOWN | no state declared yet | (not monitored)');
  // source-of-truth footer
  assert.equal(lines.at(-1), "(states reflect the CPO's last declared STATE: line per CTO)");
  // livenessEnabled true → no "monitor OFF" note
  assert.doesNotMatch(out, /monitor OFF/);
});

test('renderStateReadout: DRIVING within threshold → "ok"; recently pinged → "ping sent"', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', BASE);
  assert.match(renderStateReadout(m, BASE + SILENCE, true), /cto-7: DRIVING \| active \d+s ago \| ok/);

  // Drive a tick past the threshold so a ping is recorded, then read back: "sent".
  assert.deepEqual(m.tick(BASE + SILENCE + 1).map((d) => d.name), ['cto-7']); // records lastPingAt
  assert.match(renderStateReadout(m, BASE + SILENCE + 1, true), /cto-7: DRIVING \|.*\| quiet 1s — ping sent/);
});

test('renderStateReadout: a limited loop shows RATE_LIMITED | paused on usage limit | waiting for reset', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', BASE);
  m.applyLimitFeed('cto-7', true, '11pm', BASE + 60_000); // capped 1m after declaring
  const out = renderStateReadout(m, BASE + 13 * 60_000, true); // 12m into the cap
  const line = out.split('\n').find((l) => l.startsWith('cto-7:'));
  assert.equal(line, 'cto-7: RATE_LIMITED | paused on usage limit 12m | waiting for reset (resets 11pm)');
});

test('renderStateReadout: limited loop with no reset hint → "waiting for reset"', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', BASE);
  m.applyLimitFeed('cto-7', true, null, BASE);
  assert.match(renderStateReadout(m, BASE + 5 * 60_000, true), /cto-7: RATE_LIMITED \|.*\| waiting for reset$/m);
});

test('renderStateReadout: empty map (no CTOs) → plain "No per-CTO state declared yet."', () => {
  const empty = new LivenessMonitor({ ctoNames: [], silenceThresholdMs: SILENCE, pingCooldownMs: COOLDOWN });
  assert.equal(renderStateReadout(empty, 123, true), 'No per-CTO state declared yet.');
  assert.equal(renderStateReadout(null, 123, true), 'No per-CTO state declared yet.');
});

test('renderStateReadout: livenessEnabled false → prepends the "monitor OFF" note, still lists states', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', BASE);
  const out = renderStateReadout(m, BASE + 4 * 60_000, false);
  const lines = out.split('\n');
  assert.equal(lines[0], 'liveness monitor OFF — states shown are last-declared, not actively monitored');
  assert.match(out, /cto-7: DRIVING/); // states still shown beneath the note
  assert.equal(lines.at(-1), "(states reflect the CPO's last declared STATE: line per CTO)");
});

test('renderStateReadout is read-only and NOT pause-gated: paused KillSwitch does not change the readout', () => {
  const m = mk();
  m.applyState('cto-7', 'DRIVING', BASE);
  const ks = new KillSwitch();
  ks.stop(); // paused
  assert.equal(ks.paused, true);
  // The readout depends only on the map + now, never on pause state — same output paused or not.
  const before = renderStateReadout(m, BASE + 500, true);
  const after = renderStateReadout(m, BASE + 500, true);
  assert.equal(before, after);
  assert.match(before, /cto-7: DRIVING/);
  // And reading did not mutate the map (snapshot unchanged).
  assert.match(m.snapshot(), /cto-7=DRIVING/);
});
