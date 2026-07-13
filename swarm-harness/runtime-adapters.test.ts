import { describe, expect, test } from 'bun:test'
import { ClaudeStopAdapter, CodexStopAdapter } from './runtime-adapters'

const OP = '1508921858165047390'
const BUS = '1510301812434141194'

function transcript(summary: string, chatId = OP): string {
  return [
    JSON.stringify({
      type: 'user', uuid: 'user-1', isMeta: false,
      message: { content: `<channel source="discord" chat_id="${chatId}">task</channel>` },
    }),
    JSON.stringify({
      type: 'assistant', uuid: 'assistant-1', isSidechain: false,
      message: { content: [{ type: 'text', text: summary }] },
    }),
  ].join('\n')
}

describe('runtime lifecycle adapters translate only', () => {
  test('Claude selects the turn channel from a multi-bound transcript and agent text is data', () => {
    const raw = transcript('agent summary', BUS)
    const adapter = new ClaudeStopAdapter({
      env: {
        SWARM_NAME: 'qofi-product',
        DISCORD_BOUND_CHANNEL: `${OP},${BUS}`,
        DISCORD_OPERATOR_CHANNEL: OP,
      },
      readTranscript: () => raw,
      now: () => 123,
    })
    const result = adapter.normalizeStop({ session_id: 's-1', task_id: 't-1', transcript_path: '/tmp/t' })
    expect(result).toMatchObject({
      runtime: 'claude', channelId: BUS, fallbackChannelId: OP, summary: 'agent summary', occurredAtMs: 123,
    })
  })

  test('Claude event identity remains stable when Stop re-enters', () => {
    const raw = transcript('same summary')
    const adapter = new ClaudeStopAdapter({
      env: { SWARM_NAME: 'press-backend', DISCORD_BOUND_CHANNEL: OP },
      readTranscript: () => raw,
      now: () => 100,
    })
    const first = adapter.normalizeStop({ session_id: 's-1', transcript_path: '/tmp/t' })
    const retry = adapter.normalizeStop({ session_id: 's-1', transcript_path: '/tmp/t', stop_hook_active: true })
    expect(retry.eventId).toBe(first.eventId)
  })

  test('Claude lead and sibling SubagentStop boundaries have distinct stable identities', () => {
    const transcripts: Record<string, string> = {
      '/lead': transcript('lead summary'),
      '/agent-a': transcript('agent A summary'),
      '/agent-b': transcript('agent B summary'),
    }
    const adapter = new ClaudeStopAdapter({
      env: { SWARM_NAME: 'press-backend', DISCORD_BOUND_CHANNEL: OP },
      readTranscript: path => transcripts[path] ?? '',
      now: () => 100,
    })
    const lead = adapter.normalizeStop({
      hook_event_name: 'Stop', session_id: 's-1', task_id: 'task-1',
      stop_event_id: 'same-native-id', transcript_path: '/lead',
    })
    const agentA = adapter.normalizeStop({
      hook_event_name: 'SubagentStop', session_id: 's-1', task_id: 'task-1',
      stop_event_id: 'same-native-id', agent_id: 'agent-a',
      transcript_path: '/lead', agent_transcript_path: '/agent-a',
    })
    const agentB = adapter.normalizeStop({
      hook_event_name: 'SubagentStop', session_id: 's-1', task_id: 'task-1',
      stop_event_id: 'same-native-id', agent_id: 'agent-b',
      transcript_path: '/lead', agent_transcript_path: '/agent-b',
    })
    expect(new Set([lead.eventId, agentA.eventId, agentB.eventId]).size).toBe(3)
    expect(new Set([lead.taskId, agentA.taskId, agentB.taskId]).size).toBe(3)
    expect(agentA.summary).toBe('agent A summary')
    expect(agentB.summary).toBe('agent B summary')
    expect(adapter.normalizeStop({
      hook_event_name: 'SubagentStop', session_id: 's-1', task_id: 'task-1',
      stop_event_id: 'same-native-id', agent_id: 'agent-a',
      agent_transcript_path: '/agent-a',
    }).eventId).toBe(agentA.eventId)
  })

  test('Claude SubagentStop recovers a multi-bound turn channel from the parent transcript', () => {
    const child = [
      JSON.stringify({
        type: 'user', uuid: 'agent-user',
        message: { content: 'delegated task without a Discord envelope' },
      }),
      JSON.stringify({
        type: 'assistant', uuid: 'agent-assistant', isSidechain: false,
        message: { content: [{ type: 'text', text: 'subagent summary' }] },
      }),
    ].join('\n')
    const adapter = new ClaudeStopAdapter({
      env: { SWARM_NAME: 'qofi-product', DISCORD_BOUND_CHANNEL: `${OP},${BUS}` },
      readTranscript: path => path === '/parent' ? transcript('lead summary', BUS) : child,
    })
    const result = adapter.normalizeStop({
      hook_event_name: 'SubagentStop', session_id: 's-1', task_id: 'task-1',
      transcript_path: '/parent', agent_transcript_path: '/child', agent_id: 'agent-a',
    })
    expect(result.channelId).toBe(BUS)
    expect(result.summary).toBe('subagent summary')
  })

  test('Claude treats a supplied native stop id as digest input, not replay authority', () => {
    const adapter = new ClaudeStopAdapter({
      env: { SWARM_NAME: 'press-backend', DISCORD_BOUND_CHANNEL: OP },
      now: () => 100,
    })
    const first = adapter.normalizeStop({
      session_id: 's-1', task_id: 'task-1', stop_event_id: 'a'.repeat(64),
    })
    const second = adapter.normalizeStop({
      session_id: 's-1', task_id: 'task-2', stop_event_id: 'a'.repeat(64),
    })
    expect(first.eventId).not.toBe('a'.repeat(64))
    expect(first.eventId).not.toBe(second.eventId)
  })

  test('multi-bound Claude event without a proven transcript channel fails closed to queue', () => {
    const result = new ClaudeStopAdapter({
      env: { SWARM_NAME: 'qofi-product', DISCORD_BOUND_CHANNEL: `${OP},${BUS}` },
    }).normalizeStop({ session_id: 's-1' })
    expect(result.channelId).toBeNull()
  })

  test('Codex adapter returns the same normalized schema without carrying policy', () => {
    const result = new CodexStopAdapter(() => 500).normalizeStop({
      swarm: 'press-backend', taskId: 'task-9', turnId: 'turn-9', channelId: OP,
      fallbackChannelId: BUS, summary: 'Codex result summary',
    })
    expect(result).toMatchObject({
      schema: 'qofi.swarm.stop/v1', runtime: 'codex', swarm: 'press-backend', taskId: 'task-9',
      channelId: OP, fallbackChannelId: BUS, summary: 'Codex result summary', occurredAtMs: 500,
    })
    expect(result.eventId).toMatch(/^[a-f0-9]{64}$/)
  })
})
