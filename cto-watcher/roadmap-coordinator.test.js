import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RoadmapCoordinator } from './roadmap-coordinator.js';

const CONTRACT = {
  checkin_schema: 'qofi.cto-checkin/v1',
  normalized_event_schema: 'qofi-swarm-event/v1',
  roadmap_schema: 'qofi-swarm-roadmap/v1',
  roadmap_query_command: '!watcher roadmap',
  swarm_states: ['DRIVING', 'WAITING_FOR_OPERATOR', 'STOOD_DOWN'],
  contract_sha256: 'a'.repeat(64),
};

function document(status = 'DRIVING') {
  return {
    schema: 'qofi-swarm-roadmap/v1', parity_matrix: 'docs/RUNTIME-PARITY.md',
    generated_at: '2026-07-13T10:00:00.000Z',
    items: { 'ADR-0023': { status } },
  };
}

test('authenticated surface matches shared command and queues a phone-sized query', async () => {
  const jobs = [];
  const replies = [];
  const policy = {
    contract: async () => CONTRACT,
    roadmapQuery: async () => ({ text: '🧭 Roadmap\nADR-0023 · DRIVING · press-backend' }),
    activeTask: async () => ({ bound: true, current_task: 'task-42', state: 'DRIVING', event_at: '2026-07-13T10:00:00.000Z' }),
  };
  const coordinator = new RoadmapCoordinator({
    policy, store: { repoRoot: '/repo', authorityFile: '/private/authority' },
    enqueue: job => jobs.push(job), deliver: async () => {}, digestChannelId: '1510301812434141194',
    digestIntervalMs: 60_000, queryEnabled: true,
  });
  await coordinator.initialize();
  assert.equal(coordinator.matchesQuery('  !WATCHER ROADMAP '), true);
  assert.equal(coordinator.matchesQuery('roadmap'), false);
  assert.deepEqual(await coordinator.resolveTask('press-backend', 'DRIVING', 'ping-1'), {
    bound: true, current_task: 'task-42', state: 'DRIVING', event_at: '2026-07-13T10:00:00.000Z',
  });
  await coordinator.enqueueQuery({ channelId: '1', reply: text => replies.push(text) });
  assert.equal(replies.length, 0);
  await jobs.shift().run();
  assert.match(replies[0], /^🧭 Roadmap/);
});

test('scheduled digest serializes loads, advances only after queued delivery, and retries after drop', async () => {
  const jobs = [];
  const sent = [];
  let loads = 0;
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  const policy = {
    contract: async () => CONTRACT,
    roadmapQuery: async () => ({ text: 'query' }),
    activeTask: async () => ({ bound: false, current_task: 'pending-000000000000000000000000' }),
    roadmapDigest: async () => { loads++; await blocked; return { text: '📍 Roadmap digest\nMoved\nADR-0023', document: document() }; },
  };
  const coordinator = new RoadmapCoordinator({
    policy, store: { repoRoot: '/repo', authorityFile: '/private/authority' },
    enqueue: job => jobs.push(job), deliver: async (...args) => sent.push(args),
    digestChannelId: '1510301812434141194', digestIntervalMs: 60_000, enabled: true,
  });
  await coordinator.initialize();
  const first = coordinator.tick(1000);
  const overlapping = await coordinator.tick(1001);
  assert.equal(overlapping, false);
  assert.equal(loads, 1);
  release();
  assert.equal(await first, true);
  assert.equal(jobs.length, 1);
  assert.equal(coordinator.deliveryDropped(jobs[0]), true);
  assert.equal(await coordinator.tick(1002), true, 'drop leaves digest due');
  await jobs.pop().run();
  assert.equal(sent.length, 1);
  assert.equal(await coordinator.tick(60_000), false, 'interval measured from successful delivery');
  assert.equal(await coordinator.tick(61_003), true);
});

test('missing trusted artifact yields explicit unavailable query and unbound task, never invented status', async () => {
  const jobs = [];
  const replies = [];
  const policy = {
    contract: async () => CONTRACT,
    roadmapQuery: async () => { throw new Error('authority missing'); },
    activeTask: async store => {
      if (store.eventStoreDirectory) throw new Error('journal missing');
      return { bound: false, current_task: 'pending-111111111111111111111111', state: 'DRIVING', event_at: null };
    },
  };
  const coordinator = new RoadmapCoordinator({
    policy, store: { repoRoot: '/repo', authorityFile: '/private/authority' },
    enqueue: job => jobs.push(job), deliver: async () => {}, digestChannelId: '1510301812434141194',
    digestIntervalMs: 60_000, queryEnabled: true,
  });
  await coordinator.initialize();
  assert.deepEqual(await coordinator.resolveTask('press-backend', 'DRIVING', 'ping-1'), {
    bound: false, current_task: 'pending-111111111111111111111111', state: 'DRIVING', event_at: null,
  });
  await coordinator.enqueueQuery({ channelId: '1', reply: text => replies.push(text) });
  await jobs.shift().run();
  assert.equal(replies[0], '🧭 Roadmap unavailable · harness artifact not readable');
});

test('roadmap Discord errors are sanitized before the shared retry/dead-letter queue sees them', async () => {
  const jobs = [];
  const policy = {
    contract: async () => CONTRACT,
    roadmapQuery: async () => ({ text: '🧭 Roadmap\nADR-0023 · DRIVING · press-backend' }),
    activeTask: async () => ({ bound: false, current_task: 'pending-000000000000000000000000' }),
  };
  const coordinator = new RoadmapCoordinator({
    policy, store: { repoRoot: '/repo', authorityFile: '/private/authority' },
    enqueue: job => jobs.push(job), deliver: async () => {}, digestChannelId: '1510301812434141194',
    digestIntervalMs: 60_000,
  });
  await coordinator.initialize();
  await coordinator.enqueueQuery({
    channelId: '1',
    reply: async () => { throw new Error('secret-provider-account-identifier'); },
  });
  await assert.rejects(jobs[0].run(), err => {
    assert.equal(err.message, 'roadmap Discord delivery failed');
    return true;
  });
});
