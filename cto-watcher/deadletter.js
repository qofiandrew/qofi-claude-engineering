// deadletter.js — recoverable persistence for a relay delivery that could not be
// delivered after legitimate retries (or failed terminally on a deterministic
// error). The delivery queue's onDropped used to surface only an operator DM
// ("re-send by hand") — the message BODY was preserved nowhere. This writes the
// full job to a file so the content is recoverable, not lost.
//
// DATA-AT-REST (ADR-0010). Relay bodies can carry sensitive content, so a
// dead-letter file gets the same hygiene as tokens.env: it is written chmod 600
// in a gitignored directory the operator owns. Retention is operator-cleared
// (no auto-prune): a dropped delivery is a failure that already paged a human, so
// the file persists until the operator reads it and deletes it.
//
// Pure except for the injected `dir`: no Date / Math.random in the signature
// (ts + rand are injectable) so the write is deterministic under test.

import { mkdirSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';

/** Slugify a label into a safe, bounded filename fragment. */
function slugify(label) {
  return String(label ?? 'delivery').replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48) || 'delivery';
}

/**
 * Write one dropped delivery to a recoverable, chmod-600 JSON file under `dir`.
 * The job's recoverable fields (channelId, body, mention, label) are captured at
 * enqueue time (the queue's `run` closure isn't serializable). Returns the path.
 *
 * @param {{
 *   dir: string,
 *   job: {label?:string, channelId?:string, body?:string, mention?:string|null},
 *   err: any,
 *   attempts: number,
 *   ts?: number,
 *   rand?: string,
 * }} args
 * @returns {string} the dead-letter file path
 */
export function writeDeadLetter({ dir, job, err, attempts, ts = Date.now(), rand }) {
  if (!dir) throw new Error('writeDeadLetter requires a dir');
  const suffix = rand ?? Math.random().toString(36).slice(2, 8);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const name = `${ts}-${slugify(job?.label)}-${suffix}.json`;
  const path = join(dir, name);
  const record = {
    ts,
    label: job?.label ?? null,
    channelId: job?.channelId ?? null,
    mention: job?.mention ?? null,
    attempts,
    error: err?.message ?? String(err),
    body: job?.body ?? null,
  };
  // mode on writeFileSync only applies when the file is CREATED and is masked by
  // umask, so chmod explicitly afterwards to guarantee 600 regardless of umask.
  writeFileSync(path, JSON.stringify(record, null, 2) + '\n', { mode: 0o600 });
  chmodSync(path, 0o600);
  return path;
}
