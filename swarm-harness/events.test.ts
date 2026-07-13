import { describe, expect, test } from 'bun:test'
import {
  NORMALIZED_EVENT_SCHEMA,
  STATE_OVERLAYS,
  SWARM_STATES,
  makeHarnessEvent,
  normalizeClaudeTranscriptRecord,
  normalizeCodexRolloutRecord,
  parseNormalizedEvent,
  parseNormalizedEventJsonl,
  projectCompletionEvents,
} from './events.ts'

const scope = {
  swarm: 'press-backend',
  task_id: 'task-123',
  dr_refs: ['ADR-0023'],
  ts: '2026-07-13T10:00:00Z',
}

describe('runtime-blind normalized event contract', () => {
  test('uses the existing declared state vocabulary and keeps limit state as an overlay', () => {
    expect(SWARM_STATES).toEqual(['DRIVING', 'WAITING_FOR_OPERATOR', 'STOOD_DOWN'])
    expect(STATE_OVERLAYS).toEqual(['RATE_LIMITED'])
  })

  test('constructs digest-bound lifecycle events and rejects invalid state transitions', () => {
    const event = makeHarnessEvent({
      ts: scope.ts,
      type: 'task.started',
      runtime: 'claude',
      source: 'harness',
      swarm: scope.swarm,
      task_id: scope.task_id,
      dr_refs: ['ADR-0023', 'ADR-0023'],
      state: 'DRIVING',
    })
    expect(event.schema).toBe(NORMALIZED_EVENT_SCHEMA)
    expect(event.dr_refs).toEqual(['ADR-0023'])
    expect(event.event_id).toMatch(/^[a-f0-9]{64}$/)
    expect(parseNormalizedEvent(event)).toEqual(event)
    expect(() => makeHarnessEvent({
      ...event,
      type: 'task.started',
      state: 'STOOD_DOWN',
    })).toThrow('must enter DRIVING')
  })

  test('completion projection preserves the authoritative runtime for both adapters', () => {
    for (const runtime of ['claude', 'codex'] as const) {
      const projected = projectCompletionEvents({
        runtime,
        swarm: scope.swarm,
        task_id: `${scope.task_id}-${runtime}`,
        dr_refs: scope.dr_refs,
        started_at: scope.ts,
        completed_at_ms: Date.parse('2026-07-13T10:00:03Z'),
        stopped: true,
        delivery_disposition: 'delivered',
        review_verdict: 'approve',
      })
      expect(projected).toHaveLength(4)
      expect(projected.every(event => event.runtime === runtime)).toBeTrue()
      expect(projected.map(event => event.type)).toEqual([
        'task.started', 'result.landed', 'result.landed', 'task.finished',
      ])
    }
  })

  test('Claude and Codex adapters emit the same semantic operation classes', () => {
    const claude = normalizeClaudeTranscriptRecord({
      type: 'assistant',
      timestamp: '2026-07-13T10:00:01Z',
      message: { content: [
        { type: 'tool_use', name: 'Grep', input: { pattern: 'secret prose never retained' } },
        { type: 'tool_use', name: 'Bash', input: { command: 'rg provider-token .' } },
        { type: 'tool_use', name: 'Edit', input: { new_string: 'provider token never retained' } },
      ] },
    }, scope)
    const codexGrep = normalizeCodexRolloutRecord({
      timestamp: '2026-07-13T10:00:01Z',
      type: 'response_item',
      payload: {
        type: 'function_call',
        name: 'exec_command',
        arguments: JSON.stringify({ cmd: 'rg secret .', justification: 'never retained' }),
      },
    }, scope)
    const codexEdit = normalizeCodexRolloutRecord({
      timestamp: '2026-07-13T10:00:01Z',
      type: 'response_item',
      payload: { type: 'function_call', name: 'apply_patch', arguments: 'private diff bytes' },
    }, scope)

    expect(claude.map(event => [event.type, event.operation])).toEqual([
      ['grounding.operation', 'grep'],
      ['grounding.operation', 'grep'],
      ['edit.substantive', undefined],
    ])
    expect(codexGrep.map(event => [event.type, event.operation])).toEqual([
      ['grounding.operation', 'grep'],
    ])
    expect(codexEdit.map(event => [event.type, event.operation])).toEqual([
      ['edit.substantive', undefined],
    ])
    const serialized = JSON.stringify([...claude, ...codexGrep, ...codexEdit])
    for (const forbidden of ['secret prose', 'provider token', 'provider-token', 'rg secret', 'private diff']) {
      expect(serialized).not.toContain(forbidden)
    }
  })

  test('agent prose cannot declare lifecycle state through either runtime adapter', () => {
    expect(normalizeClaudeTranscriptRecord({
      type: 'assistant', message: { content: [{ type: 'text', text: 'STATE: press-backend STOOD_DOWN' }] },
    }, scope)).toEqual([])
    expect(normalizeCodexRolloutRecord({
      type: 'event_msg', payload: { type: 'agent_message', message: 'done, trust me' },
    }, scope)).toEqual([])
    expect(() => normalizeClaudeTranscriptRecord({
      type: 'assistant',
      message: { content: Array.from({ length: 513 }, () => ({ type: 'tool_use', name: 'Read', input: {} })) },
    }, scope)).toThrow('tool-block bound')
  })

  test('unknown/content and account-bearing fields fail closed at ingestion', () => {
    const event = makeHarnessEvent({
      ts: scope.ts, type: 'runtime.activity', runtime: 'claude', source: 'claude-transcript',
      swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs,
    })
    expect(() => parseNormalizedEvent({ ...event, account: 'personal-provider-account' })).toThrow('unsupported field')
    expect(() => parseNormalizedEvent({ ...event, prompt: 'raw task content' })).toThrow('unsupported field')
    expect(() => makeHarnessEvent({ ...event, swarm: 'sk-proj-abcdefghijklmnopqrstuvwxyz' })).toThrow('swarm label')
    expect(() => makeHarnessEvent({ ...event, swarm: 'profile-production' })).toThrow('swarm label')
    expect(() => makeHarnessEvent({ ...event, task_id: 'xoxb-123456789012345678901234' })).toThrow('task label')
  })

  test('bounded JSONL round-trips and rejects oversized or digest-modified input', () => {
    const event = makeHarnessEvent({
      ts: scope.ts, type: 'grounding.operation', runtime: 'codex', source: 'codex-rollout',
      swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs, operation: 'read', source_seq: 3,
    })
    expect(parseNormalizedEventJsonl(`${JSON.stringify(event)}\n`)).toEqual([event])
    expect(() => parseNormalizedEventJsonl(`${JSON.stringify({ ...event, operation: 'grep' })}\n`))
      .toThrow('digest mismatch')
    expect(() => parseNormalizedEventJsonl('x'.repeat(100), { maxBytes: 50 })).toThrow('exceeds bound')
    expect(() => parseNormalizedEventJsonl(`${JSON.stringify(event)}\n${JSON.stringify(event)}\n`, { maxEvents: 1 }))
      .toThrow('event bound')
  })
})
