import { createHash, randomBytes } from 'node:crypto'
import {
  closeSync,
  constants,
  fstatSync,
  fsyncSync,
  linkSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import {
  makeHarnessEvent,
  normalizeClaudeTranscriptRecord,
  normalizeCodexRolloutRecord,
  parseNormalizedEvent,
  type AdapterScope,
  type NormalizedSwarmEvent,
  type WorkerRuntime,
} from './events.ts'
import { NormalizedEventStore } from './event-store.ts'
import {
  createGroundingBudgetState,
  filePackGapReport,
  observeGroundingEvent,
  type GroundingBudgetPolicy,
  type GroundingBudgetState,
  type PackGapReport,
} from './grounding-budget.ts'
import {
  assessFirstSubstantiveEdit,
  buildProductContextGapReport,
  buildProductContextPreloadPlan,
  createGroundingState,
  MAX_PRODUCT_CONTEXT_PACK_BYTES,
  parseProductContextTaskBrief,
  recordGroundingAction,
  validateProductContextPack,
  type GroundingPolicy,
  type GroundingState,
  type ProductContextPack,
  type ProductContextPreloadPlan,
  type ProductContextTaskBrief,
} from './product-context-pack.ts'
import { parseProductContextCacheEntry } from './product-context-cache.ts'
import {
  assertOwnerPrivateAuthorityDirectory,
  canonicalAuthorityJsonLine,
  readPrivateCanonicalAuthorityRecord,
  type HarnessParityAdoption,
} from './parity-adoption.ts'

export const GROUNDING_WRAPPER_STATE_SCHEMA = 'qofi-grounding-wrapper-state/v1' as const
export const GROUNDING_WRAPPER_DECISION_SCHEMA = 'qofi-grounding-wrapper-decision/v1' as const
export const MAX_GROUNDING_STATE_FILES = 100_000
export const MAX_GROUNDING_STATE_BYTES = 64 * 1024

const SAFE_TASK = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
const SHA256 = /^[a-f0-9]{64}$/
const COMMIT = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/
const STATE_FILE = /^state-([0-9]{8})\.json$/
const GAP_FILE = 'pack-gap.json'

type ToolHint = Readonly<{
  /** Transient only. Paths and queries never enter the state or normalized event store. */
  path: string | null
  query: string | null
  opaqueExec: boolean
}>

type AdaptedRuntimeRecord = Readonly<{
  events: readonly NormalizedSwarmEvent[]
  hints: readonly ToolHint[]
}>

export interface GroundingRecordAdapter {
  readonly runtime: WorkerRuntime
  normalize(raw: unknown, scope: AdapterScope): AdaptedRuntimeRecord
}

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function parseArguments(value: unknown): Record<string, unknown> | null {
  if (object(value)) return value
  if (typeof value !== 'string' || Buffer.byteLength(value) > 64 * 1024) return null
  try {
    const parsed: unknown = JSON.parse(value)
    return object(parsed) ? parsed : null
  } catch {
    return null
  }
}

function stringField(value: Record<string, unknown> | null, names: readonly string[]): string | null {
  if (!value) return null
  for (const name of names) {
    const candidate = value[name]
    if (typeof candidate === 'string' && candidate.length > 0 && candidate.length <= 4096
      && !candidate.includes('\0')) return candidate
  }
  return null
}

function claudeRecord(raw: unknown): Record<string, unknown> | null {
  if (!object(raw)) return null
  // Claude PreToolUse is the production blocking seam. Convert its native
  // envelope to the same assistant/tool_use shape consumed by the established
  // transcript normalizer; no separate policy classifier is introduced.
  if (typeof raw.tool_name === 'string') {
    return {
      type: 'assistant',
      timestamp: raw.timestamp,
      message: { content: [{ type: 'tool_use', name: raw.tool_name, input: raw.tool_input }] },
    }
  }
  return raw
}

function claudeToolHints(raw: Record<string, unknown>): ToolHint[] {
  const message = object(raw.message) ? raw.message : raw
  const content = Array.isArray(message.content) ? message.content : []
  return content.flatMap(entry => {
    if (!object(entry) || entry.type !== 'tool_use' || typeof entry.name !== 'string') return []
    const input = object(entry.input) ? entry.input : null
    const path = stringField(input, ['file_path', 'path', 'notebook_path'])
    const query = stringField(input, ['pattern', 'query'])
    return [{ path, query, opaqueExec: entry.name === 'Bash' }]
  })
}

/** Thin Claude record translator. It inspects native fields but carries no policy. */
export class ClaudeGroundingRecordAdapter implements GroundingRecordAdapter {
  readonly runtime = 'claude' as const

  normalize(raw: unknown, scope: AdapterScope): AdaptedRuntimeRecord {
    const record = claudeRecord(raw)
    if (!record) return { events: [], hints: [] }
    const events = normalizeClaudeTranscriptRecord(record, scope)
    const hints = claudeToolHints(record)
    if (events.length !== hints.length) throw new Error('Claude grounding adapter projection is inconsistent')
    return { events, hints }
  }
}

function codexPayload(raw: unknown): Record<string, unknown> | null {
  if (!object(raw)) return null
  return object(raw.payload) ? raw.payload : raw
}

function codexToolHint(raw: unknown): ToolHint | null {
  const payload = codexPayload(raw)
  if (!payload || !['function_call', 'custom_tool_call'].includes(String(payload.type))
    || typeof payload.name !== 'string') return null
  const args = parseArguments(payload.arguments ?? payload.input)
  return {
    path: stringField(args, ['file_path', 'path', 'notebook_path', 'cwd']),
    query: stringField(args, ['pattern', 'query']),
    opaqueExec: payload.name === 'exec_command',
  }
}

/** Thin Codex rollout translator. It is intended for a supervised pre-dispatch stream. */
export class CodexGroundingRecordAdapter implements GroundingRecordAdapter {
  readonly runtime = 'codex' as const

  normalize(raw: unknown, scope: AdapterScope): AdaptedRuntimeRecord {
    const events = normalizeCodexRolloutRecord(raw, scope)
    if (events.length === 0) return { events, hints: [] }
    const hint = codexToolHint(raw)
    if (!hint || events.length !== 1) throw new Error('Codex grounding adapter projection is inconsistent')
    return { events, hints: [hint] }
  }
}

export type DurableGroundingWrapperState = Readonly<{
  schema: typeof GROUNDING_WRAPPER_STATE_SCHEMA
  version: number
  runtime: WorkerRuntime
  swarm: string
  task_id: string
  dr_refs: readonly string[]
  corpus_sha256: string
  corpus_commit: string | null
  next_source_seq: number
  last_timestamp_ms: number
  context: GroundingState
  budget: GroundingBudgetState
  event: NormalizedSwarmEvent
}>

function scopeDigest(scope: Readonly<{
  receiptSha256: string
  runtime: WorkerRuntime
  swarm: string
  taskId: string
  corpusSha256: string
  corpusCommit: string | null
}>): string {
  const hash = createHash('sha256')
  for (const value of [
    scope.receiptSha256, scope.runtime, scope.swarm, scope.taskId, scope.corpusSha256,
    scope.corpusCommit ?? 'no-corpus-commit',
  ]) hash.update(value).update('\0')
  return hash.digest('hex')
}

function ensurePrivateChild(parent: string, name: string): string {
  if (!/^[a-z0-9][a-z0-9.-]{0,127}$/.test(name)) throw new Error('grounding state child name is invalid')
  const path = join(parent, name)
  try { mkdirSync(path, { mode: 0o700 }) } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
  }
  return assertOwnerPrivateAuthorityDirectory(path, 'grounding state directory')
}

function publishPrivateRecord(directory: string, name: string, value: unknown): 'created' | 'duplicate' {
  const bytes = canonicalAuthorityJsonLine(value)
  if (Buffer.byteLength(bytes) > MAX_GROUNDING_STATE_BYTES) {
    throw new Error('grounding state record exceeds its byte bound')
  }
  const target = join(directory, name)
  try {
    const existing = readPrivateCanonicalAuthorityRecord(
      target, 'grounding state record', MAX_GROUNDING_STATE_BYTES,
    )
    if (existing.bytes.toString('utf8') !== bytes) throw new Error('grounding state record conflicts')
    return 'duplicate'
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  const temp = join(directory, `.${name}.tmp.${process.pid}.${randomBytes(8).toString('hex')}`)
  let fd: number | undefined
  try {
    fd = openSync(
      temp,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW ?? 0),
      0o600,
    )
    writeFileSync(fd, bytes)
    fsyncSync(fd)
    closeSync(fd)
    fd = undefined
    try { linkSync(temp, target) } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      const existing = readPrivateCanonicalAuthorityRecord(
        target, 'grounding state record', MAX_GROUNDING_STATE_BYTES,
      )
      if (existing.bytes.toString('utf8') !== bytes) {
        throw new Error('concurrent grounding state transition refused')
      }
      return 'duplicate'
    }
    unlinkSync(temp)
    const directoryFd = openSync(directory, constants.O_RDONLY)
    try { fsyncSync(directoryFd) } finally { closeSync(directoryFd) }
    return 'created'
  } finally {
    if (fd !== undefined) try { closeSync(fd) } catch {}
    try { unlinkSync(temp) } catch {}
  }
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).length === keys.length
    && keys.every(key => Object.prototype.hasOwnProperty.call(value, key))
}

class DurableGroundingTaskStore {
  constructor(
    readonly directory: string,
    private readonly pack: ProductContextPack,
    private readonly brief: ProductContextTaskBrief,
    private readonly runtime: WorkerRuntime,
    private readonly swarm: string,
    private readonly drRefs: readonly string[],
    private readonly corpusCommit: string | null,
  ) {
    assertOwnerPrivateAuthorityDirectory(directory, 'grounding task state')
  }

  private names(): string[] {
    assertOwnerPrivateAuthorityDirectory(this.directory, 'grounding task state')
    const names = readdirSync(this.directory).sort()
    if (names.length > MAX_GROUNDING_STATE_FILES + 1) throw new Error('grounding state file bound exceeded')
    for (const name of names) {
      if (name !== GAP_FILE && !STATE_FILE.test(name)) {
        throw new Error('grounding task state contains an unknown entry')
      }
    }
    return names
  }

  private parseState(value: unknown, expectedVersion: number): DurableGroundingWrapperState {
    if (!object(value) || !exactKeys(value, [
      'schema', 'version', 'runtime', 'swarm', 'task_id', 'dr_refs', 'corpus_sha256',
      'corpus_commit', 'next_source_seq', 'last_timestamp_ms', 'context', 'budget', 'event',
    ]) || value.schema !== GROUNDING_WRAPPER_STATE_SCHEMA
      || value.version !== expectedVersion || value.runtime !== this.runtime
      || value.swarm !== this.swarm || value.task_id !== this.brief.taskId
      || JSON.stringify(value.dr_refs) !== JSON.stringify(this.drRefs)
      || value.corpus_sha256 !== this.pack.corpusSha256
      || value.corpus_commit !== this.corpusCommit
      || !Number.isSafeInteger(value.next_source_seq) || Number(value.next_source_seq) < 1
      || Number(value.next_source_seq) > 1_000_001
      || !Number.isSafeInteger(value.last_timestamp_ms) || Number(value.last_timestamp_ms) < 0) {
      throw new Error('grounding wrapper state is malformed or outside task scope')
    }
    const event = parseNormalizedEvent(value.event)
    if (event.runtime !== this.runtime || event.swarm !== this.swarm
      || event.task_id !== this.brief.taskId
      || JSON.stringify(event.dr_refs) !== JSON.stringify(this.drRefs)
      || event.source_seq !== Number(value.next_source_seq) - 1
      || Date.parse(event.ts) !== value.last_timestamp_ms) {
      throw new Error('grounding wrapper event is outside task scope')
    }
    const context = value.context as GroundingState
    buildProductContextGapReport(this.pack, this.brief, context)
    const budget = value.budget as GroundingBudgetState
    // This validates the entire budget shape without changing it.
    observeGroundingEvent(budget, makeHarnessEvent({
      ts: event.ts,
      type: 'runtime.activity',
      runtime: this.runtime,
      source: this.runtime === 'claude' ? 'claude-transcript' : 'codex-rollout',
      swarm: this.swarm,
      task_id: this.brief.taskId,
      dr_refs: [...this.drRefs],
      source_seq: event.source_seq,
    }))
    if (budget.task_id !== this.brief.taskId || budget.swarm !== this.swarm
      || budget.runtime !== this.runtime || budget.corpus_sha256 !== this.pack.corpusSha256) {
      throw new Error('grounding budget is outside task scope')
    }
    return value as unknown as DurableGroundingWrapperState
  }

  replay(eventStore: NormalizedEventStore): DurableGroundingWrapperState[] {
    const names = this.names().filter(name => STATE_FILE.test(name))
    const states: DurableGroundingWrapperState[] = []
    names.forEach((name, index) => {
      const match = name.match(STATE_FILE)!
      const version = Number(match[1])
      if (version !== index) throw new Error('grounding state journal is not contiguous')
      const read = readPrivateCanonicalAuthorityRecord(
        join(this.directory, name), 'grounding task transition', MAX_GROUNDING_STATE_BYTES,
      )
      const state = this.parseState(read.value, version)
      eventStore.append(state.event)
      states.push(state)
    })
    return states
  }

  append(state: DurableGroundingWrapperState): void {
    const name = `state-${String(state.version).padStart(8, '0')}.json`
    publishPrivateRecord(this.directory, name, state)
  }

  publishGap(report: PackGapReport): void {
    publishPrivateRecord(this.directory, GAP_FILE, report)
  }

  assertGap(report: PackGapReport): void {
    const read = readPrivateCanonicalAuthorityRecord(
      join(this.directory, GAP_FILE), 'grounding pack-gap artifact', MAX_GROUNDING_STATE_BYTES,
    )
    if (canonicalAuthorityJsonLine(read.value) !== canonicalAuthorityJsonLine(report)) {
      throw new Error('durable pack-gap artifact does not match grounding state')
    }
  }
}

export type GroundingWrapperDecision = Readonly<{
  schema: typeof GROUNDING_WRAPPER_DECISION_SCHEMA
  ok: boolean
  reason: string
  appended_event_ids: readonly string[]
  operation_count: number
  gap_report_required: boolean
  first_substantive_edit_seen: boolean
}>

export type SupervisedGroundingWrapperOptions = Readonly<{
  adapter: GroundingRecordAdapter
  eventStore: NormalizedEventStore
  stateDirectory: string
  repoRoot: string
  swarm: string
  taskId: string
  drRefs: readonly string[]
  pack: unknown
  taskBrief: unknown
  budgetPolicy: GroundingBudgetPolicy
  contextPolicy?: GroundingPolicy
  /** Required by the production authority reader; null is test/library-only. */
  corpusCommit?: string | null
  now?: () => number
}>

function inside(root: string, candidate: string): boolean {
  const rel = relative(root, candidate)
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
}

function canonicalToolPath(value: string | null, repoRoot: string): string | null {
  if (!value || value.includes('\0') || value.includes('\\')) return null
  const absolute = isAbsolute(value) ? resolve(value) : resolve(repoRoot, value)
  if (!inside(repoRoot, absolute)) return null
  const rel = relative(repoRoot, absolute).split(sep).join('/')
  if (!rel || rel.startsWith('../') || rel.includes('//')) return null
  return rel
}

/**
 * Harness-owned enforcement around one supervised task. Runtime adapters only
 * translate raw envelopes. This class owns preload order, budget, durable gap,
 * event identity, and the edit decision for both runtimes.
 */
export class SupervisedGroundingWrapper {
  readonly preload: ProductContextPreloadPlan
  private readonly adapter: GroundingRecordAdapter
  private readonly eventStore: NormalizedEventStore
  private readonly taskStore: DurableGroundingTaskStore
  private readonly repoRoot: string
  private readonly swarm: string
  private readonly taskId: string
  private readonly drRefs: readonly string[]
  private readonly pack: ProductContextPack
  private readonly brief: ProductContextTaskBrief
  private readonly budgetPolicy: GroundingBudgetPolicy
  private readonly contextPolicy?: GroundingPolicy
  private readonly corpusCommit: string | null
  private readonly now: () => number
  private state: DurableGroundingWrapperState
  private poisoned = false

  constructor(options: SupervisedGroundingWrapperOptions) {
    if (options.adapter.runtime !== 'claude' && options.adapter.runtime !== 'codex') {
      throw new Error('grounding wrapper runtime is invalid')
    }
    this.adapter = options.adapter
    this.eventStore = options.eventStore
    this.repoRoot = realpathSync(resolve(options.repoRoot))
    this.swarm = options.swarm
    this.taskId = options.taskId
    this.drRefs = [...new Set(options.drRefs)].sort()
    this.pack = validateProductContextPack(options.pack).pack
    this.brief = parseProductContextTaskBrief(options.taskBrief)
    if (this.brief.taskId !== this.taskId) throw new Error('grounding task brief has the wrong task scope')
    this.preload = buildProductContextPreloadPlan(this.pack, this.brief, options.contextPolicy)
    this.budgetPolicy = options.budgetPolicy
    this.contextPolicy = options.contextPolicy
    this.corpusCommit = options.corpusCommit ?? null
    if (this.corpusCommit !== null && !COMMIT.test(this.corpusCommit)) {
      throw new Error('grounding corpus commit is invalid')
    }
    this.now = options.now ?? Date.now
    this.taskStore = new DurableGroundingTaskStore(
      options.stateDirectory, this.pack, this.brief, this.adapter.runtime,
      this.swarm, this.drRefs, this.corpusCommit,
    )
    const replay = this.taskStore.replay(this.eventStore)
    if (replay.length > 0) {
      this.state = replay.at(-1)!
      const expected = createGroundingBudgetState({
        task_id: this.taskId,
        swarm: this.swarm,
        runtime: this.adapter.runtime,
        corpus_sha256: this.pack.corpusSha256,
      }, this.budgetPolicy)
      if (this.state.budget.max_operations_before_first_edit
        !== expected.max_operations_before_first_edit) {
        throw new Error('grounding budget policy changed during the task')
      }
    } else {
      const timestamp = this.timestamp(-1, this.now())
      const event = makeHarnessEvent({
        ts: new Date(timestamp).toISOString(),
        type: 'grounding.started',
        runtime: this.adapter.runtime,
        source: 'harness',
        swarm: this.swarm,
        task_id: this.taskId,
        dr_refs: [...this.drRefs],
        source_seq: 0,
      })
      this.state = {
        schema: GROUNDING_WRAPPER_STATE_SCHEMA,
        version: 0,
        runtime: this.adapter.runtime,
        swarm: this.swarm,
        task_id: this.taskId,
        dr_refs: this.drRefs,
        corpus_sha256: this.pack.corpusSha256,
        corpus_commit: this.corpusCommit,
        next_source_seq: 1,
        last_timestamp_ms: timestamp,
        context: createGroundingState(this.pack, this.brief, this.contextPolicy),
        budget: createGroundingBudgetState({
          task_id: this.taskId,
          swarm: this.swarm,
          runtime: this.adapter.runtime,
          corpus_sha256: this.pack.corpusSha256,
        }, this.budgetPolicy),
        event,
      }
      this.persist(this.state)
    }
  }

  private timestamp(previous: number, candidate: number): number {
    if (!Number.isSafeInteger(candidate) || candidate < 0) throw new Error('grounding wrapper clock is invalid')
    return Math.max(candidate, previous + 1)
  }

  private decision(ok: boolean, reason: string, ids: readonly string[] = []): GroundingWrapperDecision {
    return {
      schema: GROUNDING_WRAPPER_DECISION_SCHEMA,
      ok,
      reason,
      appended_event_ids: [...ids],
      operation_count: this.state.budget.operation_count,
      gap_report_required: this.state.budget.tripped && this.state.budget.gap_report === null,
      first_substantive_edit_seen: this.state.budget.first_substantive_edit_seen,
    }
  }

  private persist(next: DurableGroundingWrapperState): void {
    if (this.poisoned) throw new Error('grounding wrapper requires reconstruction after a persistence failure')
    this.taskStore.append(next)
    try {
      this.eventStore.append(next.event)
      this.state = next
    } catch (error) {
      // The immutable task transition is authoritative. A fresh wrapper will
      // reconcile its event before another decision; this instance fails shut.
      this.poisoned = true
      throw error
    }
  }

  private sequence(event: NormalizedSwarmEvent): NormalizedSwarmEvent {
    if (this.state.next_source_seq > 1_000_000) throw new Error('grounding source sequence bound exceeded')
    const candidate = Date.parse(event.ts)
    const timestamp = this.timestamp(
      this.state.last_timestamp_ms,
      Number.isFinite(candidate) ? candidate : this.now(),
    )
    return makeHarnessEvent({
      ts: new Date(timestamp).toISOString(),
      type: event.type,
      runtime: event.runtime,
      source: event.source,
      swarm: event.swarm,
      task_id: event.task_id,
      dr_refs: event.dr_refs,
      source_seq: this.state.next_source_seq,
      state: event.state,
      previous_state: event.previous_state,
      outcome: event.outcome,
      result_kind: event.result_kind,
      result_status: event.result_status,
      operation: event.operation,
    })
  }

  private persistEvent(
    event: NormalizedSwarmEvent,
    context: GroundingState,
    budget: GroundingBudgetState,
  ): void {
    const next: DurableGroundingWrapperState = {
      ...this.state,
      version: this.state.version + 1,
      next_source_seq: event.source_seq! + 1,
      last_timestamp_ms: Date.parse(event.ts),
      context,
      budget,
      event,
    }
    this.persist(next)
  }

  private requiredReadDecision(event: NormalizedSwarmEvent, hint: ToolHint): Readonly<{
    ok: boolean
    reason: string
    context: GroundingState
  }> {
    const unread = this.preload.primaryReadOrder.filter(ref => !this.state.context.reads.includes(ref))
    if (unread.length === 0 || this.state.context.firstSubstantiveEditAuthorized) {
      return { ok: true, reason: 'named-context-refs-consumed', context: this.state.context }
    }
    if (event.type !== 'grounding.operation' || event.operation !== 'read') {
      return { ok: false, reason: 'named-context-refs-not-consumed', context: this.state.context }
    }
    const nextRef = unread[0]!
    const expected = this.preload.requiredRefs.find(ref => ref.name === nextRef)!
    if (canonicalToolPath(hint.path, this.repoRoot) !== expected.path) {
      return { ok: false, reason: 'named-context-ref-read-required', context: this.state.context }
    }
    this.verifyNamedRef(expected.path, expected.contentSha256)
    const recorded = recordGroundingAction(this.state.context, { kind: 'read', ref: nextRef })
    return { ok: recorded.ok, reason: recorded.reason, context: recorded.state }
  }

  private verifyNamedRef(path: string, expectedSha256: string): void {
    const absolute = resolve(this.repoRoot, path)
    if (!inside(this.repoRoot, absolute)) throw new Error('named context ref escaped the repository')
    const before = lstatSync(absolute)
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
      || before.size < 0 || before.size > MAX_PRODUCT_CONTEXT_PACK_BYTES) {
      throw new Error('named context ref has unsafe identity or size')
    }
    const fd = openSync(absolute, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    try {
      const opened = fstatSync(fd)
      if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size
        || opened.mtimeMs !== before.mtimeMs || opened.ctimeMs !== before.ctimeMs
        || opened.nlink !== 1) throw new Error('named context ref changed while opening')
      const bytes = readFileSync(fd)
      const after = fstatSync(fd)
      if (after.dev !== opened.dev || after.ino !== opened.ino || after.size !== opened.size
        || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs
        || createHash('sha256').update(bytes).digest('hex') !== expectedSha256) {
        throw new Error('named context ref does not match the corpus pack')
      }
    } finally {
      closeSync(fd)
    }
  }

  private handle(eventValue: NormalizedSwarmEvent, hint: ToolHint): GroundingWrapperDecision {
    const event = this.sequence(eventValue)
    if (event.type === 'grounding.operation') {
      const required = this.requiredReadDecision(event, hint)
      if (!required.ok) return this.decision(false, required.reason)
      let context = required.context
      if (event.operation === 'grep' && !context.firstSubstantiveEditAuthorized) {
        const path = canonicalToolPath(hint.path, this.repoRoot)
        const ref = this.preload.requiredRefs.find(candidate => candidate.path === path)?.name
        if (ref && hint.query) {
          const recorded = recordGroundingAction(context, { kind: 'grep', ref, query: hint.query })
          if (!recorded.ok) return this.decision(false, recorded.reason)
          context = recorded.state
        }
      }
      const budget = observeGroundingEvent(this.state.budget, event)
      this.persistEvent(event, context, budget.state)
      return this.decision(true, budget.reason, [event.event_id])
    }
    if (event.type === 'edit.substantive') {
      const required = this.requiredReadDecision(event, hint)
      if (!required.ok) return this.decision(false, required.reason)
      const budget = observeGroundingEvent(this.state.budget, event)
      if (!budget.ok) return this.decision(false, budget.reason)
      const context = this.state.context.firstSubstantiveEditAuthorized
        ? { ok: true, state: this.state.context, reason: 'substantive-edit-already-authorized' }
        : assessFirstSubstantiveEdit(this.pack, this.brief, this.state.context)
      if (!context.ok) return this.decision(false, context.reason)
      if (budget.state.gap_report) this.taskStore.assertGap(budget.state.gap_report)
      this.persistEvent(event, context.state, budget.state)
      return this.decision(true, budget.reason, [event.event_id])
    }
    if (event.type === 'runtime.activity' && hint.opaqueExec
      && !this.state.context.firstSubstantiveEditAuthorized) {
      return this.decision(false, 'unclassified-pre-edit-exec-refused')
    }
    this.persistEvent(event, this.state.context, this.state.budget)
    return this.decision(true, 'runtime-event-recorded', [event.event_id])
  }

  /** Process one native pre-dispatch record. Any refusal must prevent tool execution. */
  process(raw: unknown): GroundingWrapperDecision {
    if (this.poisoned) throw new Error('grounding wrapper requires reconstruction after a persistence failure')
    const adapted = this.adapter.normalize(raw, {
      swarm: this.swarm,
      task_id: this.taskId,
      dr_refs: [...this.drRefs],
      ts: new Date(this.now()).toISOString(),
    })
    if (adapted.events.length === 0) return this.decision(true, 'runtime-record-ignored')
    const appended: string[] = []
    for (let index = 0; index < adapted.events.length; index += 1) {
      const decision = this.handle(adapted.events[index]!, adapted.hints[index]!)
      appended.push(...decision.appended_event_ids)
      if (!decision.ok) return { ...decision, appended_event_ids: appended }
    }
    return this.decision(true, 'runtime-record-admitted', appended)
  }

  /** Publish the required result artifact before the held edit can be retried. */
  filePackGap(missingContextRefs: readonly string[]): GroundingWrapperDecision {
    if (this.poisoned) throw new Error('grounding wrapper requires reconstruction after a persistence failure')
    const budget = filePackGapReport(this.state.budget, missingContextRefs)
    this.taskStore.publishGap(budget.gap_report!)
    this.taskStore.assertGap(budget.gap_report!)
    const timestamp = this.timestamp(this.state.last_timestamp_ms, this.now())
    const event = makeHarnessEvent({
      ts: new Date(timestamp).toISOString(),
      type: 'grounding.gap_reported',
      runtime: this.adapter.runtime,
      source: 'harness',
      swarm: this.swarm,
      task_id: this.taskId,
      dr_refs: [...this.drRefs],
      source_seq: this.state.next_source_seq,
    })
    this.persistEvent(event, this.state.context, budget)
    return this.decision(true, 'durable-pack-gap-filed', [event.event_id])
  }
}

export type AdoptedGroundingWrapperOptions = Readonly<{
  adoption: Extract<HarnessParityAdoption, { enabled: true }>
  runtime: WorkerRuntime
  repoRoot: string
  taskId: string
  pack: unknown
  taskBrief: unknown
  budgetPolicy: GroundingBudgetPolicy
  contextPolicy?: GroundingPolicy
  corpusCommit?: string | null
  now?: () => number
}>

export function groundingAuthorityPaths(
  adoption: Extract<HarnessParityAdoption, { enabled: true }>,
  taskId: string,
): Readonly<{ contextCache: string, taskBrief: string }> {
  if (!SAFE_TASK.test(taskId)) throw new Error('grounding task id is invalid')
  const root = join(adoption.stateRoot, 'grounding-authority')
  const digest = createHash('sha256').update(taskId, 'utf8').digest('hex')
  return {
    contextCache: join(root, 'product-context-cache.json'),
    taskBrief: join(root, 'task-briefs', `${digest}.json`),
  }
}

export type AdoptedGroundingAuthorityOptions = Omit<
  AdoptedGroundingWrapperOptions,
  'pack' | 'taskBrief' | 'corpusCommit'
> & Readonly<{ observedCorpusCommit: string }>

/**
 * Fixed production authority reader. Pack/brief paths are derived from the
 * validated receipt and task identity; they are never accepted from worker
 * input or environment variables.
 */
export function createAdoptedGroundingWrapperFromAuthority(
  options: AdoptedGroundingAuthorityOptions,
): SupervisedGroundingWrapper {
  const paths = groundingAuthorityPaths(options.adoption, options.taskId)
  if (!COMMIT.test(options.observedCorpusCommit)) {
    throw new Error('observed product context corpus commit is invalid')
  }
  const cache = parseProductContextCacheEntry(readPrivateCanonicalAuthorityRecord(
    paths.contextCache,
    'product context cache authority',
    MAX_PRODUCT_CONTEXT_PACK_BYTES + MAX_GROUNDING_STATE_BYTES,
  ).value)
  if (cache.corpus_commit !== options.observedCorpusCommit) {
    throw new Error('product context cache is stale for the worker corpus commit')
  }
  const coreRefs = new Set(cache.pack.refs.map(ref => ref.name))
  const missingCore = ['invariants', 'key-files', 'module-map'].filter(ref => !coreRefs.has(ref))
  if (missingCore.length > 0) {
    throw new Error(`product context cache lacks core refs: ${missingCore.join(',')}`)
  }
  const taskBrief = readPrivateCanonicalAuthorityRecord(
    paths.taskBrief,
    'product context task brief authority',
    MAX_GROUNDING_STATE_BYTES,
  ).value
  const { observedCorpusCommit, ...rest } = options
  return createAdoptedGroundingWrapper({
    ...rest,
    corpusCommit: observedCorpusCommit,
    pack: cache.pack,
    taskBrief,
  })
}

/**
 * Production adoption seam. The lifecycle owner must pass an already-validated
 * operator receipt that names both runtimes; a worker cannot self-enable this
 * wrapper. No caller should construct a one-runtime receipt or fallback path.
 */
export function createAdoptedGroundingWrapper(
  options: AdoptedGroundingWrapperOptions,
): SupervisedGroundingWrapper {
  if (!options.adoption.enabled) throw new Error('grounding parity adoption is disabled')
  if (!SAFE_TASK.test(options.taskId)) throw new Error('grounding task id is invalid')
  const repoRoot = realpathSync(resolve(options.repoRoot))
  const stateRoot = assertOwnerPrivateAuthorityDirectory(
    options.adoption.stateRoot, 'grounding parity state root',
  )
  const rel = relative(repoRoot, stateRoot)
  if (rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))) {
    throw new Error('grounding state root must be outside the worker repository')
  }
  const pack = validateProductContextPack(options.pack).pack
  const taskDigest = scopeDigest({
    receiptSha256: options.adoption.receiptSha256,
    runtime: options.runtime,
    swarm: options.adoption.swarm,
    taskId: options.taskId,
    corpusSha256: pack.corpusSha256,
    corpusCommit: options.corpusCommit ?? null,
  })
  const groundingRoot = ensurePrivateChild(stateRoot, 'grounding')
  const runtimeRoot = ensurePrivateChild(groundingRoot, options.runtime)
  const taskRoot = ensurePrivateChild(runtimeRoot, taskDigest)
  const eventRoot = ensurePrivateChild(stateRoot, 'events')
  return new SupervisedGroundingWrapper({
    adapter: options.runtime === 'claude'
      ? new ClaudeGroundingRecordAdapter()
      : new CodexGroundingRecordAdapter(),
    eventStore: new NormalizedEventStore(eventRoot, { repoRoot }),
    stateDirectory: taskRoot,
    repoRoot,
    swarm: options.adoption.swarm,
    taskId: options.taskId,
    drRefs: options.adoption.drRefs,
    pack,
    taskBrief: options.taskBrief,
    budgetPolicy: options.budgetPolicy,
    contextPolicy: options.contextPolicy,
    corpusCommit: options.corpusCommit,
    now: options.now,
  })
}
