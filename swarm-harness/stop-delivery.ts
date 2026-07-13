import {
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, join, resolve, sep } from 'node:path'
import type { WorkerRuntime as HarnessWorkerRuntime } from './events'

export const STOP_EVENT_SCHEMA = 'qofi.swarm.stop/v1' as const

export type WorkerRuntime = Exclude<HarnessWorkerRuntime, 'harness'>

export interface NormalizedStopEvent {
  schema: typeof STOP_EVENT_SCHEMA
  eventId: string
  runtime: WorkerRuntime
  swarm: string
  taskId: string
  channelId: string | null
  fallbackChannelId: string | null
  summary: string
  occurredAtMs: number
}

export interface DeliveryReceipt {
  messageId: string
}

export interface MessageSender {
  send(channelId: string, text: string): Promise<DeliveryReceipt>
}

export type StopDisposition = 'delivered' | 'queued' | 'blocked'

export interface StopOutcome {
  schema: 'qofi.swarm.stop-outcome/v1'
  eventId: string
  disposition: StopDisposition
  stopped: boolean
  attempts: number
  receiptId: string | null
  deadLetterId: string | null
  fallback: 'delivered' | 'failed' | 'unavailable' | 'not-needed'
  fallbackReceiptId: string | null
  completedAtMs: number
  error: string | null
}

interface StoredOutcome extends StopOutcome {
  event: NormalizedStopEvent
}

function publicOutcome(stored: StoredOutcome): StopOutcome {
  const { event: _event, ...outcome } = stored
  return outcome
}

function sameDurableStopScope(
  prior: NormalizedStopEvent,
  current: NormalizedStopEvent,
): boolean {
  return prior.schema === current.schema
    && prior.eventId === current.eventId
    && prior.runtime === current.runtime
    && prior.swarm === current.swarm
    && prior.taskId === current.taskId
    && prior.channelId === current.channelId
    && prior.fallbackChannelId === current.fallbackChannelId
}

function durableStopEvent(event: NormalizedStopEvent): NormalizedStopEvent {
  validateStopEvent(event)
  return { ...event, summary: redactStopText(event.summary) }
}

function durableStopOutcome(outcome: StopOutcome): StopOutcome {
  return {
    ...outcome,
    error: outcome.error === null ? null : redactStopText(outcome.error, 400),
  }
}

interface RetryResult {
  ok: boolean
  attempts: number
  receipt: DeliveryReceipt | null
  error: string | null
}

export interface StopDeliveryPipelineOptions {
  sender: MessageSender
  fallbackSender?: MessageSender
  store: StopStateStore
  maxAttempts?: number
  fallbackMaxAttempts?: number
  backoffMs?: readonly number[]
  sleep?: (ms: number) => Promise<void>
  now?: () => number
}

const LABEL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const EVENT_ID = /^[a-f0-9]{32,64}$/
const CHANNEL_ID = /^\d{16,22}$/
const MAX_SUMMARY_CHARS = 1_500

const SECRET_PATTERNS: readonly RegExp[] = [
  /\b(?:sk|rk|pk)-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}\b/gi,
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
  /\bxox(?:a|b|p|r|s)-[A-Za-z0-9-]{12,}\b/gi,
  /\b(?:eyJ[A-Za-z0-9_-]{8,})\.(?:eyJ[A-Za-z0-9_-]{8,})\.[A-Za-z0-9_-]{8,}\b/g,
  /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g,
  /\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{20,}\b/g,
  /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi,
]

export function redactStopText(value: unknown, maxChars = MAX_SUMMARY_CHARS): string {
  let text = String(value ?? '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
  for (const pattern of SECRET_PATTERNS) text = text.replace(pattern, '[REDACTED]')
  text = text.trim()
  if (text.length > maxChars) text = `${text.slice(0, Math.max(0, maxChars - 1))}…`
  return text
}

export function safeStopLabel(value: unknown, fallback: string): string {
  const candidate = String(value ?? '').trim()
  return LABEL.test(candidate) ? candidate : fallback
}

function validateStopEvent(event: NormalizedStopEvent): void {
  if (event.schema !== STOP_EVENT_SCHEMA) throw new Error('unsupported stop event schema')
  if (!EVENT_ID.test(event.eventId)) throw new Error('invalid stop event id')
  if (!LABEL.test(event.swarm)) throw new Error('invalid swarm label')
  if (!LABEL.test(event.taskId)) throw new Error('invalid task label')
  if (event.runtime !== 'claude' && event.runtime !== 'codex') throw new Error('invalid runtime')
  if (event.channelId !== null && !CHANNEL_ID.test(event.channelId)) throw new Error('invalid primary channel')
  if (event.fallbackChannelId !== null && !CHANNEL_ID.test(event.fallbackChannelId)) {
    throw new Error('invalid fallback channel')
  }
  if (!Number.isSafeInteger(event.occurredAtMs) || event.occurredAtMs < 0) {
    throw new Error('invalid occurrence time')
  }
}

export function formatStopMessage(event: NormalizedStopEvent): string {
  validateStopEvent(event)
  const summary = redactStopText(event.summary) || 'No agent-composed boundary summary was supplied.'
  return [
    `⏹️ stop · ${event.swarm} · ${event.taskId}`,
    `${event.runtime} worker boundary`,
    summary,
  ].join('\n')
}

function safeError(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error)
  return redactStopText(raw, 400) || 'delivery failed'
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise(resolvePromise => setTimeout(resolvePromise, ms))
}

async function deliverWithRetry(
  sender: MessageSender,
  channelId: string,
  text: string,
  maxAttempts: number,
  backoffMs: readonly number[],
  sleep: (ms: number) => Promise<void>,
): Promise<RetryResult> {
  let error: string | null = null
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      const receipt = await sender.send(channelId, text)
      if (!receipt || typeof receipt.messageId !== 'string' || !receipt.messageId.trim()) {
        throw new Error('Discord returned no message receipt')
      }
      return { ok: true, attempts: attempt, receipt, error: null }
    } catch (caught) {
      error = safeError(caught)
      if (attempt < maxAttempts) {
        const configured = backoffMs[Math.min(attempt - 1, backoffMs.length - 1)] ?? 0
        const hinted = caught instanceof DiscordDeliveryError ? (caught.retryAfterMs ?? 0) : 0
        // Stop hooks have a finite runtime budget; honor Discord's hint up to a
        // five-second ceiling, then dead-letter rather than being killed before
        // the delivered-or-queued decision can be made.
        const delay = Math.min(5_000, Math.max(configured, hinted))
        if (delay > 0) await sleep(delay)
      }
    }
  }
  return { ok: false, attempts: maxAttempts, receipt: null, error }
}

function assertPrivateDirectory(path: string): void {
  let prefix = sep
  for (const part of resolve(path).split(sep).filter(Boolean)) {
    prefix = join(prefix, part)
    const component = lstatSync(prefix)
    if (!component.isSymbolicLink()) continue
    const target = realpathSync(prefix)
    const targetInfo = lstatSync(target)
    if (component.uid !== 0 || !targetInfo.isDirectory() || targetInfo.uid !== 0
      || (targetInfo.mode & 0o022) !== 0) {
      throw new Error(`${basename(path)} contains untrusted symlink indirection`)
    }
  }
  const info = lstatSync(path)
  const uid = process.getuid?.()
  if (!info.isDirectory() || info.isSymbolicLink() || uid === undefined || info.uid !== uid) {
    throw new Error(`${basename(path)} is not an owner-real directory`)
  }
  if ((info.mode & 0o077) !== 0) throw new Error(`${basename(path)} must be mode 0700`)
}

function ensurePrivateDirectory(path: string): void {
  if (!existsSync(path)) mkdirSync(path, { recursive: true, mode: 0o700 })
  assertPrivateDirectory(path)
}

function contained(root: string, child: string): boolean {
  const prefix = root.endsWith(sep) ? root : `${root}${sep}`
  return child.startsWith(prefix)
}

/**
 * Owner-private durable stop state. One immutable record per event avoids a
 * shared append race and makes replay idempotent after a hook/process crash.
 */
export class StopStateStore {
  readonly root: string

  constructor(root: string) {
    this.root = resolve(root)
    ensurePrivateDirectory(this.root)
    for (const dir of ['outcomes', 'dead-letter', 'audit', 'locks']) {
      ensurePrivateDirectory(join(this.root, dir))
    }
  }

  private recordPath(kind: 'outcomes' | 'dead-letter' | 'audit', eventId: string): string {
    if (!EVENT_ID.test(eventId)) throw new Error('invalid stop event id')
    const path = resolve(this.root, kind, `${eventId}.json`)
    if (!contained(this.root, path)) throw new Error('stop state path escaped its root')
    return path
  }

  private atomicRecord(path: string, value: unknown): void {
    ensurePrivateDirectory(dirname(path))
    if (existsSync(path)) {
      const existing = lstatSync(path)
      const uid = process.getuid?.()
      if (!existing.isFile() || existing.isSymbolicLink() || existing.nlink !== 1
        || uid === undefined || existing.uid !== uid || (existing.mode & 0o077) !== 0) {
        throw new Error('existing durable record is not a private real file')
      }
      return
    }
    const tmp = `${path}.tmp-${process.pid}-${Math.random().toString(16).slice(2)}`
    let fd: number | null = null
    try {
      fd = openSync(tmp, 'wx', 0o600)
      writeFileSync(fd, `${JSON.stringify(value)}\n`, 'utf8')
      fsyncSync(fd)
      closeSync(fd)
      fd = null
      renameSync(tmp, path)
      const dirFd = openSync(dirname(path), 'r')
      try { fsyncSync(dirFd) } finally { closeSync(dirFd) }
      const info = lstatSync(path)
      const uid = process.getuid?.()
      if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1
        || uid === undefined || info.uid !== uid || (info.mode & 0o077) !== 0) {
        throw new Error('durable record failed private-file verification')
      }
    } finally {
      if (fd !== null) closeSync(fd)
      rmSync(tmp, { force: true })
    }
  }

  readOutcome(eventId: string): StoredOutcome | null {
    const path = this.recordPath('outcomes', eventId)
    if (!existsSync(path)) return null
    const info = lstatSync(path)
    const uid = process.getuid?.()
    if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1
      || uid === undefined || info.uid !== uid || (info.mode & 0o077) !== 0) {
      throw new Error('stored stop outcome is not a private real file')
    }
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as StoredOutcome
    if (parsed.eventId !== eventId || parsed.event?.eventId !== eventId) {
      throw new Error('stored stop outcome identity mismatch')
    }
    return parsed
  }

  writeOutcome(event: NormalizedStopEvent, outcome: StopOutcome): void {
    this.atomicRecord(this.recordPath('outcomes', event.eventId), {
      ...durableStopOutcome(outcome),
      event: durableStopEvent(event),
    })
  }

  writeDeadLetter(event: NormalizedStopEvent, attempts: number, error: string | null, queuedAtMs: number): string {
    const path = this.recordPath('dead-letter', event.eventId)
    this.atomicRecord(path, {
      schema: 'qofi.swarm.stop-dead-letter/v1',
      deadLetterId: event.eventId,
      event: durableStopEvent(event),
      attempts,
      error: redactStopText(error, 400),
      queuedAtMs,
    })
    const record = JSON.parse(readFileSync(path, 'utf8')) as { deadLetterId?: string }
    if (record.deadLetterId !== event.eventId) throw new Error('dead-letter verification failed')
    return event.eventId
  }

  hasAudit(eventId: string): boolean {
    return existsSync(this.recordPath('audit', eventId))
  }

  writeAudit(event: NormalizedStopEvent, outcome: StopOutcome): void {
    const durable = durableStopOutcome(outcome)
    this.atomicRecord(this.recordPath('audit', event.eventId), {
      schema: 'qofi.swarm.stop-audit/v1',
      eventId: event.eventId,
      runtime: event.runtime,
      swarm: event.swarm,
      taskId: event.taskId,
      occurredAtMs: event.occurredAtMs,
      outcome: {
        disposition: durable.disposition,
        stopped: durable.stopped,
        attempts: durable.attempts,
        receiptId: durable.receiptId,
        deadLetterId: durable.deadLetterId,
        fallback: durable.fallback,
        fallbackReceiptId: durable.fallbackReceiptId,
        completedAtMs: durable.completedAtMs,
        error: durable.error,
      },
    })
  }

  async withEventLock<T>(eventId: string, fn: () => Promise<T>): Promise<T> {
    if (!EVENT_ID.test(eventId)) throw new Error('invalid stop event id')
    const lockPath = join(this.root, 'locks', `${eventId}.lock`)
    const deadline = Date.now() + 15_000
    for (;;) {
      try {
        mkdirSync(lockPath, { mode: 0o700 })
        break
      } catch (error: any) {
        if (error?.code !== 'EEXIST') throw error
        const lock = lstatSync(lockPath)
        const uid = process.getuid?.()
        if (!lock.isDirectory() || lock.isSymbolicLink() || uid === undefined
          || lock.uid !== uid || (lock.mode & 0o077) !== 0) {
          throw new Error('stop event lock is not an owner-private real directory')
        }
        const age = Date.now() - lock.mtimeMs
        if (age > 60_000) {
          rmSync(lockPath, { recursive: true, force: true })
          continue
        }
        if (Date.now() >= deadline) throw new Error('timed out waiting for stop event lock')
        await defaultSleep(20)
      }
    }
    try {
      return await fn()
    } finally {
      rmSync(lockPath, { recursive: true, force: true })
    }
  }
}

export class StopDeliveryPipeline {
  private readonly sender: MessageSender
  private readonly fallbackSender?: MessageSender
  private readonly store: StopStateStore
  private readonly maxAttempts: number
  private readonly fallbackMaxAttempts: number
  private readonly backoffMs: readonly number[]
  private readonly sleep: (ms: number) => Promise<void>
  private readonly now: () => number

  constructor(options: StopDeliveryPipelineOptions) {
    this.sender = options.sender
    this.fallbackSender = options.fallbackSender
    this.store = options.store
    this.maxAttempts = Math.max(1, Math.min(5, options.maxAttempts ?? 3))
    this.fallbackMaxAttempts = Math.max(1, Math.min(3, options.fallbackMaxAttempts ?? 2))
    this.backoffMs = (options.backoffMs?.length ? options.backoffMs : [250, 1_000, 3_000])
      .map(ms => Math.max(0, Math.min(5_000, Math.floor(ms))))
    this.sleep = options.sleep ?? defaultSleep
    this.now = options.now ?? Date.now
  }

  /**
   * Completion/other harness gates call this instead of `execute` when Stop is
   * refused. The refusal is a first-class, replay-safe lifecycle outcome: no
   * Discord attempt and no dead-letter, but both private outcome and audit
   * records must exist before the method returns.
   */
  async recordBlockedAttempt(event: NormalizedStopEvent, reason: unknown): Promise<StopOutcome> {
    const refusal = redactStopText(reason, 400) || 'stop gate refused the boundary'
    try {
      validateStopEvent(event)
      return await this.store.withEventLock(event.eventId, async () => {
        const prior = this.store.readOutcome(event.eventId)
        if (prior) {
          if (!sameDurableStopScope(prior.event, event)) {
            throw new Error('stop event id is already bound to a different normalized scope')
          }
          if (prior.disposition !== 'blocked' || prior.stopped !== false) {
            throw new Error('stop event already has a non-blocked terminal outcome')
          }
          if (!this.store.hasAudit(event.eventId)) this.store.writeAudit(prior.event, prior)
          return publicOutcome(prior)
        }
        const outcome: StopOutcome = {
          schema: 'qofi.swarm.stop-outcome/v1',
          eventId: event.eventId,
          disposition: 'blocked',
          stopped: false,
          attempts: 0,
          receiptId: null,
          deadLetterId: null,
          fallback: 'not-needed',
          fallbackReceiptId: null,
          completedAtMs: this.now(),
          error: refusal,
        }
        this.store.writeOutcome(event, outcome)
        this.store.writeAudit(event, outcome)
        return outcome
      })
    } catch (error) {
      const outcome: StopOutcome = {
        schema: 'qofi.swarm.stop-outcome/v1',
        eventId: EVENT_ID.test(event?.eventId ?? '') ? event.eventId : '0'.repeat(64),
        disposition: 'blocked',
        stopped: false,
        attempts: 0,
        receiptId: null,
        deadLetterId: null,
        fallback: 'unavailable',
        fallbackReceiptId: null,
        completedAtMs: this.now(),
        error: safeError(error),
      }
      if (EVENT_ID.test(event?.eventId ?? '')
        && LABEL.test(event?.swarm ?? '')
        && LABEL.test(event?.taskId ?? '')
        && (event?.runtime === 'claude' || event?.runtime === 'codex')) {
        try { this.store.writeAudit(event, outcome) } catch {}
      }
      return outcome
    }
  }

  async execute(event: NormalizedStopEvent): Promise<StopOutcome> {
    try {
      validateStopEvent(event)
      return await this.store.withEventLock(event.eventId, async () => {
        const prior = this.store.readOutcome(event.eventId)
        if (prior) {
          if (!sameDurableStopScope(prior.event, event)) {
            throw new Error('stop event id is already bound to a different normalized scope')
          }
          if (!this.store.hasAudit(event.eventId)) this.store.writeAudit(prior.event, prior)
          return publicOutcome(prior)
        }

        const message = formatStopMessage(event)
        const primary = event.channelId
          ? await deliverWithRetry(
            this.sender, event.channelId, message, this.maxAttempts, this.backoffMs, this.sleep,
          )
          : { ok: false, attempts: 0, receipt: null, error: 'primary channel unavailable' }

        if (primary.ok) {
          const outcome: StopOutcome = {
            schema: 'qofi.swarm.stop-outcome/v1',
            eventId: event.eventId,
            disposition: 'delivered',
            stopped: true,
            attempts: primary.attempts,
            receiptId: primary.receipt!.messageId,
            deadLetterId: null,
            fallback: 'not-needed',
            fallbackReceiptId: null,
            completedAtMs: this.now(),
            error: null,
          }
          this.store.writeOutcome(event, outcome)
          this.store.writeAudit(event, outcome)
          return outcome
        }

        const queuedAtMs = this.now()
        const deadLetterId = this.store.writeDeadLetter(event, primary.attempts, primary.error, queuedAtMs)
        let fallback: StopOutcome['fallback'] = 'unavailable'
        let fallbackReceiptId: string | null = null
        if (event.fallbackChannelId && this.fallbackSender) {
          const fallbackText = `⚠️ stop delivery queued · ${event.swarm} · ${event.taskId} · ${deadLetterId}`
          const result = await deliverWithRetry(
            this.fallbackSender,
            event.fallbackChannelId,
            fallbackText,
            this.fallbackMaxAttempts,
            this.backoffMs,
            this.sleep,
          )
          fallback = result.ok ? 'delivered' : 'failed'
          fallbackReceiptId = result.receipt?.messageId ?? null
        }
        const outcome: StopOutcome = {
          schema: 'qofi.swarm.stop-outcome/v1',
          eventId: event.eventId,
          disposition: 'queued',
          stopped: true,
          attempts: primary.attempts,
          receiptId: null,
          deadLetterId,
          fallback,
          fallbackReceiptId,
          completedAtMs: this.now(),
          error: primary.error,
        }
        this.store.writeOutcome(event, outcome)
        this.store.writeAudit(event, outcome)
        return outcome
      })
    } catch (error) {
      const blocked: StopOutcome = {
        schema: 'qofi.swarm.stop-outcome/v1',
        eventId: EVENT_ID.test(event?.eventId ?? '') ? event.eventId : '0'.repeat(64),
        disposition: 'blocked',
        stopped: false,
        attempts: 0,
        receiptId: null,
        deadLetterId: null,
        fallback: 'unavailable',
        fallbackReceiptId: null,
        completedAtMs: this.now(),
        error: safeError(error),
      }
      // Invalid channel/timestamp/etc. is itself a stop outcome. When the event
      // identity and non-content audit labels are safe, record that refusal;
      // storage failures are the only case where durable audit is impossible.
      if (EVENT_ID.test(event?.eventId ?? '')
        && LABEL.test(event?.swarm ?? '')
        && LABEL.test(event?.taskId ?? '')
        && (event?.runtime === 'claude' || event?.runtime === 'codex')) {
        try { this.store.writeAudit(event, blocked) } catch {}
      }
      return blocked
    }
  }
}

class DiscordDeliveryError extends Error {
  constructor(message: string, readonly retryAfterMs: number | null = null) {
    super(message)
  }
}

export interface DiscordRestSenderOptions {
  token: string
  apiBase?: string
  timeoutMs?: number
  fetchImpl?: typeof fetch
}

/** Discord sender that counts success only after a 2xx response with a message id. */
export class DiscordRestSender implements MessageSender {
  private readonly token: string
  private readonly apiBase: string
  private readonly timeoutMs: number
  private readonly fetchImpl: typeof fetch

  constructor(options: DiscordRestSenderOptions) {
    if (!options.token) throw new Error('Discord token is unavailable')
    this.token = options.token
    this.apiBase = (options.apiBase ?? 'https://discord.com/api/v10').replace(/\/$/, '')
    this.timeoutMs = Math.max(500, Math.min(15_000, options.timeoutMs ?? 4_000))
    this.fetchImpl = options.fetchImpl ?? fetch
  }

  async send(channelId: string, text: string): Promise<DeliveryReceipt> {
    if (!CHANNEL_ID.test(channelId)) throw new Error('invalid Discord channel')
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs)
    try {
      const response = await this.fetchImpl(`${this.apiBase}/channels/${channelId}/messages`, {
        method: 'POST',
        headers: {
          authorization: `Bot ${this.token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ content: redactStopText(text, 1_900), allowed_mentions: { parse: [] } }),
        signal: controller.signal,
      })
      let payload: any = null
      try { payload = await response.json() } catch {}
      if (!response.ok) {
        const retryAfter = response.status === 429 && Number.isFinite(Number(payload?.retry_after))
          ? Math.ceil(Number(payload.retry_after) * 1_000)
          : null
        throw new DiscordDeliveryError(`Discord send failed with HTTP ${response.status}`, retryAfter)
      }
      if (!payload || typeof payload.id !== 'string' || !payload.id) {
        throw new DiscordDeliveryError('Discord send returned no message id')
      }
      return { messageId: payload.id }
    } catch (error: any) {
      if (error?.name === 'AbortError') throw new DiscordDeliveryError('Discord send timed out')
      throw error
    } finally {
      clearTimeout(timeout)
    }
  }
}
