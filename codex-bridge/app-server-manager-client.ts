/** Connection-bound Unix HTTP client for the global Codex App Server manager. */

import { randomBytes } from 'crypto'
import { Agent, request as httpRequest, type IncomingMessage } from 'http'
import { performance } from 'perf_hooks'
import {
  assertOwnerPrivateSocketParent,
  attestOwnerUnixSocket,
  sameUnixSocket,
  type UnixSocketIdentity,
} from './app-server-unix-socket.ts'
import {
  isMissingThreadError,
  type CodexEventSummary,
  type CodexFailureKind,
  type CodexTurnResult,
} from './codex.ts'
import { CODEX_APP_SERVER_PROTOCOL_VERSION } from './app-server-client.ts'
import {
  DEFAULT_CODEX_REASONING_EFFORT,
  isManagedCodexReasoningEffort,
  type ManagedCodexReasoningEffort,
} from './model.ts'
import {
  APP_SERVER_MANAGER_SCHEMA,
  APP_SERVER_MANAGER_VERSION,
  FABLE_EARLY_REVIEW_STATUS,
  FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA,
  FABLE_REVIEWER_SCOPE_SCHEMA,
  FABLE_REVIEWER_SLOT,
  MANAGER_MAX_RESERVATION_TTL_MS,
  MANAGER_MAX_RESULT_BODY_BYTES,
  MANAGER_MAX_TURN_BODY_BYTES,
  MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA,
  type ManagerErrorResponse,
  type ManagerCompletionReviewArguments,
  type ManagerCompletionReviewBeginRequest,
  type ManagerCompletionReviewBeginResponse,
  type ManagerCompletionReviewEndRequest,
  type ManagerCompletionReviewEndResponse,
  type ManagerCompletionReviewPollRequest,
  type ManagerCompletionReviewPollResponse,
  type ManagerHealthResponse,
  type ManagerRegisterRequest,
  type ManagerRegisterResponse,
  type ManagerPhase,
  type ManagerReviewerScopeRequest,
  type ManagerReviewerScopeResponse,
  type ManagerSessionId,
  type ManagerSessionsReplaceRequest,
  type ManagerSessionsReplaceResponse,
  type ManagerTurnCleanupRequest,
  type ManagerTurnCleanupResponse,
  type ManagerTurnInterruptRequest,
  type ManagerTurnInterruptResponse,
  type ManagerTurnReserveRequest,
  type ManagerTurnReserveResponse,
  type ManagerTurnReservationCancelRequest,
  type ManagerTurnReservationCancelResponse,
  type ManagerTurnStartRequest,
  type ManagerTurnStartResponse,
  type ManagerUnregisterRequest,
  type ManagerUnregisterResponse,
} from './app-server-manager.ts'

const DEFAULT_REQUEST_BYTES = 64 * 1024
const DEFAULT_TURN_REQUEST_BYTES = MANAGER_MAX_TURN_BODY_BYTES
const DEFAULT_RESPONSE_BYTES = MANAGER_MAX_RESULT_BODY_BYTES
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000
const DEFAULT_INTERRUPT_GRACE_MS = 30_000
const PRE_ADMISSION_RETRY_DELAY_MS = 100
export const MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS = 60_000
export const MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS = 10_000
const TOKEN = /^[0-9a-f]{64}$/
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$/
const encoder = new TextEncoder()

type JsonObject = Record<string, unknown>
type CancelKind = 'aborted' | 'timeout' | null

export type AppServerManagerClientOptions = {
  socketPath: string
  requestTimeoutMs?: number
  interruptGraceMs?: number
  maxRequestBytes?: number
  maxTurnRequestBytes?: number
  maxResponseBytes?: number
}

export type ManagerTurnRunOptions = {
  signal?: AbortSignal
  timeoutMs: number
  onEvent?: (event: CodexEventSummary) => void
}

export type ManagerPreAdmissionOptions = {
  signal?: AbortSignal
  timeoutMs?: number
}

export type ManagerTurnExecution = {
  leaseId: string
  response: ManagerTurnStartResponse
  result: CodexTurnResult
}

export type ManagerLivenessDisposition = 'ready' | 'shared-busy' | 'maintenance'

export type ManagerLiveness = Readonly<{
  health: ManagerHealthResponse
  disposition: ManagerLivenessDisposition
}>

type RequestOptions = {
  agent: Agent
  timeoutMs: number
  maxRequestBytes?: number
  maxResponseBytes?: number
  ambiguousOnLoss?: boolean
  abortSignal?: AbortSignal
  allowFaulted?: boolean
}

type RemoteErrorMetadata = Readonly<{
  status: number
  phase: ManagerPhase
  retryable: boolean
  poolExhausted: boolean
  parkedUntilMs: number | null
}>

const REMOTE_PHASES = new Set<ManagerPhase>([
  'starting', 'idle', 'reserved', 'active', 'completion-review-pending',
  'completion-review-complete', 'terminal-cleanup-pending',
  'drained', 'ambiguous', 'stopping',
])
const RETRYABLE_PRE_ADMISSION_PHASES = new Set<ManagerPhase>([
  'idle', 'reserved', 'active', 'completion-review-pending',
  'completion-review-complete', 'terminal-cleanup-pending', 'drained', 'starting',
])

function object(value: unknown): value is JsonObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  min: number,
  max: number,
  name: string,
): number {
  const selected = value ?? fallback
  if (!Number.isSafeInteger(selected) || selected < min || selected > max) {
    throw new TypeError(`${name} must be an integer from ${min} to ${max}`)
  }
  return selected
}

function safeIdentifier(value: unknown): value is string {
  return typeof value === 'string' && SAFE_ID.test(value)
}

function safeGeneration(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) > 0
}

function exactKeys(value: JsonObject, expected: readonly string[]): boolean {
  return Object.keys(value).sort().join(',') === [...expected].sort().join(',')
}

function safeStringArray(value: unknown, maxEntries: number, maxEntryBytes: number): value is string[] {
  return Array.isArray(value)
    && value.length <= maxEntries
    && value.every(entry => typeof entry === 'string'
      && encoder.encode(entry).byteLength <= maxEntryBytes
      && !entry.includes('\0'))
}

function managerErrorDetail(value: unknown, status: number): string {
  if (!object(value)) return `manager HTTP ${status}`
  const candidate = typeof value.error === 'string'
    ? value.error
    : typeof value.detail === 'string'
      ? value.detail
      : typeof value.message === 'string' ? value.message : ''
  return candidate ? candidate.slice(0, 1000) : `manager HTTP ${status}`
}

function remoteErrorMetadata(value: unknown, status: number): RemoteErrorMetadata | null {
  const keys = object(value) ? Object.keys(value).sort().join(',') : ''
  const ordinary = ['error', 'phase', 'retryable'].sort().join(',')
  const parked = ['error', 'parkedUntilMs', 'phase', 'retryable'].sort().join(',')
  if (!Number.isSafeInteger(status) || status < 400 || status > 599
    || !object(value) || (keys !== ordinary && keys !== parked)
    || typeof value.error !== 'string' || value.error.length === 0 || value.error.length > 1024
    || value.error.includes('\0')
    || typeof value.phase !== 'string' || !REMOTE_PHASES.has(value.phase as ManagerPhase)
    || typeof value.retryable !== 'boolean'
    || (keys === parked && value.parkedUntilMs !== null
      && (!Number.isSafeInteger(value.parkedUntilMs) || (value.parkedUntilMs as number) < 0))) {
    return null
  }
  return {
    status,
    phase: value.phase as ManagerPhase,
    retryable: value.retryable,
    poolExhausted: keys === parked,
    parkedUntilMs: keys === parked ? value.parkedUntilMs as number | null : null,
  }
}

export class AppServerManagerClientError extends Error {
  constructor(
    message: string,
    readonly kind: 'boundary' | 'state' | 'timeout' | 'transport' | 'protocol' | 'remote',
    readonly ambiguous = false,
    readonly remoteHttpStatus: number | null = null,
    readonly remotePhase: ManagerPhase | null = null,
    readonly remoteRetryable: boolean | null = null,
    readonly remotePoolExhausted = false,
    readonly remoteParkedUntilMs: number | null = null,
  ) {
    super(message)
    this.name = 'AppServerManagerClientError'
  }
}

function validateRegisterResponse(
  value: unknown,
  expectedReasoningEffort: ManagedCodexReasoningEffort,
): ManagerRegisterResponse {
  if (!object(value)
    || !exactKeys(value, [
      'registrationToken', 'generation', 'facadeEndpoint', 'serverVersion',
      'reasoningEffort', 'activeProfile', 'pool', 'thresholdPercent', 'parkedUntilMs',
    ])
    || typeof value.registrationToken !== 'string' || !TOKEN.test(value.registrationToken)
    || !safeGeneration(value.generation)
    || typeof value.facadeEndpoint !== 'string'
    || !value.facadeEndpoint.startsWith('unix:///')
    || value.facadeEndpoint.includes('|') || value.facadeEndpoint.includes('\0')
    || value.serverVersion !== '0.144.1'
    || !isManagedCodexReasoningEffort(value.reasoningEffort)
    || value.reasoningEffort !== expectedReasoningEffort) {
    throw new AppServerManagerClientError('manager returned malformed registration', 'protocol', true)
  }
  if ((value.activeProfile !== null && !safeIdentifier(value.activeProfile))
    || !safeIdentifier(value.pool)
    || typeof value.thresholdPercent !== 'number' || !Number.isFinite(value.thresholdPercent)
    || value.thresholdPercent <= 0 || value.thresholdPercent > 100
    || (value.parkedUntilMs !== null && !Number.isSafeInteger(value.parkedUntilMs))) {
    throw new AppServerManagerClientError('manager returned malformed registration profile state', 'protocol', true)
  }
  return value as unknown as ManagerRegisterResponse
}

function validateReservationResponse(
  value: unknown,
  requestId: string,
  nowMs = Date.now(),
): ManagerTurnReserveResponse {
  if (!object(value)
    || !exactKeys(value, ['reservationToken', 'requestId', 'expiresAtMs', 'generation', 'profile'])
    || typeof value.reservationToken !== 'string' || !TOKEN.test(value.reservationToken)
    || value.requestId !== requestId
    || !Number.isSafeInteger(value.expiresAtMs) || (value.expiresAtMs as number) <= nowMs
    || (value.expiresAtMs as number) > nowMs + MANAGER_MAX_RESERVATION_TTL_MS
    || !safeGeneration(value.generation)
    || !safeIdentifier(value.profile)) {
    throw new AppServerManagerClientError('manager returned malformed turn reservation', 'protocol', true)
  }
  return value as unknown as ManagerTurnReserveResponse
}

function validateHealthContract(value: unknown): ManagerHealthResponse {
  if (!object(value)
    || !exactKeys(value, [
      'schema', 'status', 'phase', 'generation', 'registeredSwarmCount',
      'upstreamReady', 'upstreamState', 'managerVersion', 'protocolVersion', 'cliVersion',
    ])
    || value.schema !== APP_SERVER_MANAGER_SCHEMA
    || !['ready', 'drained', 'busy', 'review-pending', 'cleanup-pending', 'ambiguous', 'stopping'].includes(
      String(value.status),
    )
    || ![
      'starting', 'idle', 'reserved', 'active', 'completion-review-pending',
      'completion-review-complete', 'terminal-cleanup-pending',
      'drained', 'ambiguous', 'stopping',
    ].includes(String(value.phase))
    || !safeGeneration(value.generation)
    || !Number.isSafeInteger(value.registeredSwarmCount)
    || (value.registeredSwarmCount as number) < 0
    || typeof value.upstreamReady !== 'boolean'
    || !['ready', 'stopped', 'cleanup-pending', 'ambiguous'].includes(String(value.upstreamState))
    || value.managerVersion !== APP_SERVER_MANAGER_VERSION
    || value.protocolVersion !== CODEX_APP_SERVER_PROTOCOL_VERSION
    || value.cliVersion !== CODEX_APP_SERVER_PROTOCOL_VERSION) {
    throw new AppServerManagerClientError('manager health contract is incompatible or malformed', 'protocol')
  }
  return value as unknown as ManagerHealthResponse
}

function validateHealthResponse(value: unknown): ManagerHealthResponse {
  const health = validateHealthContract(value)
  if (health.status !== 'ready'
    || health.phase !== 'idle'
    || health.upstreamReady !== true
    || health.upstreamState !== 'ready') {
    throw new AppServerManagerClientError('manager health is incompatible or not ready', 'protocol')
  }
  return health
}

/**
 * Validate the complete manager health envelope and the exact nonfatal global
 * state combinations a registered swarm may observe while another client or a
 * bounded lifecycle operation owns the serialized manager.
 */
export function validateManagerLivenessResponse(value: unknown): ManagerLiveness {
  const health = validateHealthContract(value)
  const upstreamReady = health.upstreamReady
  const upstreamState = health.upstreamState
  let disposition: ManagerLivenessDisposition | null = null
  if (health.status === 'ready' && health.phase === 'idle'
    && upstreamReady && upstreamState === 'ready') {
    disposition = 'ready'
  } else if (health.status === 'busy'
    && (health.phase === 'idle' || health.phase === 'reserved' || health.phase === 'active')
    && upstreamReady && upstreamState === 'ready') {
    disposition = 'shared-busy'
  } else if (health.status === 'cleanup-pending'
    && health.phase === 'terminal-cleanup-pending'
    && !upstreamReady && upstreamState === 'cleanup-pending') {
    // stopGeneration clears the generation handle synchronously before its
    // reap promise can yield, so cleanup-pending is never upstream-ready.
    disposition = 'shared-busy'
  } else if (health.status === 'review-pending'
    && (health.phase === 'completion-review-pending'
      || health.phase === 'completion-review-complete')
    && !upstreamReady && upstreamState === 'cleanup-pending') {
    disposition = 'shared-busy'
  } else if (health.status === 'drained' && health.phase === 'drained'
    && !upstreamReady && upstreamState === 'stopped') {
    disposition = 'maintenance'
  } else if (health.status === 'busy' && health.phase === 'starting'
    && ((upstreamReady && upstreamState === 'ready')
      || (!upstreamReady && upstreamState === 'stopped'))) {
    disposition = 'maintenance'
  }
  if (!disposition) {
    throw new AppServerManagerClientError(
      `manager liveness state is fatal or internally inconsistent (${health.status}/${health.phase})`,
      'protocol',
    )
  }
  return { health, disposition }
}

/** Tracks one fixed drain/resume window; changing drained -> starting does not reset it. */
export class ManagerLivenessMonitor {
  private maintenanceStartedAtMs: number | null = null

  observe(liveness: ManagerLiveness, nowMs = performance.now()): boolean {
    if (!Number.isFinite(nowMs) || nowMs < 0) {
      throw new TypeError('manager liveness timestamp must be a finite monotonic value')
    }
    if (liveness.disposition !== 'maintenance') {
      this.maintenanceStartedAtMs = null
      return true
    }
    if (this.maintenanceStartedAtMs === null) {
      this.maintenanceStartedAtMs = nowMs
      return false
    }
    if (nowMs < this.maintenanceStartedAtMs) {
      throw new AppServerManagerClientError('manager liveness clock moved backwards', 'state')
    }
    if (nowMs - this.maintenanceStartedAtMs >= MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS) {
      throw new AppServerManagerClientError(
        `manager maintenance exceeded ${MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS}ms`,
        'state',
      )
    }
    return false
  }
}

/** Bounds maintenance while heartbeat polling is suppressed by admission work. */
export class ManagerPreAdmissionMaintenanceMonitor {
  private maintenanceStartedAtMs: number | null = null

  observe(phase: ManagerPhase, nowMs = performance.now()): void {
    if (!Number.isFinite(nowMs) || nowMs < 0) {
      throw new TypeError('manager maintenance timestamp must be a finite monotonic value')
    }
    if (phase !== 'drained' && phase !== 'starting') {
      this.maintenanceStartedAtMs = null
      return
    }
    if (this.maintenanceStartedAtMs === null) this.maintenanceStartedAtMs = nowMs
    this.remaining(nowMs)
  }

  remaining(nowMs = performance.now()): number | null {
    if (this.maintenanceStartedAtMs === null) return null
    if (!Number.isFinite(nowMs) || nowMs < this.maintenanceStartedAtMs) {
      throw new AppServerManagerClientError('manager maintenance clock moved backwards', 'state')
    }
    const remaining = MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS
      - (nowMs - this.maintenanceStartedAtMs)
    if (remaining <= 0) {
      throw new AppServerManagerClientError(
        `manager maintenance exceeded ${MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS}ms`,
        'timeout',
      )
    }
    return remaining
  }
}

function validateTurnResponse(value: unknown): ManagerTurnStartResponse {
  if (!object(value)
    || !safeIdentifier(value.leaseId)
    || !safeIdentifier(value.threadId)
    || !safeIdentifier(value.turnId)
    || value.cleanupRequired !== true
    || !safeGeneration(value.generation)
    || !safeIdentifier(value.profile)
    || (value.rotation !== null && (
      !object(value.rotation)
      || !exactKeys(value.rotation, ['reason', 'previousProfile', 'activeProfile', 'parkedUntilMs'])
      || !['soft', 'hard'].includes(String(value.rotation.reason))
      || !safeIdentifier(value.rotation.previousProfile)
      || (value.rotation.activeProfile !== null && !safeIdentifier(value.rotation.activeProfile))
      || (value.rotation.parkedUntilMs !== null && !Number.isSafeInteger(value.rotation.parkedUntilMs))
    ))
    || !object(value.result)
    || typeof value.result.ok !== 'boolean'
    || value.result.threadId !== value.threadId
    || value.result.turnId !== value.turnId
    || !['completed', 'interrupted', 'failed', 'protocol', 'disconnected'].includes(
      String(value.result.status),
    )
    || !safeStringArray(value.result.messages, 256, 1024 * 1024)
    || typeof value.result.ambiguous !== 'boolean'
    || (value.result.quotaLimited !== undefined && value.result.quotaLimited !== true)
    || (value.result.error !== undefined && typeof value.result.error !== 'string')) {
    throw new AppServerManagerClientError('manager returned malformed turn result', 'protocol', true)
  }
  return value as unknown as ManagerTurnStartResponse
}

function validateReviewerScope(value: unknown): ManagerReviewerScopeResponse {
  const bounded = (candidate: unknown, min: number, max: number): boolean =>
    Number.isSafeInteger(candidate) && (candidate as number) >= min && (candidate as number) <= max
  if (!object(value)
    || !exactKeys(value, [
      'schema', 'slot', 'slot_token', 'early_review',
      'swarm', 'profile', 'task_id', 'state_dir', 'policy',
    ])
    || value.schema !== FABLE_REVIEWER_SCOPE_SCHEMA
    || value.slot !== FABLE_REVIEWER_SLOT
    || typeof value.slot_token !== 'string' || !/^[0-9a-f]{64}$/.test(value.slot_token)
    || value.early_review !== FABLE_EARLY_REVIEW_STATUS
    || typeof value.swarm !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value.swarm)
    || typeof value.profile !== 'string' || !/^[a-z][a-z0-9_-]{0,31}$/.test(value.profile)
    || !safeIdentifier(value.task_id) || typeof value.state_dir !== 'string'
    || !value.state_dir.startsWith('/') || value.state_dir.length > 4096 || value.state_dir.includes('\0')
    || !object(value.policy)
    || !exactKeys(value.policy, [
      'auth_lane', 'max_calls_per_task', 'max_calls_per_window', 'window_seconds',
      'timeout_seconds', 'failure_policy',
    ])
    || !['device', 'anthropic-api-key'].includes(String(value.policy.auth_lane))
    || value.policy.max_calls_per_task !== 1
    || !bounded(value.policy.max_calls_per_window, 1, 1_000)
    || !bounded(value.policy.window_seconds, 60, 3_600)
    || !bounded(value.policy.timeout_seconds, 1, 600)
    || value.policy.failure_policy !== 'review-pending') {
    throw new AppServerManagerClientError('manager returned malformed reviewer scope', 'protocol', true)
  }
  return value as unknown as ManagerReviewerScopeResponse
}

function validateCompletionReviewBegin(
  value: unknown,
  leaseId: string,
): ManagerCompletionReviewBeginResponse {
  if (!object(value) || !exactKeys(value, [
    'schema', 'status', 'leaseId', 'completionToken', 'expiresAtMs',
  ]) || value.schema !== MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA
    || value.status !== 'pending' || value.leaseId !== leaseId
    || typeof value.completionToken !== 'string' || !TOKEN.test(value.completionToken)
    || !Number.isSafeInteger(value.expiresAtMs) || (value.expiresAtMs as number) <= Date.now()) {
    throw new AppServerManagerClientError('manager returned malformed completion review admission', 'protocol', true)
  }
  return value as unknown as ManagerCompletionReviewBeginResponse
}

function validateCompletionReviewPoll(value: unknown): ManagerCompletionReviewPollResponse {
  if (!object(value)) {
    throw new AppServerManagerClientError('manager returned malformed completion review status', 'protocol', true)
  }
  if (exactKeys(value, ['status']) && value.status === 'pending') return { status: 'pending' }
  if (!exactKeys(value, [
    'status', 'reviewedDiffSha256', 'verdict', 'artifactName', 'artifactSha256',
  ]) || value.status !== 'complete'
    || typeof value.reviewedDiffSha256 !== 'string' || !TOKEN.test(value.reviewedDiffSha256)
    || !['approve', 'needs-changes', 'block', 'review-unavailable'].includes(String(value.verdict))
    || typeof value.artifactName !== 'string'
    || !/^(?:fable-review-[0-9]{8}T[0-9]{12}Z-[0-9a-f]{16}|fable-review-budget-exhausted)\.json$/.test(value.artifactName)
    || typeof value.artifactSha256 !== 'string' || !TOKEN.test(value.artifactSha256)) {
    throw new AppServerManagerClientError('manager returned malformed completion review status', 'protocol', true)
  }
  return value as unknown as ManagerCompletionReviewPollResponse
}

export function managerTurnResponseToCodexResult(
  response: ManagerTurnStartResponse,
  cancelKind: CancelKind = null,
): CodexTurnResult {
  const terminal = response.result
  const messages = [...terminal.messages]
  if (terminal.ok && terminal.status === 'completed' && !terminal.ambiguous) {
    return { ok: true, threadId: response.threadId, messages }
  }
  const error = (terminal.error || (
    terminal.status === 'interrupted' ? 'turn interrupted'
      : terminal.status === 'disconnected' ? 'manager connection lost during turn'
        : terminal.status === 'protocol' ? 'Codex App Server protocol failure'
          : 'Codex App Server turn failed'
  )).slice(0, 4096)
  let errorKind: CodexFailureKind
  if (terminal.quotaLimited === true) errorKind = 'usage-limit'
  else if (isMissingThreadError(error)) errorKind = 'missing-thread'
  else if (terminal.status === 'interrupted' && cancelKind) errorKind = cancelKind
  else if (terminal.status === 'interrupted') errorKind = 'aborted'
  else if (terminal.status === 'disconnected' || terminal.status === 'protocol' || terminal.ambiguous) {
    errorKind = 'protocol'
  } else errorKind = 'turn-failed'
  return { ok: false, threadId: response.threadId, messages, error, errorKind }
}

export function managerClientErrorToCodexResult(
  error: unknown,
  threadId: string | null,
): CodexTurnResult {
  const managerError = error instanceof AppServerManagerClientError ? error : null
  const detail = (error instanceof Error ? error.message : String(error)).slice(0, 4096)
  const errorKind: CodexFailureKind = managerError?.kind === 'timeout'
    ? 'timeout'
    : managerError?.kind === 'transport' || managerError?.kind === 'protocol'
      ? 'protocol'
      : 'spawn'
  return { ok: false, threadId, messages: [], error: detail, errorKind }
}

export class AppServerManagerClient {
  readonly socketPath: string
  private readonly socketIdentity: UnixSocketIdentity
  private readonly requestTimeoutMs: number
  private readonly interruptGraceMs: number
  private readonly maxRequestBytes: number
  private readonly maxTurnRequestBytes: number
  private readonly maxResponseBytes: number
  private readonly leaseAgent: Agent
  private readonly controlAgent: Agent
  private registrationToken: string | null = null
  private registrationInFlight = false
  private facadeSocketPath: string | null = null
  private facadeSocketIdentity: UnixSocketIdentity | null = null
  private reservationRequestId: string | null = null
  private reservationToken: string | null = null
  private reservationExpiresAtMs: number | null = null
  private reservationCancelable = false
  private activeRequestId: string | null = null
  private activeLeaseId: string | null = null
  private closed = false
  private faulted = false

  constructor(options: AppServerManagerClientOptions) {
    this.socketPath = options.socketPath
    try {
      assertOwnerPrivateSocketParent(this.socketPath)
      this.socketIdentity = attestOwnerUnixSocket(this.socketPath)
    } catch (error) {
      throw new AppServerManagerClientError(`unsafe manager socket: ${error}`, 'boundary')
    }
    this.requestTimeoutMs = boundedInteger(
      options.requestTimeoutMs, DEFAULT_REQUEST_TIMEOUT_MS, 100, 120_000, 'requestTimeoutMs',
    )
    this.interruptGraceMs = boundedInteger(
      options.interruptGraceMs, DEFAULT_INTERRUPT_GRACE_MS, 100, 120_000, 'interruptGraceMs',
    )
    this.maxRequestBytes = boundedInteger(
      options.maxRequestBytes, DEFAULT_REQUEST_BYTES, 1024, 1024 * 1024, 'maxRequestBytes',
    )
    this.maxTurnRequestBytes = boundedInteger(
      options.maxTurnRequestBytes,
      DEFAULT_TURN_REQUEST_BYTES,
      1024 * 1024,
      80 * 1024 * 1024,
      'maxTurnRequestBytes',
    )
    this.maxResponseBytes = boundedInteger(
      options.maxResponseBytes, DEFAULT_RESPONSE_BYTES, 1024, 8 * 1024 * 1024, 'maxResponseBytes',
    )
    this.leaseAgent = new Agent({ keepAlive: true, maxSockets: 1, maxFreeSockets: 1 })
    this.controlAgent = new Agent({ keepAlive: false, maxSockets: 2 })
  }

  get isRegistered(): boolean { return this.registrationToken !== null }
  get hasTurnReservation(): boolean { return this.reservationToken !== null }
  get hasActiveLease(): boolean {
    return this.reservationRequestId !== null
      || this.activeRequestId !== null
      || this.activeLeaseId !== null
  }

  async health(): Promise<ManagerHealthResponse> {
    const value = await this.requestJson('GET', '/v1/health', undefined, {
      agent: this.controlAgent,
      timeoutMs: this.requestTimeoutMs,
    })
    return validateHealthResponse(value)
  }

  async liveness(): Promise<ManagerLiveness> {
    this.attestRegisteredFacade()
    const value = await this.requestJson('GET', '/v1/health', undefined, {
      agent: this.controlAgent,
      timeoutMs: this.requestTimeoutMs,
    })
    this.attestRegisteredFacade()
    return validateManagerLivenessResponse(value)
  }

  async register(
    request: ManagerRegisterRequest,
    options: ManagerPreAdmissionOptions = {},
  ): Promise<ManagerRegisterResponse> {
    if (this.closed || this.faulted) {
      throw new AppServerManagerClientError('manager client is closed or faulted', 'state')
    }
    if (this.registrationToken || this.registrationInFlight || this.hasActiveLease) {
      throw new AppServerManagerClientError('manager client is already registered', 'state')
    }
    if (options.signal?.aborted) {
      throw new AppServerManagerClientError('manager registration aborted before admission', 'state')
    }
    const body = Object.freeze({
      swarm: request.swarm,
      repo: request.repo,
      stateDir: request.stateDir,
      ...(request.sessions === undefined ? {} : { sessions: Object.freeze([...request.sessions]) }),
      ...(request.model === undefined ? {} : { model: request.model }),
      ...(request.reasoningEffort === undefined ? {} : { reasoningEffort: request.reasoningEffort }),
      ...(request.profile === undefined ? {} : { profile: request.profile }),
    }) as ManagerRegisterRequest
    const expectedReasoningEffort = request.reasoningEffort ?? DEFAULT_CODEX_REASONING_EFFORT
    const timeoutMs = boundedInteger(
      options.timeoutMs, this.requestTimeoutMs, 100, 86_400_000, 'registration timeoutMs',
    )
    this.registrationInFlight = true
    try {
      const response = await this.retryPreAdmissionRequest(
        '/v1/register', body, timeoutMs, options.signal,
        value => validateRegisterResponse(value, expectedReasoningEffort), false,
      )
      this.registrationToken = response.registrationToken
      try {
        this.pinRegisteredFacade(response.facadeEndpoint)
      } catch (error) {
        this.faulted = true
        throw new AppServerManagerClientError(
          `manager facade attestation failed after registration: ${error}`,
          'boundary',
          true,
        )
      }
      return response
    } catch (error) {
      if (error instanceof AppServerManagerClientError && error.ambiguous) this.faulted = true
      throw error
    } finally {
      this.registrationInFlight = false
    }
  }

  async replaceSessions(sessions: readonly ManagerSessionId[]): Promise<ManagerSessionsReplaceResponse> {
    const registrationToken = this.requireToken()
    const unique = [...new Set(sessions)]
    if (unique.length !== sessions.length || !safeStringArray(unique, 256, 256)
      || unique.some(session => !safeIdentifier(session))) {
      throw new AppServerManagerClientError('manager sessions must be unique bounded ids', 'state')
    }
    const body = { registrationToken, sessions: unique } as ManagerSessionsReplaceRequest
    const value = await this.requestJson('POST', '/v1/sessions/replace', body, {
      agent: this.controlAgent,
      timeoutMs: this.requestTimeoutMs,
    })
    if (!object(value)
      || !exactKeys(value, ['generation', 'facadeEndpoint', 'sessionCount'])
      || !safeGeneration(value.generation)
      || typeof value.facadeEndpoint !== 'string' || !value.facadeEndpoint.startsWith('unix:///')
      || !Number.isSafeInteger(value.sessionCount) || (value.sessionCount as number) !== unique.length) {
      throw new AppServerManagerClientError('manager returned malformed session sync', 'protocol')
    }
    return value as unknown as ManagerSessionsReplaceResponse
  }

  async reserveTurn(options: ManagerPreAdmissionOptions = {}): Promise<ManagerTurnReserveResponse> {
    if (this.hasActiveLease) {
      throw new AppServerManagerClientError('manager client already has a turn reservation or lease', 'state')
    }
    if (options.signal?.aborted) {
      throw new AppServerManagerClientError('manager turn reservation aborted before admission', 'state')
    }
    const registrationToken = this.requireToken()
    const requestId = randomBytes(16).toString('hex')
    const body = Object.freeze({ registrationToken, requestId }) as ManagerTurnReserveRequest
    const timeoutMs = boundedInteger(
      options.timeoutMs, this.requestTimeoutMs, 100, 86_400_000, 'reservation timeoutMs',
    )
    this.reservationRequestId = requestId
    try {
      const response = await this.retryPreAdmissionRequest(
        '/v1/turn/reserve', body, timeoutMs, options.signal,
        value => validateReservationResponse(value, requestId), true,
      )
      this.reservationToken = response.reservationToken
      this.reservationExpiresAtMs = response.expiresAtMs
      this.reservationCancelable = true
      return response
    } catch (error) {
      if (error instanceof AppServerManagerClientError && error.ambiguous) this.faulted = true
      if (!this.faulted) this.clearReservation()
      throw error
    }
  }

  async cancelTurnReservation(
    options: ManagerPreAdmissionOptions = {},
  ): Promise<ManagerTurnReservationCancelResponse | null> {
    if (this.activeRequestId || this.activeLeaseId) {
      throw new AppServerManagerClientError('cannot cancel a reservation with an active turn lease', 'state')
    }
    if (this.reservationRequestId === null && this.reservationToken === null) return null
    const requestId = this.reservationRequestId
    const reservationToken = this.reservationToken
    if (!requestId || !reservationToken || this.reservationExpiresAtMs === null
      || !this.reservationCancelable) {
      throw new AppServerManagerClientError('turn reservation outcome is not cancelable', 'state', true)
    }
    const registrationToken = this.registrationToken
    if (!registrationToken) {
      throw new AppServerManagerClientError('turn reservation registration is unavailable', 'state', true)
    }
    const body = Object.freeze({
      registrationToken, reservationToken, requestId,
    }) as ManagerTurnReservationCancelRequest
    const timeoutMs = boundedInteger(
      options.timeoutMs, this.requestTimeoutMs, 100, 86_400_000, 'reservation cancel timeoutMs',
    )
    try {
      const value = await this.retryPreAdmissionRequest(
        '/v1/turn/reservation-cancel', body, timeoutMs, options.signal,
        candidate => {
          if (!object(candidate) || !exactKeys(candidate, ['cancelled'])
            || candidate.cancelled !== true) {
            throw new AppServerManagerClientError(
              'manager returned malformed reservation cancellation', 'protocol', true,
            )
          }
          return candidate as unknown as ManagerTurnReservationCancelResponse
        },
        true,
        true,
        false,
      )
      this.clearReservation()
      return value
    } catch (error) {
      if (error instanceof AppServerManagerClientError && error.ambiguous) this.faulted = true
      throw error
    }
  }

  async runTurn(
    request: Omit<ManagerTurnStartRequest, 'registrationToken' | 'reservationToken' | 'requestId'>,
    options: ManagerTurnRunOptions,
  ): Promise<ManagerTurnExecution> {
    if (this.activeRequestId || this.activeLeaseId) {
      throw new AppServerManagerClientError('manager client already has an active turn lease', 'state')
    }
    if (!Number.isSafeInteger(options.timeoutMs) || options.timeoutMs < 100 || options.timeoutMs > 86_400_000) {
      throw new AppServerManagerClientError('manager turn timeout is out of bounds', 'state')
    }
    if (options.signal?.aborted) {
      throw new AppServerManagerClientError('manager turn aborted before start', 'state')
    }
    const registrationToken = this.requireToken()
    const requestId = this.reservationRequestId
    const reservationToken = this.reservationToken
    if (!requestId || !reservationToken || this.reservationExpiresAtMs === null) {
      throw new AppServerManagerClientError('manager turn requires an active reservation', 'state')
    }
    this.activeRequestId = requestId
    let cancelKind: CancelKind = null
    let interruptSent = false
    const forceStop = new AbortController()
    let forceStopTimer: ReturnType<typeof setTimeout> | null = null
    const emit = (event: CodexEventSummary): void => {
      try { options.onEvent?.(event) } catch {}
    }
    const requestInterrupt = (kind: Exclude<CancelKind, null>): void => {
      if (interruptSent) return
      interruptSent = true
      cancelKind = kind
      void this.interrupt(requestId).catch(() => {})
      forceStopTimer = setTimeout(() => forceStop.abort(), this.interruptGraceMs)
      forceStopTimer.unref?.()
    }
    const onAbort = () => requestInterrupt('aborted')
    options.signal?.addEventListener('abort', onAbort, { once: true })
    if (options.signal?.aborted) onAbort()
    const timeout = setTimeout(() => requestInterrupt('timeout'), options.timeoutMs)
    timeout.unref?.()
    emit({ type: 'turn.started', status: 'manager' })
    try {
      const body = {
        ...request, registrationToken, reservationToken, requestId,
      } as ManagerTurnStartRequest
      const response = validateTurnResponse(await this.requestJson('POST', '/v1/turn/start', body, {
        agent: this.leaseAgent,
        timeoutMs: options.timeoutMs + this.interruptGraceMs,
        ambiguousOnLoss: true,
        abortSignal: forceStop.signal,
        maxRequestBytes: this.maxTurnRequestBytes,
      }))
      this.clearReservation()
      this.activeLeaseId = response.leaseId
      emit({
        type: response.result.status === 'completed' ? 'turn.completed' : 'turn.failed',
        status: response.result.status,
      })
      return {
        leaseId: response.leaseId,
        response,
        result: managerTurnResponseToCodexResult(response, cancelKind),
      }
    } catch (error) {
      if (error instanceof AppServerManagerClientError) {
        if (error.ambiguous) this.faulted = true
      } else {
        this.faulted = true
      }
      throw error
    } finally {
      clearTimeout(timeout)
      if (forceStopTimer) clearTimeout(forceStopTimer)
      options.signal?.removeEventListener('abort', onAbort)
      this.activeRequestId = null
    }
  }

  async beginCompletionReview(
    leaseId: string,
    reviewedDiffSha256: string,
    argumentsValue: ManagerCompletionReviewArguments,
  ): Promise<ManagerCompletionReviewBeginResponse> {
    if (!safeIdentifier(leaseId) || leaseId !== this.activeLeaseId
      || typeof reviewedDiffSha256 !== 'string' || !TOKEN.test(reviewedDiffSha256)) {
      throw new AppServerManagerClientError('completion review does not match the active manager lease', 'state')
    }
    const body: ManagerCompletionReviewBeginRequest = {
      schema: MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA,
      registrationToken: this.requireToken(),
      leaseId,
      reviewedDiffSha256,
      arguments: argumentsValue,
    }
    try {
      return validateCompletionReviewBegin(await this.requestJson(
        'POST', '/v1/reviewer/completion/begin', body,
        {
          agent: this.leaseAgent,
          timeoutMs: this.requestTimeoutMs,
          maxRequestBytes: this.maxTurnRequestBytes,
          ambiguousOnLoss: true,
        },
      ), leaseId)
    } catch (error) {
      if (error instanceof AppServerManagerClientError && error.ambiguous) this.faulted = true
      throw error
    }
  }

  async completionReviewStatus(
    leaseId: string,
    completionToken: string,
  ): Promise<ManagerCompletionReviewPollResponse> {
    if (!safeIdentifier(leaseId) || leaseId !== this.activeLeaseId || !TOKEN.test(completionToken)) {
      throw new AppServerManagerClientError('completion review poll does not match the active manager lease', 'state')
    }
    const body: ManagerCompletionReviewPollRequest = {
      registrationToken: this.requireToken(), leaseId, completionToken,
    }
    return validateCompletionReviewPoll(await this.requestJson(
      'POST', '/v1/reviewer/completion/status', body,
      { agent: this.controlAgent, timeoutMs: this.requestTimeoutMs },
    ))
  }

  async endCompletionReview(
    leaseId: string,
    completionToken: string,
  ): Promise<ManagerCompletionReviewEndResponse> {
    if (!safeIdentifier(leaseId) || leaseId !== this.activeLeaseId || !TOKEN.test(completionToken)) {
      throw new AppServerManagerClientError('completion review end does not match the active manager lease', 'state')
    }
    const body: ManagerCompletionReviewEndRequest = {
      registrationToken: this.requireToken(), leaseId, completionToken,
    }
    try {
      const value = await this.requestJson('POST', '/v1/reviewer/completion/end', body, {
        agent: this.leaseAgent,
        timeoutMs: this.requestTimeoutMs,
        ambiguousOnLoss: true,
      })
      if (!object(value) || !exactKeys(value, ['ended', 'leaseId'])
        || value.ended !== true || value.leaseId !== leaseId) {
        throw new AppServerManagerClientError('manager returned malformed completion review end', 'protocol', true)
      }
      return value as unknown as ManagerCompletionReviewEndResponse
    } catch (error) {
      this.faulted = true
      throw error
    }
  }

  async cleanupComplete(leaseId: string, ok: boolean): Promise<ManagerTurnCleanupResponse> {
    if (!safeIdentifier(leaseId) || leaseId !== this.activeLeaseId) {
      throw new AppServerManagerClientError('cleanup does not match the active manager lease', 'state')
    }
    const body = {
      registrationToken: this.requireToken(),
      leaseId,
      ok,
    } as ManagerTurnCleanupRequest
    try {
      // Let the completed turn response settle before cleanup. Bun may use a
      // different Unix client socket for the acknowledgement; the lease and
      // registration capabilities, not physical socket reuse, authorize it.
      await new Promise<void>(resolveReady => setTimeout(resolveReady, 0))
      const value = await this.requestJson('POST', '/v1/turn/cleanup-complete', body, {
        agent: this.leaseAgent,
        timeoutMs: this.requestTimeoutMs,
        ambiguousOnLoss: true,
      })
      if (!object(value)
        || !exactKeys(value, ['generation', 'ready', 'activeProfile', 'parkedUntilMs'])
        || !safeGeneration(value.generation)
        || value.ready !== true
        || (value.activeProfile !== null && !safeIdentifier(value.activeProfile))
        || (value.parkedUntilMs !== null && !Number.isSafeInteger(value.parkedUntilMs))) {
        throw new AppServerManagerClientError('manager returned malformed cleanup ack', 'protocol', true)
      }
      return value as unknown as ManagerTurnCleanupResponse
    } catch (error) {
      this.faulted = true
      throw error
    } finally {
      this.activeLeaseId = null
      if (!ok) this.faulted = true
    }
  }

  /** Resolve only metadata trusted by the manager for the currently active turn. */
  async reviewerScope(slotToken?: string): Promise<ManagerReviewerScopeResponse> {
    if (!this.activeRequestId) {
      throw new AppServerManagerClientError('reviewer scope requires an active turn', 'state')
    }
    if (slotToken !== undefined && !/^[0-9a-f]{64}$/.test(slotToken)) {
      throw new AppServerManagerClientError('reviewer slot token is malformed', 'state')
    }
    const body: ManagerReviewerScopeRequest = {
      schema: FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA,
      ...(slotToken === undefined ? {} : { slot_token: slotToken }),
    }
    return validateReviewerScope(await this.requestJson('POST', '/v1/reviewer/scope', body, {
      // The turn response holds the one-socket lease agent. Reviewer metadata
      // is a concurrent, read-only control request on its own local socket.
      agent: this.controlAgent,
      timeoutMs: this.requestTimeoutMs,
      maxRequestBytes: this.maxRequestBytes,
    }))
  }

  async unregister(
    options: ManagerPreAdmissionOptions = {},
  ): Promise<ManagerUnregisterResponse | null> {
    if (!this.registrationToken) return null
    if (this.hasActiveLease) throw new AppServerManagerClientError('cannot unregister with an active lease', 'state')
    const body = Object.freeze({
      registrationToken: this.registrationToken,
    }) as ManagerUnregisterRequest
    const timeoutMs = boundedInteger(
      options.timeoutMs, this.requestTimeoutMs, 100, 86_400_000, 'unregister timeoutMs',
    )
    try {
      const value = await this.retryPreAdmissionRequest(
        '/v1/unregister', body, timeoutMs, options.signal,
        candidate => {
          if (!object(candidate) || !exactKeys(candidate, ['removed']) || candidate.removed !== true) {
            throw new AppServerManagerClientError(
              'manager returned malformed unregister ack', 'protocol', true,
            )
          }
          return candidate as unknown as ManagerUnregisterResponse
        },
        false,
      )
      this.registrationToken = null
      this.facadeSocketPath = null
      this.facadeSocketIdentity = null
      return value
    } catch (error) {
      if (error instanceof AppServerManagerClientError && error.ambiguous) this.faulted = true
      throw error
    }
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    if (this.registrationInFlight || this.reservationRequestId !== null) this.faulted = true
    this.leaseAgent.destroy()
    this.controlAgent.destroy()
  }

  private clearReservation(): void {
    this.reservationRequestId = null
    this.reservationToken = null
    this.reservationExpiresAtMs = null
    this.reservationCancelable = false
  }

  private pinRegisteredFacade(endpoint: string): void {
    const socketPath = endpoint.slice('unix://'.length)
    assertOwnerPrivateSocketParent(socketPath)
    const identity = attestOwnerUnixSocket(socketPath)
    this.facadeSocketPath = socketPath
    this.facadeSocketIdentity = identity
  }

  private attestRegisteredFacade(): void {
    if (!this.registrationToken) return
    const socketPath = this.facadeSocketPath
    const expected = this.facadeSocketIdentity
    if (!socketPath || !expected) {
      this.faulted = true
      throw new AppServerManagerClientError('registered manager facade identity is absent', 'boundary')
    }
    let observed: UnixSocketIdentity
    try {
      assertOwnerPrivateSocketParent(socketPath)
      observed = attestOwnerUnixSocket(socketPath)
    } catch (error) {
      this.faulted = true
      throw new AppServerManagerClientError(`registered manager facade attestation failed: ${error}`, 'boundary')
    }
    if (!sameUnixSocket(expected, observed)) {
      this.faulted = true
      throw new AppServerManagerClientError('registered manager facade identity changed', 'boundary')
    }
  }

  private retryablePreAdmissionConflict(error: unknown): error is AppServerManagerClientError {
    return error instanceof AppServerManagerClientError
      && error.kind === 'remote'
      && error.ambiguous === false
      && error.remoteHttpStatus === 409
      && error.remoteRetryable === true
      && error.remotePoolExhausted === false
      && error.remotePhase !== null
      && RETRYABLE_PRE_ADMISSION_PHASES.has(error.remotePhase)
  }

  private async retryPreAdmissionRequest<T>(
    path: '/v1/register' | '/v1/unregister' | '/v1/turn/reserve' | '/v1/turn/reservation-cancel',
    body: ManagerRegisterRequest | ManagerUnregisterRequest
      | ManagerTurnReserveRequest | ManagerTurnReservationCancelRequest,
    timeoutMs: number,
    signal: AbortSignal | undefined,
    validate: (value: unknown) => T,
    retryAmbiguousTransportLoss: boolean,
    allowFaulted = false,
    enforceMaintenanceDeadline = true,
  ): Promise<T> {
    const deadline = performance.now() + timeoutMs
    const maintenance = enforceMaintenanceDeadline
      ? new ManagerPreAdmissionMaintenanceMonitor()
      : null
    let sawAmbiguousLoss = false
    let ambiguousLossStartedAtMs: number | null = null
    const ambiguityRemaining = (nowMs: number): number => {
      if (ambiguousLossStartedAtMs === null) return Number.POSITIVE_INFINITY
      const remaining = MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS
        - (nowMs - ambiguousLossStartedAtMs)
      if (remaining <= 0) {
        throw new AppServerManagerClientError(
          `manager ambiguous response loss exceeded ${MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS}ms`,
          'timeout',
          true,
        )
      }
      return remaining
    }
    while (true) {
      if (signal?.aborted) {
        throw new AppServerManagerClientError(
          'manager pre-admission request aborted', 'state', sawAmbiguousLoss,
        )
      }
      const nowMs = performance.now()
      const maintenanceRemaining = maintenance?.remaining(nowMs) ?? Number.POSITIVE_INFINITY
      const remaining = Math.ceil(Math.min(
        deadline - nowMs,
        maintenanceRemaining,
        ambiguityRemaining(nowMs),
      ))
      if (remaining <= 0) {
        throw new AppServerManagerClientError(
          `manager pre-admission wait timed out after ${timeoutMs}ms`, 'timeout', sawAmbiguousLoss,
        )
      }
      try {
        const value = await this.requestJson('POST', path, body, {
          agent: this.controlAgent,
          timeoutMs: Math.max(1, Math.min(this.requestTimeoutMs, remaining)),
          ambiguousOnLoss: true,
          abortSignal: signal,
          allowFaulted,
        })
        return validate(value)
      } catch (error) {
        const managerError = error instanceof AppServerManagerClientError ? error : null
        const retryableLoss = retryAmbiguousTransportLoss
          && !signal?.aborted
          && managerError?.ambiguous === true
          && (managerError.kind === 'transport' || managerError.kind === 'timeout')
        if (retryableLoss) {
          sawAmbiguousLoss = true
          if (ambiguousLossStartedAtMs === null) ambiguousLossStartedAtMs = performance.now()
        } else if (this.retryablePreAdmissionConflict(error)) {
          // Exact idempotent replay would return 200 if this immutable request
          // owned a reservation/cancellation. A validated contention response
          // therefore proves non-admission and ends the unknown-outcome window.
          sawAmbiguousLoss = false
          ambiguousLossStartedAtMs = null
          maintenance?.observe(error.remotePhase!)
        } else if (sawAmbiguousLoss && managerError && !managerError.ambiguous) {
          throw new AppServerManagerClientError(
            managerError.message,
            managerError.kind,
            true,
            managerError.remoteHttpStatus,
            managerError.remotePhase,
            managerError.remoteRetryable,
            managerError.remotePoolExhausted,
            managerError.remoteParkedUntilMs,
          )
        } else throw error
      }
      const retryNowMs = performance.now()
      const maintenanceRetryRemaining = maintenance?.remaining(retryNowMs)
        ?? Number.POSITIVE_INFINITY
      const retryRemaining = Math.ceil(Math.min(
        deadline - retryNowMs,
        maintenanceRetryRemaining,
        ambiguityRemaining(retryNowMs),
      ))
      if (retryRemaining <= 0) {
        throw new AppServerManagerClientError(
          `manager pre-admission wait timed out after ${timeoutMs}ms`, 'timeout', sawAmbiguousLoss,
        )
      }
      await this.waitForPreAdmissionRetry(
        Math.min(PRE_ADMISSION_RETRY_DELAY_MS, retryRemaining), signal, sawAmbiguousLoss,
      )
    }
  }

  private waitForPreAdmissionRetry(
    delayMs: number,
    signal: AbortSignal | undefined,
    ambiguous: boolean,
  ): Promise<void> {
    return new Promise((resolveWait, rejectWait) => {
      let timer: ReturnType<typeof setTimeout> | null = null
      const finish = (error?: AppServerManagerClientError) => {
        if (timer) clearTimeout(timer)
        signal?.removeEventListener('abort', onAbort)
        if (error) rejectWait(error)
        else resolveWait()
      }
      const onAbort = () => finish(new AppServerManagerClientError(
        'manager pre-admission request aborted', 'state', ambiguous,
      ))
      signal?.addEventListener('abort', onAbort, { once: true })
      if (signal?.aborted) {
        onAbort()
        return
      }
      timer = setTimeout(() => finish(), delayMs)
      timer.unref?.()
    })
  }

  private async interrupt(requestId: string): Promise<ManagerTurnInterruptResponse> {
    const body = {
      registrationToken: this.requireToken(),
      requestId,
    } as ManagerTurnInterruptRequest
    const value = await this.requestJson('POST', '/v1/turn/interrupt', body, {
      agent: this.controlAgent,
      timeoutMs: this.requestTimeoutMs,
    })
    if (!object(value)
      || !exactKeys(value, ['accepted', 'threadId', 'turnId'])
      || value.accepted !== true || !safeIdentifier(value.threadId) || !safeIdentifier(value.turnId)) {
      throw new AppServerManagerClientError('manager returned malformed interrupt ack', 'protocol')
    }
    return value as unknown as ManagerTurnInterruptResponse
  }

  private requireToken(): string {
    if (this.closed || this.faulted) throw new AppServerManagerClientError('manager client is not usable', 'state')
    if (!this.registrationToken) throw new AppServerManagerClientError('manager client is not registered', 'state')
    return this.registrationToken
  }

  private attestSocket(): void {
    let observed: UnixSocketIdentity
    try { observed = attestOwnerUnixSocket(this.socketPath) } catch (error) {
      this.faulted = true
      throw new AppServerManagerClientError(`manager socket attestation failed: ${error}`, 'boundary')
    }
    if (!sameUnixSocket(this.socketIdentity, observed)) {
      this.faulted = true
      throw new AppServerManagerClientError('manager socket identity changed', 'boundary')
    }
  }

  private requestJson(
    method: 'GET' | 'POST',
    path: string,
    body: unknown,
    options: RequestOptions,
  ): Promise<unknown> {
    if (this.closed || (this.faulted && !options.allowFaulted)) {
      return Promise.reject(new AppServerManagerClientError('manager client is closed or faulted', 'state'))
    }
    this.attestSocket()
    let serialized = ''
    if (body !== undefined) {
      try { serialized = JSON.stringify(body) } catch {
        return Promise.reject(new AppServerManagerClientError('manager request is not JSON serializable', 'state'))
      }
      if (encoder.encode(serialized).byteLength > (options.maxRequestBytes ?? this.maxRequestBytes)) {
        return Promise.reject(new AppServerManagerClientError('manager request exceeds byte bound', 'state'))
      }
    }
    const maxResponseBytes = options.maxResponseBytes ?? this.maxResponseBytes
    return new Promise((resolveRequest, rejectRequest) => {
      let settled = false
      let timer: ReturnType<typeof setTimeout> | null = null
      const finish = (error?: Error, value?: unknown) => {
        if (settled) return
        settled = true
        if (timer) clearTimeout(timer)
        if (error) rejectRequest(error)
        else resolveRequest(value)
      }
      const req = httpRequest({
        socketPath: this.socketPath,
        path,
        method,
        agent: options.agent,
        headers: body === undefined ? { accept: 'application/json' } : {
          accept: 'application/json',
          'content-type': 'application/json',
          'content-length': String(Buffer.byteLength(serialized)),
        },
      })
      req.once('response', (response: IncomingMessage) => {
        const chunks: Buffer[] = []
        let bytes = 0
        const contentType = String(response.headers['content-type'] ?? '').split(';', 1)[0]!.trim()
        if (contentType !== 'application/json' || response.headers['content-encoding']) {
          response.resume()
          finish(new AppServerManagerClientError('manager response is not unencoded JSON', 'protocol', Boolean(options.ambiguousOnLoss)))
          return
        }
        const declared = Number(response.headers['content-length'] ?? 0)
        if ((declared && (!Number.isSafeInteger(declared) || declared > maxResponseBytes))) {
          response.destroy()
          finish(new AppServerManagerClientError('manager response exceeds byte bound', 'protocol', Boolean(options.ambiguousOnLoss)))
          return
        }
        response.on('data', chunk => {
          if (settled) return
          const value = Buffer.from(chunk)
          bytes += value.byteLength
          if (bytes > maxResponseBytes) {
            response.destroy()
            finish(new AppServerManagerClientError('manager response exceeds byte bound', 'protocol', Boolean(options.ambiguousOnLoss)))
            return
          }
          chunks.push(value)
        })
        response.once('end', () => {
          if (settled) return
          let value: unknown
          try { value = JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch {
            finish(new AppServerManagerClientError('manager response is malformed JSON', 'protocol', Boolean(options.ambiguousOnLoss)))
            return
          }
          if ((response.statusCode ?? 500) < 200 || (response.statusCode ?? 500) >= 300) {
            const remote = value as ManagerErrorResponse
            const metadata = remoteErrorMetadata(remote, response.statusCode ?? 500)
            if (!metadata) {
              finish(new AppServerManagerClientError(
                'manager returned malformed error response',
                'protocol',
                Boolean(options.ambiguousOnLoss),
              ))
              return
            }
            finish(new AppServerManagerClientError(
              managerErrorDetail(remote, response.statusCode ?? 500),
              'remote',
              metadata?.phase === 'ambiguous',
              metadata?.status ?? null,
              metadata?.phase ?? null,
              metadata?.retryable ?? null,
              metadata?.poolExhausted ?? false,
              metadata?.parkedUntilMs ?? null,
            ))
            return
          }
          finish(undefined, value)
        })
        response.once('error', error => finish(new AppServerManagerClientError(
          `manager response failed: ${error.message}`, 'transport', Boolean(options.ambiguousOnLoss),
        )))
      })
      req.once('error', error => finish(error instanceof AppServerManagerClientError ? error
        : new AppServerManagerClientError(
          `manager request failed: ${error.message}`, 'transport', Boolean(options.ambiguousOnLoss),
        )))
      const onAbort = () => req.destroy(new AppServerManagerClientError(
        'manager turn did not terminate after interrupt grace', 'timeout', true,
      ))
      options.abortSignal?.addEventListener('abort', onAbort, { once: true })
      req.once('close', () => options.abortSignal?.removeEventListener('abort', onAbort))
      timer = setTimeout(() => {
        req.destroy(new AppServerManagerClientError(
          `manager request timed out after ${options.timeoutMs}ms`, 'timeout', Boolean(options.ambiguousOnLoss),
        ))
      }, options.timeoutMs)
      timer.unref?.()
      req.end(serialized || undefined)
    })
  }
}
