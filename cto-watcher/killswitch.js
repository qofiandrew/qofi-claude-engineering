// killswitch.js — DM-controlled soft-pause for the watcher.
//
// Pure + dependency-light so the lockout-critical auth is unit-tested. The DM
// wiring (intents, message handler, replies) lives in index.js; this module owns
// the command grammar, the fail-closed authorization read, and the pause state.
//
// AUTH MODEL (lockout-critical): a DM command is authorized ONLY if the sender's
// id is in the OPERATOR channel group's allowFrom in access.json — NOT the bus
// group (that's the watcher bot, which could never use the switch and would be a
// lockout). Read fresh at command time so #qofi-product membership drives it.
// Any failure to read/parse the ACL authorizes NO ONE (fail-closed).

import { readFileSync } from 'node:fs';

/** Recognize the three DM commands. Exact, case-insensitive, trimmed. Else null. */
export function parseDmCommand(content) {
  if (typeof content !== 'string') return null;
  switch (content.trim().toLowerCase()) {
    case '!watcher stop': return 'stop';
    case '!watcher start': return 'start';
    case '!watcher status': return 'status';
    default: return null;
  }
}

/**
 * Read groups[operatorChannelId].allowFrom from access.json. FAIL-CLOSED: returns
 * [] on a missing channel id, unreadable/malformed file, missing group, or a
 * non-array allowFrom — an unreadable ACL must authorize no one, never everyone.
 */
export function readOperatorAllowFrom(accessPath, operatorChannelId) {
  if (!operatorChannelId) return [];
  try {
    const access = JSON.parse(readFileSync(accessPath, 'utf8'));
    const group = access?.groups?.[operatorChannelId];
    return Array.isArray(group?.allowFrom) ? group.allowFrom : [];
  } catch {
    return []; // fail-closed
  }
}

/**
 * Decide a DM command. Authorized IFF it's a recognized command, arrived as a DM
 * (never a guild channel), and the sender is in the operator allowFrom.
 * @returns {{command: 'stop'|'start'|'status'|null, authorized: boolean, reason: string}}
 */
export function authorizeDm({ isDM, senderId, content, allowFrom }) {
  const command = parseDmCommand(content);
  if (!command) return { command: null, authorized: false, reason: 'not a command' };
  if (!isDM) return { command, authorized: false, reason: 'not a DM (guild message)' };
  const authorized = !!senderId && Array.isArray(allowFrom) && allowFrom.includes(senderId);
  return { command, authorized, reason: authorized ? 'ok' : 'sender not in operator allowFrom' };
}

/**
 * In-memory pause state. Default ACTIVE — so a pm2 restart always comes back
 * running (safe default; pause does NOT survive restart). relayHalted() and
 * livenessHalted() are the gates index.js checks before shuttling / pinging.
 */
export class KillSwitch {
  constructor() { this.paused = false; }
  stop() { this.paused = true; }
  start() { this.paused = false; }
  relayHalted() { return this.paused; }
  livenessHalted() { return this.paused; }
}
