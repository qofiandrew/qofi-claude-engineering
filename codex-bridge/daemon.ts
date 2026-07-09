#!/usr/bin/env bun
/**
 * Discord ↔ Codex bridge daemon.
 *
 * The Claude Code bridge plugin (../bridge) rides Claude's channels capability:
 * an MCP server pushes inbound Discord messages into the live session. Codex
 * CLI has no channels concept, so this is a standalone daemon instead: it owns
 * the Discord gateway connection, applies the SAME access gate as the plugin
 * (pairing / allowlists / channel binding / bot-to-bot mention rules), and
 * drives Codex one turn per message via `codex exec --json` with per-chat
 * session resume. Codex's final agent message is posted back to the chat.
 *
 * Env:
 *   DISCORD_BOT_TOKEN        required — the bot identity
 *   DISCORD_BOUND_CHANNEL    optional — comma-separated channel ids the bot answers in
 *   DISCORD_STATE_DIR        default ~/.codex/channels/discord
 *   DISCORD_ACCESS_MODE      'static' pins access.json to its boot snapshot
 *   CODEX_BRIDGE_CWD         working dir codex runs in (the agent's repo); default $PWD
 *   CODEX_SANDBOX            read-only | workspace-write (default) | danger-full-access
 *   CODEX_MODEL              optional model override
 *   CODEX_PROFILE            optional config profile
 *   CODEX_TURN_TIMEOUT_MS    default 1800000 (30 min)
 *   CODEX_BIN                default 'codex'
 */

import {
  Client,
  GatewayIntentBits,
  Partials,
  ChannelType,
  type Message,
  type Attachment,
} from 'discord.js'
import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync, chmodSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { parseBoundChannels } from '../bridge/binding.ts'
import { forwardedContent, safeAttName } from '../bridge/normalize.ts'
import { AccessStore, gate, type InboundMeta } from './gate.ts'
import { chunk, MAX_CHUNK_LIMIT } from './chunk.ts'
import { runCodexTurn, SessionStore, type CodexConfig } from './codex.ts'
import { buildEnvelope, PREAMBLE } from './prompt.ts'

const STATE_DIR = process.env.DISCORD_STATE_DIR ?? join(homedir(), '.codex', 'channels', 'discord')
const ENV_FILE = join(STATE_DIR, '.env')
const INBOX_DIR = join(STATE_DIR, 'inbox')
const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024

// Load <state>/.env into process.env. Real env wins.
try {
  chmodSync(ENV_FILE, 0o600) // token is a credential — lock to owner
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^(\w+)=(.*)$/)
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2]
  }
} catch {}

const TOKEN = process.env.DISCORD_BOT_TOKEN
if (!TOKEN) {
  process.stderr.write(
    `codex-bridge: DISCORD_BOT_TOKEN required\n  set in ${ENV_FILE}\n  format: DISCORD_BOT_TOKEN=MTIz...\n`,
  )
  process.exit(1)
}

const BOUND_CHANNELS = parseBoundChannels(process.env.DISCORD_BOUND_CHANNEL)
// Optional deployment-specific brief appended to the built-in preamble on the
// first turn of every chat's thread — e.g. swarm doctrine from swarm-up.sh.
const PREAMBLE_EXTRA = process.env.CODEX_BRIDGE_PREAMBLE_EXTRA
const FULL_PREAMBLE = PREAMBLE_EXTRA ? `${PREAMBLE}${PREAMBLE_EXTRA}\n\n` : PREAMBLE
const store = new AccessStore(STATE_DIR, process.env.DISCORD_ACCESS_MODE === 'static')
const sessions = new SessionStore(STATE_DIR)

const codexCfg: CodexConfig = {
  cwd: process.env.CODEX_BRIDGE_CWD ?? process.cwd(),
  sandbox: process.env.CODEX_SANDBOX ?? 'workspace-write',
  model: process.env.CODEX_MODEL || undefined,
  profile: process.env.CODEX_PROFILE || undefined,
  timeoutMs: Number(process.env.CODEX_TURN_TIMEOUT_MS ?? 30 * 60 * 1000),
  bin: process.env.CODEX_BIN || undefined,
}

process.on('unhandledRejection', err => {
  process.stderr.write(`codex-bridge: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`codex-bridge: uncaught exception: ${err}\n`)
})

const client = new Client({
  intents: [
    GatewayIntentBits.DirectMessages,
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
  // DMs arrive as partial channels — messageCreate never fires without this.
  partials: [Partials.Channel],
})

// Track message IDs we recently sent, so reply-to-bot in guild channels
// counts as a mention without needing fetchReference().
const recentSentIds = new Set<string>()
const RECENT_SENT_CAP = 200
function noteSent(id: string): void {
  recentSentIds.add(id)
  if (recentSentIds.size > RECENT_SENT_CAP) {
    const first = recentSentIds.values().next().value
    if (first) recentSentIds.delete(first)
  }
}

async function isMentioned(msg: Message, extraPatterns?: string[]): Promise<boolean> {
  if (client.user && msg.mentions.has(client.user)) return true
  const refId = msg.reference?.messageId
  if (refId) {
    if (recentSentIds.has(refId)) return true
    try {
      const ref = await msg.fetchReference()
      if (ref.author.id === client.user?.id) return true
    } catch {}
  }
  for (const pat of extraPatterns ?? []) {
    try {
      if (new RegExp(pat, 'i').test(msg.content)) return true
    } catch {}
  }
  return false
}

// The access CLI drops approved/<senderId> files when pairing someone —
// same protocol as the Claude bridge. Poll, confirm on Discord, clean up.
function checkApprovals(): void {
  let files: string[]
  try {
    files = readdirSync(store.approvedDir)
  } catch {
    return
  }
  for (const senderId of files) {
    const file = join(store.approvedDir, senderId)
    let dmChannelId = ''
    try {
      dmChannelId = readFileSync(file, 'utf8').trim()
    } catch {}
    if (!dmChannelId) {
      rmSync(file, { force: true })
      continue
    }
    void (async () => {
      try {
        const ch = await client.channels.fetch(dmChannelId)
        if (ch?.isTextBased() && 'send' in ch) await ch.send('Paired! Say hi to Codex.')
      } catch (err) {
        process.stderr.write(`codex-bridge: failed to send approval confirm: ${err}\n`)
      } finally {
        rmSync(file, { force: true }) // don't loop on a broken send
      }
    })()
  }
}
if (process.env.DISCORD_ACCESS_MODE !== 'static') setInterval(checkApprovals, 5000).unref()

async function downloadAttachment(att: Attachment): Promise<string> {
  if (att.size > MAX_ATTACHMENT_BYTES) {
    throw new Error(
      `attachment too large: ${(att.size / 1024 / 1024).toFixed(1)}MB, max ${MAX_ATTACHMENT_BYTES / 1024 / 1024}MB`,
    )
  }
  const res = await fetch(att.url)
  const buf = Buffer.from(await res.arrayBuffer())
  const name = att.name ?? `${att.id}`
  const rawExt = name.includes('.') ? name.slice(name.lastIndexOf('.') + 1) : 'bin'
  const ext = rawExt.replace(/[^a-zA-Z0-9]/g, '') || 'bin'
  const path = join(INBOX_DIR, `${Date.now()}-${att.id}.${ext}`)
  mkdirSync(INBOX_DIR, { recursive: true })
  writeFileSync(path, buf)
  return path
}

// Best-effort name of a forwarded message's source channel (see bridge/server.ts).
async function resolveForwardChannel(msg: Message): Promise<string | undefined> {
  const id = msg.reference?.channelId
  if (!id) return undefined
  const cached = client.channels.cache.get(id)
  if (cached && 'name' in cached && typeof cached.name === 'string') return cached.name
  try {
    const ch = await client.channels.fetch(id)
    if (ch && 'name' in ch && typeof ch.name === 'string') return ch.name
  } catch {}
  return undefined
}

// ---- turn queue -----------------------------------------------------------
// Codex turns run in the agent's repo with write access — never run two at
// once. One global FIFO; each queued item is one inbound message.
let queueTail: Promise<void> = Promise.resolve()
let queueDepth = 0
function enqueue(job: () => Promise<void>): void {
  queueDepth++
  queueTail = queueTail
    .then(job)
    .catch(err => process.stderr.write(`codex-bridge: turn job failed: ${err}\n`))
    .finally(() => {
      queueDepth--
    })
}

async function runTurn(msg: Message, content: string, attachmentPaths: string[], atts: string[]) {
  const chatId = msg.channelId

  // Typing indicator for the whole turn — Discord's lasts ~10s, so refresh.
  const typing = setInterval(() => {
    if ('sendTyping' in msg.channel) void msg.channel.sendTyping().catch(() => {})
  }, 8000)
  if ('sendTyping' in msg.channel) void msg.channel.sendTyping().catch(() => {})

  try {
    const envelope = buildEnvelope(content, {
      chatId,
      messageId: msg.id,
      user: msg.author.username,
      userId: msg.author.id,
      ts: msg.createdAt.toISOString(),
      attachments: atts.length ? atts : undefined,
      attachmentPaths: attachmentPaths.length ? attachmentPaths : undefined,
    })

    let threadId = sessions.get(chatId)
    const prompt = threadId ? envelope : FULL_PREAMBLE + envelope
    let result = await runCodexTurn(threadId, prompt, codexCfg)

    // A vanished thread (rotated/deleted session files) shouldn't strand the
    // chat — drop the mapping and retry once as a fresh thread.
    if (!result.ok && threadId) {
      process.stderr.write(
        `codex-bridge: resume of ${threadId} failed (${result.error}); retrying fresh\n`,
      )
      sessions.delete(chatId)
      threadId = null
      result = await runCodexTurn(null, FULL_PREAMBLE + envelope, codexCfg)
    }

    if (result.threadId) sessions.set(chatId, result.threadId)

    const access = store.load()
    const limit = Math.max(1, Math.min(access.textChunkLimit ?? MAX_CHUNK_LIMIT, MAX_CHUNK_LIMIT))
    const mode = access.chunkMode ?? 'length'
    const replyMode = access.replyToMode ?? 'first'

    const text = result.ok
      ? result.messages.at(-1) ?? '(codex completed the turn without a reply message)'
      : `⚠️ codex turn failed: ${result.error}`

    const chunks = chunk(text, limit, mode)
    for (let i = 0; i < chunks.length; i++) {
      const shouldReplyTo = replyMode !== 'off' && (replyMode === 'all' || i === 0)
      const sent = await (msg.channel as any).send({
        content: chunks[i],
        ...(shouldReplyTo
          ? { reply: { messageReference: msg.id, failIfNotExists: false } }
          : {}),
      })
      noteSent(sent.id)
    }
  } catch (err) {
    process.stderr.write(`codex-bridge: turn failed for chat ${chatId}: ${err}\n`)
    try {
      await (msg.channel as any).send(`⚠️ codex-bridge error: ${err instanceof Error ? err.message : err}`)
    } catch {}
  } finally {
    clearInterval(typing)
  }
}

async function handleInbound(msg: Message): Promise<void> {
  const gateChannelId = msg.channel.isThread()
    ? msg.channel.parentId ?? msg.channelId
    : msg.channelId

  // For DMs, gateChannelId is the DM channel id (≠ user id) — the pairing
  // entry carries it so the approval confirmation can be delivered. Same
  // convention as the plugin.
  const meta: InboundMeta = {
    senderId: msg.author.id,
    isDM: msg.channel.type === ChannelType.DM,
    gateChannelId,
    isMentioned: () => isMentioned(msg, store.load().mentionPatterns),
  }
  const result = await gate(meta, { store, boundChannels: BOUND_CHANNELS })

  if (result.action === 'drop') {
    process.stderr.write(`codex-bridge: DROP ${result.reason} (sender ${msg.author.id})\n`)
    return
  }

  if (result.action === 'pair') {
    const lead = result.isResend ? 'Still pending' : 'Pairing required'
    try {
      await msg.reply(`${lead} — run on the host:\n\nbun cli.ts pair ${result.code}\n(from codex-bridge/)`)
    } catch (err) {
      process.stderr.write(`codex-bridge: failed to send pairing code: ${err}\n`)
    }
    return
  }

  // Ack reaction — "seen". Fire-and-forget.
  if (result.access.ackReaction) void msg.react(result.access.ackReaction).catch(() => {})

  // Download attachments up front — unlike the Claude plugin (which exposes a
  // download tool the model calls lazily), Codex only sees the prompt text, so
  // paths must be materialized before the turn starts.
  const atts: string[] = []
  const paths: string[] = []
  for (const att of msg.attachments.values()) {
    const kb = (att.size / 1024).toFixed(0)
    atts.push(`${safeAttName(att)} (${att.contentType ?? 'unknown'}, ${kb}KB)`)
    try {
      paths.push(await downloadAttachment(att))
    } catch (err) {
      process.stderr.write(`codex-bridge: attachment download failed: ${err}\n`)
    }
  }

  const forwarded = forwardedContent(msg, await resolveForwardChannel(msg))
  const body = [msg.content, forwarded].filter(Boolean).join('\n\n')
  const content = body || (atts.length > 0 ? '(attachment)' : '')

  if (queueDepth > 0 && 'react' in msg) void msg.react('⏳').catch(() => {})
  enqueue(() => runTurn(msg, content, paths, atts))
}

client.on('messageCreate', msg => {
  if (msg.author.bot && msg.author.id === msg.client.user?.id) return // ignore own messages
  if (msg.author.bot && !msg.mentions.has(msg.client.user!)) return // ignore bot msgs that don't @mention us
  handleInbound(msg).catch(e => process.stderr.write(`codex-bridge: handleInbound failed: ${e}\n`))
})

client.on('error', err => {
  process.stderr.write(`codex-bridge: client error: ${err}\n`)
})

client.once('ready', c => {
  process.stderr.write(
    `codex-bridge: gateway connected as ${c.user.tag} (cwd ${codexCfg.cwd}, sandbox ${codexCfg.sandbox}${BOUND_CHANNELS.length ? `, bound [${BOUND_CHANNELS.join(', ')}]` : ''})\n`,
  )
})

let shuttingDown = false
function shutdown(): void {
  if (shuttingDown) return
  shuttingDown = true
  process.stderr.write('codex-bridge: shutting down\n')
  setTimeout(() => process.exit(0), 2000)
  void Promise.resolve(client.destroy()).finally(() => process.exit(0))
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)

client.login(TOKEN).catch(err => {
  process.stderr.write(`codex-bridge: login failed: ${err}\n`)
  process.exit(1)
})
