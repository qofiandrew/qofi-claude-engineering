// deadletter.test.js — the recoverable dead-letter writer. Verifies the file
// carries the full job record AND lands chmod 600 (a ratified constraint —
// ADR-0010 — because relay bodies can carry sensitive content). ts + rand are
// injected so the write is deterministic; the dir is a throwaway tmpdir.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writeDeadLetter } from './deadletter.js';

test('writeDeadLetter: writes the full job record to a recoverable file', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dl-'));
  try {
    const job = {
      label: 'CTO->bus src="reserve-backend-2"',
      channelId: 'C123', body: 'the full undelivered body', mention: 'U9',
    };
    const err = new Error('Invalid Form Body content[BASE_TYPE_MAX_LENGTH]');
    const path = writeDeadLetter({ dir, job, err, attempts: 1, ts: 1700000000000, rand: 'abc123' });
    const rec = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal(rec.label, job.label);
    assert.equal(rec.channelId, 'C123');
    assert.equal(rec.body, 'the full undelivered body', 'the body is preserved for recovery');
    assert.equal(rec.mention, 'U9');
    assert.equal(rec.attempts, 1);
    assert.match(rec.error, /BASE_TYPE_MAX_LENGTH/);
    assert.equal(rec.ts, 1700000000000);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeDeadLetter: the file lands chmod 600 (ratified data-at-rest constraint)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dl-'));
  try {
    const path = writeDeadLetter({ dir, job: { label: 'x', body: 'secret-ish' }, err: new Error('boom'), attempts: 4, ts: 1, rand: 'r' });
    const mode = statSync(path).mode & 0o777;
    assert.equal(mode, 0o600, `expected 600, got ${mode.toString(8)}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeDeadLetter: a missing dir throws (fail-loud, not a silent no-op)', () => {
  assert.throws(() => writeDeadLetter({ dir: '', job: {}, err: new Error('x'), attempts: 1 }), /requires a dir/);
});
