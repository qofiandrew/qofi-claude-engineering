// swarmstatus.js — read the swarm-watch status.json feed for per-CTO usage-limit state.
//
// `bin/swarm-watch.sh` scrapes each swarm's tmux pane and writes a swarm-status/v1
// JSON snapshot to $SWARM_STATE_DIR/status.json every tick. The cto-watcher
// CANNOT see the tmux pane — but it runs on the same host and CAN read that local
// file to learn which CTOs are paused on a Claude usage / 5-hour limit (a swarm
// whose `state` is "paused-limit"). That lets the watcher stop firing useless
// revival pings at a capped loop (a throttled session can't act on them) and
// instead wait for the cap to clear. This module is the READ side only — pure
// parse + a thin file-reading wrapper; the overlay logic lives in liveness.js.
//
// Trust model — fail-SAFE, "don't know" beats "guess": if the feed is missing,
// unreadable, malformed, or STALE (generated_at too old ⇒ swarm-watch is probably
// dead), we return null and the caller leaves each CTO's limit overlay UNCHANGED.
// A successfully-read, fresh snapshot is authoritative: a CTO absent from it, or
// present with any state other than "paused-limit", is treated as NOT limited.

import { readFileSync } from 'node:fs';

const PAUSED_LIMIT = 'paused-limit'; // swarm-status/v1 enum value for a usage-cap pause

/**
 * Parse a swarm-status/v1 snapshot into a per-name limit map. PURE (no I/O) so
 * the shape + staleness logic is unit-testable. Returns null when the snapshot
 * is unusable — malformed JSON, wrong shape, an unparseable/absent `generated_at`,
 * or older than maxAgeMs. Otherwise a Map<name, {paused, resetHint}>.
 *
 * @param {string} text      raw status.json contents
 * @param {number} nowMs     current epoch ms (caller-supplied for testability)
 * @param {number} [maxAgeMs] max age of generated_at before the snapshot is stale;
 *                            omit/undefined to skip the staleness guard
 * @returns {Map<string, {paused: boolean, resetHint: string|null}> | null}
 */
export function parseSwarmLimitStates(text, nowMs, maxAgeMs) {
  let snap;
  try { snap = JSON.parse(text); } catch { return null; }
  if (!snap || typeof snap !== 'object' || !Array.isArray(snap.swarms)) return null;

  // Staleness guard: a snapshot whose generated_at is too old means swarm-watch
  // stopped writing — distrust it so we neither clear a real limit nor hold a
  // phantom one off dead data. An unparseable/absent timestamp is itself reason
  // to distrust the snapshot. generated_at is UTC "…Z" (Date.parse handles it).
  if (maxAgeMs != null) {
    const genMs = Date.parse(snap.generated_at);
    if (!Number.isFinite(genMs)) return null;
    if (nowMs - genMs > maxAgeMs) return null;
  }

  const byName = new Map();
  for (const sw of snap.swarms) {
    if (!sw || typeof sw.name !== 'string') continue;
    byName.set(sw.name, {
      paused: sw.state === PAUSED_LIMIT,
      resetHint: typeof sw.limit_reset_hint === 'string' ? sw.limit_reset_hint : null,
    });
  }
  return byName;
}

/**
 * Read + parse the feed file. Returns null on ANY failure (missing/unreadable
 * file OR unusable contents per parseSwarmLimitStates) — the caller treats null
 * as "leave the overlay unchanged". Never throws.
 *
 * @returns {Map<string, {paused: boolean, resetHint: string|null}> | null}
 */
export function readSwarmLimitStates(path, nowMs, maxAgeMs) {
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { return null; }
  return parseSwarmLimitStates(text, nowMs, maxAgeMs);
}
