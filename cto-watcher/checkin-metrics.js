// Owner-private append-only ping-to-check-in metrics. Records labels, outcomes,
// and latency only; candidate/progress text never enters this journal.

import {
  constants,
  closeSync,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  openSync,
  realpathSync,
  writeFileSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';

const METRIC_SCHEMA = 'qofi.cto-checkin-metric/v1';
const MAX_METRIC_BYTES = 8192;
const MAX_JOURNAL_BYTES = 16 * 1024 * 1024;

function assertPrivateDirectory(path) {
  const resolved = resolve(path);
  const stat = lstatSync(resolved);
  const uid = process.getuid?.();
  if (!stat.isDirectory()
    || stat.isSymbolicLink()
    || uid === undefined
    || stat.uid !== uid
    || (stat.mode & 0o777) !== 0o700
    || realpathSync(resolved) !== resolved) {
    throw new Error('check-in metric parent must be an owner-real mode 0700 directory with no symlinked component');
  }
  return { path: resolved, dev: stat.dev, ino: stat.ino };
}

export class CheckInMetricJournal {
  constructor(path) {
    if (typeof path !== 'string' || !path) throw new Error('check-in metric path is required');
    this.path = resolve(path);
    this.parent = assertPrivateDirectory(dirname(this.path));
  }

  append(metric) {
    if (!metric || metric.schema !== METRIC_SCHEMA) throw new Error('check-in metric schema is invalid');
    const safe = {
      schema: metric.schema,
      ping_id: metric.ping_id,
      addressee: metric.addressee,
      current_task: metric.current_task,
      outcome: metric.outcome,
      latency_ms: metric.latency_ms,
      attempt: metric.attempt,
      errors: metric.errors,
      recorded_at_ms: metric.recorded_at_ms,
    };
    const line = `${JSON.stringify(safe)}\n`;
    const lineBytes = Buffer.byteLength(line);
    if (lineBytes > MAX_METRIC_BYTES) throw new Error('check-in metric exceeds bound');
    // Revalidate every append. Provisioning owns this directory; the watcher
    // never mkdir/chmods through a path that could have been substituted.
    const beforeParent = assertPrivateDirectory(dirname(this.path));
    if (beforeParent.path !== this.parent.path
      || beforeParent.dev !== this.parent.dev
      || beforeParent.ino !== this.parent.ino) {
      throw new Error('check-in metric parent identity changed');
    }
    const noFollow = constants.O_NOFOLLOW ?? 0;
    const fd = openSync(this.path, constants.O_WRONLY | constants.O_CREAT | constants.O_APPEND | noFollow, 0o600);
    try {
      const stat = fstatSync(fd);
      const uid = process.getuid?.();
      if (!stat.isFile()
        || stat.nlink !== 1
        || uid === undefined
        || stat.uid !== uid
        || (stat.mode & 0o777) !== 0o600) {
        throw new Error('check-in metric journal must be owner-regular single-link');
      }
      if (stat.size < 0 || stat.size + lineBytes > MAX_JOURNAL_BYTES) {
        throw new Error('check-in metric journal exceeds bound');
      }
      const afterParent = assertPrivateDirectory(dirname(this.path));
      if (afterParent.path !== beforeParent.path
        || afterParent.dev !== beforeParent.dev
        || afterParent.ino !== beforeParent.ino) {
        throw new Error('check-in metric parent changed while opening journal');
      }
      const stable = fstatSync(fd);
      if (stable.dev !== stat.dev || stable.ino !== stat.ino || stable.nlink !== 1
        || stable.uid !== stat.uid || stable.mode !== stat.mode || stable.size !== stat.size) {
        throw new Error('check-in metric journal changed while opening');
      }
      fchmodSync(fd, 0o600);
      writeFileSync(fd, line);
      // Accepted metrics are compliance evidence. Return only after the append
      // is durable to the file; directory creation/rename is not involved.
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
  }
}
