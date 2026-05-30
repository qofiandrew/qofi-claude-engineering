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
import { config as loadDotenv } from 'dotenv';
import { Client, GatewayIntentBits, Events } from 'discord.js';
import { prepareContext, decideRoute } from './routing.js';
import { LivenessMonitor } from './liveness.js';
import { readTokenFromEnvFile } from './token.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

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
  ],
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

  // Per-CTO liveness monitor (cpo/CLAUDE.md §"The CTO loop"). Everything-in-bus:
  // state is parsed from the bus stream; revival pings post to the bus. OFF
  // unless livenessEnabled — keeps the relay unaffected until the operator flips it.
  if (ctx.livenessEnabled) {
    monitor = new LivenessMonitor({
      ctoNames: [...ctx.ctoByName.keys()],
      silenceThresholdMs: ctx.silenceThresholdMs,
      pingCooldownMs: ctx.pingCooldownMs,
    });
    log(`[liveness] ON — monitoring ${ctx.ctoByName.size} CTO(s) on the bus`);
    setInterval(async () => {
      for (const d of monitor.tick(Date.now())) {
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
    log('[liveness] OFF (livenessEnabled not set in config)');
  }
});

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

client.on(Events.MessageCreate, async (message) => {
  if (!ctx) return; // not ready yet
  const msg = {
    channelId: message.channelId,
    authorId: message.author?.id,
    content: message.content ?? '',
  };

  let decision;
  try {
    decision = decideRoute(msg, ctx);
  } catch (err) {
    log(`[error] decideRoute threw: ${err.message}`);
    return;
  }

  // OP1 timer reset — a CTO's OWN message (shuttled or empty) is liveness activity.
  if (monitor && decision.ctoActivity && decision.sourceName) {
    monitor.noteChannelActivity(decision.sourceName, Date.now());
  }

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
        await send(decision.toChannelId, decision.text, decision.mentionUserId);
        log(`[shuttle] CTO->bus src="${decision.sourceName}" dst=${decision.toChannelId} matched=true`);
      } catch (err) {
        log(`[error] shuttle CTO->bus failed (src="${decision.sourceName}"): ${err.message}`);
      }
      return;

    case 'route': // bus(CPO) directive -> CTO (@mention the CTO bot so its swarm acts)
      try {
        await send(decision.toChannelId, decision.text, decision.mentionUserId);
        if (monitor) monitor.noteDirective(decision.toName, Date.now()); // OP1: directive names the CTO -> reset clock
        log(`[shuttle] bus->CTO dst="${decision.toName}" channel=${decision.toChannelId} matched=true`);
      } catch (err) {
        log(`[error] route bus->CTO failed (dst="${decision.toName}"): ${err.message}`);
      }
      return;

    case 'state': { // CPO STATE line(s) — never shuttled
      if (monitor) {
        const now = Date.now();
        let changed = false;
        for (const s of decision.states) {
          const r = monitor.applyState(s.name, s.state, now); // OP1: also resets the clock (heartbeat)
          if (r && r.changed) { changed = true; log(`[state] ${s.name} ${r.from} -> ${r.to}`); }
        }
        if (changed) log(`[state] map: ${monitor.snapshot()}`);
      }
      for (const name of decision.unknownNames) await alertOperators(name, 'STATE'); // fail-closed, no tracking
      return;
    }

    case 'alert': // unknown directive name -> fail closed
      await alertOperators(decision.name, 'DIRECTIVE');
      return;

    default:
      log(`[error] unknown decision action: ${decision.action}`);
  }
});

// Send `text` to a channel. If mentionUserId is set, prepend "<@id> " and allow
// exactly that one ping (so the recipient bot, which only acts on mentions,
// picks it up) — no other mentions are ever resolved.
async function send(channelId, text, mentionUserId = null) {
  const channel = await client.channels.fetch(channelId);
  if (!channel || typeof channel.send !== 'function') {
    throw new Error(`channel ${channelId} is not sendable (missing access or not a text channel?)`);
  }
  const content = mentionUserId ? `<@${mentionUserId}> ${text}` : text;
  const allowedMentions = mentionUserId ? { users: [mentionUserId] } : { parse: [] };
  await channel.send({ content, allowedMentions });
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
