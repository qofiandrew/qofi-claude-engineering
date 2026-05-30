// routing.js — the pure decision core of the cto-watcher relay.
//
// Zero dependencies (no discord.js, no network). EVERYTHING-IN-BUS: directives,
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

export const STATES = ['DRIVING', 'WAITING_FOR_OPERATOR', 'STOOD_DOWN'];

/**
 * @typedef {Object} InMsg
 * @property {string} channelId
 * @property {string} authorId
 * @property {string} content   - EMPTY unless the MessageContent intent is on
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

  // Liveness monitor (AUTO-mode accelerator). OFF unless explicitly enabled.
  // Thresholds tuned to the operator's distribution (work cycles ~20m, ~10% to 30m).
  const livenessEnabled = config.livenessEnabled === true;
  const silenceThresholdMs = Math.round((config.silenceThresholdSeconds ?? 1800) * 1000);
  const pingCooldownMs = Math.round((config.pingCooldownSeconds ?? 1800) * 1000);
  const checkIntervalMs = Math.round((config.checkIntervalSeconds ?? 60) * 1000);

  return {
    selfId, busChannelId, cpoBotUserId, alertUserIds, ctoByName, ctoById,
    livenessEnabled, silenceThresholdMs, pingCooldownMs, checkIntervalMs,
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
 *  - { action: 'shuttle', toChannelId, text, mentionUserId, sourceName }     // CTO channel -> bus
 *  - { action: 'state',   states: [{name,state}], unknownNames: [name] }     // CPO STATE lines (never shuttled)
 *  - { action: 'route',   toChannelId, toName, text, mentionUserId }         // CPO directive -> CTO
 *  - { action: 'alert',   userIds, name }                                     // unknown directive name (fail closed)
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
    // (b2) DIRECTIVE grammar — leading "[".
    const dir = parseDirective(msg.content);
    if (dir) {
      const dest = ctx.ctoByName.get(dir.name);
      if (!dest) return { action: 'alert', userIds: ctx.alertUserIds, name: dir.name };
      return { action: 'route', toChannelId: dest.channelId, toName: dir.name, text: dir.body, mentionUserId: dest.botUserId };
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
    // A2 — EMPTY-CONTENT BACKSTOP: never shuttle empty text (forwards/embeds read
    // empty at top level), but still register the activity.
    if (msg.content.trim() === '') {
      return { action: 'skip-empty', sourceName, authorId: msg.authorId, ctoActivity: true };
    }
    return {
      action: 'shuttle',
      toChannelId: ctx.busChannelId,
      text: formatForBus(sourceName, msg.content),
      mentionUserId: ctx.cpoBotUserId,
      sourceName,
      ctoActivity: true,
    };
  }

  return { action: 'ignore', reason: 'channel is neither the bus nor a known CTO channel' };
}
