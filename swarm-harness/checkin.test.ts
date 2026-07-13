import { describe, expect, test } from 'bun:test'
import {
  CTO_CHECKIN_SCHEMA,
  CtoCheckInEnforcer,
  validateCtoCheckIn,
  type CtoCheckIn,
  type CheckInMetric,
  type CheckInPingSender,
} from './checkin'
import checkInSchema from './cto-checkin.schema.json'

const CHANNEL = '1508921858165047390'

class Sender implements CheckInPingSender {
  calls: Array<{ channelId: string; text: string }> = []
  async send(channelId: string, text: string) {
    this.calls.push({ channelId, text })
    return { messageId: `ping-${this.calls.length}` }
  }
}

function valid(overrides: Partial<CtoCheckIn> = {}): CtoCheckIn {
  return {
    schema: CTO_CHECKIN_SCHEMA,
    ping_id: 'idle-17',
    addressee: 'press-cto',
    current_task: 'task-42',
    status: 'DRIVING',
    progress_since_last_checkin: 'Implemented the parser and landed its focused tests.',
    blockers: [],
    next_action: 'Run the integration fixture.',
    needs_input: false,
    ...overrides,
  }
}

const truth = { addressee: 'press-cto', currentTask: 'task-42', status: 'DRIVING' as const }

describe('CTO check-in schema', () => {
  test('published schema identity and emitted state vocabulary match code', () => {
    expect(checkInSchema.$id).toBe(CTO_CHECKIN_SCHEMA)
    expect(checkInSchema.properties.schema.const).toBe(CTO_CHECKIN_SCHEMA)
    expect(checkInSchema.properties.status.enum).toEqual(['DRIVING', 'WAITING_FOR_OPERATOR', 'STOOD_DOWN'])
  })

  test('accepts the exact structured contract against harness ground truth', () => {
    const result = validateCtoCheckIn(valid(), { ...truth, pingId: 'idle-17' })
    expect(result).toEqual({ ok: true, value: valid(), errors: [] })
  })

  test('rejects a blanket acknowledgment', () => {
    const result = validateCtoCheckIn('still working', { ...truth, pingId: 'idle-17' })
    expect(result.ok).toBeFalse()
    expect(result.errors).toContain('bare acknowledgment is not a check-in')
  })

  test('rejects overlay/runtime synonyms outside the shared state vocabulary', () => {
    const result = validateCtoCheckIn({ ...valid(), status: 'RATE_LIMITED' }, {
      ...truth, pingId: 'idle-17',
    })
    expect(result.ok).toBeFalse()
    expect(result.errors).toContain('check-in status is outside the state vocabulary')
  })

  test('rejects self-reported task/status that disagree with harness truth', () => {
    const result = validateCtoCheckIn(valid({ current_task: 'other-task', status: 'STOOD_DOWN' }), {
      ...truth, pingId: 'idle-17',
    })
    expect(result.errors).toContain('check-in task does not match harness truth')
    expect(result.errors).toContain('check-in status does not match harness truth')
  })

  test('rejects extra fields and credential-bearing content', () => {
    const result = validateCtoCheckIn({
      ...valid(),
      progress_since_last_checkin: 'used ghp_abcdefghijklmnopqrstuvwxyz123456',
      self_assessment: 'great',
    }, { ...truth, pingId: 'idle-17' })
    expect(result.ok).toBeFalse()
    expect(result.errors).toContain('unsupported check-in field: self_assessment')
    expect(result.errors).toContain('progress_since_last_checkin contains forbidden credential or identity material')
  })
})

describe('idle ping correlation and escalation', () => {
  test('valid check-in records ping-to-check-in latency and clears pending state', async () => {
    const sender = new Sender()
    const metrics: CheckInMetric[] = []
    const enforcer = new CtoCheckInEnforcer({ sender, onMetric: metric => { metrics.push(metric) } })
    await enforcer.issue({
      pingId: 'idle-17', channelId: CHANNEL, addressee: 'press-cto', currentTask: 'task-42', sentAtMs: 1_000,
    })
    const result = await enforcer.receive('idle-17', JSON.stringify(valid()), truth, 1_650)

    expect(result.accepted).toBeTrue()
    expect(result.metric).toMatchObject({ outcome: 'accepted', latency_ms: 650, attempt: 1 })
    expect(enforcer.isPending('idle-17')).toBeFalse()
    expect(metrics).toHaveLength(1)
  })

  test('bare acknowledgment fails validation and the harness re-pings with escalation', async () => {
    const sender = new Sender()
    const enforcer = new CtoCheckInEnforcer({ sender })
    await enforcer.issue({
      pingId: 'idle-17', channelId: CHANNEL, addressee: 'press-cto', currentTask: 'task-42', sentAtMs: 2_000,
    })
    const result = await enforcer.receive('idle-17', 'ack', truth, 2_125)

    expect(result.accepted).toBeFalse()
    if (result.accepted) throw new Error('expected rejection')
    expect(result.errors).toContain('bare acknowledgment is not a check-in')
    expect(result.rePingReceipt.messageId).toBe('ping-2')
    expect(sender.calls).toHaveLength(2)
    expect(sender.calls[1].text).toContain('attempt 2')
    expect(sender.calls[1].text).toContain('Prior response failed validation')
    expect(enforcer.isPending('idle-17')).toBeTrue()
    expect(enforcer.metrics()[0]).toMatchObject({ outcome: 'rejected', latency_ms: 125 })
  })

  test.each(['claude', 'codex'] as const)('%s worker response is runtime-blind at validation', async runtime => {
    const sender = new Sender()
    const enforcer = new CtoCheckInEnforcer({ sender })
    await enforcer.issue({
      pingId: `idle-${runtime}`, channelId: CHANNEL, addressee: 'press-cto',
      currentTask: `task-${runtime}`, sentAtMs: 10,
    })
    const response = valid({ ping_id: `idle-${runtime}`, current_task: `task-${runtime}` })
    const result = await enforcer.receive(`idle-${runtime}`, response, {
      addressee: 'press-cto', currentTask: `task-${runtime}`, status: 'DRIVING',
    }, 20)
    expect(result.accepted).toBeTrue()
  })
})
