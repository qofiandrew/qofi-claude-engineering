import {
  chmodSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { join } from 'path'

export const MAX_RETRY_NOTICES = 256
export const MAX_RETRY_NOTICE_BYTES = 256 * 1024
export const MAX_PARKED_TURNS = 256
export const MAX_PARKED_TURN_BYTES = 256 * 1024
const SAFE_ID = /^[A-Za-z0-9_-]{1,128}$/

export type RetryNoticeKind = 'inbound' | 'turn' | 'git' | 'active-turn' | 'active-git'
export type RetryNotice = {
  channel_id: string
  message_id: string
  kind: RetryNoticeKind
  sender_id: string
  gate_channel_id: string
  is_dm: boolean
  created_at: string
}

type RetryNoticeFile = {
  schema: 'codex-bridge-retry-notices/v1'
  entries: RetryNotice[]
}

export type ParkedTurn = {
  channel_id: string
  message_id: string
  sender_id: string
  gate_channel_id: string
  is_dm: boolean
  retry_at_ms: number
  rotation_attempt: number
  created_at: string
}

type ParkedTurnFile = {
  schema: 'codex-bridge-parked-turns/v1'
  entries: ParkedTurn[]
}

export function retryNoticeText(kind: RetryNoticeKind): string {
  return kind === 'active-turn' || kind === 'active-git'
    ? '⚠️ An active operation stopped and completion was not confirmed. Inspect the current workspace, then retry or reconcile.'
    : '⚠️ Completion was not confirmed before codex-bridge stopped. Inspect the current workspace, then retry or reconcile.'
}

export class RetryNoticeStore {
  readonly file: string

  constructor(readonly stateDir: string) {
    this.file = join(stateDir, 'retry-notices.json')
  }

  list(): RetryNotice[] {
    let stat
    try { stat = lstatSync(this.file) } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return []
      throw err
    }
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || stat.uid !== uid
      || (stat.mode & 0o777) !== 0o600
      || stat.size > MAX_RETRY_NOTICE_BYTES
    ) throw new Error('unsafe retry notice ledger')
    const value: unknown = JSON.parse(readFileSync(this.file, 'utf8'))
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error('malformed retry notice ledger')
    }
    const record = value as Record<string, unknown>
    if (record.schema !== 'codex-bridge-retry-notices/v1' || !Array.isArray(record.entries)) {
      throw new Error('malformed retry notice ledger schema')
    }
    if (record.entries.length > MAX_RETRY_NOTICES) throw new Error('retry notice ledger exceeds cap')
    const seen = new Set<string>()
    return record.entries.map(raw => {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        throw new Error('malformed retry notice entry')
      }
      const entry = raw as Record<string, unknown>
      if (
        typeof entry.channel_id !== 'string'
        || !SAFE_ID.test(entry.channel_id)
        || typeof entry.message_id !== 'string'
        || !SAFE_ID.test(entry.message_id)
        || !['inbound', 'turn', 'git', 'active-turn', 'active-git'].includes(String(entry.kind))
        || typeof entry.sender_id !== 'string'
        || !SAFE_ID.test(entry.sender_id)
        || typeof entry.gate_channel_id !== 'string'
        || !SAFE_ID.test(entry.gate_channel_id)
        || typeof entry.is_dm !== 'boolean'
        || typeof entry.created_at !== 'string'
        || !Number.isFinite(Date.parse(entry.created_at))
        || seen.has(entry.message_id)
      ) throw new Error('malformed retry notice entry fields')
      seen.add(entry.message_id)
      return {
        channel_id: entry.channel_id,
        message_id: entry.message_id,
        kind: entry.kind as RetryNoticeKind,
        sender_id: entry.sender_id,
        gate_channel_id: entry.gate_channel_id,
        is_dm: entry.is_dm,
        created_at: entry.created_at,
      }
    })
  }

  register(
    channelId: string,
    messageId: string,
    kind: RetryNoticeKind,
    metadata?: { senderId: string; gateChannelId: string; isDM: boolean },
  ): void {
    if (!SAFE_ID.test(channelId) || !SAFE_ID.test(messageId)) throw new Error('invalid retry notice id')
    const entries = this.list()
    const existing = entries.find(entry => entry.message_id === messageId)
    if (existing) {
      existing.channel_id = channelId
      existing.kind = kind
      if (metadata) {
        if (!SAFE_ID.test(metadata.senderId) || !SAFE_ID.test(metadata.gateChannelId)) {
          throw new Error('invalid retry notice authorization metadata')
        }
        existing.sender_id = metadata.senderId
        existing.gate_channel_id = metadata.gateChannelId
        existing.is_dm = metadata.isDM
      }
    } else {
      if (!metadata || !SAFE_ID.test(metadata.senderId) || !SAFE_ID.test(metadata.gateChannelId)) {
        throw new Error('new retry notice requires authorization metadata')
      }
      if (entries.length >= MAX_RETRY_NOTICES) throw new Error('retry notice ledger is full')
      entries.push({
        channel_id: channelId,
        message_id: messageId,
        kind,
        sender_id: metadata.senderId,
        gate_channel_id: metadata.gateChannelId,
        is_dm: metadata.isDM,
        created_at: new Date().toISOString(),
      })
    }
    this.write(entries)
  }

  remove(messageId: string): void {
    if (!SAFE_ID.test(messageId)) throw new Error('invalid retry notice id')
    const entries = this.list()
    const next = entries.filter(entry => entry.message_id !== messageId)
    if (next.length !== entries.length) this.write(next)
  }

  removeIfKind(messageId: string, kind: RetryNoticeKind): void {
    const entry = this.list().find(candidate => candidate.message_id === messageId)
    if (entry?.kind === kind) this.remove(messageId)
  }

  private write(entries: RetryNotice[]): void {
    const value: RetryNoticeFile = { schema: 'codex-bridge-retry-notices/v1', entries }
    const serialized = JSON.stringify(value, null, 2) + '\n'
    if (Buffer.byteLength(serialized) > MAX_RETRY_NOTICE_BYTES) {
      throw new Error('retry notice ledger exceeds byte cap')
    }
    mkdirSync(this.stateDir, { recursive: true, mode: 0o700 })
    const temp = `${this.file}.tmp-${process.pid}`
    try {
      writeFileSync(temp, serialized, { mode: 0o600, flag: 'wx' })
      chmodSync(temp, 0o600)
      renameSync(temp, this.file)
    } catch (err) {
      try { rmSync(temp, { force: true }) } catch {}
      throw err
    }
  }
}

/**
 * Durable metadata for quota-requeued tasks. The original Discord message is
 * refetched after the pool reset, so prompt text and attachment URLs never
 * enter harness state.
 */
export class ParkedTurnStore {
  readonly file: string

  constructor(readonly stateDir: string) {
    this.file = join(stateDir, 'parked-turns.json')
  }

  list(): ParkedTurn[] {
    let stat
    try { stat = lstatSync(this.file) } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return []
      throw err
    }
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || stat.uid !== uid
      || (stat.mode & 0o777) !== 0o600
      || stat.size > MAX_PARKED_TURN_BYTES
    ) throw new Error('unsafe parked turn ledger')
    const value: unknown = JSON.parse(readFileSync(this.file, 'utf8'))
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error('malformed parked turn ledger')
    }
    const record = value as Record<string, unknown>
    if (record.schema !== 'codex-bridge-parked-turns/v1' || !Array.isArray(record.entries)) {
      throw new Error('malformed parked turn ledger schema')
    }
    if (record.entries.length > MAX_PARKED_TURNS) throw new Error('parked turn ledger exceeds cap')
    const seen = new Set<string>()
    return record.entries.map(raw => {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        throw new Error('malformed parked turn entry')
      }
      const entry = raw as Record<string, unknown>
      if (
        typeof entry.channel_id !== 'string' || !SAFE_ID.test(entry.channel_id)
        || typeof entry.message_id !== 'string' || !SAFE_ID.test(entry.message_id)
        || typeof entry.sender_id !== 'string' || !SAFE_ID.test(entry.sender_id)
        || typeof entry.gate_channel_id !== 'string' || !SAFE_ID.test(entry.gate_channel_id)
        || typeof entry.is_dm !== 'boolean'
        || !Number.isSafeInteger(entry.retry_at_ms) || (entry.retry_at_ms as number) < 0
        || !Number.isSafeInteger(entry.rotation_attempt)
        || (entry.rotation_attempt as number) < 1 || (entry.rotation_attempt as number) > 16
        || typeof entry.created_at !== 'string' || !Number.isFinite(Date.parse(entry.created_at))
        || seen.has(entry.message_id)
      ) throw new Error('malformed parked turn entry fields')
      seen.add(entry.message_id)
      return entry as unknown as ParkedTurn
    })
  }

  register(
    channelId: string,
    messageId: string,
    metadata: { senderId: string; gateChannelId: string; isDM: boolean },
    retryAtMs: number,
    rotationAttempt: number,
  ): void {
    if (!SAFE_ID.test(channelId) || !SAFE_ID.test(messageId)
      || !SAFE_ID.test(metadata.senderId) || !SAFE_ID.test(metadata.gateChannelId)) {
      throw new Error('invalid parked turn id')
    }
    if (!Number.isSafeInteger(retryAtMs) || retryAtMs < 0
      || !Number.isSafeInteger(rotationAttempt) || rotationAttempt < 1 || rotationAttempt > 16) {
      throw new Error('invalid parked turn retry boundary')
    }
    const entries = this.list()
    const existing = entries.find(entry => entry.message_id === messageId)
    if (existing) {
      existing.channel_id = channelId
      existing.sender_id = metadata.senderId
      existing.gate_channel_id = metadata.gateChannelId
      existing.is_dm = metadata.isDM
      existing.retry_at_ms = retryAtMs
      existing.rotation_attempt = rotationAttempt
    } else {
      if (entries.length >= MAX_PARKED_TURNS) throw new Error('parked turn ledger is full')
      entries.push({
        channel_id: channelId,
        message_id: messageId,
        sender_id: metadata.senderId,
        gate_channel_id: metadata.gateChannelId,
        is_dm: metadata.isDM,
        retry_at_ms: retryAtMs,
        rotation_attempt: rotationAttempt,
        created_at: new Date().toISOString(),
      })
    }
    this.write(entries)
  }

  remove(messageId: string): void {
    if (!SAFE_ID.test(messageId)) throw new Error('invalid parked turn id')
    const entries = this.list()
    const next = entries.filter(entry => entry.message_id !== messageId)
    if (next.length !== entries.length) this.write(next)
  }

  private write(entries: ParkedTurn[]): void {
    const value: ParkedTurnFile = { schema: 'codex-bridge-parked-turns/v1', entries }
    const serialized = JSON.stringify(value, null, 2) + '\n'
    if (Buffer.byteLength(serialized) > MAX_PARKED_TURN_BYTES) {
      throw new Error('parked turn ledger exceeds byte cap')
    }
    mkdirSync(this.stateDir, { recursive: true, mode: 0o700 })
    const temp = `${this.file}.tmp-${process.pid}`
    try {
      writeFileSync(temp, serialized, { mode: 0o600, flag: 'wx' })
      chmodSync(temp, 0o600)
      renameSync(temp, this.file)
    } catch (err) {
      try { rmSync(temp, { force: true }) } catch {}
      throw err
    }
  }
}
