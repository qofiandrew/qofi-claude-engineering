import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { HarnessPolicyClient } from './harness-policy-client.js';

const HERE = dirname(fileURLToPath(import.meta.url));

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

test('Bun helper exposes byte-bound shared schemas and exact state vocabulary', async () => {
  const contract = await new HarnessPolicyClient({ timeoutMs: 10_000 }).contract();
  const expected = {
    checkin_schema: 'qofi.cto-checkin/v1',
    normalized_event_schema: 'qofi-swarm-event/v1',
    roadmap_schema: 'qofi-swarm-roadmap/v1',
    roadmap_query_command: '!watcher roadmap',
    swarm_states: ['DRIVING', 'WAITING_FOR_OPERATOR', 'STOOD_DOWN'],
  };
  assert.deepEqual({ ...contract, contract_sha256: undefined }, { ...expected, contract_sha256: undefined });
  assert.equal(
    contract.contract_sha256,
    createHash('sha256').update(canonical(expected)).digest('hex'),
    'Node adapter pins the exact canonical bytes exported by swarm-harness',
  );
});

test('check-in render and validation are delegated to swarm-harness policy', async () => {
  const policy = new HarnessPolicyClient({ timeoutMs: 10_000 });
  const ping = {
    pingId: 'idle-press-1',
    channelId: '1510131439906066442',
    addressee: 'press-backend',
    currentTask: 'task-42',
    sentAtMs: 1000,
  };
  const rendered = await policy.renderCheckIn(ping);
  assert.match(rendered.text, /qofi\.cto-checkin\/v1/);
  assert.match(rendered.text, /bare acknowledgment is invalid/i);

  const expected = {
    pingId: ping.pingId,
    addressee: ping.addressee,
    currentTask: ping.currentTask,
    status: 'DRIVING',
  };
  assert.deepEqual(await policy.validateCheckIn('ok', expected), {
    ok: false,
    value: null,
    errors: ['bare acknowledgment is not a check-in'],
  });
  const candidate = {
    schema: 'qofi.cto-checkin/v1',
    ping_id: ping.pingId,
    addressee: ping.addressee,
    current_task: ping.currentTask,
    status: 'DRIVING',
    progress_since_last_checkin: 'Implemented the result-set intake.',
    blockers: [],
    next_action: 'Run the parity fixtures.',
    needs_input: false,
  };
  const valid = await policy.validateCheckIn(candidate, expected);
  assert.equal(valid.ok, true);
  assert.deepEqual(valid.value, candidate);
});

test('policy client bounds payloads and kills a stuck helper', async () => {
  const root = mkdtempSync(join(tmpdir(), 'watcher-policy-timeout-'));
  try {
    const helper = join(root, 'hang.js');
    writeFileSync(helper, 'setInterval(() => {}, 1000)\n');
    const client = new HarnessPolicyClient({ bunPath: process.execPath, helperPath: helper, timeoutMs: 100 });
    await assert.rejects(client.contract(), /timed out/);
    await assert.rejects(
      new HarnessPolicyClient().run('checkin.validate', { candidate: 'x'.repeat(70_000), expected: {} }),
      /exceeds bound/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('roadmap query/task/digest read the CAS-bound harness artifact, not self-report', async () => {
  const root = mkdtempSync(join(tmpdir(), 'watcher-roadmap-policy-'));
  try {
    const repo = join(root, 'repo');
    const privateDir = join(root, 'private');
    const authorityFile = join(privateDir, 'authority.json');
    const eventStoreDirectory = join(root, 'events');
    mkdirSync(repo);
    mkdirSync(privateDir, { mode: 0o700 });
    mkdirSync(eventStoreDirectory, { mode: 0o700 });
    chmodSync(privateDir, 0o700);
    chmodSync(eventStoreDirectory, 0o700);
    const seed = join(root, 'seed.ts');
    const roadmapUrl = pathToFileURL(join(HERE, '..', 'swarm-harness', 'roadmap.ts')).href;
    const eventsUrl = pathToFileURL(join(HERE, '..', 'swarm-harness', 'events.ts')).href;
    const eventStoreUrl = pathToFileURL(join(HERE, '..', 'swarm-harness', 'event-store.ts')).href;
    writeFileSync(seed, [
      `import { RoadmapStore } from ${JSON.stringify(roadmapUrl)}`,
      `import { makeHarnessEvent } from ${JSON.stringify(eventsUrl)}`,
      `import { NormalizedEventStore } from ${JSON.stringify(eventStoreUrl)}`,
      'const [repo, authorityFile, eventStoreDirectory] = process.argv.slice(2)',
      "const event = makeHarnessEvent({ ts:'2026-07-13T10:00:00Z', type:'task.started', runtime:'claude', source:'harness', swarm:'press-backend', task_id:'task-42', dr_refs:['ADR-0023'], state:'DRIVING' })",
      'new NormalizedEventStore(eventStoreDirectory, { repoRoot: repo }).append(event)',
      'new RoadmapStore(repo, authorityFile).writeDerived([event])',
    ].join('\n'));
    const seeded = spawnSync('bun', [seed, repo, authorityFile, eventStoreDirectory], { encoding: 'utf8' });
    assert.equal(seeded.status, 0, seeded.stderr);

    const client = new HarnessPolicyClient({ timeoutMs: 10_000 });
    const store = { repoRoot: repo, authorityFile, eventStoreDirectory };
    const query = await client.roadmapQuery(store);
    assert.match(query.text, /ADR-0023 · DRIVING · press-backend/);
    assert.deepEqual(await client.activeTask(store, 'press-backend', 'DRIVING', 'ping-1'), {
      bound: true,
      current_task: 'task-42',
      state: 'DRIVING',
      event_at: '2026-07-13T10:00:00.000Z',
    });
    const unbound = await client.activeTask({ repoRoot: repo }, 'press-backend', 'DRIVING', 'ping-2');
    assert.equal(unbound.bound, false);
    assert.match(unbound.current_task, /^pending-[a-f0-9]{24}$/);
    assert.notEqual(unbound.current_task, 'ADR-0023');
    const digest = await client.roadmapDigest(store, null);
    assert.match(digest.text, /ADR-0023 · NEW→DRIVING · press-backend/);

    writeFileSync(join(repo, '.swarm-roadmap.json'), '{}\n');
    await assert.rejects(client.roadmapQuery(store), /authority does not match artifact/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
