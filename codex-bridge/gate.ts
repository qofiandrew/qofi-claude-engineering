/**
 * Access control for the Codex Discord bridge — a faithful port of the gate in
 * bridge/server.ts, factored into pure(ish) functions so it can be unit-tested
 * without a Discord gateway. The on-disk format (access.json, approved/) is
 * IDENTICAL to the Claude bridge plugin's, so the same operator tooling and
 * mental model apply. State dir defaults to ~/.codex/channels/discord.
 */

import { randomBytes } from 'crypto'
import { lstatSync, readFileSync, realpathSync, writeFileSync, mkdirSync, renameSync } from 'fs'
import { dirname, isAbsolute, join } from 'path'
import { assertNoExtendedAcl } from './security.ts'

export type PendingEntry = {
  senderId: string
  chatId: string // DM channel ID — where to send the approval confirm
  createdAt: number
  expiresAt: number
  replies: number
}

export type GroupPolicy = {
  requireMention: boolean
  allowFrom: string[]
}

export type Access = {
  dmPolicy: 'pairing' | 'allowlist' | 'disabled'
  allowFrom: string[]
  /** Keyed on channel ID (snowflake), not guild ID. One entry per guild channel. */
  groups: Record<string, GroupPolicy>
  pending: Record<string, PendingEntry>
  mentionPatterns?: string[]
  /** Emoji to react with on receipt. Empty string disables. */
  ackReaction?: string
  /** Which chunks get Discord's reply reference when threading. Default 'first'. */
  replyToMode?: 'off' | 'first' | 'all'
  /** Max chars per outbound message before splitting. Default 2000 (Discord's cap). */
  textChunkLimit?: number
  /** Split on paragraph boundaries instead of hard char count. */
  chunkMode?: 'length' | 'newline'
}

export function defaultAccess(): Access {
  return { dmPolicy: 'pairing', allowFrom: [], groups: {}, pending: {} }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function stringArray(value: unknown): string[] | null {
  if (!Array.isArray(value) || !value.every(item => typeof item === 'string')) return null
  return [...new Set(value.filter(item => item.length > 0).map(item => item.slice(0, 256)))]
}

export const SAFE_STATE_ID = /^[A-Za-z0-9_-]{1,128}$/

/** Normalize persisted state so malformed shapes can never broaden access. */
export function normalizeAccess(value: unknown): Access {
  if (!isRecord(value)) throw new Error('access.json must contain an object')
  const validDmPolicy = value.dmPolicy === 'pairing'
    || value.dmPolicy === 'allowlist'
    || value.dmPolicy === 'disabled'
  const dmPolicy: Access['dmPolicy'] = validDmPolicy
    ? value.dmPolicy as Access['dmPolicy']
    : value.dmPolicy === undefined ? 'pairing' : 'disabled'
  const allowFrom = stringArray(value.allowFrom) ?? []

  const groups: Access['groups'] = Object.create(null)
  if (isRecord(value.groups)) {
    for (const [channelId, raw] of Object.entries(value.groups)) {
      if (!isRecord(raw)) continue
      groups[channelId] = {
        // A malformed mention flag tightens rather than loosens the policy.
        requireMention: typeof raw.requireMention === 'boolean'
          ? raw.requireMention
          : raw.requireMention === undefined ? false : true,
        allowFrom: stringArray(raw.allowFrom) ?? [],
      }
    }
  }

  const pending: Access['pending'] = Object.create(null)
  if (isRecord(value.pending)) {
    for (const [code, raw] of Object.entries(value.pending)) {
      if (
        !/^[A-Za-z0-9_-]{1,64}$/.test(code)
        || !isRecord(raw)
        || typeof raw.senderId !== 'string'
        || typeof raw.chatId !== 'string'
        || !SAFE_STATE_ID.test(raw.senderId)
        || !SAFE_STATE_ID.test(raw.chatId)
        || typeof raw.createdAt !== 'number'
        || !Number.isFinite(raw.createdAt)
        || typeof raw.expiresAt !== 'number'
        || !Number.isFinite(raw.expiresAt)
      ) continue
      pending[code] = {
        senderId: raw.senderId.slice(0, 256),
        chatId: raw.chatId.slice(0, 256),
        createdAt: Number(raw.createdAt),
        expiresAt: Number(raw.expiresAt),
        replies: typeof raw.replies === 'number'
          && Number.isSafeInteger(raw.replies) && raw.replies >= 0
          ? raw.replies
          : 1,
      }
    }
  }

  const normalized: Access = { dmPolicy, allowFrom, groups, pending }
  const mentionPatterns = stringArray(value.mentionPatterns)
  if (mentionPatterns) normalized.mentionPatterns = mentionPatterns
  if (typeof value.ackReaction === 'string') normalized.ackReaction = value.ackReaction.slice(0, 100)
  if (value.replyToMode === 'off' || value.replyToMode === 'first' || value.replyToMode === 'all') {
    normalized.replyToMode = value.replyToMode
  }
  if (Number.isSafeInteger(value.textChunkLimit) && Number(value.textChunkLimit) > 0) {
    normalized.textChunkLimit = Math.min(Number(value.textChunkLimit), 2000)
  }
  if (value.chunkMode === 'length' || value.chunkMode === 'newline') {
    normalized.chunkMode = value.chunkMode
  }
  return normalized
}

export class AccessStore {
  readonly stateDir: string
  readonly accessFile: string
  readonly approvedDir: string
  /** static mode: snapshot at boot, never re-read or written (pairing downgraded). */
  private readonly bootAccess: Access | null

  constructor(stateDir: string, staticMode = false) {
    this.stateDir = stateDir
    this.accessFile = join(stateDir, 'access.json')
    this.approvedDir = join(stateDir, 'approved')
    this.bootAccess = staticMode
      ? (() => {
          const a = this.readFile()
          if (a.dmPolicy === 'pairing') {
            process.stderr.write(
              'codex-bridge: static mode — dmPolicy "pairing" downgraded to "allowlist"\n',
            )
            a.dmPolicy = 'allowlist'
          }
          a.pending = {}
          return a
        })()
      : null
  }

  private readFile(): Access {
    try {
      const raw = readFileSync(this.accessFile, 'utf8')
      return normalizeAccess(JSON.parse(raw))
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return defaultAccess()
      try { renameSync(this.accessFile, `${this.accessFile}.corrupt-${Date.now()}`) } catch {}
      process.stderr.write(`codex-bridge: access.json is corrupt, moved aside. Starting fresh.\n`)
      return defaultAccess()
    }
  }

  load(): Access {
    return this.bootAccess ?? this.readFile()
  }

  save(a: Access): void {
    if (this.bootAccess) return
    const normalized = normalizeAccess(a)
    mkdirSync(this.stateDir, { recursive: true, mode: 0o700 })
    const tmp = this.accessFile + '.tmp'
    writeFileSync(tmp, JSON.stringify(normalized, null, 2) + '\n', { mode: 0o600 })
    renameSync(tmp, this.accessFile)
  }
}

export function pruneExpired(a: Access, now = Date.now()): boolean {
  let changed = false
  for (const [code, p] of Object.entries(a.pending)) {
    if (p.expiresAt < now) {
      delete a.pending[code]
      changed = true
    }
  }
  return changed
}

export type GateResult =
  | { action: 'deliver'; access: Access; canonicalAccess?: Access }
  | { action: 'drop'; reason: string }
  | { action: 'pair'; code: string; isResend: boolean }

/** Normalized inbound message — the daemon builds this from a discord.js Message. */
export type InboundMeta = {
  senderId: string
  isDM: boolean
  /** Gate key: for threads, the PARENT channel id; otherwise the channel id. */
  gateChannelId: string
  /** Lazy mention check — only awaited when the group policy requires it. */
  isMentioned: () => Promise<boolean>
}

export type GateDeps = {
  store: AccessStore
  boundChannels: string[]
  /** Optional owner-controlled upper bound, freshly re-read for every message. */
  canonicalAccessFile?: string
  now?: () => number
  makeCode?: () => string
}

export type DeliveryAuthorization =
  | { ok: true; access: Access; canonicalAccess?: Access }
  | { ok: false; reason: string }

function loadCanonicalAccess(path: string): Access {
  if (!isAbsolute(path)) throw new Error('canonical access path must be absolute')
  const stat = lstatSync(path)
  const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
  if (
    !stat.isFile()
    || stat.isSymbolicLink()
    || stat.uid !== uid
    || (stat.mode & 0o077) !== 0
    || stat.size > 1024 * 1024
  ) {
    throw new Error('canonical access file must be a bounded regular file')
  }
  if (realpathSync(path) !== path) throw new Error('canonical access path is not canonical')
  const parent = dirname(path)
  const parentStat = lstatSync(parent)
  if (
    !parentStat.isDirectory()
    || parentStat.isSymbolicLink()
    || parentStat.uid !== uid
    || (parentStat.mode & 0o077) !== 0
    || realpathSync(parent) !== parent
  ) throw new Error('canonical access parent must be owner-private')
  // Mode bits alone are not an authorization boundary on macOS: an extended
  // ACL can grant another principal read or write access while stat(2) still
  // reports 0600/0700. Re-check both objects on every gate/revalidation read.
  assertNoExtendedAcl(path, 'canonical access file')
  assertNoExtendedAcl(parent, 'canonical access parent')
  return normalizeAccess(JSON.parse(readFileSync(path, 'utf8')))
}

/**
 * Revalidate a previously accepted message immediately before execution.
 * Unlike `gate`, this function never creates/resends pairing codes and never
 * mutates access state: a sender missing from the current allowlists is simply
 * revoked. Canonical state is freshly read on every call.
 */
export async function revalidateDeliveryAuthorization(
  msg: InboundMeta,
  deps: Pick<GateDeps, 'store' | 'boundChannels' | 'canonicalAccessFile'>,
): Promise<DeliveryAuthorization> {
  const access = deps.store.load()
  let canonicalAccess: Access | undefined
  if (deps.canonicalAccessFile) {
    try { canonicalAccess = loadCanonicalAccess(deps.canonicalAccessFile) } catch {
      return { ok: false, reason: 'canonical access unavailable or invalid (fail closed)' }
    }
  }

  if (msg.isDM) {
    if (access.dmPolicy === 'disabled') return { ok: false, reason: 'dmPolicy disabled' }
    if (!access.allowFrom.includes(msg.senderId)) {
      return { ok: false, reason: 'sender no longer in local DM allowFrom' }
    }
    if (canonicalAccess) {
      if (canonicalAccess.dmPolicy === 'disabled') {
        return { ok: false, reason: 'canonical dmPolicy disabled' }
      }
      if (!canonicalAccess.allowFrom.includes(msg.senderId)) {
        return { ok: false, reason: 'sender revoked by canonical DM allowFrom' }
      }
    }
    return { ok: true, access, canonicalAccess }
  }

  if (deps.boundChannels.length > 0 && !deps.boundChannels.includes(msg.gateChannelId)) {
    return { ok: false, reason: 'channel no longer bound to this bridge' }
  }
  const policy = access.groups[msg.gateChannelId]
  if (!policy || policy.allowFrom.length === 0 || !policy.allowFrom.includes(msg.senderId)) {
    return { ok: false, reason: 'sender/channel revoked by local group policy' }
  }
  const canonicalPolicy = canonicalAccess?.groups[msg.gateChannelId]
  if (canonicalAccess && (
    !canonicalPolicy
    || canonicalPolicy.allowFrom.length === 0
    || !canonicalPolicy.allowFrom.includes(msg.senderId)
  )) {
    return { ok: false, reason: 'sender/channel revoked by canonical group policy' }
  }
  if (
    ((policy.requireMention ?? false) || (canonicalPolicy?.requireMention ?? false))
    && !(await msg.isMentioned())
  ) return { ok: false, reason: 'requireMention and no mention detected' }
  return { ok: true, access, canonicalAccess }
}

/**
 * The inbound gate — same decision table as bridge/server.ts gate():
 * DM: allowFrom → deliver; allowlist → drop; pairing → code (resend cap 2,
 * pending cap 3, 1h expiry). Guild: bound-channel check, per-channel group
 * opt-in, non-empty group allowFrom, requireMention. Unlike the interactive
 * bridge, an empty guild allowlist fails closed because Discord drives a
 * non-interactive workspace-writing agent.
 */
export async function gate(msg: InboundMeta, deps: GateDeps): Promise<GateResult> {
  const { store, boundChannels } = deps
  const now = deps.now ?? Date.now
  const makeCode = deps.makeCode ?? (() => randomBytes(3).toString('hex'))

  const access = store.load()
  if (pruneExpired(access, now())) store.save(access)

  let canonicalAccess: Access | undefined
  if (deps.canonicalAccessFile) {
    try {
      canonicalAccess = loadCanonicalAccess(deps.canonicalAccessFile)
    } catch {
      return { action: 'drop', reason: 'canonical access unavailable or invalid (fail closed)' }
    }
  }

  const { senderId } = msg

  if (msg.isDM) {
    if (access.dmPolicy === 'disabled') return { action: 'drop', reason: 'dmPolicy disabled' }
    if (canonicalAccess) {
      if (canonicalAccess.dmPolicy === 'disabled') {
        return { action: 'drop', reason: 'canonical dmPolicy disabled' }
      }
      if (!canonicalAccess.allowFrom.includes(senderId)) {
        return { action: 'drop', reason: 'sender revoked by canonical DM allowFrom' }
      }
    }
    if (access.allowFrom.includes(senderId)) return { action: 'deliver', access, canonicalAccess }
    if (access.dmPolicy === 'allowlist') return { action: 'drop', reason: 'not in allowFrom' }

    // pairing mode — check for existing non-expired code for this sender
    for (const [code, p] of Object.entries(access.pending)) {
      if (p.senderId === senderId) {
        // Reply twice max (initial + one reminder), then go silent.
        if ((p.replies ?? 1) >= 2) return { action: 'drop', reason: 'pairing reply cap' }
        p.replies = (p.replies ?? 1) + 1
        store.save(access)
        return { action: 'pair', code, isResend: true }
      }
    }
    // Cap pending at 3. Extra attempts are silently dropped.
    if (Object.keys(access.pending).length >= 3) return { action: 'drop', reason: 'pending cap' }

    const code = makeCode()
    const t = now()
    access.pending[code] = {
      senderId,
      chatId: msg.gateChannelId, // DM channel ID — used later to confirm approval
      createdAt: t,
      expiresAt: t + 60 * 60 * 1000, // 1h
      replies: 1,
    }
    store.save(access)
    return { action: 'pair', code, isResend: false }
  }

  // Hard channel binding: the bot only answers in its own channel(s) even if
  // it's a member of others. Checked before the ACL so a sibling channel's
  // group entry in a shared access.json can't make this bot respond there.
  if (boundChannels.length > 0 && !boundChannels.includes(msg.gateChannelId)) {
    return {
      action: 'drop',
      reason: `channel ${msg.gateChannelId} not in bound [${boundChannels.join(', ')}]`,
    }
  }
  const policy = access.groups[msg.gateChannelId]
  if (!policy) {
    return {
      action: 'drop',
      reason: `no group for channel ${msg.gateChannelId}; known: [${Object.keys(access.groups).join(', ') || '(none)'}]`,
    }
  }
  const groupAllowFrom = policy.allowFrom ?? []
  if (groupAllowFrom.length === 0) {
    return { action: 'drop', reason: 'group allowFrom is empty (fail closed)' }
  }
  if (groupAllowFrom.length > 0 && !groupAllowFrom.includes(senderId)) {
    return { action: 'drop', reason: `sender ${senderId} not in group allowFrom` }
  }
  const canonicalPolicy = canonicalAccess?.groups[msg.gateChannelId]
  if (canonicalAccess) {
    if (!canonicalPolicy) return { action: 'drop', reason: 'channel revoked by canonical groups' }
    if (canonicalPolicy.allowFrom.length === 0) {
      return { action: 'drop', reason: 'canonical group allowFrom is empty (fail closed)' }
    }
    if (!canonicalPolicy.allowFrom.includes(senderId)) {
      return { action: 'drop', reason: 'sender revoked by canonical group allowFrom' }
    }
  }
  if (((policy.requireMention ?? false) || (canonicalPolicy?.requireMention ?? false)) && !(await msg.isMentioned())) {
    return { action: 'drop', reason: 'requireMention and no mention detected' }
  }
  return { action: 'deliver', access, canonicalAccess }
}
