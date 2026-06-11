#!/usr/bin/env node
// index.js — the cto-watcher relay daemon.
//
// A long-lived Node process that shuttles messages between the CTO Discord
// channels and the shared #cpo-cto-bus channel, in real time, over the gateway
// (websocket) — NEVER REST polling. All routing logic lives in routing.js; this
// file owns the Discord client, intents, reconnection logging, and the side
// effects (posting messages).
//
// Run under pm2 (see ecosystem.config.js). Every shuttle is logged to stdout so
// pm2 captures it.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { config as loadDotenv } from 'dotenv';
import { Client, GatewayIntentBits, Events, Partials, AttachmentBuilder } from 'discord.js';
import { prepareContext, decideRoute } from './routing.js';
import { relayMessage } from './attachments.js';
import { LivenessMonitor, renderStateReadout } from './liveness.js';
import { readTokenFromEnvFile } from './token.js';
import { readSwarmLimitStates } from './swarmstatus.js';
import { authorizeDm, readOperatorAllowFrom, KillSwitch } from './killswitch.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const START_MS = Date.now(); // process start, for !watcher status uptime

// Where the shared ACL lives (for kill-switch operator-allowFrom lookups).
// Overridable; defaults to the bridge's standard state dir.
const ACCESS_PATH =
  process.env.CTO_WATCHER_ACCESS_JSON ||
  join(process.env.DISCORD_STATE_DIR || join(homedir(), '.claude', 'channels', 'discord'), 'access.json');

// Where swarm-watch.sh writes its swarm-status/v1 snapshot. The watcher reads it
// (read-only, same host) to learn which CTOs are paused on a Claude usage limit
// — see swarmstatus.js. Overridable; defaults to swarm-watch's standard state dir.
const SWARM_STATUS_PATH =
  process.env.CTO_WATCHER_SWARM_STATUS_JSON ||
  join(process.env.SWARM_STATE_DIR || join(homedir(), '.config', 'swarm'), 'status.json');

const killswitch = new KillSwitch(); // in-memory; pm2 restart → ACTIVE (safe default)

function fmtUptime() {
  const s = Math.floor((Date.now() - START_MS) / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}h${m}m` : `${m}m${s % 60}s`;
}

function log(...args) {
  // ISO timestamp + message; pm2 prefixes its own metadata, this keeps lines greppable.
  console.log(new Date().toISOString(), ...args);
}

// Token resolution, single-source-of-truth friendly, in priority order:
//   1. process.env.DISCORD_BOT_TOKEN  (e.g. set by pm2 env or the shell)
//   2. cto-watcher/.env               (DISCORD_BOT_TOKEN via dotenv)
//   3. the repo's shared tokens.env   (BOT_CPO_CTO_BUS, or $CTO_WATCHER_TOKEN_VAR)
// so the secret can live in exactly one place (tokens.env) without copying it.
loadDotenv({ path: join(__dirname, '.env') }); // harmless if .env is absent

let TOKEN = process.env.DISCORD_BOT_TOKEN;
if (!TOKEN) {
  const tokenVar = process.env.CTO_WATCHER_TOKEN_VAR || 'BOT_CPO_CTO_BUS';
  const tokensPath = process.env.CTO_WATCHER_TOKENS_ENV || join(__dirname, '..', 'tokens.env');
  TOKEN = readTokenFromEnvFile(tokensPath, tokenVar);
  if (TOKEN) log(`[token] using ${tokenVar} from ${tokensPath}`);
}
if (!TOKEN) {
  console.error('[fatal] no bot token found. Set DISCORD_BOT_TOKEN (env or cto-watcher/.env),');
  console.error('        or add BOT_CPO_CTO_BUS to the repo tokens.env.');
  process.exit(1);
}

// Config path: $CTO_WATCHER_CONFIG, else ./config.json next to this file.
const CONFIG_PATH = resolve(process.env.CTO_WATCHER_CONFIG || join(__dirname, 'config.json'));
let rawConfig;
try {
  rawConfig = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
} catch (err) {
  console.error(`[fatal] could not read config at ${CONFIG_PATH}: ${err.message}`);
  console.error('        Copy config.example.json to config.json and fill it in.');
  process.exit(1);
}

const client = new Client({
  // Guilds + GuildMessages are required to RECEIVE messageCreate in server channels.
  // MessageContent is PRIVILEGED — without it (and the matching toggle in the
  // Developer Portal) every message body arrives EMPTY and the watcher silently
  // shuttles nothing. See README "Required manual portal step".
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
    // DirectMessages — REQUIRED for the DM kill switch; without it the watcher
    // never receives DM messageCreate and the switch silently fails.
    GatewayIntentBits.DirectMessages,
  ],
  // DM channels/messages often arrive uncached → partials are required to get
  // the messageCreate event for a DM at all.
  partials: [Partials.Channel, Partials.Message],
});

// ctx is set once we know our own user id (client.user.id) at login.
let ctx = null;
let monitor = null; // AUTO-mode liveness monitor; null unless livenessEnabled

client.once(Events.ClientReady, (c) => {
  try {
    ctx = prepareContext(rawConfig, c.user.id);
  } catch (err) {
    console.error(`[fatal] invalid config: ${err.message}`);
    process.exit(1);
  }
  log(`[ready] logged in as ${c.user.tag} (${c.user.id})`);
  log(`[ready] bus=${ctx.busChannelId} cpoBot=${ctx.cpoBotUserId} alertDMs=${ctx.alertUserIds.length}`);
  const mapped = [...ctx.ctoByName.values()].filter((e) => e.authorId).length;
  log(`[ready] watching ${ctx.ctoByName.size} CTO channel(s); ${mapped} author-id(s) mapped: ${[...ctx.ctoByName.keys()].join(', ')}`);
  for (const [name, e] of ctx.ctoByName) {
    if (!e.authorId) log(`[warn] CTO channel "${name}" has no author id — its messages will NOT shuttle (fail-closed)`);
  }
  log(`[ready] liveness thresholds: silence=${Math.round(ctx.silenceThresholdMs / 1000)}s cooldown=${Math.round(ctx.pingCooldownMs / 1000)}s check=${Math.round(ctx.checkIntervalMs / 1000)}s`);
  // DM kill switch (cpo/CLAUDE.md is unaffected — this is operational only).
  const dmIntentOn = client.options.intents.has(GatewayIntentBits.DirectMessages);
  log(`[ready] DM kill-switch: DM intent ${dmIntentOn ? 'ENABLED' : 'DISABLED'}; auth via access.json groups[${ctx.operatorChannelId ?? 'UNSET'}].allowFrom @ ${ACCESS_PATH}`);
  if (!ctx.operatorChannelId) log('[warn] no operatorChannelId in config — DM kill switch authorizes NO ONE (fail-closed)');
  if (!dmIntentOn) log('[warn] DM intent is OFF — kill-switch DMs will not be received');

  // Per-CTO liveness monitor (cpo/CLAUDE.md §"The CTO loop"). Everything-in-bus:
  // state is parsed from the bus stream; revival pings post to the bus. The map
  // is ALWAYS tracked in-memory (so "!watcher state" can report it); only the
  // revival PINGS are gated by livenessEnabled — keeping the relay unaffected
  // until the operator flips it.
  monitor = new LivenessMonitor({
    ctoNames: [...ctx.ctoByName.keys()],
    silenceThresholdMs: ctx.silenceThresholdMs,
    pingCooldownMs: ctx.pingCooldownMs,
  });
  log(`[liveness] usage-limit feed: ${SWARM_STATUS_PATH} (resume buffer ${Math.round(ctx.resumeBufferMs / 1000)}s, max feed age ${Math.round(ctx.swarmStatusMaxAgeMs / 1000)}s)`);
  if (ctx.livenessEnabled) {
    log(`[liveness] ON — monitoring ${ctx.ctoByName.size} CTO(s) on the bus`);
    setInterval(async () => {
      const now = Date.now();
      // TRACKING (no emission) — refresh the usage-limit overlay even while paused.
      refreshLimitFeed(now);
      if (killswitch.livenessHalted()) return; // paused: tracked above, emit nothing

      // Resume nudges: a CTO whose usage cap lifted (+buffer) and did NOT come
      // back on its own. Gated like pings — AUTO-only, off while paused.
      for (const r of monitor.resumesDue(now, ctx.resumeBufferMs)) {
        if (!r.nudge) { log(`[limit] ${r.name} cap cleared — no nudge (${r.reason})`); continue; }
        const was = r.resetHint ? ` (was: resets ${r.resetHint})` : '';
        const text =
          `▶️ **${r.name}**: usage limit cleared${was} — resume driving. ` +
          `Reply on the bus with \`STATE: ${r.name} DRIVING\` and the next directive, ` +
          `or \`STATE: ${r.name} WAITING_FOR_OPERATOR\` if there's nothing left to push.`;
        try {
          await send(ctx.busChannelId, text, ctx.cpoBotUserId);
          log(`[limit] nudged ${r.name} to resume (usage limit cleared)`);
        } catch (err) {
          log(`[limit] failed to nudge ${r.name}: ${err.message}`);
        }
      }

      // Revival pings (DRIVING-but-quiet loops; limited loops are skipped in tick).
      for (const d of monitor.tick(now)) {
        const mins = Math.round(d.silenceMs / 60000);
        const text =
          `⏱️ **${d.name}**: DRIVING and quiet ~${mins}m — still working, blocked, or should you correct the state? ` +
          `Reply on the bus with the STATE grammar, e.g. \`STATE: ${d.name} DRIVING\` (heartbeat) ` +
          `or \`STATE: ${d.name} WAITING_FOR_OPERATOR\`.`;
        try {
          // Pings go to the BUS, @mentioning the CPO bot (its bridge only acts on mentions).
          await send(ctx.busChannelId, text, ctx.cpoBotUserId);
          log(`[liveness] pinged ${d.name} (silent ~${mins}m)`);
        } catch (err) {
          log(`[liveness] failed to ping ${d.name}: ${err.message}`);
        }
      }
    }, ctx.checkIntervalMs);
  } else {
    log('[liveness] OFF (livenessEnabled not set) — state tracked for !watcher state, no pings/nudges');
  }
});

// Refresh each tracked CTO's usage-limit overlay from swarm-watch's status.json.
// TRACKING ONLY — never emits (the resume nudge lives in the gated interval).
// Safe to call anytime: while paused, or from the !watcher state readout so it
// reflects current limit status. Idempotent — a steady feed logs nothing (only
// RATE_LIMITED ⇄ underlying transitions log). A null feed (missing / unreadable /
// malformed / stale) leaves every overlay unchanged — "don't know" beats "guess".
function refreshLimitFeed(nowMs) {
  if (!monitor || !ctx) return;
  const feed = readSwarmLimitStates(SWARM_STATUS_PATH, nowMs, ctx.swarmStatusMaxAgeMs);
  if (!feed) return;
  for (const name of ctx.ctoByName.keys()) {
    const e = feed.get(name);
    const r = monitor.applyLimitFeed(name, e?.paused === true, e?.resetHint ?? null, nowMs);
    if (r && r.changed) {
      log(`[limit] ${name} ${r.from} -> ${r.to}` + (r.to === 'RATE_LIMITED' && e?.resetHint ? ` (resets ${e.resetHint})` : ''));
    }
  }
}

// Fail-closed alert: DM every operator on the allowlist. `kind` is DIRECTIVE or STATE.
async function alertOperators(name, kind) {
  const verb = kind === 'STATE' ? 'tracked' : 'routed';
  log(`[unmatched] ${kind} names unknown CTO "${name}" — fail-closed, NOT ${verb}; DMing ${ctx.alertUserIds.length} operator(s)`);
  if (ctx.alertUserIds.length === 0) log('[warn] alertUserIds empty — no one to DM about the unknown CTO');
  await Promise.all(ctx.alertUserIds.map(async (uid) => {
    try {
      const user = await client.users.fetch(uid);
      await user.send(
        `⚠️ cto-watcher: a CPO ${kind} on the bus named unknown CTO **${name}** — not in the channel map, ` +
        `so it was NOT ${verb} (fail-closed). Add it to config.json and restart the watcher if it should exist.`,
      );
    } catch (err) {
      log(`[error] failed to DM operator ${uid} about unknown "${name}": ${err.message}`);
    }
  }));
}

// DM kill switch. Authorized ONLY against the operator group's allowFrom in
// access.json (read fresh per command, fail-closed). DM-only; never a guild
// channel. Replies in the DM on every recognized command.
async function handleDmCommand(message) {
  const senderId = message.author?.id;
  const allowFrom = readOperatorAllowFrom(ACCESS_PATH, ctx.operatorChannelId); // fresh read, fail-closed []
  const d = authorizeDm({ isDM: !message.guildId, senderId, content: message.content ?? '', allowFrom });
  if (!d.command) return; // not one of our commands — ignore silently
  if (!d.authorized) {
    log(`[killswitch] IGNORED "${d.command}" DM from ${senderId} (${d.reason}; operator allowFrom=[${allowFrom.join(', ')}])`);
    return;
  }
  let reply;
  if (d.command === 'stop') {
    killswitch.stop();
    log('[killswitch] PAUSED — relay and liveness halted (by ' + senderId + ')');
    reply = `Paused. Relay + liveness halted; still connected under pm2. Uptime ${fmtUptime()}.`;
  } else if (d.command === 'start') {
    killswitch.start();
    log('[killswitch] RESUMED — relay and liveness active (by ' + senderId + ')');
    reply = `Resumed. Relay + liveness active. Uptime ${fmtUptime()}.`;
  } else if (d.command === 'state') {
    // Read-only diagnostic. NOT pause-gated (you'd want to inspect state while
    // paused). Freshen the usage-limit overlay first so RATE_LIMITED is current
    // even when the liveness interval isn't running; then report the in-memory
    // map only — changes nothing else.
    refreshLimitFeed(Date.now());
    reply = renderStateReadout(monitor, Date.now(), ctx.livenessEnabled);
    log(`[killswitch] state readout (by ${senderId}; paused=${killswitch.paused})`);
  } else {
    reply = `Status: ${killswitch.paused ? 'PAUSED' : 'ACTIVE'}. Uptime ${fmtUptime()}.`;
    log(`[killswitch] status → ${killswitch.paused ? 'PAUSED' : 'ACTIVE'} (by ${senderId})`);
  }
  try {
    await message.reply(reply);
  } catch (err) {
    log(`[killswitch] FAILED to send DM confirmation for "${d.command}": ${err.message}`);
  }
}

client.on(Events.MessageCreate, async (message) => {
  if (!ctx) return; // not ready yet

  // DM kill-switch path — DMs are DM-ONLY commands, NEVER relayed. Handle + return.
  if (!message.guildId) {
    await handleDmCommand(message);
    return;
  }

  const msg = {
    channelId: message.channelId,
    authorId: message.author?.id,
    content: message.content ?? '',
    attachments: extractAttachments(message),
  };

  let decision;
  try {
    decision = decideRoute(msg, ctx);
  } catch (err) {
    log(`[error] decideRoute threw: ${err.message}`);
    return;
  }

  // MONITOR TRACKING — runs even while PAUSED so resume has current state/activity.
  const now = Date.now();
  if (monitor) {
    if (decision.ctoActivity && decision.sourceName) monitor.noteChannelActivity(decision.sourceName, now); // OP1
    if (decision.action === 'state') {
      let changed = false;
      for (const s of decision.states) {
        const r = monitor.applyState(s.name, s.state, now); // also resets the clock (heartbeat)
        if (r && r.changed) { changed = true; log(`[state] ${s.name} ${r.from} -> ${r.to}`); }
      }
      if (changed) log(`[state] map: ${monitor.snapshot()}`);
    }
  }

  // SOFT-PAUSE gate: tracked above; emit NOTHING below while paused.
  if (killswitch.relayHalted()) return;

  switch (decision.action) {
    case 'ignore':
      return;

    case 'drop-foreign': // A1: not the channel's CTO identity -> never shuttled
      log(`[ignore] non-CTO message in ${decision.sourceName} from ${decision.authorId}`);
      return;

    case 'skip-empty': // A2: CTO's own message but empty body -> not shuttled (activity already noted)
      log(`[skip] empty-content message from ${decision.authorId} in ${decision.sourceName}`);
      return;

    case 'shuttle': // CTO channel -> bus (@mention the CPO so it picks it up)
      try {
        await relay(decision.toChannelId, decision.text, decision.mentionUserId, decision.attachments, `CTO->bus src="${decision.sourceName}"`);
        log(`[shuttle] CTO->bus src="${decision.sourceName}" dst=${decision.toChannelId} matched=true`);
      } catch (err) {
        log(`[error] shuttle CTO->bus failed (src="${decision.sourceName}"): ${err.message}`);
      }
      return;

    case 'route': // bus(CPO) directive -> CTO (@mention the CTO bot so its swarm acts)
      try {
        await relay(decision.toChannelId, decision.text, decision.mentionUserId, decision.attachments, `bus->CTO dst="${decision.toName}"`);
        if (monitor) monitor.noteDirective(decision.toName, Date.now()); // OP1: directive names the CTO -> reset clock
        log(`[shuttle] bus->CTO dst="${decision.toName}" channel=${decision.toChannelId} matched=true`);
      } catch (err) {
        log(`[error] route bus->CTO failed (dst="${decision.toName}"): ${err.message}`);
      }
      return;

    case 'state': // CPO STATE line(s) — never shuttled; state tracking done above the pause gate
      for (const name of decision.unknownNames) await alertOperators(name, 'STATE'); // fail-closed alert (send)
      return;

    case 'alert': // unknown directive name -> fail closed
      await alertOperators(decision.name, 'DIRECTIVE');
      return;

    default:
      log(`[error] unknown decision action: ${decision.action}`);
  }
});

// Send `text` to a channel. If mentionUserId is set, prepend "<@id> " and allow
// exactly that one ping (so the recipient bot, which only acts on mentions,
// picks it up) — no other mentions are ever resolved. `files` (AttachmentBuilder[])
// ride along on the same message when present.
async function send(channelId, text, mentionUserId = null, files = []) {
  const channel = await client.channels.fetch(channelId);
  if (!channel || typeof channel.send !== 'function') {
    throw new Error(`channel ${channelId} is not sendable (missing access or not a text channel?)`);
  }
  const content = mentionUserId ? `<@${mentionUserId}> ${text}` : text;
  const allowedMentions = mentionUserId ? { users: [mentionUserId] } : { parse: [] };
  const payload = { content, allowedMentions };
  if (files && files.length > 0) payload.files = files;
  await channel.send(payload);
}

// Lift the minimal {name,url,size,contentType} shape off each discord.js Attachment
// (a Collection) so the pure routing/attachment code never touches discord.js.
function extractAttachments(message) {
  const coll = message?.attachments;
  if (!coll || typeof coll.values !== 'function') return [];
  return [...coll.values()].map((a) => ({
    name: a?.name ?? '',
    url: a?.url ?? '',
    size: typeof a?.size === 'number' ? a.size : undefined,
    contentType: a?.contentType ?? null,
  }));
}

// Download an attachment's bytes from its CDN url, with a hard timeout so a hung
// fetch can't wedge the relay. Throws on non-2xx, timeout, or network error — the
// caller (resolveAttachments) catches and degrades to a "could not relay" note.
async function downloadAttachment(url) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ctx.attachmentDownloadTimeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return Buffer.from(await res.arrayBuffer());
  } finally {
    clearTimeout(timer);
  }
}

// Repost text + re-uploaded .md/.txt files to a channel. The watcher composes a
// fresh message as itself, so attachments don't ride along for free — each eligible
// file is downloaded and re-uploaded here. The orchestration (download, "could not
// relay" notes, text-only fallback on a rejected file-send) lives in attachments.js
// (relayMessage) so it's unit-tested; this binds the discord.js I/O into it. The
// {name,data} payloads relayMessage hands to `send` become AttachmentBuilder uploads.
function relay(channelId, text, mentionUserId, attachments, label) {
  return relayMessage({
    channelId, text, mentionUserId, attachments, label, log,
    download: downloadAttachment,
    maxBytes: ctx.maxAttachmentBytes,
    send: (chId, body, mention, files) =>
      send(chId, body, mention, (files ?? []).map((f) => new AttachmentBuilder(f.data, { name: f.name }))),
  });
}

// ── Gateway lifecycle logging ──────────────────────────────────────────────
// Silent death means shuttling stops invisibly. Log every disconnect/reconnect.
client.on(Events.ShardDisconnect, (event, shardId) => {
  log(`[gateway] shard ${shardId} DISCONNECTED (code ${event?.code}) — shuttling is PAUSED until reconnect`);
});
client.on(Events.ShardReconnecting, (shardId) => {
  log(`[gateway] shard ${shardId} reconnecting…`);
});
client.on(Events.ShardResume, (shardId, replayed) => {
  log(`[gateway] shard ${shardId} RESUMED (${replayed} events replayed) — shuttling restored`);
});
client.on(Events.ShardReady, (shardId) => {
  log(`[gateway] shard ${shardId} ready`);
});
client.on(Events.Error, (err) => {
  log(`[gateway] client error: ${err?.message ?? err}`);
});
client.on(Events.Warn, (info) => {
  log(`[gateway] warn: ${info}`);
});

process.on('unhandledRejection', (reason) => {
  log(`[error] unhandledRejection: ${reason?.message ?? reason}`);
});

client.login(TOKEN).catch((err) => {
  console.error(`[fatal] login failed: ${err.message}`);
  process.exit(1);
});
