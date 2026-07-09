/**
 * Access control for the Codex Discord bridge — a faithful port of the gate in
 * bridge/server.ts, factored into pure(ish) functions so it can be unit-tested
 * without a Discord gateway. The on-disk format (access.json, approved/) is
 * IDENTICAL to the Claude bridge plugin's, so the same operator tooling and
 * mental model apply. State dir defaults to ~/.codex/channels/discord.
 */

import { randomBytes } from 'crypto'
import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'fs'
import { join } from 'path'

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
      const parsed = JSON.parse(raw) as Partial<Access>
      return {
        dmPolicy: parsed.dmPolicy ?? 'pairing',
        allowFrom: parsed.allowFrom ?? [],
        groups: parsed.groups ?? {},
        pending: parsed.pending ?? {},
        mentionPatterns: parsed.mentionPatterns,
        ackReaction: parsed.ackReaction,
        replyToMode: parsed.replyToMode,
        textChunkLimit: parsed.textChunkLimit,
        chunkMode: parsed.chunkMode,
      }
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
    mkdirSync(this.stateDir, { recursive: true, mode: 0o700 })
    const tmp = this.accessFile + '.tmp'
    writeFileSync(tmp, JSON.stringify(a, null, 2) + '\n', { mode: 0o600 })
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
  | { action: 'deliver'; access: Access }
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
  now?: () => number
  makeCode?: () => string
}

/**
 * The inbound gate — same decision table as bridge/server.ts gate():
 * DM: allowFrom → deliver; allowlist → drop; pairing → code (resend cap 2,
 * pending cap 3, 1h expiry). Guild: bound-channel check, per-channel group
 * opt-in, group allowFrom, requireMention.
 */
export async function gate(msg: InboundMeta, deps: GateDeps): Promise<GateResult> {
  const { store, boundChannels } = deps
  const now = deps.now ?? Date.now
  const makeCode = deps.makeCode ?? (() => randomBytes(3).toString('hex'))

  const access = store.load()
  if (pruneExpired(access, now())) store.save(access)

  if (access.dmPolicy === 'disabled') return { action: 'drop', reason: 'dmPolicy disabled' }

  const { senderId } = msg

  if (msg.isDM) {
    if (access.allowFrom.includes(senderId)) return { action: 'deliver', access }
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
  if (groupAllowFrom.length > 0 && !groupAllowFrom.includes(senderId)) {
    return { action: 'drop', reason: `sender ${senderId} not in group allowFrom` }
  }
  if ((policy.requireMention ?? false) && !(await msg.isMentioned())) {
    return { action: 'drop', reason: 'requireMention and no mention detected' }
  }
  return { action: 'deliver', access }
}
