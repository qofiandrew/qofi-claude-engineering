import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  chmodSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CheckInMetricJournal } from './checkin-metrics.js';

test('latency journal is owner-private and excludes check-in prose', () => {
  const root = mkdtempSync(join(tmpdir(), 'watcher-checkin-metric-'));
  try {
    const privateDir = join(realpathSync(root), 'private');
    mkdirSync(privateDir, { mode: 0o700 });
    chmodSync(privateDir, 0o700);
    const path = join(privateDir, 'metrics.jsonl');
    new CheckInMetricJournal(path).append({
      schema: 'qofi.cto-checkin-metric/v1',
      ping_id: 'idle-1', addressee: 'press-backend', current_task: 'task-42',
      outcome: 'accepted', latency_ms: 412, attempt: 1, errors: [], recorded_at_ms: 1000,
      progress_since_last_checkin: 'must never be persisted',
    });
    assert.equal(lstatSync(path).mode & 0o777, 0o600);
    const stored = readFileSync(path, 'utf8');
    assert.match(stored, /"latency_ms":412/);
    assert.doesNotMatch(stored, /must never/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('metric journal rejects loose/symlinked/substituted parents and hard-linked files', () => {
  const root = mkdtempSync(join(tmpdir(), 'watcher-checkin-boundary-'));
  try {
    const realRoot = realpathSync(root);
    const privateDir = join(realRoot, 'private');
    mkdirSync(privateDir, { mode: 0o700 });
    chmodSync(privateDir, 0o755);
    assert.throws(() => new CheckInMetricJournal(join(privateDir, 'metrics.jsonl')), /0700/);
    chmodSync(privateDir, 0o700);

    const linkDir = join(realRoot, 'link');
    symlinkSync(privateDir, linkDir);
    assert.throws(() => new CheckInMetricJournal(join(linkDir, 'metrics.jsonl')), /symlinked component/);

    const path = join(privateDir, 'metrics.jsonl');
    const journal = new CheckInMetricJournal(path);
    const metric = {
      schema: 'qofi.cto-checkin-metric/v1', ping_id: 'idle-1', addressee: 'press-backend',
      current_task: 'task-42', outcome: 'accepted', latency_ms: 1, attempt: 1,
      errors: [], recorded_at_ms: 2,
    };
    journal.append(metric);
    chmodSync(path, 0o644);
    assert.throws(() => journal.append(metric), /owner-regular/);
    chmodSync(path, 0o600);
    const outsideLink = join(realRoot, 'hardlink');
    linkSync(path, outsideLink);
    assert.throws(() => journal.append(metric), /single-link/);
    rmSync(outsideLink);

    const oldDir = join(realRoot, 'old-private');
    renameSync(privateDir, oldDir);
    mkdirSync(privateDir, { mode: 0o700 });
    chmodSync(privateDir, 0o700);
    assert.throws(() => journal.append(metric), /identity changed/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
