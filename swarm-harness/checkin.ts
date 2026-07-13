import { SWARM_STATES, type SwarmState } from './events'
import { redactStopText, type DeliveryReceipt } from './stop-delivery'

export const CTO_CHECKIN_SCHEMA = 'qofi.cto-checkin/v1' as const

export interface CtoCheckIn {
  schema: typeof CTO_CHECKIN_SCHEMA
  ping_id: string
  addressee: string
  current_task: string
  status: SwarmState
  progress_since_last_checkin: string
  blockers: string[]
  next_action: string
  needs_input: boolean
}

export interface CheckInGroundTruth {
  addressee: string
  currentTask: string
  status: SwarmState
}

export interface CheckInValidation {
  ok: boolean
  value: CtoCheckIn | null
  errors: string[]
}

export interface CheckInPing {
  pingId: string
  channelId: string
  addressee: string
  currentTask: string
  sentAtMs: number
}

export interface CheckInMetric {
  schema: 'qofi.cto-checkin-metric/v1'
  ping_id: string
  addressee: string
  current_task: string
  outcome: 'accepted' | 'rejected'
  latency_ms: number
  attempt: number
  errors: string[]
  recorded_at_ms: number
}

export interface CheckInPingSender {
  send(channelId: string, text: string): Promise<DeliveryReceipt>
}

export interface CheckInEnforcerOptions {
  sender: CheckInPingSender
  now?: () => number
  onMetric?: (metric: CheckInMetric) => void | Promise<void>
}

export type CheckInResponse =
  | { accepted: true; checkIn: CtoCheckIn; metric: CheckInMetric }
  | { accepted: false; errors: string[]; rePingReceipt: DeliveryReceipt; metric: CheckInMetric }

const PING_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
const LABEL = /^[a-z][a-z0-9-]{0,63}$/
const TASK = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
const CHANNEL = /^\d{16,22}$/
const EXACT_KEYS = new Set([
  'schema',
  'ping_id',
  'addressee',
  'current_task',
  'status',
  'progress_since_last_checkin',
  'blockers',
  'next_action',
  'needs_input',
])
const BARE_ACK = /^(?:ack(?:nowledged)?|ok(?:ay)?|yes|yep|still working|working|on it|driving|here)$/i

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function boundedText(value: unknown, field: string, max: number, errors: string[]): string {
  if (typeof value !== 'string') {
    errors.push(`${field} must be a string`)
    return ''
  }
  const text = value.trim()
  if (!text) errors.push(`${field} must not be blank`)
  if (text.length > max) errors.push(`${field} exceeds ${max} characters`)
  if (redactStopText(text, text.length + 1) !== text) {
    errors.push(`${field} contains forbidden credential or identity material`)
  }
  return text
}

function parseCandidate(candidate: unknown): { value: unknown; earlyError: string | null } {
  if (typeof candidate !== 'string') return { value: candidate, earlyError: null }
  const text = candidate.trim()
  if (BARE_ACK.test(text)) return { value: null, earlyError: 'bare acknowledgment is not a check-in' }
  try {
    return { value: JSON.parse(text), earlyError: null }
  } catch {
    return { value: null, earlyError: 'check-in must be one JSON object with no prose wrapper' }
  }
}

/** Strict shape and ground-truth validator. Runtime adapters do not get a vote. */
export function validateCtoCheckIn(
  candidate: unknown,
  expected: CheckInGroundTruth & { pingId: string },
): CheckInValidation {
  const parsed = parseCandidate(candidate)
  if (parsed.earlyError) return { ok: false, value: null, errors: [parsed.earlyError] }
  if (!record(parsed.value)) return { ok: false, value: null, errors: ['check-in must be an object'] }
  const input = parsed.value
  const errors: string[] = []
  for (const key of Object.keys(input)) {
    if (!EXACT_KEYS.has(key)) errors.push(`unsupported check-in field: ${key}`)
  }
  for (const key of EXACT_KEYS) {
    if (!(key in input)) errors.push(`missing check-in field: ${key}`)
  }
  if (input.schema !== CTO_CHECKIN_SCHEMA) errors.push('unsupported check-in schema')
  if (input.ping_id !== expected.pingId) errors.push('check-in ping correlation does not match')
  if (input.addressee !== expected.addressee) errors.push('check-in addressee does not match harness truth')
  if (input.current_task !== expected.currentTask) errors.push('check-in task does not match harness truth')
  if (!SWARM_STATES.includes(input.status as SwarmState)) {
    errors.push('check-in status is outside the state vocabulary')
  } else if (input.status !== expected.status) {
    errors.push('check-in status does not match harness truth')
  }
  const progress = boundedText(input.progress_since_last_checkin, 'progress_since_last_checkin', 800, errors)
  const nextAction = boundedText(input.next_action, 'next_action', 500, errors)
  let blockers: string[] = []
  if (!Array.isArray(input.blockers) || input.blockers.length > 8) {
    errors.push('blockers must be an array of at most 8 strings')
  } else {
    blockers = input.blockers.map((item, index) => boundedText(item, `blockers[${index}]`, 300, errors))
  }
  if (typeof input.needs_input !== 'boolean') errors.push('needs_input must be boolean')
  if (expected.status === 'WAITING_FOR_OPERATOR' && input.needs_input !== true) {
    errors.push('WAITING_FOR_OPERATOR requires needs_input=true')
  }
  if (input.needs_input === true && blockers.length === 0) {
    errors.push('needs_input=true requires at least one blocker or question')
  }
  if (errors.length > 0) return { ok: false, value: null, errors: [...new Set(errors)] }
  return {
    ok: true,
    errors: [],
    value: {
      schema: CTO_CHECKIN_SCHEMA,
      ping_id: input.ping_id as string,
      addressee: input.addressee as string,
      current_task: input.current_task as string,
      status: input.status as SwarmState,
      progress_since_last_checkin: progress,
      blockers,
      next_action: nextAction,
      needs_input: input.needs_input as boolean,
    },
  }
}

export function renderCheckInPing(ping: CheckInPing, attempt = 1, errors: readonly string[] = []): string {
  const escalation = attempt > 1
    ? ` Prior response failed validation: ${errors.map(error => redactStopText(error, 120)).join('; ')}.`
    : ''
  return [
    `⏱️ check-in required · ${ping.currentTask} · attempt ${attempt}`,
    `Reply with exactly one ${CTO_CHECKIN_SCHEMA} JSON object addressed to ${ping.addressee}.${escalation}`,
    'Required fields: schema, ping_id, addressee, current_task, status, progress_since_last_checkin, blockers, next_action, needs_input.',
    `ping_id=${ping.pingId}. A bare acknowledgment is invalid and will be re-pinged.`,
  ].join('\n')
}

interface PendingPing extends CheckInPing {
  attempt: number
  firstSentAtMs: number
  lastSentAtMs: number
}

/**
 * Correlates a harness-owned ping with one strict worker response. Invalid
 * responses are re-pinged by this class itself; callers cannot treat activity
 * or a bare acknowledgement as completion.
 */
export class CtoCheckInEnforcer {
  private readonly sender: CheckInPingSender
  private readonly now: () => number
  private readonly onMetric?: (metric: CheckInMetric) => void | Promise<void>
  private readonly pending = new Map<string, PendingPing>()
  private readonly metricLog: CheckInMetric[] = []

  constructor(options: CheckInEnforcerOptions) {
    this.sender = options.sender
    this.now = options.now ?? Date.now
    this.onMetric = options.onMetric
  }

  async issue(ping: CheckInPing): Promise<DeliveryReceipt> {
    if (!PING_ID.test(ping.pingId)) throw new Error('invalid check-in ping id')
    if (!CHANNEL.test(ping.channelId)) throw new Error('invalid check-in channel')
    if (!LABEL.test(ping.addressee)) throw new Error('invalid CTO addressee')
    if (!TASK.test(ping.currentTask)) throw new Error('invalid current task')
    if (!Number.isSafeInteger(ping.sentAtMs) || ping.sentAtMs < 0) throw new Error('invalid ping time')
    if (this.pending.has(ping.pingId)) throw new Error('check-in ping id is already pending')
    const receipt = await this.sender.send(ping.channelId, renderCheckInPing(ping))
    if (!receipt?.messageId) throw new Error('check-in ping returned no delivery receipt')
    this.pending.set(ping.pingId, {
      ...ping,
      attempt: 1,
      firstSentAtMs: ping.sentAtMs,
      lastSentAtMs: ping.sentAtMs,
    })
    return receipt
  }

  async receive(
    pingId: string,
    candidate: unknown,
    groundTruth: CheckInGroundTruth,
    receivedAtMs = this.now(),
  ): Promise<CheckInResponse> {
    const ping = this.pending.get(pingId)
    if (!ping) throw new Error('check-in ping is not pending')
    if (!Number.isSafeInteger(receivedAtMs) || receivedAtMs < ping.firstSentAtMs) {
      throw new Error('invalid check-in receipt time')
    }
    if (groundTruth.addressee !== ping.addressee || groundTruth.currentTask !== ping.currentTask) {
      throw new Error('check-in ground truth does not match the pending ping scope')
    }
    const validation = validateCtoCheckIn(candidate, { ...groundTruth, pingId })
    const metric: CheckInMetric = {
      schema: 'qofi.cto-checkin-metric/v1',
      ping_id: pingId,
      addressee: ping.addressee,
      current_task: ping.currentTask,
      outcome: validation.ok ? 'accepted' : 'rejected',
      latency_ms: receivedAtMs - ping.firstSentAtMs,
      attempt: ping.attempt,
      errors: validation.errors,
      recorded_at_ms: receivedAtMs,
    }
    // The harness always retains the normalized latency record; an injected
    // sink may additionally persist/aggregate it for roadmap digests.
    this.metricLog.push(metric)
    await this.onMetric?.(metric)
    if (validation.ok) {
      this.pending.delete(pingId)
      return { accepted: true, checkIn: validation.value!, metric }
    }
    ping.attempt += 1
    ping.lastSentAtMs = receivedAtMs
    const rePingReceipt = await this.sender.send(
      ping.channelId,
      renderCheckInPing(ping, ping.attempt, validation.errors),
    )
    if (!rePingReceipt?.messageId) throw new Error('check-in escalation returned no delivery receipt')
    return { accepted: false, errors: validation.errors, rePingReceipt, metric }
  }

  isPending(pingId: string): boolean {
    return this.pending.has(pingId)
  }

  metrics(): readonly CheckInMetric[] {
    return this.metricLog.map(metric => ({ ...metric, errors: [...metric.errors] }))
  }
}
