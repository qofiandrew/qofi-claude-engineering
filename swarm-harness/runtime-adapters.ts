import { createHash } from 'node:crypto'
import { basename } from 'node:path'
import {
  STOP_EVENT_SCHEMA,
  StopDeliveryPipeline,
  redactStopText,
  safeStopLabel,
  type NormalizedStopEvent,
  type StopOutcome,
  type WorkerRuntime,
} from './stop-delivery'

export interface RuntimeStopAdapter<Input> {
  readonly runtime: WorkerRuntime
  normalizeStop(input: Input): NormalizedStopEvent
}

/** One runtime-blind wrapper seam: native adapters translate, this enforces. */
export async function enforceRuntimeStop<Input>(
  adapter: RuntimeStopAdapter<Input>,
  pipeline: StopDeliveryPipeline,
  input: Input,
): Promise<StopOutcome> {
  return pipeline.execute(adapter.normalizeStop(input))
}

export interface ClaudeStopEnvironment {
  SWARM_NAME?: string
  CLAUDE_PROJECT_DIR?: string
  DISCORD_BOUND_CHANNEL?: string
  DISCORD_OPERATOR_CHANNEL?: string
  DISCORD_BUS_CHANNEL?: string
  SWARM_STOP_FALLBACK_CHANNEL?: string
}

export interface ClaudeStopHookInput {
  session_id?: unknown
  task_id?: unknown
  stop_event_id?: unknown
  hook_event_name?: unknown
  agent_id?: unknown
  agent_transcript_path?: unknown
  transcript_path?: unknown
  last_assistant_message?: unknown
  stop_hook_active?: unknown
  occurred_at_ms?: unknown
}

export interface ClaudeStopAdapterOptions {
  env: ClaudeStopEnvironment
  readTranscript?: (path: string) => string
  now?: () => number
}

interface TranscriptBoundary {
  summary: string
  chatId: string | null
  identity: string
}

function digest(parts: readonly string[]): string {
  const hash = createHash('sha256')
  for (const part of parts) hash.update(part).update('\0')
  return hash.digest('hex')
}

function parseChannels(value: unknown): string[] {
  const channels = String(value ?? '')
    .split(',')
    .map(channel => channel.trim())
    .filter(channel => /^\d{16,22}$/.test(channel))
  return [...new Set(channels)]
}

function channelFromString(value: string): string | null {
  const matches = [...value.matchAll(/\bchat_id="(\d{16,22})"/g)]
  return matches.at(-1)?.[1] ?? null
}

function contentBlocks(record: any): any[] {
  const content = record?.message?.content
  return Array.isArray(content) ? content : []
}

function transcriptBoundary(raw: string): TranscriptBoundary {
  const records: { parsed: any; raw: string }[] = []
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue
    try { records.push({ parsed: JSON.parse(line), raw: line }) } catch {}
  }
  let userIndex = -1
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const record = records[index].parsed
    const content = record?.message?.content
    // Discord channel prompts are meta user records in Claude transcripts. They
    // still define the lifecycle turn/channel; tool-result user records carry
    // block arrays and therefore do not match this string-content boundary.
    if (record?.type === 'user' && typeof content === 'string') {
      userIndex = index
      break
    }
  }
  const turn = records.slice(Math.max(0, userIndex))
  const user = userIndex >= 0 ? records[userIndex] : null
  let assistant: { parsed: any; raw: string } | null = null
  let summary = ''
  for (const record of turn) {
    if (record.parsed?.type !== 'assistant' || record.parsed?.isSidechain === true) continue
    const text = contentBlocks(record.parsed)
      .filter(block => block && block.type === 'text' && typeof block.text === 'string')
      .map(block => block.text)
      .join('')
      .trim()
    if (text) {
      assistant = record
      summary = text
    }
  }
  const userContent = typeof user?.parsed?.message?.content === 'string'
    ? user.parsed.message.content
    : ''
  const chatId = channelFromString(userContent)
  const userIdentity = String(user?.parsed?.uuid ?? user?.parsed?.id ?? user?.raw ?? '')
  const assistantIdentity = String(
    assistant?.parsed?.uuid ?? assistant?.parsed?.id ?? assistant?.raw ?? '',
  )
  return {
    summary,
    chatId,
    identity: digest([userIdentity, assistantIdentity]),
  }
}

function choosePrimaryChannel(bound: readonly string[], transcriptChannel: string | null): string | null {
  if (transcriptChannel && bound.includes(transcriptChannel)) return transcriptChannel
  return bound.length === 1 ? bound[0] : null
}

function chooseLifecycleChannel(
  env: ClaudeStopEnvironment,
  bound: readonly string[],
  transcriptChannel: string | null,
): string | null {
  const bus = String(env.DISCORD_BUS_CHANNEL ?? '').trim()
  // Only the CPO receives this role-specific variable. Keep routine lifecycle
  // receipts off its operator conversation while retaining the operator as the
  // explicit failure fallback below. Ignore a bus value outside the injected
  // bound-channel authority.
  if (/^\d{16,22}$/.test(bus) && bound.includes(bus)) return bus
  return choosePrimaryChannel(bound, transcriptChannel)
}

function explicitFallback(env: ClaudeStopEnvironment, primary: string | null): string | null {
  const candidate = String(
    env.SWARM_STOP_FALLBACK_CHANNEL ?? env.DISCORD_OPERATOR_CHANNEL ?? '',
  ).trim()
  return /^\d{16,22}$/.test(candidate) && candidate !== primary ? candidate : null
}

function occurrence(value: unknown, fallback: number): number {
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : fallback
}

/** Thin Claude transcript translator: no retry, delivery, or stop policy lives here. */
export class ClaudeStopAdapter implements RuntimeStopAdapter<ClaudeStopHookInput> {
  readonly runtime = 'claude' as const
  private readonly env: ClaudeStopEnvironment
  private readonly readTranscript: (path: string) => string
  private readonly now: () => number

  constructor(options: ClaudeStopAdapterOptions) {
    this.env = options.env
    this.readTranscript = options.readTranscript ?? (() => '')
    this.now = options.now ?? Date.now
  }

  normalizeStop(input: ClaudeStopHookInput): NormalizedStopEvent {
    const hookEvent = input.hook_event_name === 'SubagentStop' ? 'SubagentStop' : 'Stop'
    const parentPath = typeof input.transcript_path === 'string' ? input.transcript_path : ''
    const path = hookEvent === 'SubagentStop' && typeof input.agent_transcript_path === 'string'
      ? input.agent_transcript_path
      : parentPath
    let boundary: TranscriptBoundary = { summary: '', chatId: null, identity: digest(['no-transcript']) }
    if (path) {
      try { boundary = transcriptBoundary(this.readTranscript(path)) } catch {}
    }
    // Native SubagentStop transcripts usually contain only the sidechain and
    // therefore omit the Discord turn envelope. Recover only the channel from
    // the parent transcript; the subagent transcript remains authoritative for
    // summary and identity. choosePrimaryChannel still rejects any channel not
    // present in the injected binding.
    let transcriptChannel = boundary.chatId
    if (hookEvent === 'SubagentStop' && !transcriptChannel && parentPath && parentPath !== path) {
      try { transcriptChannel = transcriptBoundary(this.readTranscript(parentPath)).chatId } catch {}
    }
    const bound = parseChannels(this.env.DISCORD_BOUND_CHANNEL)
    const channelId = chooseLifecycleChannel(this.env, bound, transcriptChannel)
    const project = String(this.env.CLAUDE_PROJECT_DIR ?? '')
    const swarm = safeStopLabel(this.env.SWARM_NAME, safeStopLabel(basename(project), 'swarm'))
    const session = safeStopLabel(input.session_id, 'session')
    const parentTaskId = safeStopLabel(input.task_id, session)
    const agentIdentity = hookEvent === 'SubagentStop'
      ? digest([String(input.agent_id ?? ''), boundary.identity]).slice(0, 20)
      : 'lead'
    const taskId = hookEvent === 'SubagentStop'
      ? safeStopLabel(`${parentTaskId}.subagent.${agentIdentity}`, `subagent.${agentIdentity}`)
      : parentTaskId
    const suppliedSummary = typeof input.last_assistant_message === 'string'
      ? input.last_assistant_message
      : boundary.summary
    // Runtime-supplied ids are entropy, never durable-record authority. Bind
    // every id to normalized task/subagent/transcript scope so a reused native
    // id cannot inherit another task's delivered/queued outcome.
    const suppliedId = String(input.stop_event_id ?? '').trim()
    const eventId = digest([
      'claude', swarm, session, taskId, hookEvent, agentIdentity,
      boundary.identity, suppliedId,
    ])
    return {
      schema: STOP_EVENT_SCHEMA,
      eventId,
      runtime: this.runtime,
      swarm,
      taskId,
      channelId,
      fallbackChannelId: explicitFallback(this.env, channelId),
      summary: redactStopText(suppliedSummary),
      occurredAtMs: occurrence(input.occurred_at_ms, this.now()),
    }
  }
}

export interface CodexStopInput {
  swarm: unknown
  taskId: unknown
  channelId: unknown
  fallbackChannelId?: unknown
  summary: unknown
  turnId: unknown
  occurredAtMs?: unknown
}

/** Thin Codex result translator; intended for the same wrapper boundary as `codex exec`. */
export class CodexStopAdapter implements RuntimeStopAdapter<CodexStopInput> {
  readonly runtime = 'codex' as const
  constructor(private readonly now: () => number = Date.now) {}

  normalizeStop(input: CodexStopInput): NormalizedStopEvent {
    const swarm = safeStopLabel(input.swarm, 'swarm')
    const taskId = safeStopLabel(input.taskId, 'task')
    const turnId = safeStopLabel(input.turnId, taskId)
    const channel = String(input.channelId ?? '').trim()
    const fallback = String(input.fallbackChannelId ?? '').trim()
    return {
      schema: STOP_EVENT_SCHEMA,
      eventId: digest(['codex', swarm, taskId, turnId]),
      runtime: this.runtime,
      swarm,
      taskId,
      channelId: /^\d{16,22}$/.test(channel) ? channel : null,
      fallbackChannelId: /^\d{16,22}$/.test(fallback) && fallback !== channel ? fallback : null,
      summary: redactStopText(input.summary),
      occurredAtMs: occurrence(input.occurredAtMs, this.now()),
    }
  }
}

export function normalizeStopForRuntime(
  runtime: 'claude',
  input: ClaudeStopHookInput,
  options: ClaudeStopAdapterOptions,
): NormalizedStopEvent
export function normalizeStopForRuntime(
  runtime: 'codex',
  input: CodexStopInput,
  options?: { now?: () => number },
): NormalizedStopEvent
export function normalizeStopForRuntime(
  runtime: WorkerRuntime,
  input: ClaudeStopHookInput | CodexStopInput,
  options: ClaudeStopAdapterOptions | { now?: () => number } = {},
): NormalizedStopEvent {
  return runtime === 'claude'
    ? new ClaudeStopAdapter(options as ClaudeStopAdapterOptions).normalizeStop(input as ClaudeStopHookInput)
    : new CodexStopAdapter(options.now).normalizeStop(input as CodexStopInput)
}
