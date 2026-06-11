// routing.js — the pure decision core of the cto-watcher relay.
//
// Zero network, no discord.js. (It imports only the pure attachment filter from
// attachments.js — that helper does no I/O.) EVERYTHING-IN-BUS: directives,
// STATE declarations, revival pings, and shuttled CTO traffic all share the bus.
// There is NO separate state channel.
//
// The CPO communicates through EXACTLY TWO RIGID GRAMMARS on the bus; the watcher
// is a dumb deterministic parser (no interpretation):
//   DIRECTIVE: "[<cto-name>] <text>"                       -> shuttle to that CTO
//   STATE:     "STATE: <cto-name> <DRIVING|WAITING_FOR_OPERATOR|STOOD_DOWN>"
//                                                           -> declare state; NEVER shuttled
// A CPO bus message matching neither grammar is ignored for routing and resets
// nothing. Routing is by author id + grammar — content is never interpreted.

import { filterShuttleAttachments } from './attachments.js';

export const STATES = ['DRIVING', 'WAITING_FOR_OPERATOR', 'STOOD_DOWN'];

/**
 * @typedef {Object} InAttachment
 * @property {string} name      - original filename (e.g. "response.md")
 * @property {string} url       - CDN url index.js downloads the bytes from
 * @property {number} [size]    - bytes, when Discord reports it
 *
 * @typedef {Object} InMsg
 * @property {string} channelId
 * @property {string} authorId
 * @property {string} content        - EMPTY unless the MessageContent intent is on
 * @property {InAttachment[]} [attachments] - files on the message (any type); only
 *                                   .md/.txt ones are carried, see filterShuttleAttachments
 */

export function prepareContext(config, selfId) {
  if (!config || typeof config !== 'object') throw new Error('config must be an object');
  const { busChannelId, cpoBotUserId, ctoChannels } = config;
  const alertUserIds = config.alertUserIds ?? [];

  requireSnowflake('busChannelId', busChannelId);
  requireSnowflake('cpoBotUserId', cpoBotUserId);
  if (!Array.isArray(alertUserIds)) {
    throw new Error('alertUserIds must be an array of Discord user ids (operators to DM on a fail-closed event)');
  }
  alertUserIds.forEach((id, i) => requireSnowflake(`alertUserIds[${i}]`, id));

  if (!ctoChannels || typeof ctoChannels !== 'object' || Array.isArray(ctoChannels)) {
    throw new Error('ctoChannels must be an object map of { "name": {channelId, botUserId} }');
  }
  const names = Object.keys(ctoChannels);
  if (names.length === 0) throw new Error('ctoChannels is empty — the watcher has nothing to relay');

  const ctoByName = new Map(); // name -> { channelId, botUserId|null }
  const ctoById = new Map();   // channelId -> name
  for (const name of names) {
    const raw = ctoChannels[name];
    let channelId;
    let botUserId = null;
    let authorId = null;
    if (typeof raw === 'string') {
      channelId = raw;
    } else if (raw && typeof raw === 'object') {
      channelId = raw.channelId;
      botUserId = raw.botUserId ?? null;
      authorId = raw.authorId ?? null;
    } else {
      throw new Error(`ctoChannels["${name}"] must be a channel id string or { channelId, botUserId }`);
    }
    requireSnowflake(`ctoChannels["${name}"].channelId`, channelId);
    if (botUserId !== null) requireSnowflake(`ctoChannels["${name}"].botUserId`, botUserId);
    if (authorId !== null) requireSnowflake(`ctoChannels["${name}"].authorId`, authorId);
    if (ctoById.has(channelId)) {
      throw new Error(`ctoChannels has two names on the same channel id ${channelId} ("${ctoById.get(channelId)}" and "${name}") — ambiguous`);
    }
    if (channelId === busChannelId) throw new Error(`ctoChannels["${name}"] (${channelId}) is also the bus channel — invalid`);
    // authorId = the stable id the CTO posts under (its swarm bot). Defaults to
    // botUserId (same identity), since the CTO posts as, and is mentioned at, one bot.
    // This is the INBOUND author allowlist for CTO-channel -> bus shuttling (A1).
    ctoByName.set(name, { channelId, botUserId, authorId: authorId ?? botUserId });
    ctoById.set(channelId, name);
  }

  if (selfId && selfId === cpoBotUserId) {
    throw new Error('watcher selfId equals cpoBotUserId — the watcher must be its own bot identity');
  }

  // Operator channel id — LOOKUP KEY ONLY for the DM kill switch: locates the
  // operator group's allowFrom in access.json for authorization. The watcher does
  // NOT bind to, read, post in, or surface in this channel. Absent → kill switch
  // authorizes no one (fail-closed).
  const operatorChannelId = config.operatorChannelId ?? null;
  if (operatorChannelId !== null) requireSnowflake('operatorChannelId', operatorChannelId);

  // Liveness monitor (AUTO-mode accelerator). OFF unless explicitly enabled.
  // Thresholds tuned to the operator's distribution (work cycles ~20m, ~10% to 30m).
  const livenessEnabled = config.livenessEnabled === true;
  const silenceThresholdMs = Math.round((config.silenceThresholdSeconds ?? 1800) * 1000);
  const pingCooldownMs = Math.round((config.pingCooldownSeconds ?? 1800) * 1000);
  const checkIntervalMs = Math.round((config.checkIntervalSeconds ?? 60) * 1000);

  // Usage-limit overlay (RATE_LIMITED) — fed from swarm-watch's status.json (see
  // swarmstatus.js). resumeBuffer is the grace window after a cap lifts before a
  // resume nudge fires (lets Claude Code's own auto-resume come back first);
  // swarmStatusMaxAge bounds how stale the feed may be before we distrust it.
  const resumeBufferMs = Math.round((config.resumeBufferSeconds ?? 180) * 1000);
  const swarmStatusMaxAgeMs = Math.round((config.swarmStatusMaxAgeSeconds ?? 120) * 1000);

  // Attachment shuttling (.md/.txt repost). maxAttachmentBytes caps a single file's
  // re-upload (conservative 8 MiB default — under every Discord boost tier);
  // attachmentDownloadTimeout bounds the CDN fetch. Both overridable; may be omitted.
  const maxAttachmentBytes = Math.max(1, Math.round(config.maxAttachmentBytes ?? (8 * 1024 * 1024)));
  const attachmentDownloadTimeoutMs = Math.round((config.attachmentDownloadTimeoutSeconds ?? 15) * 1000);

  return {
    selfId, busChannelId, cpoBotUserId, alertUserIds, ctoByName, ctoById, operatorChannelId,
    livenessEnabled, silenceThresholdMs, pingCooldownMs, checkIntervalMs,
    resumeBufferMs, swarmStatusMaxAgeMs,
    maxAttachmentBytes, attachmentDownloadTimeoutMs,
  };
}

function requireSnowflake(field, val) {
  if (typeof val !== 'string' || !/^\d{5,25}$/.test(val)) {
    throw new Error(`${field} must be a Discord snowflake (numeric string), got: ${JSON.stringify(val)}`);
  }
}

/**
 * Parse ALL "STATE: <name> <STATE>" lines from a message (a message may carry
 * several, one per CTO). Deterministic, with normalization: the state token is
 * trimmed + uppercased and must exact-match the three-value enum; the name is
 * trimmed. A line whose enum isn't one of the three does not match.
 * @returns {{name: string, state: string}[]}
 */
export function parseStateLines(content) {
  if (typeof content !== 'string') return [];
  const out = [];
  for (const line of content.split('\n')) {
    const m = line.match(/^\s*STATE:\s+(\S+)\s+(DRIVING|WAITING_FOR_OPERATOR|STOOD_DOWN)\s*$/i);
    if (m) out.push({ name: m[1].trim(), state: m[2].toUpperCase() });
  }
  return out;
}

/** A "[<name>] <body>" directive, or null if the content doesn't begin with "[". */
export function parseDirective(content) {
  if (typeof content !== 'string') return null;
  const m = content.match(/^\s*\[([^\]\r\n]+)\] ?([\s\S]*)$/);
  if (!m) return null;
  return { name: m[1].trim(), body: m[2] };
}

export function formatForBus(name, body) {
  return `[${name}] ${body}`;
}

/**
 * The single routing decision for an inbound message. Returns one of:
 *  - { action: 'ignore',  reason }
 *  - { action: 'shuttle', toChannelId, text, mentionUserId, sourceName, attachments }  // CTO channel -> bus
 *  - { action: 'state',   states: [{name,state}], unknownNames: [name] }     // CPO STATE lines (never shuttled)
 *  - { action: 'route',   toChannelId, toName, text, mentionUserId, attachments }      // CPO directive -> CTO
 *  - { action: 'alert',   userIds, name }                                     // unknown directive name (fail closed)
 *
 * `attachments` (on shuttle/route) is the shuttle-eligible (.md/.txt) subset of the
 * message's files, in original order — index.js downloads + re-uploads them onto the
 * reposted message. Empty array when there are none. STATE/alert never carry files.
 *
 * Ordering on a CPO bus message: STATE grammar is matched BEFORE the directive
 * grammar, so a STATE line can never leak into a CTO channel; the only shuttle
 * trigger is a leading-"[" directive that is not a STATE message.
 */
export function decideRoute(msg, ctx) {
  // Loop guard first — covers shuttled traffic AND the watcher's own pings.
  if (msg.authorId === ctx.selfId) return { action: 'ignore', reason: 'self (loop guard)' };

  if (msg.channelId === ctx.busChannelId) {
    if (msg.authorId !== ctx.cpoBotUserId) {
      return { action: 'ignore', reason: 'bus message not authored by the CPO bot' };
    }
    // (b1) STATE grammar — matched first. Never shuttled.
    const states = parseStateLines(msg.content);
    if (states.length > 0) {
      const valid = [];
      const unknownNames = [];
      for (const s of states) {
        if (ctx.ctoByName.has(s.name)) valid.push(s);
        else unknownNames.push(s.name);
      }
      return { action: 'state', states: valid, unknownNames };
    }
    // (b2) DIRECTIVE grammar — leading "[". A file-only overflow directive carries
    // the bulk as an attached .md/.txt; the leading "[<name>]" still names the
    // destination (a CPO message with NO text has no "[name]" → falls through to b3
    // ignore, since there's no way to know which CTO it's for).
    const dir = parseDirective(msg.content);
    if (dir) {
      const dest = ctx.ctoByName.get(dir.name);
      if (!dest) return { action: 'alert', userIds: ctx.alertUserIds, name: dir.name };
      return {
        action: 'route',
        toChannelId: dest.channelId,
        toName: dir.name,
        text: dir.body,
        mentionUserId: dest.botUserId,
        attachments: filterShuttleAttachments(msg.attachments),
      };
    }
    // (b3) Neither grammar — not a routable/state/reset signal.
    return { action: 'ignore', reason: 'CPO bus message matches no grammar' };
  }

  // A CTO channel (id in the map).
  const sourceName = ctx.ctoById.get(msg.channelId);
  if (sourceName !== undefined) {
    const cto = ctx.ctoByName.get(sourceName);
    // A1 — INBOUND AUTHOR ALLOWLIST: shuttle ONLY messages authored by that
    // channel's designated CTO identity. Operator forwards, other bots, and
    // system messages are ignored (fail-closed if no author id is mapped).
    if (!cto.authorId || msg.authorId !== cto.authorId) {
      return { action: 'drop-foreign', sourceName, authorId: msg.authorId };
    }
    // It IS the CTO's own message -> counts as liveness activity regardless of body.
    const attachments = filterShuttleAttachments(msg.attachments);
    // A2 — EMPTY-CONTENT BACKSTOP: never shuttle empty text (forwards/embeds read
    // empty at top level), but still register the activity. EXCEPTION (overflow
    // case): a message that is ONLY a .md/.txt file has empty text yet is NOT
    // empty-for-shuttling — a long response sent purely as a file lives here. Skip
    // only when there's neither text NOR a shuttle-eligible file.
    if (msg.content.trim() === '' && attachments.length === 0) {
      return { action: 'skip-empty', sourceName, authorId: msg.authorId, ctoActivity: true };
    }
    return {
      action: 'shuttle',
      toChannelId: ctx.busChannelId,
      // Keep the "[name]" prefix even when the body is empty (file-only): it's the
      // routing key that tells the CPO which CTO the file came from.
      text: formatForBus(sourceName, msg.content),
      mentionUserId: ctx.cpoBotUserId,
      sourceName,
      ctoActivity: true,
      attachments,
    };
  }

  return { action: 'ignore', reason: 'channel is neither the bus nor a known CTO channel' };
}
