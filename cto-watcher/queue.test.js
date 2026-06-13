// queue.test.js — dry-run of the serial delivery queue. No discord.js, no real
// timers: `send` and `sleep` are injected so we drive ordering, retry, give-up,
// and escalation deterministically. The headline test reproduces the original
// bug — a multi-channel burst where one channel's send transiently fails — and
// proves the queue now retries it through instead of dropping it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DeliveryQueue, defaultIsRetryable } from './queue.js';

const noSleep = async () => {}; // collapse backoff to nothing in tests

test('serializes: deliveries run one at a time, in FIFO order', async () => {
  const order = [];
  let inFlight = 0;
  let maxConcurrent = 0;
  const q = new DeliveryQueue({
    sleep: noSleep,
    send: async (job) => {
      inFlight++;
      maxConcurrent = Math.max(maxConcurrent, inFlight);
      await Promise.resolve(); // yield — a parallel impl would interleave here
      order.push(job.id);
      inFlight--;
    },
  });

  for (let i = 0; i < 5; i++) q.enqueue({ id: i });
  await q.onIdle();

  assert.deepEqual(order, [0, 1, 2, 3, 4]); // FIFO preserved
  assert.equal(maxConcurrent, 1);           // never two in flight
  assert.equal(q.stats.delivered, 5);
});

test('retries a transient failure, then succeeds — nothing dropped', async () => {
  let attempts = 0;
  const dropped = [];
  const q = new DeliveryQueue({
    sleep: noSleep,
    onDropped: (job) => dropped.push(job),
    send: async () => {
      attempts++;
      if (attempts < 3) throw new Error('HTTP 429'); // fails twice, then ok
    },
  });

  q.enqueue({ id: 'x' }, 'bus->CTO dst="press-backend"');
  await q.onIdle();

  assert.equal(attempts, 3);
  assert.equal(q.stats.delivered, 1);
  assert.equal(q.stats.dropped, 0);
  assert.deepEqual(dropped, []);
});

test('exhausts retries → escalates via onDropped exactly once, never silently', async () => {
  const dropped = [];
  const q = new DeliveryQueue({
    sleep: noSleep,
    maxAttempts: 4,
    onDropped: (job, err, attempts) => dropped.push({ job, msg: err.message, attempts }),
    send: async () => { throw new Error('HTTP 500'); }, // always fails
  });

  q.enqueue({ id: 'press-backend-directive' }, 'bus->CTO dst="press-backend"');
  await q.onIdle();

  assert.equal(q.stats.delivered, 0);
  assert.equal(q.stats.dropped, 1);
  assert.equal(dropped.length, 1);                 // surfaced exactly once
  assert.equal(dropped[0].attempts, 4);
  assert.equal(dropped[0].job.id, 'press-backend-directive');
});

test('a failing job does not block the rest of the queue', async () => {
  const delivered = [];
  const dropped = [];
  const q = new DeliveryQueue({
    sleep: noSleep,
    maxAttempts: 2,
    onDropped: (job) => dropped.push(job.id),
    send: async (job) => {
      if (job.id === 'bad') throw new Error('always fails');
      delivered.push(job.id);
    },
  });

  q.enqueue({ id: 'a' });
  q.enqueue({ id: 'bad' });
  q.enqueue({ id: 'b' });
  await q.onIdle();

  assert.deepEqual(delivered, ['a', 'b']); // good ones still delivered, in order
  assert.deepEqual(dropped, ['bad']);      // the bad one escalated, not silently lost
});

test('REPRO: multi-channel burst with one transient failure — old path dropped it, queue does not', async () => {
  // Four channels' messages arrive in the SAME tick (a burst). press-backend's
  // send transiently fails on its first attempt — exactly the scenario that used
  // to drop it while the other three went through. With the queue it retries and
  // every channel is delivered, in arrival order.
  const delivered = [];
  const dropped = [];
  const failedOnce = new Set();
  const q = new DeliveryQueue({
    sleep: noSleep,
    onDropped: (job) => dropped.push(job.dst),
    send: async (job) => {
      if (job.dst === 'press-backend' && !failedOnce.has('press-backend')) {
        failedOnce.add('press-backend');
        throw new Error('HTTP 429 (rate limited)'); // transient, first attempt only
      }
      delivered.push(job.dst);
    },
  });

  // The burst: enqueued synchronously, back to back, like messageCreate firing rapidly.
  for (const dst of ['reserve-backend-2', 'qofi-ios-app', 'press-backend', 'press-fileops']) {
    q.enqueue({ dst }, `bus->CTO dst="${dst}"`);
  }
  await q.onIdle();

  assert.ok(delivered.includes('press-backend'), 'press-backend must NOT be dropped');
  assert.deepEqual(
    delivered,
    ['reserve-backend-2', 'qofi-ios-app', 'press-backend', 'press-fileops'],
    'all four delivered, FIFO order preserved even though press-backend retried',
  );
  assert.deepEqual(dropped, []);
  assert.equal(q.stats.retried, 1); // exactly the one transient retry
});

test('onIdle resolves immediately when never used', async () => {
  const q = new DeliveryQueue({ send: async () => {} });
  await q.onIdle(); // must not hang
  assert.equal(q.depth, 0);
});

test('jobs enqueued mid-drain are still processed (no lost tail)', async () => {
  const delivered = [];
  let q;
  q = new DeliveryQueue({
    sleep: noSleep,
    send: async (job) => {
      delivered.push(job.id);
      if (job.id === 1) q.enqueue({ id: 2 }); // enqueue during the drain of job 1
    },
  });
  q.enqueue({ id: 1 });
  await q.onIdle();
  assert.deepEqual(delivered, [1, 2]);
});

// ── retry classifier: deterministic vs transient ─────────────────────────────

test('defaultIsRetryable: deterministic 4xx (≠429) is terminal; 429/5xx/network retry', () => {
  // terminal — no retry
  assert.equal(defaultIsRetryable({ status: 400 }), false);   // BASE_TYPE_MAX_LENGTH (the bug)
  assert.equal(defaultIsRetryable({ status: 413 }), false);   // payload too large (overflow .md path)
  assert.equal(defaultIsRetryable({ status: 404 }), false);
  assert.equal(defaultIsRetryable({ httpStatus: 403 }), false);
  // transient — retry
  assert.equal(defaultIsRetryable({ status: 429 }), true);    // rate limit
  assert.equal(defaultIsRetryable({ status: 500 }), true);
  assert.equal(defaultIsRetryable({ status: 503 }), true);
  assert.equal(defaultIsRetryable(new Error('ECONNRESET')), true); // no status -> network
  assert.equal(defaultIsRetryable({ code: 'ABORT_ERR' }), true);   // no http status
});

test('classifier: a non-retryable 400 is terminal on the FIRST attempt — no wasted retries (the bug)', async () => {
  let attempts = 0;
  const dropped = [];
  const q = new DeliveryQueue({
    sleep: noSleep,
    send: async () => { attempts++; const e = new Error('content too long'); e.status = 400; throw e; },
    onDropped: (job, err, n) => dropped.push({ label: job.label, n }),
  });
  q.enqueue({ label: 'CTO->bus' }, 'CTO->bus');
  await q.onIdle();
  assert.equal(attempts, 1, 'a deterministic 400 is tried exactly once, not 4 times');
  assert.deepEqual(dropped, [{ label: 'CTO->bus', n: 1 }]);
  assert.equal(q.stats.dropped, 1);
  assert.equal(q.stats.retried, 0);
});

test('classifier: a transient 429 retries to the bound, THEN dead-letters with the recoverable job', async () => {
  let attempts = 0;
  let droppedJob = null;
  const q = new DeliveryQueue({
    sleep: noSleep,
    maxAttempts: 4,
    send: async () => { attempts++; const e = new Error('rate limited'); e.status = 429; throw e; },
    onDropped: (job, err, n) => { droppedJob = { job, n }; },
  });
  q.enqueue({ label: 'bus->CTO', channelId: 'C9', body: 'hello', mention: 'U1' }, 'bus->CTO');
  await q.onIdle();
  assert.equal(attempts, 4, 'transient error uses every attempt');
  assert.equal(droppedJob.n, 4);
  // onDropped receives the job with its recoverable fields → the dead-letter can serialize them.
  assert.equal(droppedJob.job.channelId, 'C9');
  assert.equal(droppedJob.job.body, 'hello');
});

test('classifier: a 503 that later succeeds is delivered, not dropped', async () => {
  let attempts = 0;
  const q = new DeliveryQueue({
    sleep: noSleep,
    send: async () => { attempts++; if (attempts < 2) { const e = new Error('5xx'); e.status = 503; throw e; } },
    onDropped: () => { throw new Error('should not drop a recovered delivery'); },
  });
  q.enqueue({ label: 'x' });
  await q.onIdle();
  assert.equal(attempts, 2);
  assert.equal(q.stats.delivered, 1);
  assert.equal(q.stats.dropped, 0);
});
