#!/usr/bin/env node
// smoke.js — read-only pre-flight probe. Logs in, verifies the watcher can SEE
// every configured channel (and read/write the bus), then disconnects.
//
// It POSTS NOTHING and never enters the relay loop — safe to run before going
// live. Exits 0 if every check passes, 1 otherwise.
//
//   node smoke.js

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { config as loadDotenv } from 'dotenv';
import { Client, GatewayIntentBits, Events, PermissionFlagsBits } from 'discord.js';
import { prepareContext } from './routing.js';
import { readTokenFromEnvFile } from './token.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
loadDotenv({ path: join(__dirname, '.env') });

let TOKEN = process.env.DISCORD_BOT_TOKEN;
if (!TOKEN) {
  const tokenVar = process.env.CTO_WATCHER_TOKEN_VAR || 'BOT_CPO_CTO_BUS';
  const tokensPath = process.env.CTO_WATCHER_TOKENS_ENV || join(__dirname, '..', 'tokens.env');
  TOKEN = readTokenFromEnvFile(tokensPath, tokenVar);
}
if (!TOKEN) { console.error('[smoke] no token found'); process.exit(1); }

const CONFIG_PATH = resolve(process.env.CTO_WATCHER_CONFIG || join(__dirname, 'config.json'));
const rawConfig = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.MessageContent],
});

// Hard safety timeout: never hang connected.
const killer = setTimeout(() => { console.error('[smoke] timed out waiting for ready'); finish(1); }, 20000);

function finish(code) {
  clearTimeout(killer);
  client.destroy().finally(() => process.exit(code));
}

client.once(Events.ClientReady, async (c) => {
  let ctx;
  try {
    ctx = prepareContext(rawConfig, c.user.id);
  } catch (err) {
    console.error(`[smoke] config invalid: ${err.message}`);
    return finish(1);
  }
  console.log(`[smoke] logged in as ${c.user.tag} (${c.user.id})`);

  let ok = true;
  const checks = [
    { id: ctx.busChannelId, label: 'bus', needSend: true },
    ...[...ctx.ctoByName.entries()].map(([name, v]) => ({ id: v.channelId, label: `cto:${name}`, needSend: true })),
  ];

  for (const ch of checks) {
    try {
      const channel = await c.channels.fetch(ch.id);
      const perms = channel.permissionsFor(c.user);
      const view = perms?.has(PermissionFlagsBits.ViewChannel);
      const history = perms?.has(PermissionFlagsBits.ReadMessageHistory);
      const send = perms?.has(PermissionFlagsBits.SendMessages);
      const sendNote = ch.needSend ? `send=${send}` : 'send=n/a';
      const good = view && history && (!ch.needSend || send);
      if (!good) ok = false;
      console.log(`[smoke] ${good ? 'OK ' : 'BAD'} ${ch.label.padEnd(22)} #${channel.name}  view=${view} history=${history} ${sendNote}`);
    } catch (err) {
      ok = false;
      console.log(`[smoke] BAD ${ch.label.padEnd(22)} cannot fetch ${ch.id}: ${err.message}`);
    }
  }

  // The CPO bot just needs to exist/be reachable as a user (author-id matching).
  try {
    const cpo = await c.users.fetch(ctx.cpoBotUserId);
    console.log(`[smoke] OK  cpo bot user            ${cpo.tag} (${cpo.id})`);
  } catch (err) {
    ok = false;
    console.log(`[smoke] BAD cpo bot user            cannot fetch ${ctx.cpoBotUserId}: ${err.message}`);
  }

  console.log(ok ? '[smoke] ALL CHECKS PASSED' : '[smoke] SOME CHECKS FAILED — fix invites/permissions before going live');
  finish(ok ? 0 : 1);
});

client.on(Events.Error, (err) => console.error(`[smoke] client error: ${err?.message ?? err}`));

client.login(TOKEN).catch((err) => { console.error(`[smoke] login failed: ${err.message}`); finish(1); });
