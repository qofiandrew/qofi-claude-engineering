import { createHash } from 'crypto'

/** Runtime-blind event contract consumed by every harness policy/visibility surface. */
export const NORMALIZED_EVENT_SCHEMA = 'qofi-swarm-event/v1' as const

/** Existing CPO bus state vocabulary. Do not add runtime-specific synonyms here. */
export const SWARM_STATES = [
  'DRIVING',
  'WAITING_FOR_OPERATOR',
  'STOOD_DOWN',
] as const
export type SwarmState = typeof SWARM_STATES[number]

/** Observed overlays never become valid declared/check-in states. */
export const STATE_OVERLAYS = ['RATE_LIMITED'] as const
export type StateOverlay = typeof STATE_OVERLAYS[number]

export const NORMALIZED_EVENT_TYPES = [
  'task.started',
  'task.finished',
  'state.transitioned',
  'result.landed',
  'runtime.activity',
  'grounding.started',
  'grounding.operation',
  'grounding.gap_reported',
  'edit.substantive',
] as const
export type NormalizedEventType = typeof NORMALIZED_EVENT_TYPES[number]
export type WorkerRuntime = 'claude' | 'codex'
export type EventSource = 'claude-transcript' | 'codex-rollout' | 'result-set' | 'harness'
export type TaskOutcome = 'completed' | 'blocked' | 'failed' | 'cancelled'
export type ResultKind = 'review' | 'tests' | 'build' | 'delivery' | 'ratification' | 'other'
export type ResultStatus = 'passed' | 'failed' | 'pending' | 'blocked'
export type GroundingOperation = 'read' | 'grep'

export type NormalizedSwarmEvent = {
  schema: typeof NORMALIZED_EVENT_SCHEMA
  event_id: string
  ts: string
  type: NormalizedEventType
  runtime: WorkerRuntime
  source: EventSource
  swarm: string
  task_id: string
  dr_refs: string[]
  source_seq?: number
  state?: SwarmState
  previous_state?: SwarmState
  outcome?: TaskOutcome
  result_kind?: ResultKind
  result_status?: ResultStatus
  operation?: GroundingOperation
}

export type HarnessEventInput = Omit<NormalizedSwarmEvent, 'schema' | 'event_id'>

export type CompletionEventProjectionInput = Readonly<{
  runtime: WorkerRuntime
  swarm: string
  task_id: string
  dr_refs: readonly string[]
  started_at: string
  completed_at_ms: number
  stopped: boolean
  delivery_disposition: 'delivered' | 'queued' | 'blocked'
  review_verdict: 'approve' | 'needs-changes' | 'block' | 'review-unavailable'
}>

export type AdapterScope = {
  swarm: string
  task_id: string
  dr_refs?: string[]
  /** Fallback for runtime records that omit a timestamp. */
  ts: string
}

const SWARM_LABEL = /^[a-z][a-z0-9-]{0,63}$/
const TASK_LABEL = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
const DR_REF = /^ADR-[0-9]{4}$/
const SHA256 = /^[a-f0-9]{64}$/
const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/
const SECRET_LIKE = [
  /gh[pousr]_[A-Za-z0-9]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
  /xox[baprs]-[A-Za-z0-9-]{20,}/,
  /sk-(?:proj-|ant-|live-|test-)?[A-Za-z0-9_-]{20,}/i,
  /eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
] as const
const ACCOUNT_LIKE_LABEL = /^(?:acct|account|profile|provider|user|org|organization)-/i

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function secretLike(value: string): boolean {
  return SECRET_LIKE.some(pattern => pattern.test(value))
}

function assertExactKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>, label: string): void {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(`${label} contains unsupported field ${key}`)
  }
}

function requireTimestamp(value: unknown): string {
  if (typeof value !== 'string' || !ISO_TIMESTAMP.test(value) || Number.isNaN(Date.parse(value))) {
    throw new Error('normalized event timestamp is invalid')
  }
  return new Date(value).toISOString()
}

function requireSwarm(value: unknown): string {
  if (typeof value !== 'string' || !SWARM_LABEL.test(value) || secretLike(value) || ACCOUNT_LIKE_LABEL.test(value)) {
    throw new Error('normalized event swarm label is invalid')
  }
  return value
}

function requireTask(value: unknown): string {
  if (typeof value !== 'string' || !TASK_LABEL.test(value) || secretLike(value) || ACCOUNT_LIKE_LABEL.test(value)) {
    throw new Error('normalized event task label is invalid')
  }
  return value
}

function requireDrRefs(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > 32) throw new Error('normalized event DR refs are invalid')
  const refs = value.map(ref => {
    if (typeof ref !== 'string' || !DR_REF.test(ref)) throw new Error('normalized event DR ref is invalid')
    return ref
  })
  return [...new Set(refs)].sort()
}

function optionalEnum<T extends string>(
  value: unknown,
  values: readonly T[],
  label: string,
): T | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'string' || !values.includes(value as T)) throw new Error(`${label} is invalid`)
  return value as T
}

function validateShape(event: Omit<NormalizedSwarmEvent, 'event_id' | 'schema'>): void {
  const has = (key: keyof typeof event) => event[key] !== undefined
  const forbid = (...keys: Array<keyof typeof event>) => {
    if (keys.some(has)) throw new Error(`${event.type} contains incompatible fields`)
  }
  if (['task.started', 'task.finished', 'state.transitioned', 'grounding.started', 'grounding.gap_reported']
    .includes(event.type) && event.source !== 'harness') {
    throw new Error(`${event.type} must be harness-authored`)
  }
  if (event.type === 'result.landed' && event.source !== 'result-set') {
    throw new Error('result.landed must come from validated result-set intake')
  }
  if (['runtime.activity', 'grounding.operation', 'edit.substantive'].includes(event.type)
    && !['claude-transcript', 'codex-rollout'].includes(event.source)) {
    throw new Error(`${event.type} must come from a runtime adapter`)
  }
  switch (event.type) {
    case 'task.started':
      forbid('previous_state', 'outcome', 'result_kind', 'result_status', 'operation')
      if (event.state !== 'DRIVING') throw new Error('task.started must enter DRIVING')
      break
    case 'task.finished':
      forbid('previous_state', 'result_kind', 'result_status', 'operation')
      if (!event.outcome || !event.state) throw new Error('task.finished requires outcome and state')
      if (event.outcome === 'completed' && event.state !== 'STOOD_DOWN') {
        throw new Error('completed task must enter STOOD_DOWN')
      }
      if (['blocked', 'failed'].includes(event.outcome) && event.state !== 'WAITING_FOR_OPERATOR') {
        throw new Error('blocked or failed task must wait for operator')
      }
      if (event.outcome === 'cancelled' && event.state !== 'STOOD_DOWN') {
        throw new Error('cancelled task must enter STOOD_DOWN')
      }
      break
    case 'state.transitioned':
      forbid('outcome', 'result_kind', 'result_status', 'operation')
      if (!event.state) throw new Error('state.transitioned requires state')
      break
    case 'result.landed':
      forbid('state', 'previous_state', 'outcome', 'operation')
      if (!event.result_kind || !event.result_status) throw new Error('result.landed requires result metadata')
      break
    case 'grounding.operation':
      forbid('state', 'previous_state', 'outcome', 'result_kind', 'result_status')
      if (!event.operation) throw new Error('grounding.operation requires operation')
      break
    case 'runtime.activity':
    case 'grounding.started':
    case 'grounding.gap_reported':
    case 'edit.substantive':
      forbid('state', 'previous_state', 'outcome', 'result_kind', 'result_status', 'operation')
      break
    default:
      break
  }
}

function canonicalForId(event: Omit<NormalizedSwarmEvent, 'event_id'>): string {
  const stable: Record<string, unknown> = {}
  for (const key of Object.keys(event).sort()) {
    const value = event[key as keyof typeof event]
    if (value !== undefined) stable[key] = value
  }
  return JSON.stringify(stable)
}

/** Construct one normalized event. Unknown/content-bearing fields never cross this boundary. */
export function makeHarnessEvent(input: HarnessEventInput): NormalizedSwarmEvent {
  const runtime = optionalEnum(input.runtime, ['claude', 'codex'] as const, 'runtime')!
  const source = optionalEnum(
    input.source,
    ['claude-transcript', 'codex-rollout', 'result-set', 'harness'] as const,
    'source',
  )!
  const type = optionalEnum(input.type, NORMALIZED_EVENT_TYPES, 'event type')!
  if (!runtime || !source || !type) throw new Error('normalized event discriminator is missing')
  if (runtime === 'claude' && source === 'codex-rollout') throw new Error('runtime/source mismatch')
  if (runtime === 'codex' && source === 'claude-transcript') throw new Error('runtime/source mismatch')
  if (source === 'result-set' && type !== 'result.landed') throw new Error('result-set source requires result.landed')

  const event: Omit<NormalizedSwarmEvent, 'event_id'> = {
    schema: NORMALIZED_EVENT_SCHEMA,
    ts: requireTimestamp(input.ts),
    type,
    runtime,
    source,
    swarm: requireSwarm(input.swarm),
    task_id: requireTask(input.task_id),
    dr_refs: requireDrRefs(input.dr_refs),
    source_seq: input.source_seq === undefined
      ? undefined
      : Number.isSafeInteger(input.source_seq) && input.source_seq >= 0 && input.source_seq <= 1_000_000
        ? input.source_seq
        : (() => { throw new Error('normalized event source sequence is invalid') })(),
    state: optionalEnum(input.state, SWARM_STATES, 'state'),
    previous_state: optionalEnum(input.previous_state, SWARM_STATES, 'previous state'),
    outcome: optionalEnum(input.outcome, ['completed', 'blocked', 'failed', 'cancelled'] as const, 'outcome'),
    result_kind: optionalEnum(
      input.result_kind,
      ['review', 'tests', 'build', 'delivery', 'ratification', 'other'] as const,
      'result kind',
    ),
    result_status: optionalEnum(
      input.result_status,
      ['passed', 'failed', 'pending', 'blocked'] as const,
      'result status',
    ),
    operation: optionalEnum(input.operation, ['read', 'grep'] as const, 'grounding operation'),
  }
  validateShape(event)
  for (const key of Object.keys(event) as Array<keyof typeof event>) {
    if (event[key] === undefined) delete event[key]
  }
  const event_id = createHash('sha256')
    .update(canonicalForId(event))
    .digest('hex')
  return { ...event, event_id } as NormalizedSwarmEvent
}

/**
 * Project root-observed completion facts into the runtime-blind event stream.
 * Runtime is an explicit input so a Codex receipt can never silently acquire
 * a Claude label (or the inverse) at the authority boundary.
 */
export function projectCompletionEvents(
  input: CompletionEventProjectionInput,
): NormalizedSwarmEvent[] {
  if (!Number.isSafeInteger(input.completed_at_ms) || input.completed_at_ms < 2) {
    throw new Error('completion event timestamp is invalid')
  }
  const completed = input.completed_at_ms
  const common = {
    runtime: input.runtime,
    swarm: input.swarm,
    task_id: input.task_id,
    dr_refs: [...input.dr_refs],
  }
  const reviewStatus: ResultStatus = input.review_verdict === 'approve'
    ? 'passed'
    : input.review_verdict === 'needs-changes'
      ? 'failed'
      : input.review_verdict === 'block' ? 'blocked' : 'pending'
  const deliveryStatus: ResultStatus = input.delivery_disposition === 'delivered'
    ? 'passed'
    : input.delivery_disposition === 'queued' ? 'pending' : 'failed'
  return [
    makeHarnessEvent({
      ...common, ts: input.started_at, type: 'task.started', source: 'harness', state: 'DRIVING',
    }),
    makeHarnessEvent({
      ...common, ts: new Date(completed - 2).toISOString(), type: 'result.landed',
      source: 'result-set', result_kind: 'review', result_status: reviewStatus,
    }),
    makeHarnessEvent({
      ...common, ts: new Date(completed - 1).toISOString(), type: 'result.landed',
      source: 'result-set', result_kind: 'delivery', result_status: deliveryStatus,
    }),
    makeHarnessEvent(input.stopped ? {
      ...common, ts: new Date(completed).toISOString(), type: 'task.finished', source: 'harness',
      outcome: 'completed', state: 'STOOD_DOWN',
    } : {
      ...common, ts: new Date(completed).toISOString(), type: 'state.transitioned', source: 'harness',
      previous_state: 'DRIVING', state: 'WAITING_FOR_OPERATOR',
    }),
  ]
}

const EVENT_KEYS = new Set([
  'schema', 'event_id', 'ts', 'type', 'runtime', 'source', 'swarm', 'task_id', 'dr_refs',
  'source_seq', 'state', 'previous_state', 'outcome', 'result_kind', 'result_status', 'operation',
])

/** Strict parser for JSONL/file ingestion. Extra fields are rejected, not copied. */
export function parseNormalizedEvent(value: unknown): NormalizedSwarmEvent {
  if (!isRecord(value)) throw new Error('normalized event must be an object')
  assertExactKeys(value, EVENT_KEYS, 'normalized event')
  if (value.schema !== NORMALIZED_EVENT_SCHEMA || typeof value.event_id !== 'string' || !SHA256.test(value.event_id)) {
    throw new Error('normalized event identity is invalid')
  }
  const rebuilt = makeHarnessEvent({
    ts: value.ts as string,
    type: value.type as NormalizedEventType,
    runtime: value.runtime as WorkerRuntime,
    source: value.source as EventSource,
    swarm: value.swarm as string,
    task_id: value.task_id as string,
    dr_refs: value.dr_refs as string[],
    source_seq: value.source_seq as number | undefined,
    state: value.state as SwarmState | undefined,
    previous_state: value.previous_state as SwarmState | undefined,
    outcome: value.outcome as TaskOutcome | undefined,
    result_kind: value.result_kind as ResultKind | undefined,
    result_status: value.result_status as ResultStatus | undefined,
    operation: value.operation as GroundingOperation | undefined,
  })
  if (rebuilt.event_id !== value.event_id) throw new Error('normalized event digest mismatch')
  return rebuilt
}

function runtimeTimestamp(record: Record<string, unknown>, fallback: string): string {
  const candidate = record.timestamp ?? record.ts
  return typeof candidate === 'string' && ISO_TIMESTAMP.test(candidate) ? candidate : fallback
}

function claudeToolUses(record: Record<string, unknown>): Array<{ name: string, input: unknown, ordinal: number }> {
  const message = isRecord(record.message) ? record.message : record
  const content = Array.isArray(message.content) ? message.content : []
  if (content.length > 512) throw new Error('Claude transcript record exceeds tool-block bound')
  const tools: Array<{ name: string, input: unknown, ordinal: number }> = []
  content.forEach((entry, ordinal) => {
    if (isRecord(entry) && entry.type === 'tool_use' && typeof entry.name === 'string') {
      tools.push({ name: entry.name, input: entry.input, ordinal })
    }
  })
  return tools
}

function classifyReadCommand(command: string): GroundingOperation | null {
  const trimmed = command.trim()
  if (/^(?:rg|grep)(?:\s|$)/.test(trimmed)) return 'grep'
  if (/^(?:sed\s+-n|head|tail|ls|find|pwd|cat)(?:\s|$)/.test(trimmed)) return 'read'
  return null
}

function operationForClaudeTool(tool: { name: string, input: unknown }): GroundingOperation | 'edit' | null {
  if (['Read', 'LS', 'Glob', 'NotebookRead'].includes(tool.name)) return 'read'
  if (tool.name === 'Grep') return 'grep'
  if (['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].includes(tool.name)) return 'edit'
  if (tool.name === 'Bash' && isRecord(tool.input) && typeof tool.input.command === 'string') {
    return classifyReadCommand(tool.input.command)
  }
  return null
}

/**
 * Normalize structural Claude transcript records. Message/tool arguments and model
 * prose are inspected only for tool envelopes and are never copied downstream.
 */
export function normalizeClaudeTranscriptRecord(
  raw: unknown,
  scope: AdapterScope,
): NormalizedSwarmEvent[] {
  if (!isRecord(raw) || raw.type !== 'assistant') return []
  const ts = runtimeTimestamp(raw, scope.ts)
  const events: NormalizedSwarmEvent[] = []
  for (const tool of claudeToolUses(raw)) {
    const operation = operationForClaudeTool(tool)
    if (operation === 'edit') {
      events.push(makeHarnessEvent({
        ts, type: 'edit.substantive', runtime: 'claude', source: 'claude-transcript',
        swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs ?? [],
        source_seq: tool.ordinal,
      }))
    } else if (operation) {
      events.push(makeHarnessEvent({
        ts, type: 'grounding.operation', runtime: 'claude', source: 'claude-transcript',
        swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs ?? [],
        operation, source_seq: tool.ordinal,
      }))
    } else {
      events.push(makeHarnessEvent({
        ts, type: 'runtime.activity', runtime: 'claude', source: 'claude-transcript',
        swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs ?? [],
        source_seq: tool.ordinal,
      }))
    }
  }
  return events
}

function codexFunctionCall(record: Record<string, unknown>): { name: string, args: unknown } | null {
  const payload = isRecord(record.payload) ? record.payload : record
  const type = payload.type
  if (!['function_call', 'custom_tool_call'].includes(String(type))) return null
  const name = payload.name
  if (typeof name !== 'string') return null
  return { name, args: payload.arguments ?? payload.input }
}

function commandFromArguments(value: unknown): string {
  if (typeof value === 'string') {
    if (Buffer.byteLength(value) > 64 * 1024) return ''
    try {
      const parsed: unknown = JSON.parse(value)
      if (isRecord(parsed) && typeof parsed.cmd === 'string') return parsed.cmd
    } catch {}
    return ''
  }
  return isRecord(value) && typeof value.cmd === 'string' ? value.cmd : ''
}

function operationForCodexCall(call: { name: string, args: unknown }): GroundingOperation | 'edit' | null {
  if (call.name === 'apply_patch') return 'edit'
  if (['read_file', 'list_dir', 'view_image'].includes(call.name)) return 'read'
  if (['grep_files', 'search_files'].includes(call.name)) return 'grep'
  if (call.name !== 'exec_command') return null
  const command = commandFromArguments(call.args).trim()
  // Classification is deliberately narrow. Command bytes are discarded either way.
  return classifyReadCommand(command)
}

/** Normalize one Codex rollout record without retaining command args or model text. */
export function normalizeCodexRolloutRecord(
  raw: unknown,
  scope: AdapterScope,
): NormalizedSwarmEvent[] {
  if (!isRecord(raw)) return []
  const call = codexFunctionCall(raw)
  if (!call) return []
  const ts = runtimeTimestamp(raw, scope.ts)
  const operation = operationForCodexCall(call)
  if (operation === 'edit') {
    return [makeHarnessEvent({
      ts, type: 'edit.substantive', runtime: 'codex', source: 'codex-rollout',
      swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs ?? [],
    })]
  }
  if (operation) {
    return [makeHarnessEvent({
      ts, type: 'grounding.operation', runtime: 'codex', source: 'codex-rollout',
      swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs ?? [], operation,
    })]
  }
  return [makeHarnessEvent({
    ts, type: 'runtime.activity', runtime: 'codex', source: 'codex-rollout',
    swarm: scope.swarm, task_id: scope.task_id, dr_refs: scope.dr_refs ?? [],
  })]
}

/** Parse bounded normalized JSONL. Truncated/unknown/content-bearing records fail closed. */
export function parseNormalizedEventJsonl(
  bytes: string,
  limits: { maxBytes?: number, maxEvents?: number } = {},
): NormalizedSwarmEvent[] {
  const maxBytes = limits.maxBytes ?? 4 * 1024 * 1024
  const maxEvents = limits.maxEvents ?? 10_000
  if (Buffer.byteLength(bytes) > maxBytes) throw new Error('normalized event JSONL exceeds bound')
  const lines = bytes.split('\n').filter(Boolean)
  if (lines.length > maxEvents) throw new Error('normalized event JSONL exceeds event bound')
  return lines.map((line, index) => {
    if (Buffer.byteLength(line) > 4096) throw new Error(`normalized event line ${index + 1} exceeds bound`)
    let value: unknown
    try { value = JSON.parse(line) } catch { throw new Error(`normalized event line ${index + 1} is invalid JSON`) }
    return parseNormalizedEvent(value)
  })
}
