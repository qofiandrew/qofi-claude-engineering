import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CheckInCoordinator } from './checkin-coordinator.js';
import { HarnessPolicyClient } from './harness-policy-client.js';

const CTO_CHANNEL = '1510301812434141194';
const CTO_BOT = '1507069153335443608';

function harness() {
  const jobs = [];
  const sent = [];
  const metrics = [];
  const escalations = [];
  const coordinator = new CheckInCoordinator({
    policy: new HarnessPolicyClient({ timeoutMs: 10_000 }),
    enqueue: job => jobs.push(job),
    deliver: async (channelId, text, mention) => sent.push({ channelId, text, mention }),
    metricSink: metric => metrics.push(metric),
    onEscalate: event => escalations.push(event),
    now: () => 2000,
  });
  const drainOne = async () => jobs.shift().run();
  return { coordinator, jobs, sent, metrics, escalations, drainOne };
}

test('idle request is structured; bare ack is rejected, measured, and deterministically re-pinged', async () => {
  const h = harness();
  const issued = await h.coordinator.issue({
    name: 'press-backend', targetChannelId: CTO_CHANNEL, targetBotUserId: CTO_BOT,
    currentTask: 'task-42', status: 'DRIVING', sentAtMs: 1000,
  });
  assert.equal(issued.issued, true);
  assert.equal(h.coordinator.hasPending('press-backend'), false, 'not pending until Discord send succeeds');
  await h.drainOne();
  assert.equal(h.coordinator.hasPending('press-backend'), true);
  assert.equal(h.sent[0].channelId, CTO_CHANNEL);
  assert.equal(h.sent[0].mention, CTO_BOT);
  assert.match(h.sent[0].text, /Required fields:/);
  assert.doesNotMatch(h.sent[0].text, /still working, blocked/);

  const rejected = await h.coordinator.receive('press-backend', 'ok', 1600);
  assert.equal(rejected.accepted, false);
  assert.equal(rejected.bounded, false);
  assert.deepEqual(rejected.errors, ['bare acknowledgment is not a check-in']);
  assert.equal(h.metrics[0].latency_ms, 600);
  assert.equal(h.metrics[0].outcome, 'rejected');
  assert.equal(h.jobs.length, 1);
  await h.drainOne();
  assert.equal(h.sent[1].channelId, CTO_CHANNEL);
  assert.equal(h.sent[1].mention, CTO_BOT);
  assert.match(h.sent[1].text, /attempt 2/);
  assert.match(h.sent[1].text, /Prior response failed validation/);

  const accepted = await h.coordinator.receive('press-backend', {
    schema: 'qofi.cto-checkin/v1',
    ping_id: issued.pingId,
    addressee: 'press-backend',
    current_task: 'task-42',
    status: 'DRIVING',
    progress_since_last_checkin: 'Derived the roadmap from normalized events.',
    blockers: [],
    next_action: 'Run the watcher integration tests.',
    needs_input: false,
  }, 1900);
  assert.equal(accepted.accepted, true);
  assert.equal(h.coordinator.hasPending('press-backend'), false);
  assert.equal(h.metrics[1].latency_ms, 900);
  assert.equal(h.metrics[1].attempt, 2);
});

test('rejection is bounded and escalates; an early state cancellation suppresses stale queued send', async () => {
  const h = harness();
  const first = await h.coordinator.issue({
    name: 'press-backend', targetChannelId: CTO_CHANNEL, targetBotUserId: CTO_BOT,
    currentTask: 'task-42', status: 'DRIVING', sentAtMs: 1000,
  });
  h.coordinator.cancel('press-backend', 'state changed');
  await h.drainOne();
  assert.equal(h.sent.length, 0, 'cancelled queued request is a no-op');
  assert.equal(h.coordinator.hasOutstanding('press-backend'), false);

  const second = await h.coordinator.issue({
    name: 'press-backend', targetChannelId: CTO_CHANNEL, targetBotUserId: CTO_BOT,
    currentTask: 'task-42', status: 'DRIVING', sentAtMs: 2000,
  });
  assert.notEqual(first.pingId, second.pingId);
  await h.drainOne();
  for (let attempt = 1; attempt <= 3; attempt++) {
    const outcome = await h.coordinator.receive('press-backend', 'still working', 2000 + attempt * 100);
    if (attempt < 3) await h.drainOne();
    else assert.equal(outcome.bounded, true);
  }
  assert.equal(h.escalations.length, 1);
  assert.equal(h.coordinator.hasPending('press-backend'), false);
});

test('terminal delivery failure clears correlation and escalates without candidate content', async () => {
  const h = harness();
  await h.coordinator.issue({
    name: 'press-backend', targetChannelId: CTO_CHANNEL, targetBotUserId: CTO_BOT,
    currentTask: 'task-42', status: 'DRIVING', sentAtMs: 1000,
  });
  const job = h.jobs.shift();
  assert.equal(await h.coordinator.deliveryDropped(job, new Error('network token=hidden')), true);
  assert.equal(h.coordinator.hasOutstanding('press-backend'), false);
  assert.deepEqual(h.escalations[0].errors, ['check-in delivery exhausted its retry queue']);
});

test('Discord transport errors are reduced to a fixed message before retry/dead-letter logs', async () => {
  const jobs = [];
  const coordinator = new CheckInCoordinator({
    policy: new HarnessPolicyClient({ timeoutMs: 10_000 }),
    enqueue: job => jobs.push(job),
    deliver: async () => { throw new Error('secret-provider-account-identifier'); },
  });
  await coordinator.issue({
    name: 'press-backend', targetChannelId: CTO_CHANNEL, targetBotUserId: CTO_BOT,
    currentTask: 'task-42', status: 'DRIVING', sentAtMs: 1000,
  });
  await assert.rejects(jobs[0].run(), err => {
    assert.equal(err.message, 'check-in Discord delivery failed');
    return true;
  });
});
