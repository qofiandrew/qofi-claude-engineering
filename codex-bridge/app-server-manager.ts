/**
 * Operator-owned singleton manager for one hidden-UID Codex App Server.
 *
 * The upstream exists only on inherited JSONL stdio.  Daemons use a private
 * Unix HTTP control socket; native TUIs use per-swarm read-only Unix-WebSocket
 * facades.  Every terminal operation stops the upstream generation so the
 * root runner reaps the entire hidden UID before caller cleanup is acknowledged.
 */

import { createHash, randomBytes } from 'crypto'
import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { createServer, type IncomingMessage, type ServerResponse } from 'http'
import { userInfo } from 'os'
import { basename, dirname, isAbsolute, join, resolve, sep } from 'path'
import type { Socket } from 'net'
import {
  AppServerProtocolError,
  AppServerRemoteError,
  AppServerRequestError,
  CODEX_APP_SERVER_PROTOCOL_VERSION,
  CodexAppServerClient,
  type AppServerEffectiveThread,
  type AppServerNotification,
  type AppServerThread,
  type AppServerTurnHandle,
  type AppServerTurnResult,
  type JsonValue,
} from './app-server-client.ts'
import {
  JsonLineStdioTransport,
  readFixedProfileTelemetry,
  spawnFixedAppServerRunner,
  spawnFixedReviewRunner,
  type FixedReviewExecution,
  type FixedReviewRunner,
  type FixedReviewRunnerResult,
} from './app-server-stdio-transport.ts'
import {
  CodexNativeReadOnlyFacade,
  appServerNotificationThreadId,
} from './app-server-native-facade.ts'
import {
  closeOwnedUnixServer,
  listenOwnerUnixSocket,
  type UnixSocketIdentity,
} from './app-server-unix-socket.ts'
import { buildAppServerThreadConfig, CODEX_PERMISSION_PROFILE } from './codex.ts'
import {
  DEFAULT_CODEX_MODEL,
  DEFAULT_CODEX_REASONING_EFFORT,
  isManagedCodexReasoningEffort,
  type ManagedCodexReasoningEffort,
} from './model.ts'
import { assertNoExtendedAcl, validatePrivateStateBoundary } from './security.ts'
import { discoverWorkspacePolicy } from './workspace.ts'
import {
  DEFAULT_ROTATION_THRESHOLD_PERCENT,
  decideHardLimitCooldown,
  decideSoftCooldown,
  leasesFromHarnessState,
  profileHeadroom,
  parseRolloutTelemetry,
  rotateSwarmProfile,
  chooseProfileForSwarm,
  validateProfilePool,
  validateProfileRegistry,
  type ProfilePoolDeclaration,
  type ProfileRegistryEntry,
  type QuotaTelemetry,
  type RotationHarnessState,
  type SwarmProfileState,
  MAX_TELEMETRY_AGE_MS,
} from './profile-rotation.ts'
import {
  FABLE_ONE_SHOT_REQUEST_SCHEMA,
  FABLE_ONE_SHOT_RESULT_SCHEMA,
  spawnFixedFableCompletionReview,
  type FableCompletionReviewExecution,
  type FableCompletionReviewRunner,
} from './fable-completion-review-runner.ts'

export const APP_SERVER_MANAGER_SCHEMA = 'qofi-codex-app-server-manager/v1' as const
export const APP_SERVER_MANAGER_VERSION = '0.1.0' as const
export const MANAGER_MAX_TURN_BODY_BYTES = 70 * 1024 * 1024
export const MANAGER_MAX_TURN_PROMPT_BYTES = 64 * 1024 * 1024
export const MANAGER_MAX_RESULT_BODY_BYTES = 8 * 1024 * 1024
export const MANAGER_MAX_REVIEW_BODY_BYTES = 32 * 1024 * 1024
export const MANAGER_MAX_RESERVATION_TTL_MS = 120_000
export const MANAGER_DEFAULT_RESERVATION_TTL_MS = 30_000
export const MANAGER_MAX_CLEANUP_PENDING_TTL_MS = 120_000
export const MANAGER_DEFAULT_CLEANUP_PENDING_TTL_MS = 60_000
export type ManagerSessionId = string

const PROFILE_HANDLE = /^[a-z][a-z0-9_-]{0,31}$/
const POOL_HANDLE = /^[a-z][a-z0-9_-]{0,31}$/
const PROFILE_CATALOG_SCHEMA = 'qofi-codex-profiles/v1' as const
const ROTATION_STATE_SCHEMA = 'qofi-codex-profile-rotation/v1' as const
const MAX_PROFILE_CATALOG_BYTES = 64 * 1024
const MAX_ROTATION_STATE_BYTES = 1024 * 1024
const FABLE_REVIEWER_CONFIG_SCHEMA = 'qofi-fable-reviewer/v1' as const
export const FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA = 'qofi-fable-reviewer-scope-request/v1' as const
export const FABLE_REVIEWER_SCOPE_SCHEMA = 'qofi-fable-reviewer-scope/v1' as const
export const FABLE_REVIEWER_SLOT = 'completion-candidate' as const
export const FABLE_EARLY_REVIEW_STATUS = 'disabled-no-trusted-boundary' as const
export const MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA =
  'qofi-codex-completion-review-begin/v1' as const
export const MANAGER_COMPLETION_REVIEW_CONSUME_SCHEMA =
  'qofi-codex-completion-review-consume-request/v1' as const
export const MANAGER_COMPLETION_REVIEW_RECEIPT_SCHEMA =
  'qofi-codex-completion-review-receipt/v1' as const
const MAX_FABLE_REVIEWER_CONFIG_BYTES = 64 * 1024
const RUNTIME_ATTESTATION_PATH = '/private/etc/qofi-codex-runtime.json'
const RUNTIME_ATTESTATION_SCHEMA = 'qofi-codex-runtime/v2'
const EXACT_RUNTIME_ATTESTATION_KEYS = [
  'schema', 'operator_uid', 'runtime_uid', 'runtime_user', 'runtime_home',
  'runtime_gid', 'runtime_group', 'codex_home', 'runner_path', 'runner_sha256',
  'node_path', 'node_sha256', 'codex_script', 'codex_script_sha256',
  'launchd_canary_name', 'launchd_canary_sha256',
  'fable_reviewer_path', 'fable_reviewer_sha256',
  'fable_doctrine_path', 'fable_doctrine_sha256',
  'fable_schema_path', 'fable_schema_sha256',
  'fable_reviewer_config_sha256', 'codex_config_sha256',
].sort()

export type FableReviewerAuthLane = 'device' | 'anthropic-api-key'
export type FableReviewerFailurePolicy = 'review-pending'
export type FableReviewerPolicy = Readonly<{
  authLane: FableReviewerAuthLane
  maxCallsPerTask: number
  maxCallsPerWindow: number
  windowSeconds: number
  timeoutSeconds: number
  failurePolicy: FableReviewerFailurePolicy
}>
type FableReviewerPolicyOverride = Partial<FableReviewerPolicy>
type FableReviewerConfig = Readonly<{
  schema: typeof FABLE_REVIEWER_CONFIG_SCHEMA
  defaults: FableReviewerPolicy
  swarms: Readonly<Record<string, FableReviewerPolicyOverride>>
}>

export type ManagerReviewerScopeRequest = {
  schema: typeof FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA
  /** Opaque manager-minted capability used only to revalidate one invocation. */
  slot_token?: string
}
export type ManagerReviewerScopeResponse = {
  schema: typeof FABLE_REVIEWER_SCOPE_SCHEMA
  slot: typeof FABLE_REVIEWER_SLOT
  slot_token: string
  early_review: typeof FABLE_EARLY_REVIEW_STATUS
  swarm: string
  profile: string
  task_id: string
  state_dir: string
  policy: {
    auth_lane: FableReviewerAuthLane
    max_calls_per_task: number
    max_calls_per_window: number
    window_seconds: number
    timeout_seconds: number
    failure_policy: FableReviewerFailurePolicy
  }
}

type ProfileCatalog = Readonly<{
  schema: typeof PROFILE_CATALOG_SCHEMA
  profiles: readonly ProfileRegistryEntry[]
  pools: Readonly<Record<string, ProfilePoolDeclaration>>
}>

export type ManagerRotationTransition = Readonly<{
  reason: 'soft' | 'hard'
  previousProfile: string
  activeProfile: string | null
  parkedUntilMs: number | null
}>

export type ManagerHealthResponse = {
  schema: typeof APP_SERVER_MANAGER_SCHEMA
  status: 'ready' | 'drained' | 'busy' | 'review-pending' | 'cleanup-pending' | 'ambiguous' | 'stopping'
  phase: ManagerPhase
  generation: number
  registeredSwarmCount: number
  upstreamReady: boolean
  upstreamState: 'ready' | 'stopped' | 'cleanup-pending' | 'ambiguous'
  managerVersion: typeof APP_SERVER_MANAGER_VERSION
  protocolVersion: typeof CODEX_APP_SERVER_PROTOCOL_VERSION
  cliVersion: typeof CODEX_APP_SERVER_PROTOCOL_VERSION
}
export type ManagerRegisterRequest = {
  swarm: string
  repo: string
  stateDir: string
  sessions?: ManagerSessionId[]
  model?: string | null
  reasoningEffort?: ManagedCodexReasoningEffort | null
  profile?: string | null
}
export type ManagerRegisterResponse = {
  registrationToken: string
  generation: number
  facadeEndpoint: string
  serverVersion: typeof CODEX_APP_SERVER_PROTOCOL_VERSION
  reasoningEffort: ManagedCodexReasoningEffort
  activeProfile: string | null
  pool: string
  thresholdPercent: number
  parkedUntilMs: number | null
}
export type ManagerSessionsReplaceRequest = {
  registrationToken: string
  sessions: ManagerSessionId[]
}
export type ManagerSessionsReplaceResponse = {
  generation: number
  facadeEndpoint: string
  sessionCount: number
}
export type ManagerTurnReserveRequest = {
  registrationToken: string
  requestId: string
}
export type ManagerTurnReserveResponse = {
  reservationToken: string
  requestId: string
  expiresAtMs: number
  generation: number
  profile: string
}
export type ManagerTurnReservationCancelRequest = {
  registrationToken: string
  reservationToken: string
  requestId: string
}
export type ManagerTurnReservationCancelResponse = { cancelled: true }
export type ManagerTurnStartRequest = {
  registrationToken: string
  reservationToken: string
  requestId: string
  /** Exact immutable Discord message ID for reviewer provenance. */
  taskId: string
  threadId: string | null
  prompt: string
  clientUserMessageId?: string | null
  readableRoots?: string[]
  writableRoots?: string[]
  deniedPaths?: string[]
  environment?: Record<string, string>
}
export type ManagerTurnStartResponse = {
  leaseId: string
  threadId: string
  turnId: string
  result: AppServerTurnResult
  cleanupRequired: true
  generation: number
  profile: string
  rotation: ManagerRotationTransition | null
}
export type ManagerTurnInterruptRequest = {
  registrationToken: string
  requestId: string
}
export type ManagerTurnInterruptResponse = {
  accepted: true
  threadId: string
  turnId: string
}
export type ManagerTurnCleanupRequest = {
  registrationToken?: string
  cleanupToken?: string
  leaseId: string
  ok: boolean
}
export type ManagerTurnCleanupResponse = {
  generation: number
  ready: true
  activeProfile: string | null
  parkedUntilMs: number | null
}
export type ManagerCompletionReviewArguments = Readonly<{
  diff_or_files: string | Readonly<{
    files: readonly Readonly<{ path: string; content: string }>[]
  }>
  context_refs: readonly []
  mode: 'code'
}>
export type ManagerCompletionReviewBeginRequest = {
  schema: typeof MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA
  registrationToken: string
  leaseId: string
  reviewedDiffSha256: string
  arguments: ManagerCompletionReviewArguments
}
export type ManagerCompletionReviewBeginResponse = {
  schema: typeof MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA
  status: 'pending'
  leaseId: string
  completionToken: string
  expiresAtMs: number
}
export type ManagerCompletionReviewPollRequest = {
  registrationToken: string
  leaseId: string
  completionToken: string
}
export type ManagerCompletionReviewPollResponse = Readonly<{
  status: 'pending'
}> | Readonly<{
  status: 'complete'
  reviewedDiffSha256: string
  verdict: 'approve' | 'needs-changes' | 'block' | 'review-unavailable'
  artifactName: string
  artifactSha256: string
}>
export type ManagerCompletionReviewConsumeRequest = {
  schema: typeof MANAGER_COMPLETION_REVIEW_CONSUME_SCHEMA
  completionToken: string
  repoRoot: string
  taskId: string
}
export type ManagerCompletionReviewReceipt = Readonly<{
  schema: typeof MANAGER_COMPLETION_REVIEW_RECEIPT_SCHEMA
  swarm: string
  profile: string
  taskId: string
  repoRoot: string
  reviewedDiffSha256: string
  verdict: 'approve' | 'needs-changes' | 'block' | 'review-unavailable'
  artifactName: string
  artifactSha256: string
}>
export type ManagerCompletionReviewEndRequest = {
  registrationToken: string
  leaseId: string
  completionToken: string
}
export type ManagerCompletionReviewEndResponse = { ended: true; leaseId: string }
export type ManagerReviewStartRequest = { requestId: string; prompt: string }
export type ManagerReviewStartResponse = ManagerTurnStartResponse & { cleanupToken: string }
export type ManagerUnregisterRequest = { registrationToken: string }
export type ManagerUnregisterResponse = { removed: true }
export type ManagerDrainRequest = Record<string, never>
export type ManagerDrainResponse = { drained: true; generation: number }
export type ManagerResumeRequest = Record<string, never>
export type ManagerResumeResponse = { ready: true; generation: number }
export type ManagerShutdownRequest = Record<string, never>
export type ManagerShutdownResponse = { stopping: true }
export type ManagerErrorResponse = {
  error: string
  phase: ManagerPhase
  retryable: boolean
  /** Present only when admission is parked by an exhausted auth pool. */
  parkedUntilMs?: number | null
}

export type ManagerPhase =
  | 'starting'
  | 'idle'
  | 'reserved'
  | 'active'
  | 'completion-review-pending'
  | 'completion-review-complete'
  | 'terminal-cleanup-pending'
  | 'drained'
  | 'ambiguous'
  | 'stopping'

export type ManagerClient = Pick<CodexAppServerClient,
  | 'startThreadEffective'
  | 'resumeThreadEffective'
  | 'readThread'
  | 'startTurn'
  | 'interrupt'
  | 'close'
>

export type ManagerGeneration = {
  client: ManagerClient
  stop: () => Promise<void>
  exited: Promise<ManagerGenerationExit>
}

export type ManagerGenerationExit = {
  code: number | null
  signal: NodeJS.Signals | null
}

export type ManagerGenerationFactory = (handlers: {
  onNotification: (notification: AppServerNotification) => void
  onProtocolError: (error: Error) => void
}, profile?: string) => Promise<ManagerGeneration>

export type AppServerManagerOptions = {
  stateDir: string
  swarmHome: string
  controlSocketPath?: string
  operatorHome?: string
  model?: string
  generationFactory?: ManagerGenerationFactory
  reviewRunner?: FixedReviewRunner
  completionReviewRunner?: FableCompletionReviewRunner
  profileTelemetryReader?: (profile: string) => Promise<QuotaTelemetry>
  facadeFactory?: (options: ConstructorParameters<typeof CodexNativeReadOnlyFacade>[0]) => CodexNativeReadOnlyFacade
  maxControlBodyBytes?: number
  maxReviewBodyBytes?: number
  requestBodyTimeoutMs?: number
  reservationTtlMs?: number
  cleanupPendingTtlMs?: number
  /** Test seam only; production derives the bound from queue-window + child timeout policy. */
  completionReviewTtlMs?: number
  /** Test seam only; production uses the fixed root runtime attestation. */
  runtimeAttestationPath?: string
  /** Test seam only; production requires uid 0. */
  expectedRuntimeAttestationUid?: number
}

type Registration = {
  swarm: string
  repo: string
  stateDir: string
  token: string
  facade: CodexNativeReadOnlyFacade
  primaryThreads: Set<string>
  threads: Set<string>
  parents: Map<string, string>
  model: string
  reasoningEffort: ManagedCodexReasoningEffort
  /** Leased non-secret auth-profile handle; credential bytes never enter manager state. */
  profile: string | null
  pool: string
  thresholdPercent: number
}

type ActiveLease = {
  id: string
  cleanupToken: string
  kind: 'turn' | 'review'
  registration: Registration | null
  requestId: string
  taskId: string | null
  ownerSocket: Socket | null
  ownerCloseHandler: (() => void) | null
  threadId: string | null
  turnId: string | null
  turnReady: Promise<{ threadId: string; turnId: string }>
  resolveTurnReady: (value: { threadId: string; turnId: string }) => void
  cleanupTimer: ReturnType<typeof setTimeout> | null
  cancelReview: (() => Promise<void>) | null
  profile: string | null
  pendingRotationState: RotationHarnessState | null
  rotation: ManagerRotationTransition | null
  /** One opaque completion-review capability for this exact terminal lease. */
  reviewerSlotToken: string | null
  terminalResult: AppServerTurnResult | null
  completionReviewTimer: ReturnType<typeof setTimeout> | null
  completionReview: null | {
    token: string
    inputSha256: string
    reviewedDiffSha256: string
    expiresAtMs: number
    status: 'pending' | 'complete' | 'failed'
    execution: FableCompletionReviewExecution | null
    result: ManagerCompletionReviewPollResponse | null
    consumed: boolean
  }
}

type TurnReservation = {
  token: string
  registration: Registration
  requestId: string
  expiresAtMs: number
  generation: number
  profile: string
  timer: ReturnType<typeof setTimeout>
}

type TurnReservationCancelTombstone = {
  registration: Registration
  registrationToken: string
  reservationToken: string
  requestId: string
  generation: number
}

class ManagerHttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly retryable = false,
    readonly parkedUntilMs: number | null | undefined = undefined,
  ) {
    super(message)
  }
}

class ManagerGenerationReapError extends Error {
  constructor(initializationDiagnostic?: string, reapDiagnostic?: string) {
    super('fixed App Server runner could not be reaped after initialization failure'
      + (initializationDiagnostic ? `; initialization=${JSON.stringify(initializationDiagnostic)}` : '')
      + (reapDiagnostic ? `; reap=${JSON.stringify(reapDiagnostic)}` : ''))
  }
}

const MAX_CONFIG_BYTES = 256 * 1024
const MAX_SESSIONS_BYTES = 256 * 1024
const MAX_SESSIONS = 256
const MAX_TURN_PROMPT_BYTES = MANAGER_MAX_TURN_PROMPT_BYTES
const MAX_REVIEW_PROMPT_BYTES = 5_242_880
const MAX_REVIEW_RESPONSE_BYTES = MANAGER_MAX_RESULT_BODY_BYTES
const MANAGER_RESTORE_ATTEMPTS = 2
const MANAGER_RESTORE_RETRY_DELAY_MS = 250
const MANAGER_GENERATION_STABILITY_MS = 100
const MAX_RESERVATION_CANCEL_TOMBSTONES = 32

type DrainRecovery =
  | 'none'
  | 'idle-upstream-exit'
  | 'idle-protocol-error'
  | 'prelease-restore-failure'
  | 'prelease-upstream-failure'

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function inside(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(root + sep)
}

function safeToken(value: unknown, max = 256): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= max && !value.includes('\0')
}

function safeSwarm(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value)
}

function uniqueSessions(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > MAX_SESSIONS) throw new ManagerHttpError(400, 'invalid sessions')
  const result: string[] = []
  const seen = new Set<string>()
  for (const id of value) {
    if (!safeToken(id) || seen.has(id)) throw new ManagerHttpError(400, 'invalid or duplicate session id')
    seen.add(id)
    result.push(id)
  }
  return result
}

function secureOwnerFile(path: string, maxBytes: number): Buffer {
  const before = lstatSync(path)
  const uid = typeof process.getuid === 'function' ? process.getuid() : before.uid
  if (!before.isFile() || before.isSymbolicLink() || before.uid !== uid
    || (before.mode & 0o022) !== 0 || before.size > maxBytes) {
    throw new Error(`unsafe owner control file: ${path}`)
  }
  assertNoExtendedAcl(path, 'manager control file')
  const fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = fstatSync(fd)
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size
      || opened.mtimeMs !== before.mtimeMs || opened.ctimeMs !== before.ctimeMs) {
      throw new Error(`control file changed while opening: ${path}`)
    }
    assertNoExtendedAcl(path, 'manager control file')
    const bytes = readFileSync(fd)
    const after = fstatSync(fd)
    if (bytes.byteLength > maxBytes || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs) {
      throw new Error(`control file changed while reading: ${path}`)
    }
    assertNoExtendedAcl(path, 'manager control file')
    return bytes
  } finally {
    closeSync(fd)
  }
}

function exactObjectKeys(value: Record<string, unknown>, required: readonly string[], optional: readonly string[] = []): boolean {
  const allowed = new Set([...required, ...optional])
  return required.every(key => Object.prototype.hasOwnProperty.call(value, key))
    && Object.keys(value).every(key => allowed.has(key))
}

function loadProfileCatalog(swarmHome: string): ProfileCatalog {
  const path = join(swarmHome, 'codex-profiles.json')
  let bytes: Buffer
  try { bytes = secureOwnerFile(path, MAX_PROFILE_CATALOG_BYTES) } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return {
        schema: PROFILE_CATALOG_SCHEMA,
        profiles: [{ label: 'default', shared: true }],
        pools: {
          default: {
            profiles: ['default'],
            thresholdPercent: DEFAULT_ROTATION_THRESHOLD_PERCENT,
          },
        },
      }
    }
    throw error
  }
  const value: unknown = JSON.parse(bytes.toString('utf8'))
  if (!object(value) || !exactObjectKeys(value, ['schema', 'profiles', 'pools'])
    || value.schema !== PROFILE_CATALOG_SCHEMA || !Array.isArray(value.profiles) || !object(value.pools)) {
    throw new Error('codex-profiles.json has an incompatible schema')
  }
  const profiles = validateProfileRegistry(value.profiles as ProfileRegistryEntry[])
  const pools: Record<string, ProfilePoolDeclaration> = {}
  for (const [name, raw] of Object.entries(value.pools)) {
    if (!POOL_HANDLE.test(name) || !object(raw)
      || !exactObjectKeys(raw, ['profiles'], ['thresholdPercent'])) {
      throw new Error('codex-profiles.json has an invalid pool')
    }
    pools[name] = validateProfilePool(profiles, raw as unknown as ProfilePoolDeclaration)
  }
  if (!pools.default) throw new Error('codex-profiles.json must declare the default pool')
  return { schema: PROFILE_CATALOG_SCHEMA, profiles, pools }
}

function reviewerPositiveInteger(value: unknown, min: number, max: number, name: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < min || (value as number) > max) {
    throw new Error(`fable-reviewer.json ${name} must be an integer from ${min} through ${max}`)
  }
  return value as number
}

function parseReviewerPolicy(value: unknown, partial: boolean): FableReviewerPolicy | FableReviewerPolicyOverride {
  if (!object(value)) throw new Error('fable-reviewer.json policy must be an object')
  const keys = [
    'authLane', 'maxCallsPerTask', 'maxCallsPerWindow', 'windowSeconds',
    'timeoutSeconds', 'failurePolicy',
  ] as const
  if (!exactObjectKeys(value, partial ? [] : keys, partial ? keys : [])) {
    throw new Error('fable-reviewer.json policy has missing or unknown keys')
  }
  const result: FableReviewerPolicyOverride = {}
  if ('authLane' in value) {
    if (value.authLane !== 'device' && value.authLane !== 'anthropic-api-key') {
      throw new Error('fable-reviewer.json authLane is invalid')
    }
    result.authLane = value.authLane
  }
  if ('maxCallsPerTask' in value) {
    // Runtime policy has exactly one manager-granted terminal completion call.
    // The installed App Server protocol has no trusted semantic boundary from
    // which to authorize an early review, so extra per-task slots are refused
    // fail-closed rather than delegated to a worker-controlled MCP argument.
    result.maxCallsPerTask = reviewerPositiveInteger(value.maxCallsPerTask, 1, 1, 'maxCallsPerTask')
  }
  if ('maxCallsPerWindow' in value) {
    result.maxCallsPerWindow = reviewerPositiveInteger(value.maxCallsPerWindow, 1, 1_000, 'maxCallsPerWindow')
  }
  if ('windowSeconds' in value) {
    result.windowSeconds = reviewerPositiveInteger(value.windowSeconds, 60, 3_600, 'windowSeconds')
  }
  if ('timeoutSeconds' in value) {
    result.timeoutSeconds = reviewerPositiveInteger(value.timeoutSeconds, 1, 600, 'timeoutSeconds')
  }
  if ('failurePolicy' in value) {
    if (value.failurePolicy !== 'review-pending') {
      throw new Error('fable-reviewer.json failurePolicy must be review-pending')
    }
    result.failurePolicy = value.failurePolicy
  }
  return result as FableReviewerPolicy | FableReviewerPolicyOverride
}

function loadFableReviewerConfig(swarmHome: string): { config: FableReviewerConfig; sha256: string } {
  const bytes = secureOwnerFile(join(swarmHome, 'fable-reviewer.json'), MAX_FABLE_REVIEWER_CONFIG_BYTES)
  const value: unknown = JSON.parse(bytes.toString('utf8'))
  if (!object(value) || !exactObjectKeys(value, ['schema', 'defaults', 'swarms'])
    || value.schema !== FABLE_REVIEWER_CONFIG_SCHEMA || !object(value.swarms)) {
    throw new Error('fable-reviewer.json has an incompatible schema')
  }
  const defaults = parseReviewerPolicy(value.defaults, false) as FableReviewerPolicy
  if (defaults.maxCallsPerTask > defaults.maxCallsPerWindow) {
    throw new Error('fable-reviewer.json maxCallsPerTask cannot exceed maxCallsPerWindow')
  }
  const swarms: Record<string, FableReviewerPolicyOverride> = Object.create(null)
  for (const [swarm, policy] of Object.entries(value.swarms)) {
    if (!safeSwarm(swarm)) throw new Error('fable-reviewer.json has an invalid swarm override')
    swarms[swarm] = parseReviewerPolicy(policy, true)
    const resolved = { ...defaults, ...swarms[swarm] }
    if (resolved.maxCallsPerTask > resolved.maxCallsPerWindow) {
      throw new Error('fable-reviewer.json maxCallsPerTask cannot exceed maxCallsPerWindow')
    }
  }
  return {
    config: { schema: FABLE_REVIEWER_CONFIG_SCHEMA, defaults, swarms },
    sha256: createHash('sha256').update(bytes).digest('hex'),
  }
}

function attestedFableReviewerConfigHash(
  path = RUNTIME_ATTESTATION_PATH,
  expectedUid = 0,
): { configSha256: string; reviewerSha256: string } {
  if (!isAbsolute(path) || resolve(path) !== path || realpathSync(path) !== path) {
    throw new Error('runtime attestation path must be fixed, absolute, and canonical')
  }
  const before = lstatSync(path)
  let parent = dirname(path)
  for (;;) {
    const info = lstatSync(parent)
    if (!info.isDirectory() || info.isSymbolicLink()
      || (info.uid !== 0 && info.uid !== expectedUid) || (info.mode & 0o022) !== 0) {
      throw new Error('runtime attestation parent is not authority-controlled')
    }
    if (expectedUid === 0) assertNoExtendedAcl(parent, 'runtime attestation parent')
    const next = dirname(parent)
    if (next === parent) break
    parent = next
  }
  if (!before.isFile() || before.isSymbolicLink() || before.uid !== expectedUid
    || (before.mode & 0o022) !== 0 || before.nlink !== 1
    || before.size < 2 || before.size > 16 * 1024) {
    throw new Error('runtime attestation must be a bounded root-controlled regular file')
  }
  assertNoExtendedAcl(path, 'runtime attestation')
  const fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  let bytes: Buffer
  try {
    const opened = fstatSync(fd)
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.uid !== before.uid
      || opened.mode !== before.mode || opened.size !== before.size
      || opened.mtimeMs !== before.mtimeMs || opened.ctimeMs !== before.ctimeMs) {
      throw new Error('runtime attestation changed while opening')
    }
    bytes = readFileSync(fd)
    const after = fstatSync(fd)
    if (bytes.byteLength !== opened.size || after.size !== opened.size
      || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) {
      throw new Error('runtime attestation changed while reading')
    }
  } finally {
    closeSync(fd)
  }
  const final = lstatSync(path)
  if (final.dev !== before.dev || final.ino !== before.ino || final.uid !== before.uid
    || final.mode !== before.mode || final.nlink !== before.nlink || final.size !== before.size
    || final.mtimeMs !== before.mtimeMs || final.ctimeMs !== before.ctimeMs) {
    throw new Error('runtime attestation was replaced while reading')
  }
  assertNoExtendedAcl(path, 'runtime attestation')
  const value: unknown = JSON.parse(bytes.toString('utf8'))
  if (!object(value)
    || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(EXACT_RUNTIME_ATTESTATION_KEYS)
    || value.schema !== RUNTIME_ATTESTATION_SCHEMA) {
    throw new Error('runtime attestation does not exactly match the installed v2 schema')
  }
  const operatorUid = typeof process.getuid === 'function' ? process.getuid() : value.operator_uid
  if (value.operator_uid !== operatorUid
    || value.fable_reviewer_path !== '/usr/local/libexec/qofi-fable-reviewer-mcp.py'
    || value.fable_doctrine_path !== '/usr/local/libexec/qofi-fable-reviewer-doctrine.md'
    || value.fable_schema_path !== '/usr/local/libexec/qofi-adversarial-review-output.schema.json'
    || typeof value.fable_reviewer_sha256 !== 'string'
    || !/^[0-9a-f]{64}$/.test(value.fable_reviewer_sha256)
    || typeof value.fable_doctrine_sha256 !== 'string'
    || !/^[0-9a-f]{64}$/.test(value.fable_doctrine_sha256)
    || typeof value.fable_schema_sha256 !== 'string'
    || !/^[0-9a-f]{64}$/.test(value.fable_schema_sha256)
    || typeof value.fable_reviewer_config_sha256 !== 'string'
    || !/^[0-9a-f]{64}$/.test(value.fable_reviewer_config_sha256)) {
    throw new Error('runtime attestation reviewer policy authority is invalid')
  }
  return {
    configSha256: value.fable_reviewer_config_sha256,
    reviewerSha256: value.fable_reviewer_sha256,
  }
}

function resolveReviewerPolicy(config: FableReviewerConfig, swarm: string): FableReviewerPolicy {
  const override = Object.prototype.hasOwnProperty.call(config.swarms, swarm)
    ? config.swarms[swarm]
    : undefined
  return { ...config.defaults, ...(override ?? {}) }
}

const EMPTY_COMPLETION_REVIEW_MATERIAL = 'qofi completion review: no workspace file changes'
const REVIEW_SHA256 = /^[0-9a-f]{64}$/
const REVIEW_ARTIFACT_NAME =
  /^(?:fable-review-[0-9]{8}T[0-9]{12}Z-[0-9a-f]{16}|fable-review-budget-exhausted)\.json$/
const REVIEW_VERDICTS = new Set(['approve', 'needs-changes', 'block', 'review-unavailable'])

function canonicalFableJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalFableJson).join(',')}]`
  const record = value as Record<string, unknown>
  return `{${Object.keys(record).sort().map(key => (
    `${JSON.stringify(key)}:${canonicalFableJson(record[key])}`
  )).join(',')}}`
}

function safeCompletionPath(value: unknown): value is string {
  if (typeof value !== 'string' || value.length < 1 || value.length > 1024
    || value.startsWith('/') || value.startsWith('./') || value.includes('\\')
    || value.includes('\0') || value.includes('//')) return false
  const ordinary = value.endsWith(' [deleted]') ? value.slice(0, -10) : value
  return ordinary.length > 0 && ordinary.split('/').every(part => part !== '' && part !== '.' && part !== '..')
}

function normalizeCompletionReviewArguments(
  value: unknown,
  expectedHash: string,
): { arguments: ManagerCompletionReviewArguments; inputSha256: string } {
  if (!object(value) || !exactObjectKeys(value, ['diff_or_files', 'context_refs', 'mode'])
    || value.mode !== 'code' || !Array.isArray(value.context_refs) || value.context_refs.length !== 0
    || !REVIEW_SHA256.test(expectedHash)) {
    throw new ManagerHttpError(400, 'invalid completion review material')
  }
  let diffOrFiles: ManagerCompletionReviewArguments['diff_or_files']
  let reviewedBytes: string
  if (typeof value.diff_or_files === 'string') {
    if (value.diff_or_files !== EMPTY_COMPLETION_REVIEW_MATERIAL) {
      throw new ManagerHttpError(400, 'completion review string is not the exact no-change sentinel')
    }
    diffOrFiles = value.diff_or_files
    reviewedBytes = value.diff_or_files
  } else if (object(value.diff_or_files)
    && exactObjectKeys(value.diff_or_files, ['files'])
    && Array.isArray(value.diff_or_files.files)
    && value.diff_or_files.files.length >= 1
    && value.diff_or_files.files.length <= 128) {
    const files: Array<{ path: string; content: string }> = []
    const paths = new Set<string>()
    for (const item of value.diff_or_files.files) {
      if (!object(item) || !exactObjectKeys(item, ['path', 'content'])
        || !safeCompletionPath(item.path) || typeof item.content !== 'string'
        || item.content.includes('\0') || Buffer.byteLength(item.content, 'utf8') > 2 * 1024 * 1024
        || paths.has(item.path)) {
        throw new ManagerHttpError(400, 'invalid completion review named-file material')
      }
      paths.add(item.path)
      files.push({ path: item.path, content: item.content })
    }
    const sorted = [...files].sort((left, right) => Buffer.compare(
      Buffer.from(left.path, 'utf8'), Buffer.from(right.path, 'utf8'),
    ))
    if (JSON.stringify(files) !== JSON.stringify(sorted)) {
      throw new ManagerHttpError(400, 'completion review named files are not canonically ordered')
    }
    diffOrFiles = { files }
    reviewedBytes = canonicalFableJson({ files })
  } else {
    throw new ManagerHttpError(400, 'invalid completion review material')
  }
  if (Buffer.byteLength(reviewedBytes, 'utf8') > 2 * 1024 * 1024
    || createHash('sha256').update(reviewedBytes).digest('hex') !== expectedHash) {
    throw new ManagerHttpError(409, 'completion review material hash mismatch')
  }
  const normalized: ManagerCompletionReviewArguments = {
    diff_or_files: diffOrFiles,
    context_refs: [],
    mode: 'code',
  }
  return {
    arguments: normalized,
    inputSha256: createHash('sha256').update(canonicalFableJson(normalized)).digest('hex'),
  }
}

function validateCompletionReviewRunnerResult(
  value: unknown,
  expectedHash: string,
): Extract<ManagerCompletionReviewPollResponse, { status: 'complete' }> {
  if (!object(value) || !exactObjectKeys(value, [
    'schema', 'reviewed_diff_sha256', 'artifact', 'result',
  ]) || value.schema !== FABLE_ONE_SHOT_RESULT_SCHEMA
    || value.reviewed_diff_sha256 !== expectedHash
    || !object(value.artifact) || !exactObjectKeys(value.artifact, ['name', 'sha256'])
    || typeof value.artifact.name !== 'string' || !REVIEW_ARTIFACT_NAME.test(value.artifact.name)
    || typeof value.artifact.sha256 !== 'string' || !REVIEW_SHA256.test(value.artifact.sha256)
    || !object(value.result) || !exactObjectKeys(value.result, [
      'schema', 'verdict', 'summary', 'checked', 'not_checked', 'findings', 'next_steps',
    ]) || value.result.schema !== 'qofi-adversarial-review-output/v2'
    || typeof value.result.verdict !== 'string' || !REVIEW_VERDICTS.has(value.result.verdict)
    || Buffer.byteLength(JSON.stringify(value.result), 'utf8') > 512 * 1024) {
    throw new Error('fixed Fable reviewer returned an invalid completion receipt')
  }
  return {
    status: 'complete',
    reviewedDiffSha256: expectedHash,
    verdict: value.result.verdict as Extract<ManagerCompletionReviewPollResponse, { status: 'complete' }>['verdict'],
    artifactName: value.artifact.name,
    artifactSha256: value.artifact.sha256,
  }
}

function reviewerScopeForLease(
  lease: ActiveLease,
  token: string,
  policy: FableReviewerPolicy,
): ManagerReviewerScopeResponse {
  if (!lease.registration || !lease.profile || !lease.taskId) {
    throw new Error('completion review lease lacks bound scope')
  }
  return {
    schema: FABLE_REVIEWER_SCOPE_SCHEMA,
    slot: FABLE_REVIEWER_SLOT,
    slot_token: token,
    early_review: FABLE_EARLY_REVIEW_STATUS,
    swarm: lease.registration.swarm,
    profile: lease.profile,
    task_id: lease.taskId,
    state_dir: lease.registration.stateDir,
    policy: {
      auth_lane: policy.authLane,
      max_calls_per_task: policy.maxCallsPerTask,
      max_calls_per_window: policy.maxCallsPerWindow,
      window_seconds: policy.windowSeconds,
      timeout_seconds: policy.timeoutSeconds,
      failure_policy: policy.failurePolicy,
    },
  }
}

function operatorPeerUid(socket: Socket | null): number | null {
  if (!socket) return null
  try {
    const credentials = (socket as unknown as {
      _handle?: { getPeerCredentials?: () => { uid?: unknown } }
    })._handle?.getPeerCredentials?.()
    return Number.isSafeInteger(credentials?.uid) ? credentials!.uid as number : null
  } catch {
    return null
  }
}

function unknownQuotaTelemetry(reason: 'no_token_count' | 'malformed' = 'no_token_count'): QuotaTelemetry {
  return { status: 'unknown', reason, observedAtMs: null, physicalLine: null }
}

function telemetryAtBoundary(
  telemetry: Readonly<Record<string, QuotaTelemetry>>,
  nowMs = Date.now(),
): Readonly<Record<string, QuotaTelemetry>> {
  return Object.fromEntries(Object.entries(telemetry).map(([profile, sample]) => {
    if (sample.status === 'fresh'
      && (sample.observedAtMs > nowMs || nowMs - sample.observedAtMs > MAX_TELEMETRY_AGE_MS)) {
      return [profile, {
        status: 'unknown', reason: 'stale',
        observedAtMs: sample.observedAtMs, physicalLine: sample.physicalLine,
      } satisfies QuotaTelemetry]
    }
    return [profile, sample]
  }))
}

function validPersistedTelemetry(value: unknown): value is QuotaTelemetry {
  if (!object(value) || !['fresh', 'unknown'].includes(String(value.status))) return false
  if (value.status === 'unknown') {
    return ['no_token_count', 'rate_limits_null', 'stale', 'malformed', 'incomplete'].includes(String(value.reason))
      && (value.observedAtMs === null || Number.isFinite(value.observedAtMs))
      && (value.physicalLine === null || Number.isSafeInteger(value.physicalLine))
  }
  const validWindow = (window: unknown, minutes: number): boolean => window === null || (
    object(window) && window.windowMinutes === minutes
    && typeof window.usedPercent === 'number' && Number.isFinite(window.usedPercent)
    && window.usedPercent >= 0 && window.usedPercent <= 100
    && Number.isSafeInteger(window.resetsAtMs) && (window.resetsAtMs as number) > 0
  )
  return Number.isFinite(value.observedAtMs) && Number.isSafeInteger(value.physicalLine)
    && validWindow(value.fiveHour, 300) && validWindow(value.weekly, 10_080)
    && (value.fiveHour !== null || value.weekly !== null)
}

function readRotationHarnessState(stateDir: string): RotationHarnessState {
  const path = join(stateDir, 'profile-rotation-state.json')
  let bytes: Buffer
  try { bytes = secureOwnerFile(path, MAX_ROTATION_STATE_BYTES) } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return { swarms: {} }
    throw error
  }
  const value: unknown = JSON.parse(bytes.toString('utf8'))
  if (!object(value) || !exactObjectKeys(value, ['schema', 'swarms'])
    || value.schema !== ROTATION_STATE_SCHEMA || !object(value.swarms)) {
    throw new Error('profile rotation state has an incompatible schema')
  }
  const swarms: Record<string, SwarmProfileState> = {}
  for (const [swarm, raw] of Object.entries(value.swarms)) {
    if (!safeSwarm(swarm) || !object(raw)
      || !exactObjectKeys(raw, ['activeProfile', 'cooldowns', 'telemetry'])
      || (raw.activeProfile !== null && (typeof raw.activeProfile !== 'string' || !PROFILE_HANDLE.test(raw.activeProfile)))
      || !object(raw.cooldowns) || !object(raw.telemetry)) {
      throw new Error('profile rotation state has an invalid swarm entry')
    }
    const cooldowns: Record<string, number> = {}
    const telemetry: Record<string, QuotaTelemetry> = {}
    for (const [profile, until] of Object.entries(raw.cooldowns)) {
      if (!PROFILE_HANDLE.test(profile) || !Number.isSafeInteger(until) || (until as number) < 0) {
        throw new Error('profile rotation state has an invalid cooldown')
      }
      cooldowns[profile] = until as number
    }
    for (const [profile, sample] of Object.entries(raw.telemetry)) {
      if (!PROFILE_HANDLE.test(profile) || !validPersistedTelemetry(sample)) {
        throw new Error('profile rotation state has invalid telemetry')
      }
      telemetry[profile] = sample
    }
    swarms[swarm] = { activeProfile: raw.activeProfile as string | null, cooldowns, telemetry }
  }
  return { swarms }
}

function writePrivateJson(path: string, value: unknown): void {
  const serialized = JSON.stringify(value, null, 2) + '\n'
  if (Buffer.byteLength(serialized) > MAX_ROTATION_STATE_BYTES) throw new Error('profile rotation state exceeds byte cap')
  const temp = `${path}.tmp-${process.pid}-${randomBytes(6).toString('hex')}`
  try {
    writeFileSync(temp, serialized, { mode: 0o600, flag: 'wx' })
    chmodSync(temp, 0o600)
    renameSync(temp, path)
  } catch (error) {
    try { rmSync(temp, { force: true }) } catch {}
    throw error
  }
}

function parseSessionsFile(stateDir: string, profile = 'default'): string[] {
  const path = join(stateDir, 'sessions.json')
  let bytes: Buffer
  try { bytes = secureOwnerFile(path, MAX_SESSIONS_BYTES) } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
  const value = JSON.parse(bytes.toString('utf8')) as unknown
  let ids: unknown[]
  if (object(value) && value.schema === 'codex-bridge-sessions/v2' && Array.isArray(value.entries)) {
    ids = value.entries.map(entry => object(entry) && entry.profile_id === profile ? entry.thread_id : null)
  } else if (object(value) && value.schema === 'codex-bridge-sessions/v1' && Array.isArray(value.entries)) {
    ids = profile === 'default' ? value.entries.map(entry => object(entry) ? entry.thread_id : null) : []
  } else if (object(value) && !('schema' in value)) {
    ids = profile === 'default' ? Object.values(value) : []
  } else {
    throw new Error('unsupported sessions.json shape')
  }
  return [...new Set(uniqueSessions(ids))]
}

function parseCodexRow(swarmHome: string, swarm: string): { repo: string; pool: string } {
  const bytes = secureOwnerFile(join(swarmHome, 'swarm.conf'), MAX_CONFIG_BYTES)
  const matches: { repo: string; pool: string }[] = []
  for (const raw of bytes.toString('utf8').split(/\r?\n/)) {
    const trimmed = raw.trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const fields = raw.split('|').map(field => field.trim())
    if (fields.length > 8 && fields.slice(8).some(Boolean)) throw new Error('swarm.conf has unknown nonempty fields')
    while (fields.length < 8) fields.push('')
    if (fields[0] !== swarm) continue
    if (fields[6] !== 'codex') throw new Error('registered swarm is not a Codex row')
    if (!isAbsolute(fields[1]) || resolve(fields[1]) !== fields[1]) throw new Error('swarm repo is not absolute normalized')
    const pool = fields[7] || 'default'
    if (!POOL_HANDLE.test(pool)) throw new Error('Codex auth pool is invalid')
    matches.push({ repo: fields[1], pool })
  }
  if (matches.length !== 1) throw new Error('swarm.conf must contain exactly one matching Codex row')
  return matches[0]
}

/** Current config rows are the authority for which persisted swarms may lease. */
function configuredCodexSwarms(swarmHome: string): Set<string> {
  const bytes = secureOwnerFile(join(swarmHome, 'swarm.conf'), MAX_CONFIG_BYTES)
  const configured = new Set<string>()
  for (const raw of bytes.toString('utf8').split(/\r?\n/)) {
    const trimmed = raw.trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const fields = raw.split('|').map(field => field.trim())
    if (fields.length > 8 && fields.slice(8).some(Boolean)) {
      throw new Error('swarm.conf has unknown nonempty fields')
    }
    while (fields.length < 8) fields.push('')
    if (!safeSwarm(fields[0])) throw new Error('swarm.conf has an invalid swarm name')
    if (fields[6] !== 'codex') continue
    if (configured.has(fields[0])) throw new Error('swarm.conf has duplicate Codex rows')
    configured.add(fields[0])
  }
  return configured
}

function safeRootList(value: unknown, label: string, max = 64): string[] {
  if (value === undefined) return []
  if (!Array.isArray(value) || value.length > max) throw new ManagerHttpError(400, `invalid ${label}`)
  return value.map(path => {
    if (typeof path !== 'string' || !isAbsolute(path) || resolve(path) !== path || path === '/') {
      throw new ManagerHttpError(400, `invalid ${label}`)
    }
    return path
  })
}

function safeEnvironment(value: unknown): Record<string, string> {
  if (value === undefined) return {}
  if (!object(value) || Object.keys(value).length > 96) throw new ManagerHttpError(400, 'invalid environment')
  const result: Record<string, string> = {}
  for (const [name, raw] of Object.entries(value)) {
    if (!/^[A-Z][A-Z0-9_]{0,63}$/.test(name) || typeof raw !== 'string'
      || Buffer.byteLength(raw) > 8192 || raw.includes('\0')) {
      throw new ManagerHttpError(400, 'invalid environment')
    }
    result[name] = raw
  }
  return result
}

function randomCapability(): string {
  return randomBytes(32).toString('hex')
}

function ensureNativeViewDir(stateDir: string): string {
  const path = join(stateDir, 'native-view')
  let created = false
  try {
    mkdirSync(path, { mode: 0o700 })
    created = true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
  }
  if (created) chmodSync(path, 0o700)
  const info = lstatSync(path)
  const uid = typeof process.getuid === 'function' ? process.getuid() : info.uid
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== uid
    || (info.mode & 0o777) !== 0o700 || realpathSync(path) !== path) {
    throw new Error('native-view must be an owner mode-0700 real directory')
  }
  validatePrivateStateBoundary(stateDir, false)
  return path
}

function missingThread(error: unknown): boolean {
  return error instanceof AppServerRemoteError
    && /(?:not found|not loaded|no rollout found|missing|does not exist)/i.test(error.message)
}

function rootControlledReadRoot(path: string): boolean {
  try { assertNoExtendedAcl(path, 'root-controlled read root') } catch { return false }
  let current = lstatSync(path).isDirectory() ? path : dirname(path)
  for (;;) {
    const info = lstatSync(current)
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== 0 || (info.mode & 0o022) !== 0) return false
    try { assertNoExtendedAcl(current, 'root-controlled read-root parent') } catch { return false }
    const parent = dirname(current)
    if (parent === current) return true
    current = parent
  }
}

function boundedProtocolDiagnostic(error: Error): string {
  // Protocol errors are locally classified, but the unsupported-version path
  // incorporates a server-supplied user-agent. Keep anything that can reach
  // the operator pane or control response printable, single-line, and small.
  const message = typeof error.message === 'string' ? error.message : 'unknown protocol error'
  return message.slice(0, 2048).replace(/[^\x20-\x7e]/g, ' ').replace(/ +/g, ' ').trim().slice(0, 512)
    || 'unknown protocol error'
}

function boundedInitializationDiagnostic(error: unknown): string {
  return boundedProtocolDiagnostic(error instanceof Error
    ? error
    : new Error('unknown initialization failure'))
}

function fixedReviewTurnResult(
  execution: FixedReviewRunnerResult,
  threadId: string,
  turnId: string,
): AppServerTurnResult {
  const successful = execution.code === 0 && execution.signal === null
    && !execution.timedOut && !execution.outputExceeded && !execution.inputFailed
  const output = execution.stdout.trimEnd()
  if (successful) {
    return {
      ok: true, threadId, turnId, status: 'completed',
      messages: output ? [output] : [], ambiguous: false,
    }
  }
  const reason = execution.timedOut
    ? 'fixed review runner timed out'
    : execution.outputExceeded
      ? 'fixed review runner output exceeded 1MiB'
      : execution.inputFailed
        ? 'fixed review runner stdio failed'
        : `fixed review runner exited (${execution.signal ?? execution.code ?? 'unknown'})`
  const diagnostic = boundedProtocolDiagnostic(new Error(execution.stderr))
  return {
    ok: false, threadId, turnId, status: 'failed', messages: [],
    error: `${reason}${diagnostic !== 'unknown protocol error' ? `: ${diagnostic}` : ''}`,
    ambiguous: false,
  }
}

function cleanSupervisorExit(reason: string): boolean {
  return /^fixed App Server runner exited \(0\)(?::|$)/.test(reason)
}

function structuredRemoteQuotaFailure(error: unknown): boolean {
  if (!(error instanceof AppServerRemoteError)) return false
  if (error.code === 429) return true
  const inspect = (value: unknown, depth = 0): boolean => {
    if (depth > 4) return false
    if (value === 'usageLimitExceeded' || value === 'usage_limit_exceeded') return true
    if (!object(value)) return false
    for (const [key, child] of Object.entries(value)) {
      if (['httpStatusCode', 'http_status_code', 'status', 'statusCode'].includes(key) && child === 429) return true
      if (['codexErrorInfo', 'errorInfo', 'error', 'data', 'cause'].includes(key) && inspect(child, depth + 1)) return true
      if (['code', 'type'].includes(key) && typeof child === 'string'
        && ['usage_limit_exceeded', 'rate_limit_exceeded', 'rate_limit_reached'].includes(child)) return true
    }
    return false
  }
  return inspect(error.data)
}

/** Classify a failed initialize boundary without letting expected reap status replace its cause. */
export function managerInitializationFailure(
  error: unknown,
  reportedProtocolDiagnostic: string | null,
  runnerReason: string,
  reaped: boolean,
  reapError?: unknown,
): Error {
  const protocolDiagnostic = reportedProtocolDiagnostic
    ? boundedProtocolDiagnostic(new Error(reportedProtocolDiagnostic))
    : error instanceof AppServerProtocolError ? boundedProtocolDiagnostic(error) : null
  const initializationDiagnostic = protocolDiagnostic ?? boundedInitializationDiagnostic(error)
  const boundedRunnerReason = boundedProtocolDiagnostic(new Error(runnerReason))
  if (!reaped) {
    const reapDiagnostic = reapError === undefined
      ? boundedRunnerReason
      : boundedInitializationDiagnostic(reapError)
    return new ManagerGenerationReapError(initializationDiagnostic, reapDiagnostic)
  }
  if (protocolDiagnostic) {
    return new Error(`App Server protocol error during initialization: ${protocolDiagnostic}`)
  }
  if (boundedRunnerReason === 'JSONL transport is closed' || cleanSupervisorExit(boundedRunnerReason)) {
    return new Error(`App Server initialization failed: ${initializationDiagnostic}`)
  }
  // stopAndWait initiates termination itself, so even an abnormal supervisor
  // status can be cleanup-induced. Preserve both bounded facts instead of
  // treating the later status as proof that it caused initialization to fail.
  return new Error(
    `App Server initialization failed: runner=${JSON.stringify(boundedRunnerReason)}; `
    + `initialization=${JSON.stringify(initializationDiagnostic)}`,
  )
}

function defaultGenerationFactory(stateDir: string): ManagerGenerationFactory {
  return async (handlers, profile = 'default') => {
    const transport = spawnFixedAppServerRunner({
      cwd: stateDir, profile, maxMessageBytes: 80 * 1024 * 1024,
    })
    let client: CodexAppServerClient
    let initializationProtocolDiagnostic: string | null = null
    try {
      client = await CodexAppServerClient.connect(transport, {
        clientInfo: { name: 'qofi-app-server-manager', title: 'Qofi App Server Manager', version: '0.1.0' },
        // runtimeWorkspaceRoots and its effective response field are gated by
        // Codex 0.144.1's experimentalApi capability. No additional server
        // request is delegated merely by advertising this protocol opt-in.
        experimentalApi: true,
        onNotification: handlers.onNotification,
        onProtocolError: error => {
          // A fault received before the initialize response rejects the
          // pending request as AppServerRequestError. Retain the causal
          // protocol classification here rather than relying on the type of
          // the later Promise rejection.
          initializationProtocolDiagnostic ??= boundedProtocolDiagnostic(error)
          handlers.onProtocolError(error)
        },
        // No server request is delegated to a daemon/viewer. The protocol
        // client returns bounded explicit "unhandled" errors immediately.
        serverRequestHandlers: {
          'currentTime/read': () => ({ currentTimeAt: Math.floor(Date.now() / 1000) }),
        },
        maxInboundMessageBytes: 80 * 1024 * 1024,
        maxOutboundMessageBytes: 80 * 1024 * 1024,
      })
    } catch (error) {
      // CodexAppServerClient has already classified a protocol fault before
      // closing the transport. Reaping the fixed runner then produces the
      // expected supervisor exit (0); never let that later exit overwrite the
      // causal handshake diagnostic.
      // A factory rejection occurs before startGeneration can retain a handle.
      // Reap here so the bounded retry can never overlap an untracked root
      // runner or hidden-UID App Server. A failed reap is deliberately a
      // distinct non-retryable error; parent death remains the final cleanup.
      try {
        await transport.stopAndWait()
      } catch (reapError) {
        throw managerInitializationFailure(
          error, initializationProtocolDiagnostic, transport.boundedFailureReason(), false, reapError,
        )
      }
      throw managerInitializationFailure(
        error, initializationProtocolDiagnostic, transport.boundedFailureReason(), true,
      )
    }
    return {
      client,
      stop: async () => {
        client.close()
        await transport.stopAndWait()
      },
      exited: transport.exited,
    }
  }
}

export class AppServerManager {
  readonly controlSocketPath: string
  private phase: ManagerPhase = 'starting'
  private generation = 0
  private generationProfile = 'default'
  private generationAttempt = 0
  private generationHandle: ManagerGeneration | null = null
  private expectedGenerationStop = false
  private stopGenerationPromise: Promise<void> | null = null
  private drainRecovery: DrainRecovery = 'none'
  private operationInProgress = false
  private readonly registrations = new Map<string, Registration>()
  private readonly tokens = new Map<string, Registration>()
  private reservation: TurnReservation | null = null
  private readonly reservationCancelTombstones: TurnReservationCancelTombstone[] = []
  private lease: ActiveLease | null = null
  private readonly requestIds = new Set<string>()
  private readonly control = createServer((request, response) => void this.route(request, response))
  private controlIdentity: UnixSocketIdentity | null = null
  private readonly generationFactory: ManagerGenerationFactory
  private readonly profileCatalog: ProfileCatalog
  private readonly fableReviewerConfig: FableReviewerConfig
  private readonly fableReviewerConfigSha256: string
  private rotationState: RotationHarnessState
  private readonly rotationStatePath: string
  private readonly profileTelemetryReader: (profile: string) => Promise<QuotaTelemetry>
  private readonly reviewRunner: FixedReviewRunner
  private readonly completionReviewRunner: FableCompletionReviewRunner
  private readonly facadeFactory: NonNullable<AppServerManagerOptions['facadeFactory']>
  private readonly maxControlBodyBytes: number
  private readonly maxReviewBodyBytes: number
  private readonly requestBodyTimeoutMs: number
  private readonly reservationTtlMs: number
  private readonly cleanupPendingTtlMs: number
  private readonly completionReviewTtlMs: number | null
  private shuttingDown = false

  private constructor(readonly options: AppServerManagerOptions) {
    this.controlSocketPath = options.controlSocketPath ?? join(options.stateDir, 'control.sock')
    this.generationFactory = options.generationFactory ?? defaultGenerationFactory(options.stateDir)
    this.profileCatalog = loadProfileCatalog(options.swarmHome)
    const loadedReviewerConfig = loadFableReviewerConfig(options.swarmHome)
    const requireRuntimeAttestation = options.runtimeAttestationPath !== undefined
      || options.generationFactory === undefined
    const attestedReviewerAuthority = requireRuntimeAttestation
      ? attestedFableReviewerConfigHash(
        options.runtimeAttestationPath, options.expectedRuntimeAttestationUid,
      )
      : { configSha256: loadedReviewerConfig.sha256, reviewerSha256: undefined }
    if (loadedReviewerConfig.sha256 !== attestedReviewerAuthority.configSha256) {
      throw new Error('fable-reviewer.json differs from the installed root authority')
    }
    this.fableReviewerConfig = loadedReviewerConfig.config
    this.fableReviewerConfigSha256 = loadedReviewerConfig.sha256
    this.rotationStatePath = join(options.stateDir, 'profile-rotation-state.json')
    this.rotationState = readRotationHarnessState(options.stateDir)
    this.reconcileRotationStateWithConfiguredRows()
    this.profileTelemetryReader = options.profileTelemetryReader ?? (options.generationFactory
      ? async () => unknownQuotaTelemetry()
      : async profile => {
      try {
        const sanitized = await readFixedProfileTelemetry(profile, { cwd: options.stateDir })
        if ('status' in sanitized) return unknownQuotaTelemetry()
        return parseRolloutTelemetry(JSON.stringify({
          timestamp: sanitized.timestamp,
          type: 'event_msg',
          payload: { type: 'token_count', info: null, rate_limits: sanitized.rate_limits },
        }))
      } catch {
        return unknownQuotaTelemetry('malformed')
      }
    })
    this.reviewRunner = options.reviewRunner
      ?? (prompt => spawnFixedReviewRunner({ cwd: options.stateDir }, prompt))
    this.completionReviewRunner = options.completionReviewRunner
      ?? (request => spawnFixedFableCompletionReview({
        cwd: options.stateDir,
        expectedReviewerSha256: attestedReviewerAuthority.reviewerSha256,
      }, request))
    this.facadeFactory = options.facadeFactory ?? (facadeOptions => new CodexNativeReadOnlyFacade(facadeOptions))
    this.maxControlBodyBytes = options.maxControlBodyBytes ?? 64 * 1024
    // A raw 5MiB review can expand substantially when JSON escapes control
    // characters. Bound the wire envelope separately from the raw prompt.
    this.maxReviewBodyBytes = options.maxReviewBodyBytes ?? MANAGER_MAX_REVIEW_BODY_BYTES
    this.requestBodyTimeoutMs = options.requestBodyTimeoutMs ?? 5_000
    this.reservationTtlMs = options.reservationTtlMs ?? MANAGER_DEFAULT_RESERVATION_TTL_MS
    if (!Number.isSafeInteger(this.reservationTtlMs) || this.reservationTtlMs <= 0
      || this.reservationTtlMs > MANAGER_MAX_RESERVATION_TTL_MS) {
      throw new Error(`reservationTtlMs must be an integer from 1 through ${MANAGER_MAX_RESERVATION_TTL_MS}`)
    }
    this.cleanupPendingTtlMs = options.cleanupPendingTtlMs ?? MANAGER_DEFAULT_CLEANUP_PENDING_TTL_MS
    if (!Number.isSafeInteger(this.cleanupPendingTtlMs) || this.cleanupPendingTtlMs <= 0
      || this.cleanupPendingTtlMs > MANAGER_MAX_CLEANUP_PENDING_TTL_MS) {
      throw new Error(`cleanupPendingTtlMs must be an integer from 1 through ${MANAGER_MAX_CLEANUP_PENDING_TTL_MS}`)
    }
    this.completionReviewTtlMs = options.completionReviewTtlMs ?? null
    if (this.completionReviewTtlMs !== null
      && (!Number.isSafeInteger(this.completionReviewTtlMs)
        || this.completionReviewTtlMs < 10 || this.completionReviewTtlMs > 4_230_000)) {
      throw new Error('completionReviewTtlMs test seam is out of bounds')
    }
    this.control.headersTimeout = 5_000
    this.control.requestTimeout = 0
    this.control.keepAliveTimeout = 65_000
    this.control.maxHeadersCount = 32
    this.control.maxConnections = 64
  }

  static async start(options: AppServerManagerOptions): Promise<AppServerManager> {
    const stateDir = validatePrivateStateBoundary(options.stateDir, false)
    if (stateDir !== options.stateDir) throw new Error('manager state dir must be canonical')
    const swarmHome = realpathSync(options.swarmHome)
    if (swarmHome !== options.swarmHome) throw new Error('SWARM_HOME must be canonical')
    const manager = new AppServerManager({ ...options, stateDir, swarmHome })
    try {
      // Startup has the same no-lease safety boundary as a drained resume.
      // In particular, macOS may close the first hidden-UID generation while
      // its per-user helpers settle after a prior quiescence proof.  Retry the
      // bounded generation restore here too. Do not publish the control socket
      // until the generation is stable and idle, so a concurrent first-launch
      // caller can wait on the tmux generation instead of observing a valid
      // but not-yet-ready endpoint.
      await manager.restoreReadyGeneration()
    } catch (error) {
      await manager.stopGeneration().catch(() => {})
      throw error
    }
    try {
      manager.controlIdentity = await listenOwnerUnixSocket(manager.control, manager.controlSocketPath)
    } catch (error) {
      await manager.stopGeneration().catch(() => {})
      throw error
    }
    if (manager.phase !== 'idle' || !manager.generationHandle) {
      const identity = manager.controlIdentity
      manager.controlIdentity = null
      await manager.stopGeneration().catch(() => {})
      await closeOwnedUnixServer(manager.control, identity)
      throw new Error('upstream App Server exited while publishing manager readiness')
    }
    return manager
  }

  health(): ManagerHealthResponse {
    const status: ManagerHealthResponse['status'] = this.operationInProgress && this.phase === 'idle' ? 'busy'
      : this.phase === 'idle' ? 'ready'
      : this.phase === 'drained' ? 'drained'
      : this.phase === 'completion-review-pending' || this.phase === 'completion-review-complete'
        ? 'review-pending'
      : this.phase === 'terminal-cleanup-pending' ? 'cleanup-pending'
      : this.phase === 'ambiguous' ? 'ambiguous'
      : this.phase === 'stopping' ? 'stopping' : 'busy'
    return {
      schema: APP_SERVER_MANAGER_SCHEMA,
      status,
      phase: this.phase,
      generation: this.generation,
      registeredSwarmCount: this.registrations.size,
      upstreamReady: this.generationHandle !== null,
      upstreamState: ['completion-review-pending', 'completion-review-complete', 'terminal-cleanup-pending'].includes(this.phase)
        ? 'cleanup-pending'
        : this.phase === 'ambiguous' ? 'ambiguous'
        : this.generationHandle ? 'ready' : 'stopped',
      managerVersion: APP_SERVER_MANAGER_VERSION,
      protocolVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
      cliVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
    }
  }

  private poolDeclaration(poolName: string): ProfilePoolDeclaration {
    const pool = this.profileCatalog.pools[poolName]
    if (!pool) throw new ManagerHttpError(409, `unknown Codex auth pool: ${poolName}`)
    return validateProfilePool(this.profileCatalog.profiles, pool)
  }

  private currentReviewerConfig(): FableReviewerConfig {
    const current = loadFableReviewerConfig(this.options.swarmHome)
    if (current.sha256 !== this.fableReviewerConfigSha256
      || JSON.stringify(current.config) !== JSON.stringify(this.fableReviewerConfig)) {
      throw new ManagerHttpError(409, 'fable-reviewer.json changed after manager startup')
    }
    return current.config
  }

  async reviewerScope(
    request: ManagerReviewerScopeRequest,
    ownerSocket: Socket | null = null,
  ): Promise<ManagerReviewerScopeResponse> {
    if (!object(request) || !exactObjectKeys(request, ['schema'], ['slot_token'])
      || request.schema !== FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA
      || (request.slot_token !== undefined && !/^[0-9a-f]{64}$/.test(request.slot_token))) {
      throw new ManagerHttpError(400, 'invalid reviewer scope request')
    }
    const peerUid = operatorPeerUid(ownerSocket)
    const operatorUid = typeof process.getuid === 'function' ? process.getuid() : null
    if (ownerSocket !== null && (peerUid === null || operatorUid === null || peerUid !== operatorUid)) {
      throw new ManagerHttpError(403, 'reviewer scope peer is not the operator')
    }
    // The App Server worker can reach this endpoint only through its MCP shim,
    // but an active turn is not a trusted completion boundary. Scope is now
    // minted solely by beginCompletionReview after a terminal App Server event,
    // generation reap, hidden-UID ACL revocation, and host snapshot capture.
    // Refusal intentionally emits no slot and therefore cannot create an
    // artifact that a completion gate might mistake for terminal evidence.
    throw new ManagerHttpError(409, 'worker-initiated reviewer scope is disabled; review is host-owned')
  }

  /**
   * Remove only leases whose Codex row no longer exists. Ordinary daemon
   * unregister/restart leaves the row present and therefore preserves its
   * lease; allocation re-runs this proof so removal does not require a manager
   * restart to release an otherwise dormant exclusive profile.
   */
  private reconcileRotationStateWithConfiguredRows(): ReadonlySet<string> {
    const configured = configuredCodexSwarms(this.options.swarmHome)
    const swarms = Object.fromEntries(
      Object.entries(this.rotationState.swarms)
        .filter(([swarm]) => configured.has(swarm)),
    )
    if (Object.keys(swarms).length !== Object.keys(this.rotationState.swarms).length) {
      this.rotationState = { swarms }
      this.persistRotationState()
    }
    return configured
  }

  private persistRotationState(): void {
    writePrivateJson(this.rotationStatePath, {
      schema: ROTATION_STATE_SCHEMA,
      swarms: this.rotationState.swarms,
    })
    const leases = leasesFromHarnessState(this.rotationState)
    for (const registration of this.registrations.values()) {
      const state = this.rotationState.swarms[registration.swarm]
      if (!state) continue
      const pool = this.poolDeclaration(registration.pool)
      const choice = chooseProfileForSwarm({
        registry: this.profileCatalog.profiles,
        pool,
        leases,
        swarmName: registration.swarm,
        telemetry: state.telemetry,
        cooldowns: state.cooldowns,
      })
      const profiles = pool.profiles.map(label => {
        const telemetry = state.telemetry[label] ?? unknownQuotaTelemetry()
        return {
          label,
          shared: this.profileCatalog.profiles.find(item => item.label === label)?.shared === true,
          leased_by: Object.entries(leases).filter(([, profile]) => profile === label).map(([swarm]) => swarm),
          cooldown_until_ms: state.cooldowns[label] ?? null,
          telemetry_status: telemetry.status,
          observed_at_ms: telemetry.observedAtMs,
          headroom_percent: profileHeadroom(telemetry),
          five_hour: telemetry.status === 'fresh' && telemetry.fiveHour
            ? { used_percent: telemetry.fiveHour.usedPercent, resets_at_ms: telemetry.fiveHour.resetsAtMs }
            : null,
          weekly: telemetry.status === 'fresh' && telemetry.weekly
            ? { used_percent: telemetry.weekly.usedPercent, resets_at_ms: telemetry.weekly.resetsAtMs }
            : null,
        }
      })
      writePrivateJson(join(registration.stateDir, 'rotation-state.json'), {
        schema: ROTATION_STATE_SCHEMA,
        swarm: registration.swarm,
        pool: registration.pool,
        threshold_percent: registration.thresholdPercent,
        active_profile: state.activeProfile,
        parked_until_ms: state.activeProfile === null && choice.kind === 'exhausted' ? choice.resumeAtMs : null,
        profiles,
      })
    }
  }

  private ensureSwarmProfile(swarm: string, poolName: string, nowMs = Date.now()): {
    state: SwarmProfileState
    parkedUntilMs: number | null
  } {
    this.reconcileRotationStateWithConfiguredRows()
    const pool = this.poolDeclaration(poolName)
    const loaded = this.rotationState.swarms[swarm] ?? {
      activeProfile: null, cooldowns: {}, telemetry: {},
    }
    const prior: SwarmProfileState = {
      ...loaded,
      telemetry: telemetryAtBoundary(loaded.telemetry, nowMs),
    }
    const cooldowns = Object.fromEntries(
      Object.entries(prior.cooldowns).filter(([, until]) => until > nowMs),
    )
    let activeProfile = prior.activeProfile
    const leases = leasesFromHarnessState(this.rotationState)
    const entry = activeProfile
      ? this.profileCatalog.profiles.find(profile => profile.label === activeProfile)
      : null
    const activeTelemetry = activeProfile ? prior.telemetry[activeProfile] : undefined
    const activeSoft = activeTelemetry
      ? decideSoftCooldown(activeTelemetry, pool.thresholdPercent, nowMs)
      : { trigger: false }
    const exclusiveConflict = activeProfile && entry?.shared !== true
      ? Object.entries(leases).some(([owner, profile]) => owner !== swarm && profile === activeProfile)
      : false
    if (!activeProfile || !pool.profiles.includes(activeProfile)
      || (cooldowns[activeProfile] ?? 0) > nowMs || activeSoft.trigger || exclusiveConflict || !entry) {
      const choice = chooseProfileForSwarm({
        registry: this.profileCatalog.profiles,
        pool,
        leases,
        swarmName: swarm,
        telemetry: prior.telemetry,
        cooldowns,
        nowMs,
      })
      activeProfile = choice.kind === 'selected' ? choice.profile : null
    }
    const state: SwarmProfileState = { activeProfile, cooldowns, telemetry: prior.telemetry }
    this.rotationState = {
      ...this.rotationState,
      swarms: { ...this.rotationState.swarms, [swarm]: state },
    }
    const choice = chooseProfileForSwarm({
      registry: this.profileCatalog.profiles,
      pool,
      leases: leasesFromHarnessState(this.rotationState),
      swarmName: swarm,
      telemetry: state.telemetry,
      cooldowns: state.cooldowns,
      nowMs,
    })
    const parkedUntilMs = activeProfile === null && choice.kind === 'exhausted' ? choice.resumeAtMs : null
    return { state, parkedUntilMs }
  }

  async register(request: ManagerRegisterRequest): Promise<ManagerRegisterResponse> {
    return this.exclusiveOperation(() => this.registerExclusive(request))
  }

  private async registerExclusive(request: ManagerRegisterRequest): Promise<ManagerRegisterResponse> {
    this.requireIdle()
    if (!safeSwarm(request.swarm)) throw new ManagerHttpError(400, 'invalid swarm')
    const operatorHome = this.options.operatorHome ?? userInfo().homedir
    const expectedState = join(operatorHome, '.codex', 'channels', `discord-${request.swarm}`)
    if (request.stateDir !== expectedState) throw new ManagerHttpError(400, 'stateDir does not match swarm')
    const stateDir = validatePrivateStateBoundary(request.stateDir, false)
    const row = parseCodexRow(this.options.swarmHome, request.swarm)
    const repo = realpathSync(request.repo)
    if (repo !== request.repo || repo !== row.repo || inside(this.options.swarmHome, repo)) {
      throw new ManagerHttpError(400, 'repo does not match the exact canonical Codex row')
    }
    const assignment = this.ensureSwarmProfile(request.swarm, row.pool)
    const profile = assignment.state.activeProfile
    const persisted = profile ? parseSessionsFile(stateDir, profile) : []
    const sessions = request.sessions === undefined ? persisted : uniqueSessions(request.sessions)
    if (request.sessions !== undefined
      && (sessions.length !== persisted.length || sessions.some(id => !persisted.includes(id)))) {
      throw new ManagerHttpError(409, 'sessions do not match private persisted state')
    }
    const existing = this.registrations.get(request.swarm)
    this.assertThreadsUnclaimed(sessions, existing)
    if (request.profile) {
      throw new ManagerHttpError(400, 'named CODEX_PROFILE cannot be safely layered per App Server thread')
    }
    const model = request.model ?? this.options.model ?? DEFAULT_CODEX_MODEL
    if (!/^[A-Za-z0-9_.:-]{1,128}$/.test(model)) throw new ManagerHttpError(400, 'invalid model')
    const reasoningEffort = request.reasoningEffort ?? DEFAULT_CODEX_REASONING_EFFORT
    if (!isManagedCodexReasoningEffort(reasoningEffort)) {
      throw new ManagerHttpError(400, 'invalid reasoning effort')
    }
    if (existing) {
      if (existing.repo !== repo || existing.stateDir !== stateDir) {
        throw new ManagerHttpError(409, 'existing swarm registration has different authority')
      }
      await this.revalidateRegistration(existing)
      this.assertThreadsUnclaimed(sessions, existing)
      const candidate: Registration = {
        ...existing,
        token: randomCapability(),
        primaryThreads: new Set(profile === existing.profile ? existing.primaryThreads : sessions),
        threads: new Set(profile === existing.profile ? existing.threads : sessions),
        parents: new Map(profile === existing.profile ? existing.parents : []),
        model,
        reasoningEffort,
        profile,
        pool: row.pool,
        thresholdPercent: this.poolDeclaration(row.pool).thresholdPercent
          ?? DEFAULT_ROTATION_THRESHOLD_PERCENT,
      }
      this.replacePrimaryThreads(candidate, sessions)
      const priorThreads = [...existing.threads]
      const unionThreads = profile === existing.profile
        ? [...new Set([...priorThreads, ...candidate.threads])]
        : [...candidate.threads]
      existing.facade.setModel(model)
      existing.facade.setReasoningEffort(reasoningEffort)
      existing.facade.replaceThreadIds(unionThreads)
      try {
        if (candidate.profile) {
          await this.ensureGenerationProfile(candidate.profile)
          await this.refreshRegistrationHistory(candidate)
        }
      } catch (error) {
        existing.facade.setModel(existing.model)
        existing.facade.setReasoningEffort(existing.reasoningEffort)
        existing.facade.replaceThreadIds(priorThreads)
        throw error
      }
      this.clearReservationCancelTombstones(existing)
      this.tokens.delete(existing.token)
      existing.token = candidate.token
      existing.model = candidate.model
      existing.reasoningEffort = candidate.reasoningEffort
      existing.primaryThreads = candidate.primaryThreads
      existing.threads = candidate.threads
      existing.parents = candidate.parents
      existing.profile = candidate.profile
      existing.pool = candidate.pool
      existing.thresholdPercent = candidate.thresholdPercent
      existing.facade.replaceThreadIds([...existing.threads])
      this.tokens.set(existing.token, existing)
      this.persistRotationState()
      return {
        registrationToken: existing.token,
        generation: this.generation,
        facadeEndpoint: existing.facade.endpoint,
        serverVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
        reasoningEffort: existing.reasoningEffort,
        activeProfile: existing.profile,
        pool: existing.pool,
        thresholdPercent: existing.thresholdPercent,
        parkedUntilMs: assignment.parkedUntilMs,
      }
    }
    const facade = this.facadeFactory({
      socketPath: join(ensureNativeViewDir(stateDir), 'app-server.sock'),
      swarmName: request.swarm,
      repo,
      stateDir,
      model,
      reasoningEffort,
    })
    facade.replaceThreadIds(sessions)
    await facade.start()
    const registration: Registration = {
      swarm: request.swarm, repo, stateDir, token: randomCapability(), facade,
      primaryThreads: new Set(sessions), threads: new Set(sessions),
      parents: new Map(), model, reasoningEffort, profile: 'default',
      pool: row.pool,
      thresholdPercent: this.poolDeclaration(row.pool).thresholdPercent
        ?? DEFAULT_ROTATION_THRESHOLD_PERCENT,
    }
    registration.profile = profile
    this.registrations.set(request.swarm, registration)
    this.tokens.set(registration.token, registration)
    try {
      if (registration.profile) {
        await this.ensureGenerationProfile(registration.profile)
        await this.refreshRegistrationHistory(registration)
      }
    } catch (error) {
      this.registrations.delete(request.swarm)
      this.tokens.delete(registration.token)
      await facade.close()
      throw error
    }
    this.persistRotationState()
    return {
      registrationToken: registration.token,
      generation: this.generation,
      facadeEndpoint: facade.endpoint,
      serverVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
      reasoningEffort: registration.reasoningEffort,
      activeProfile: registration.profile,
      pool: registration.pool,
      thresholdPercent: registration.thresholdPercent,
      parkedUntilMs: assignment.parkedUntilMs,
    }
  }

  async replaceSessions(request: ManagerSessionsReplaceRequest): Promise<ManagerSessionsReplaceResponse> {
    return this.exclusiveOperation(() => this.replaceSessionsExclusive(request))
  }

  private async replaceSessionsExclusive(
    request: ManagerSessionsReplaceRequest,
  ): Promise<ManagerSessionsReplaceResponse> {
    const registration = this.registrationForToken(request.registrationToken)
    const cleanupOwner = this.phase === 'terminal-cleanup-pending'
      && this.lease?.registration === registration
    if (this.phase !== 'idle' && !cleanupOwner) throw new ManagerHttpError(409, `manager is ${this.phase}`)
    await this.revalidateRegistration(registration)
    const sessions = uniqueSessions(request.sessions)
    this.assertThreadsUnclaimed(sessions, registration)
    const sessionProfile = cleanupOwner ? this.lease?.profile : registration.profile
    const persisted = sessionProfile ? parseSessionsFile(registration.stateDir, sessionProfile) : []
    if (sessions.length !== persisted.length || sessions.some(id => !persisted.includes(id))) {
      throw new ManagerHttpError(409, 'sessions do not match private persisted state')
    }
    this.replacePrimaryThreads(registration, sessions)
    registration.facade.replaceThreadIds([...registration.threads])
    if (this.phase === 'idle' && registration.profile === this.generationProfile) {
      await this.refreshRegistrationHistory(registration)
    }
    this.clearReservationCancelTombstones(registration)
    return {
      generation: this.generation,
      facadeEndpoint: registration.facade.endpoint,
      sessionCount: sessions.length,
    }
  }

  async reserveTurn(request: ManagerTurnReserveRequest): Promise<ManagerTurnReserveResponse> {
    return this.exclusiveOperation(() => this.reserveTurnExclusive(request))
  }

  private async reserveTurnExclusive(
    request: ManagerTurnReserveRequest,
  ): Promise<ManagerTurnReserveResponse> {
    const current = this.reservation
    if (this.phase === 'reserved' && current) {
      if (Date.now() >= current.expiresAtMs) {
        this.expireReservation(current)
        throw new ManagerHttpError(409, 'turn reservation expired; manager is blocked')
      }
      if (request.registrationToken === current.registration.token
        && request.requestId === current.requestId) {
        return {
          reservationToken: current.token,
          requestId: current.requestId,
          expiresAtMs: current.expiresAtMs,
          generation: current.generation,
          profile: current.profile,
        }
      }
      throw new ManagerHttpError(409, 'manager is reserved by another turn request', true)
    }
    this.requireIdle()
    const registration = this.registrationForToken(request.registrationToken)
    if (!safeToken(request.requestId, 128) || this.requestIds.has(request.requestId)) {
      throw new ManagerHttpError(409, 'invalid or duplicate requestId')
    }
    await this.revalidateRegistration(registration)
    const assignment = this.ensureSwarmProfile(registration.swarm, registration.pool)
    registration.profile = assignment.state.activeProfile
    this.persistRotationState()
    if (!registration.profile) {
      throw new ManagerHttpError(
        409,
        'Codex auth pool exhausted',
        true,
        assignment.parkedUntilMs,
      )
    }
    await this.ensureGenerationProfile(registration.profile)
    this.requireIdle()
    const stableHandle = this.generationHandle
    const stableGeneration = this.generation
    if (this.generationHandle !== stableHandle || this.generation !== stableGeneration
      || this.tokens.get(request.registrationToken) !== registration) {
      throw new ManagerHttpError(409, 'manager readiness changed during reservation admission', true)
    }
    const expiresAtMs = Date.now() + this.reservationTtlMs
    const reservation: TurnReservation = {
      token: randomCapability(), registration, requestId: request.requestId,
      expiresAtMs, generation: this.generation,
      profile: registration.profile,
      timer: setTimeout(() => this.expireReservation(reservation), this.reservationTtlMs),
    }
    reservation.timer.unref?.()
    this.requestIds.add(request.requestId)
    this.reservation = reservation
    this.drainRecovery = 'none'
    this.phase = 'reserved'
    return {
      reservationToken: reservation.token,
      requestId: reservation.requestId,
      expiresAtMs,
      generation: reservation.generation,
      profile: reservation.profile,
    }
  }

  async cancelTurnReservation(
    request: ManagerTurnReservationCancelRequest,
  ): Promise<ManagerTurnReservationCancelResponse> {
    // Exact tombstone replay is a read-only acknowledgement and must not wait
    // behind an unrelated active turn's long-lived exclusive operation.
    if (this.isReservationCancelReplay(request)) return { cancelled: true }
    return this.exclusiveOperation(() => this.cancelTurnReservationExclusive(request))
  }

  private async cancelTurnReservationExclusive(
    request: ManagerTurnReservationCancelRequest,
  ): Promise<ManagerTurnReservationCancelResponse> {
    const registration = this.registrationForToken(request.registrationToken)
    // A tombstone is an acknowledgement only. Check it before the current
    // reservation so a lost response from A cannot let A's retry inspect or
    // mutate a newer reservation held by B.
    if (this.isReservationCancelReplay(request, registration)) return { cancelled: true }
    const reservation = this.reservation
    if (!reservation) {
      throw new ManagerHttpError(409, 'no active turn reservation')
    }
    if (!['reserved', 'ambiguous'].includes(this.phase)) {
      throw new ManagerHttpError(409, 'no active turn reservation')
    }
    if (!safeToken(request.requestId, 128)
      || !safeToken(request.reservationToken, 128)
      || reservation.registration !== registration
      || reservation.requestId !== request.requestId
      || reservation.token !== request.reservationToken) {
      throw new ManagerHttpError(403, 'turn reservation capability mismatch')
    }
    const tombstone: TurnReservationCancelTombstone = {
      registration,
      registrationToken: request.registrationToken,
      reservationToken: request.reservationToken,
      requestId: request.requestId,
      generation: this.generation,
    }
    this.releaseReservation(reservation, this.phase === 'reserved')
    this.rememberReservationCancel(tombstone)
    return { cancelled: true }
  }

  private isReservationCancelReplay(
    request: ManagerTurnReservationCancelRequest,
    registration?: Registration,
  ): boolean {
    if (!safeToken(request.requestId, 128)
      || !safeToken(request.reservationToken, 128)
      || typeof request.registrationToken !== 'string'
      || !/^[0-9a-f]{64}$/.test(request.registrationToken)) return false
    const bound = registration ?? this.tokens.get(request.registrationToken)
    if (!bound) return false
    return this.reservationCancelTombstones.some(tombstone =>
      tombstone.registration === bound
      && tombstone.registrationToken === request.registrationToken
      && tombstone.reservationToken === request.reservationToken
      && tombstone.requestId === request.requestId
      && tombstone.generation === this.generation)
  }

  async startTurn(request: ManagerTurnStartRequest, ownerSocket: Socket | null = null): Promise<ManagerTurnStartResponse> {
    return this.exclusiveOperation(() => this.startTurnExclusive(request, ownerSocket))
  }

  private async startTurnExclusive(
    request: ManagerTurnStartRequest,
    ownerSocket: Socket | null,
  ): Promise<ManagerTurnStartResponse> {
    const registration = this.registrationForToken(request.registrationToken)
    const reservation = this.reservation
    if (this.phase !== 'reserved' || !reservation) {
      throw new ManagerHttpError(409, 'manager has no matching turn reservation')
    }
    if (!safeToken(request.requestId, 128)
      || !safeToken(request.reservationToken, 128)
      || reservation.registration !== registration
      || reservation.requestId !== request.requestId
      || reservation.token !== request.reservationToken) {
      throw new ManagerHttpError(403, 'turn reservation capability mismatch')
    }
    if (registration.profile !== reservation.profile || this.generationProfile !== reservation.profile) {
      throw new ManagerHttpError(409, 'turn auth-profile lease changed before start')
    }
    const stableHandle = this.generationHandle
    const stableGeneration = this.generation
    try {
      await this.revalidateReservedRegistration(registration)
    } catch (error) {
      if (this.phase === 'reserved' && this.reservation === reservation) {
        // Do not revoke the registration token or reservation capability here:
        // the daemon may already have granted attachment ACLs and still needs
        // the exact cancel endpoint for its cleanup finally block.  Authority
        // drift nevertheless blocks admission and reaps the upstream.
        this.drainRecovery = 'none'
        this.phase = 'ambiguous'
        void this.stopGeneration().catch(() => {})
      }
      throw new ManagerHttpError(409, `registration authority changed after reservation: ${error}`)
    }
    if (this.phase !== 'reserved' || this.reservation !== reservation
      || this.generationHandle !== stableHandle || this.generation !== stableGeneration
      || this.tokens.get(request.registrationToken) !== registration) {
      throw new ManagerHttpError(409, 'turn reservation changed before lease admission')
    }
    if (typeof request.prompt !== 'string' || Buffer.byteLength(request.prompt) > MAX_TURN_PROMPT_BYTES) {
      throw new ManagerHttpError(413, 'turn prompt exceeds 64MiB')
    }
    // Older non-Discord test/maintenance callers may omit taskId, but such a
    // lease deliberately receives no reviewer scope. Production callers are
    // statically required to carry the immutable Discord message ID.
    const taskId = request.taskId as string | undefined
    if (taskId !== undefined
      && (!safeToken(taskId, 128) || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/.test(taskId))) {
      throw new ManagerHttpError(400, 'turn taskId is invalid')
    }
    const readable = this.validateTurnRoots(registration, safeRootList(request.readableRoots, 'readableRoots'), 'read')
    const writable = this.validateTurnRoots(registration, safeRootList(request.writableRoots, 'writableRoots'), 'write')
    const denied = safeRootList(request.deniedPaths, 'deniedPaths')
    const environment = safeEnvironment(request.environment)
    if (request.threadId !== null
      && (!safeToken(request.threadId) || !registration.threads.has(request.threadId))) {
      throw new ManagerHttpError(400, 'thread is not registered to this swarm')
    }
    const lease = this.consumeReservation(reservation, ownerSocket)
    lease.taskId = taskId ?? null
    try {
      const client = this.requireClient()
      const config = buildAppServerThreadConfig(
        registration.repo, readable, denied, writable, environment, registration.reasoningEffort,
      )
      let effective: AppServerEffectiveThread
      if (request.threadId !== null) {
        try {
          effective = await client.resumeThreadEffective(this.workspaceThreadParams(
            registration.repo, config, request.threadId, registration.model,
          ))
        } catch (error) {
          if (!missingThread(error)) throw error
          registration.threads.delete(request.threadId)
          registration.primaryThreads.delete(request.threadId)
          registration.parents.delete(request.threadId)
          effective = await client.startThreadEffective(this.workspaceThreadParams(
            registration.repo, config, undefined, registration.model,
          ))
        }
      } else {
        effective = await client.startThreadEffective(this.workspaceThreadParams(
          registration.repo, config, undefined, registration.model,
        ))
      }
      this.validateEffective(
        effective, registration.repo, CODEX_PERMISSION_PROFILE, registration.model,
        registration.reasoningEffort, writable,
      )
      const threadId = effective.thread.id
      if (!safeToken(threadId)) throw new Error('upstream returned invalid thread id')
      this.assertThreadsUnclaimed([threadId], registration)
      registration.threads.add(threadId)
      registration.primaryThreads.add(threadId)
      registration.facade.replaceThreadIds([...registration.threads])
      registration.facade.cacheThread(threadId, effective.thread)
      let handle: AppServerTurnHandle
      try {
        handle = await client.startTurn({
          threadId,
          clientUserMessageId: request.clientUserMessageId ?? null,
          input: [{ type: 'text', text: request.prompt, text_elements: [] }],
          cwd: registration.repo,
          approvalPolicy: 'never',
          // thread/start or thread/resume has already loaded and verified the
          // complete named permission profile for this exact turn. Supplying a
          // legacy sandboxPolicy here would replace that profile and discard its
          // protected-path read rules before model tool execution.
          model: registration.model,
          effort: registration.reasoningEffort,
        })
      } catch (error) {
        if (!structuredRemoteQuotaFailure(error)) throw error
        const turnId = `quota-${randomCapability()}`
        lease.threadId = threadId
        lease.turnId = turnId
        lease.resolveTurnReady({ threadId, turnId })
        const result: AppServerTurnResult = {
          ok: false, threadId, turnId, status: 'failed', messages: [],
          error: 'structured upstream usage limit rejection', quotaLimited: true,
          ambiguous: false,
        }
        return await this.completeTerminalTurnLease(lease, result, reservation.profile)
      }
      this.bindTurn(lease, handle)
      const result = await handle.completion
      if (result.ambiguous) {
        await this.blockAmbiguous('upstream turn outcome is ambiguous')
        throw new ManagerHttpError(503, 'turn outcome is ambiguous; manager remains stopped')
      }
      return await this.completeTerminalTurnLease(lease, result, reservation.profile)
    } catch (error) {
      if (this.phase === 'active') await this.blockAmbiguous('turn failed before a proven terminal event')
      throw error
    } finally {
      this.requestIds.delete(request.requestId)
    }
  }

  private async completeTerminalTurnLease(
    lease: ActiveLease,
    result: AppServerTurnResult,
    profile: string,
  ): Promise<ManagerTurnStartResponse> {
    this.detachLeaseOwner(lease)
    lease.terminalResult = result
    this.phase = 'terminal-cleanup-pending'
    try {
      await this.stopGeneration()
    } catch {
      this.drainRecovery = 'none'
      this.phase = 'ambiguous'
      throw new ManagerHttpError(503, 'upstream reap failed after terminal turn; manager is blocked')
    }
    // Telemetry is read only after the generation is reaped, but before the
    // daemon-facing cleanup deadline starts. The caller cannot acknowledge a
    // result it has not received yet.
    await this.planRotationAfterTurn(lease, result)
    this.armCleanupPendingTimer(lease)
    if (this.lease !== lease || this.phase !== 'terminal-cleanup-pending'
      || !lease.threadId || !lease.turnId) {
      throw new ManagerHttpError(503, 'turn cleanup acknowledgement deadline expired; manager is blocked')
    }
    return {
      leaseId: lease.id, threadId: lease.threadId, turnId: lease.turnId, result,
      cleanupRequired: true, generation: this.generation, profile,
      rotation: lease.rotation,
    }
  }

  private async planRotationAfterTurn(lease: ActiveLease, result: AppServerTurnResult): Promise<void> {
    const registration = lease.registration
    const profile = lease.profile
    if (!registration || !profile) return
    const configured = this.reconcileRotationStateWithConfiguredRows()
    if (!configured.has(registration.swarm)) {
      // The just-completed task is still cleaned up normally, but a removed
      // row cannot reacquire a lease while planning its terminal rotation.
      lease.pendingRotationState = this.rotationState
      return
    }
    let telemetry: QuotaTelemetry
    try { telemetry = await this.profileTelemetryReader(profile) } catch {
      telemetry = unknownQuotaTelemetry('malformed')
    }
    const current = this.rotationState.swarms[registration.swarm] ?? {
      activeProfile: profile, cooldowns: {}, telemetry: {},
    }
    const sampled: RotationHarnessState = {
      ...this.rotationState,
      swarms: {
        ...this.rotationState.swarms,
        [registration.swarm]: {
          ...current,
          activeProfile: profile,
          telemetry: { ...current.telemetry, [profile]: telemetry },
        },
      },
    }
    const nowMs = Date.now()
    const knownReset = telemetry.status === 'fresh'
      ? Math.max(0, ...[telemetry.fiveHour, telemetry.weekly]
        .filter((window): window is NonNullable<typeof window> => window !== null)
        .map(window => window.resetsAtMs))
      : 0
    const hard = result.quotaLimited === true
      ? decideHardLimitCooldown({
        code: 'usage_limit_exceeded',
        ...(knownReset > nowMs ? { reset_at: knownReset } : {}),
      }, nowMs)
      : decideHardLimitCooldown(null, nowMs)
    const soft = decideSoftCooldown(telemetry, registration.thresholdPercent, nowMs)
    const trigger = hard.hardLimit || soft.trigger
    if (!trigger) {
      lease.pendingRotationState = sampled
      return
    }
    const cooldownUntilMs = hard.hardLimit ? hard.cooldownUntilMs : soft.cooldownUntilMs
    if (cooldownUntilMs === null || cooldownUntilMs <= nowMs) {
      lease.pendingRotationState = sampled
      return
    }
    const rotated = rotateSwarmProfile({
      state: sampled,
      registry: this.profileCatalog.profiles,
      pool: this.poolDeclaration(registration.pool),
      swarmName: registration.swarm,
      coolingProfile: profile,
      cooldownUntilMs,
      nowMs,
    })
    lease.pendingRotationState = rotated.state
    lease.rotation = {
      reason: hard.hardLimit ? 'hard' : 'soft',
      previousProfile: profile,
      activeProfile: rotated.activeProfile,
      parkedUntilMs: rotated.parked ? rotated.resumeAtMs : null,
    }
  }

  async interruptTurn(request: ManagerTurnInterruptRequest): Promise<ManagerTurnInterruptResponse> {
    const registration = this.registrationForToken(request.registrationToken)
    const lease = this.lease
    if (!lease || lease.kind !== 'turn' || lease.registration !== registration || lease.requestId !== request.requestId
      || this.phase !== 'active') throw new ManagerHttpError(409, 'no matching active turn')
    const target = await this.withTimeout(lease.turnReady, 10_000, 'turn has not been accepted yet')
    await this.requireClient().interrupt(target.threadId, target.turnId)
    return { accepted: true, ...target }
  }

  async beginCompletionReview(
    request: ManagerCompletionReviewBeginRequest,
  ): Promise<ManagerCompletionReviewBeginResponse> {
    return this.exclusiveOperation(() => this.beginCompletionReviewExclusive(request))
  }

  private async beginCompletionReviewExclusive(
    request: ManagerCompletionReviewBeginRequest,
  ): Promise<ManagerCompletionReviewBeginResponse> {
    if (!object(request) || !exactObjectKeys(request, [
      'schema', 'registrationToken', 'leaseId', 'reviewedDiffSha256', 'arguments',
    ]) || request.schema !== MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA
      || !safeToken(request.leaseId) || !REVIEW_SHA256.test(request.reviewedDiffSha256)) {
      throw new ManagerHttpError(400, 'invalid completion review begin request')
    }
    const registration = this.registrationForToken(request.registrationToken)
    const lease = this.lease
    if (!lease || lease.kind !== 'turn' || lease.registration !== registration
      || lease.id !== request.leaseId || !lease.profile || !lease.taskId
      || lease.terminalResult?.ok !== true || this.generationHandle !== null
      || !['terminal-cleanup-pending', 'completion-review-pending', 'completion-review-complete'].includes(this.phase)) {
      throw new ManagerHttpError(409, 'no matching successful terminal turn for completion review')
    }
    const normalized = normalizeCompletionReviewArguments(
      request.arguments, request.reviewedDiffSha256,
    )
    if (lease.completionReview) {
      if (lease.completionReview.inputSha256 !== normalized.inputSha256
        || lease.completionReview.reviewedDiffSha256 !== request.reviewedDiffSha256
        || lease.completionReview.status === 'failed') {
        throw new ManagerHttpError(409, 'completion review begin does not match the active invocation')
      }
      return {
        schema: MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA,
        status: 'pending',
        leaseId: lease.id,
        completionToken: lease.completionReview.token,
        expiresAtMs: lease.completionReview.expiresAtMs,
      }
    }
    if (this.phase !== 'terminal-cleanup-pending') {
      throw new ManagerHttpError(409, 'completion review cannot begin from the current phase')
    }
    await this.revalidateRegistration(registration)
    if (this.phase !== 'terminal-cleanup-pending' || this.lease !== lease
      || lease.completionReview !== null || this.generationHandle !== null) {
      throw new ManagerHttpError(409, 'terminal completion review boundary changed during revalidation')
    }
    const policy = resolveReviewerPolicy(this.currentReviewerConfig(), registration.swarm)
    const completionToken = randomCapability()
    const expiresAtMs = Date.now() + (this.completionReviewTtlMs
      ?? (policy.windowSeconds + policy.timeoutSeconds + 30) * 1000)
    this.clearCleanupPendingTimer(lease)
    this.phase = 'completion-review-pending'
    const state: NonNullable<ActiveLease['completionReview']> = {
      token: completionToken,
      inputSha256: normalized.inputSha256,
      reviewedDiffSha256: request.reviewedDiffSha256,
      expiresAtMs,
      status: 'pending',
      execution: null,
      result: null,
      consumed: false,
    }
    lease.completionReview = state
    let execution: FableCompletionReviewExecution
    try {
      execution = this.completionReviewRunner({
        schema: FABLE_ONE_SHOT_REQUEST_SCHEMA,
        scope: reviewerScopeForLease(lease, completionToken, policy),
        arguments: normalized.arguments,
        expected_reviewed_diff_sha256: request.reviewedDiffSha256,
      })
      state.execution = execution
    } catch {
      state.status = 'failed'
      this.phase = 'ambiguous'
      this.drainRecovery = 'none'
      throw new ManagerHttpError(503, 'fixed host Fable reviewer is unavailable; manager is blocked')
    }
    this.armCompletionReviewTimer(lease, state)
    void execution.completed.then(value => {
      if (this.lease !== lease || lease.completionReview !== state
        || state.status !== 'pending' || this.phase !== 'completion-review-pending') return
      try {
        state.result = validateCompletionReviewRunnerResult(value, state.reviewedDiffSha256)
        state.status = 'complete'
        state.execution = null
        this.phase = 'completion-review-complete'
      } catch {
        state.status = 'failed'
        state.execution = null
        this.clearCompletionReviewTimer(lease)
        this.phase = 'ambiguous'
        this.drainRecovery = 'none'
      }
    }, () => {
      if (this.lease !== lease || lease.completionReview !== state || state.status !== 'pending') return
      state.status = 'failed'
      state.execution = null
      this.clearCompletionReviewTimer(lease)
      this.phase = 'ambiguous'
      this.drainRecovery = 'none'
    })
    return {
      schema: MANAGER_COMPLETION_REVIEW_BEGIN_SCHEMA,
      status: 'pending',
      leaseId: lease.id,
      completionToken,
      expiresAtMs,
    }
  }

  completionReviewStatus(
    request: ManagerCompletionReviewPollRequest,
  ): ManagerCompletionReviewPollResponse {
    if (!object(request) || !exactObjectKeys(request, [
      'registrationToken', 'leaseId', 'completionToken',
    ])) throw new ManagerHttpError(400, 'invalid completion review poll request')
    const registration = this.registrationForToken(request.registrationToken)
    const lease = this.lease
    const review = lease?.completionReview
    if (!lease || lease.kind !== 'turn' || lease.registration !== registration
      || lease.id !== request.leaseId || !review || review.token !== request.completionToken
      || !['completion-review-pending', 'completion-review-complete'].includes(this.phase)
      || review.status === 'failed') {
      throw new ManagerHttpError(409, 'no matching completion review invocation')
    }
    return review.status === 'complete' && review.result
      ? review.result
      : { status: 'pending' }
  }

  consumeCompletionReview(
    request: ManagerCompletionReviewConsumeRequest,
  ): ManagerCompletionReviewReceipt {
    if (!object(request) || !exactObjectKeys(request, [
      'schema', 'completionToken', 'repoRoot', 'taskId',
    ]) || request.schema !== MANAGER_COMPLETION_REVIEW_CONSUME_SCHEMA
      || !safeToken(request.completionToken) || !safeToken(request.taskId, 128)
      || typeof request.repoRoot !== 'string') {
      throw new ManagerHttpError(400, 'invalid completion review consume request')
    }
    const lease = this.lease
    const review = lease?.completionReview
    const registration = lease?.registration
    if (this.phase !== 'completion-review-complete' || !lease || lease.kind !== 'turn'
      || !review || review.status !== 'complete' || !review.result
      || review.token !== request.completionToken
      || !registration || request.repoRoot !== registration.repo || request.taskId !== lease.taskId) {
      throw new ManagerHttpError(409, 'completion review receipt is unavailable or outside its bound scope')
    }
    // Mark before responding, but make an exact replay idempotent. A root
    // broker can crash after the manager commits consumption and before its
    // own durable journal lands; returning the identical manager-bound receipt
    // is safer than either invoking Fable twice or stranding the lease.
    review.consumed = true
    return {
      schema: MANAGER_COMPLETION_REVIEW_RECEIPT_SCHEMA,
      swarm: registration.swarm,
      profile: lease.profile!,
      taskId: lease.taskId!,
      repoRoot: registration.repo,
      reviewedDiffSha256: review.result.reviewedDiffSha256,
      verdict: review.result.verdict,
      artifactName: review.result.artifactName,
      artifactSha256: review.result.artifactSha256,
    }
  }

  endCompletionReview(
    request: ManagerCompletionReviewEndRequest,
  ): ManagerCompletionReviewEndResponse {
    if (!object(request) || !exactObjectKeys(request, [
      'registrationToken', 'leaseId', 'completionToken',
    ])) throw new ManagerHttpError(400, 'invalid completion review end request')
    const registration = this.registrationForToken(request.registrationToken)
    const lease = this.lease
    const review = lease?.completionReview
    if (this.phase !== 'completion-review-complete' || !lease || lease.kind !== 'turn'
      || lease.registration !== registration || lease.id !== request.leaseId
      || !review || review.status !== 'complete' || review.token !== request.completionToken
      || !review.consumed) {
      throw new ManagerHttpError(409, 'completion review is not complete and consumed for this lease')
    }
    this.clearCompletionReviewTimer(lease)
    this.phase = 'terminal-cleanup-pending'
    this.armCleanupPendingTimer(lease)
    return { ended: true, leaseId: lease.id }
  }

  private armCompletionReviewTimer(
    lease: ActiveLease,
    review: NonNullable<ActiveLease['completionReview']>,
  ): void {
    if (lease.completionReviewTimer || review.expiresAtMs <= Date.now()) {
      throw new Error('cannot arm an invalid completion review deadline')
    }
    lease.completionReviewTimer = setTimeout(() => {
      if (this.lease !== lease || lease.completionReview !== review
        || !['completion-review-pending', 'completion-review-complete'].includes(this.phase)
        || review.status === 'failed') return
      review.status = 'failed'
      const execution = review.execution
      review.execution = null
      lease.completionReviewTimer = null
      this.phase = 'ambiguous'
      this.drainRecovery = 'none'
      if (execution) void execution.stopAndWait().catch(() => {})
    }, Math.max(1, review.expiresAtMs - Date.now()))
    lease.completionReviewTimer.unref?.()
  }

  private clearCompletionReviewTimer(lease: ActiveLease): void {
    if (lease.completionReviewTimer) clearTimeout(lease.completionReviewTimer)
    lease.completionReviewTimer = null
  }

  async cleanupComplete(request: ManagerTurnCleanupRequest): Promise<ManagerTurnCleanupResponse> {
    return this.exclusiveOperation(() => this.cleanupCompleteExclusive(request))
  }

  private async cleanupCompleteExclusive(
    request: ManagerTurnCleanupRequest,
  ): Promise<ManagerTurnCleanupResponse> {
    const lease = this.lease
    if (!lease || lease.id !== request.leaseId || this.phase !== 'terminal-cleanup-pending') {
      throw new ManagerHttpError(409, 'no matching cleanup-pending lease')
    }
    const authorized = lease.registration
      ? request.registrationToken === lease.registration.token
      : request.cleanupToken === lease.cleanupToken
    if (!authorized) throw new ManagerHttpError(403, 'cleanup capability mismatch')
    // Once the exact cleanup capability is accepted, the old timeout must be
    // unable to race registration revalidation or generation restoration.
    this.clearCleanupPendingTimer(lease)
    if (request.ok !== true) {
      this.drainRecovery = 'none'
      this.phase = 'ambiguous'
      throw new ManagerHttpError(409, 'cleanup was not proven; manager remains stopped')
    }
    if (lease.pendingRotationState) this.rotationState = lease.pendingRotationState
    const completedRegistration = lease.registration
    if (completedRegistration) {
      const priorProfile = completedRegistration.profile
      completedRegistration.profile = this.rotationState.swarms[completedRegistration.swarm]?.activeProfile ?? null
      if (completedRegistration.profile !== priorProfile) {
        const sessions = completedRegistration.profile
          ? parseSessionsFile(completedRegistration.stateDir, completedRegistration.profile)
          : []
        completedRegistration.primaryThreads = new Set(sessions)
        completedRegistration.threads = new Set(sessions)
        completedRegistration.parents.clear()
        completedRegistration.facade.replaceThreadIds(sessions)
      }
    }
    this.lease = null
    try {
      await this.revalidateAllRegistrations()
      const nextProfile = completedRegistration?.profile
        ?? [...this.registrations.values()].find(item => item.profile !== null)?.profile
        ?? 'default'
      this.generationProfile = nextProfile
      await this.restoreReadyGeneration()
      this.persistRotationState()
      let parkedUntilMs: number | null = null
      if (completedRegistration && completedRegistration.profile === null) {
        const state = this.rotationState.swarms[completedRegistration.swarm]
        if (state) {
          const choice = chooseProfileForSwarm({
            registry: this.profileCatalog.profiles,
            pool: this.poolDeclaration(completedRegistration.pool),
            leases: leasesFromHarnessState(this.rotationState),
            swarmName: completedRegistration.swarm,
            telemetry: state.telemetry,
            cooldowns: state.cooldowns,
          })
          parkedUntilMs = choice.kind === 'exhausted' ? choice.resumeAtMs : null
        }
      }
      return {
        generation: this.generation,
        ready: true,
        activeProfile: completedRegistration?.profile ?? null,
        parkedUntilMs,
      }
    } catch (error) {
      if (this.phase !== 'ambiguous') {
        const stopped = await this.stopGeneration().then(() => true, () => false)
        this.phase = 'ambiguous'
        this.drainRecovery = stopped && this.lease === null
          ? 'prelease-restore-failure'
          : 'none'
      }
      throw error
    }
  }

  async startReview(request: ManagerReviewStartRequest, ownerSocket: Socket | null = null): Promise<ManagerReviewStartResponse> {
    return this.exclusiveOperation(() => this.startReviewExclusive(request, ownerSocket))
  }

  private async startReviewExclusive(
    request: ManagerReviewStartRequest,
    ownerSocket: Socket | null,
  ): Promise<ManagerReviewStartResponse> {
    this.requireIdle()
    if (!safeToken(request.requestId, 128) || this.requestIds.has(request.requestId)) {
      throw new ManagerHttpError(409, 'invalid or duplicate requestId')
    }
    if (typeof request.prompt !== 'string' || Buffer.byteLength(request.prompt) > MAX_REVIEW_PROMPT_BYTES) {
      throw new ManagerHttpError(413, 'review prompt exceeds 5MiB')
    }
    const lease = this.activateLease('review', null, request.requestId, ownerSocket)
    this.requestIds.add(request.requestId)
    let sharedGenerationReaped = false
    let execution: FixedReviewExecution | null = null
    try {
      // Review is deliberately outside the shared App Server generation: its
      // process-wide multi-agent and shell capabilities cannot be weakened by
      // a per-thread config. Reap that generation before the fixed, tool-less
      // review child can acquire the hidden UID's global runner lock.
      await this.stopGeneration()
      sharedGenerationReaped = true
      if (this.lease !== lease || this.phase !== 'active') {
        throw new ManagerHttpError(503, 'review lease changed while stopping the shared App Server')
      }
      execution = this.reviewRunner(request.prompt)
      lease.cancelReview = execution.stopAndWait
      const completed = await execution.completed
      if (this.lease !== lease || this.phase !== 'active') {
        throw new ManagerHttpError(503, 'review outcome is ambiguous; manager remains stopped')
      }
      lease.cancelReview = null
      const threadId = `review-${randomCapability()}`
      const turnId = `review-${randomCapability()}`
      this.bindReview(lease, threadId, turnId)
      const result = fixedReviewTurnResult(completed, threadId, turnId)
      this.detachLeaseOwner(lease)
      this.phase = 'terminal-cleanup-pending'
      this.armCleanupPendingTimer(lease)
      if (this.lease !== lease || this.phase !== 'terminal-cleanup-pending') {
        throw new ManagerHttpError(503, 'review cleanup acknowledgement deadline expired; manager is blocked')
      }
      return {
        leaseId: lease.id,
        cleanupToken: lease.cleanupToken,
        threadId,
        turnId,
        result,
        cleanupRequired: true,
        generation: this.generation,
        profile: this.generationProfile,
        rotation: null,
      }
    } catch (error) {
      if (this.phase === 'active') {
        if (sharedGenerationReaped && execution === null
          && this.lease === lease && lease.kind === 'review'
          && lease.threadId === null && lease.turnId === null
          && this.generationHandle === null) {
          // A synchronous launch rejection proves that no review child exists.
          // Reviews grant no external workspace ACLs, so the manager can
          // release the empty lease and create a fresh shared generation.
          try {
            await this.recoverRejectedReview(lease)
          } catch (recoveryError) {
            throw new ManagerHttpError(
              503,
              `review launch recovery failed: rejection=${JSON.stringify(boundedInitializationDiagnostic(error))}; `
              + `recovery=${JSON.stringify(boundedInitializationDiagnostic(recoveryError))}`,
            )
          }
        } else {
          await this.blockAmbiguous('review failed before a proven terminal event')
        }
      }
      throw error
    } finally {
      this.requestIds.delete(request.requestId)
    }
  }

  private async recoverRejectedReview(lease: ActiveLease): Promise<void> {
    if (this.phase !== 'active' || this.lease !== lease || lease.kind !== 'review'
      || lease.threadId !== null || lease.turnId !== null || this.generationHandle !== null
      || this.stopGenerationPromise !== null || lease.cancelReview !== null) {
      throw new Error('review rejection boundary changed before recovery')
    }
    this.detachLeaseOwner(lease)
    this.lease = null
    this.drainRecovery = 'none'
    this.phase = 'starting'
    try {
      await this.restoreReadyGeneration()
    } catch (error) {
      if (this.phase !== 'ambiguous') {
        const stopped = await this.stopGeneration().then(() => true, () => false)
        this.drainRecovery = stopped ? 'prelease-restore-failure' : 'none'
        this.phase = 'ambiguous'
      }
      throw error
    }
  }

  async unregister(request: ManagerUnregisterRequest): Promise<ManagerUnregisterResponse> {
    if (this.phase === 'active') return this.unregisterDuringActive(request)
    return this.exclusiveOperation(() => this.unregisterExclusive(request))
  }

  private async unregisterDuringActive(
    request: ManagerUnregisterRequest,
  ): Promise<ManagerUnregisterResponse> {
    const registration = this.registrationForToken(request.registrationToken)
    const lease = this.lease
    const stableWorkspaceTurn = this.generationHandle !== null
      && this.stopGenerationPromise === null && !this.expectedGenerationStop
    const stableFixedReview = lease?.kind === 'review'
      && this.generationHandle === null && this.stopGenerationPromise === null
      && lease.cancelReview !== null
    if (!this.operationInProgress || !lease || this.reservation !== null
      || (!stableWorkspaceTurn && !stableFixedReview) || this.shuttingDown) {
      throw new ManagerHttpError(409, 'manager active transition is not stable for unregister')
    }
    if (lease.registration === registration) {
      throw new ManagerHttpError(409, 'registration owns the current manager boundary')
    }
    // This is the only non-exclusive manager mutation. dropRegistration
    // removes the token/map entries synchronously before facade.close() can
    // yield, so a duplicate request cannot close the facade twice. The active
    // lease either belongs to a different registration or is a review lease.
    await this.dropRegistration(registration)
    return { removed: true }
  }

  private async unregisterExclusive(
    request: ManagerUnregisterRequest,
  ): Promise<ManagerUnregisterResponse> {
    const registration = this.registrationForToken(request.registrationToken)
    if (this.stopGenerationPromise !== null || this.shuttingDown) {
      throw new ManagerHttpError(409, 'manager transition is not stable for unregister')
    }
    const owner = this.reservation?.registration ?? this.lease?.registration ?? null
    if (owner === registration) {
      throw new ManagerHttpError(409, 'registration owns the current manager boundary')
    }
    const stable = this.phase === 'idle'
      ? this.generationHandle !== null && this.reservation === null && this.lease === null
      : this.phase === 'reserved'
        ? this.generationHandle !== null && this.reservation !== null && this.lease === null
        : this.phase === 'terminal-cleanup-pending'
          ? this.generationHandle === null && this.reservation === null && this.lease !== null
          : this.phase === 'drained'
            ? this.generationHandle === null && this.reservation === null && this.lease === null
            : this.phase === 'ambiguous'
              ? this.generationHandle === null
              : false
    if (!stable) throw new ManagerHttpError(409, `manager is ${this.phase}`)
    await this.dropRegistration(registration)
    return { removed: true }
  }

  async drain(): Promise<ManagerDrainResponse> {
    return this.exclusiveOperation(() => this.drainExclusive())
  }

  private async drainExclusive(): Promise<ManagerDrainResponse> {
    if (this.phase === 'drained') {
      if (this.lease || this.generationHandle || this.stopGenerationPromise) {
        throw new ManagerHttpError(409, 'manager drain transition is incomplete')
      }
      this.clearReservationCancelTombstones()
      return { drained: true, generation: this.generation }
    }
    if (this.phase === 'ambiguous') {
      const recovery = this.drainRecovery
      if (recovery === 'none' || this.lease !== null) {
        throw new ManagerHttpError(409, 'manager ambiguity is not safely drain-recoverable')
      }
      try {
        await this.stopGeneration()
      } catch (error) {
        this.drainRecovery = 'none'
        throw error
      }
      if (this.phase === 'drained' && this.lease === null && !this.generationHandle) {
        this.clearReservationCancelTombstones()
        return { drained: true, generation: this.generation }
      }
      if (this.phase !== 'ambiguous' || this.drainRecovery !== recovery
        || this.lease !== null || this.generationHandle) {
        throw new ManagerHttpError(409, 'manager drain recovery changed concurrently')
      }
      this.drainRecovery = 'none'
      this.phase = 'drained'
      this.clearReservationCancelTombstones()
      return { drained: true, generation: this.generation }
    }
    this.requireIdle()
    if (this.lease !== null) throw new ManagerHttpError(409, 'idle manager unexpectedly retains a lease')
    this.clearReservationCancelTombstones()
    this.drainRecovery = 'none'
    this.phase = 'drained'
    try {
      await this.stopGeneration()
    } catch (error) {
      this.phase = 'ambiguous'
      throw error
    }
    return { drained: true, generation: this.generation }
  }

  async resume(): Promise<ManagerResumeResponse> {
    return this.exclusiveOperation(() => this.resumeExclusive())
  }

  private async resumeExclusive(): Promise<ManagerResumeResponse> {
    if (this.phase !== 'drained') throw new ManagerHttpError(409, 'manager is not drained')
    if (this.lease !== null || this.generationHandle || this.stopGenerationPromise) {
      throw new ManagerHttpError(409, 'manager drain transition is incomplete')
    }
    this.phase = 'starting'
    try {
      await this.revalidateAllRegistrations()
    } catch (error) {
      this.phase = 'drained'
      throw error
    }
    await this.restoreReadyGeneration()
    return { ready: true, generation: this.generation }
  }

  async shutdown(): Promise<void> {
    if (this.shuttingDown) return
    return this.exclusiveOperation(() => this.shutdownExclusive())
  }

  private async shutdownExclusive(): Promise<void> {
    if (this.shuttingDown) return
    if (!['idle', 'drained'].includes(this.phase)) throw new ManagerHttpError(409, 'manager is busy or blocked')
    this.clearReservationCancelTombstones()
    if (this.lease) this.clearCleanupPendingTimer(this.lease)
    this.shuttingDown = true
    this.phase = 'stopping'
    await this.stopGeneration().catch(() => {})
    for (const registration of [...this.registrations.values()]) await this.dropRegistration(registration)
    const identity = this.controlIdentity
    this.controlIdentity = null
    await closeOwnedUnixServer(this.control, identity)
  }

  private workspaceThreadParams(
    repo: string,
    config: Record<string, unknown>,
    threadId?: string,
    model?: string,
  ) {
    return {
      ...(threadId ? { threadId } : {}),
      cwd: repo,
      approvalPolicy: 'never' as const,
      permissions: CODEX_PERMISSION_PROFILE,
      runtimeWorkspaceRoots: [repo],
      model: model ?? null,
      config: config as Record<string, JsonValue>,
    }
  }

  private validateEffective(
    effective: AppServerEffectiveThread,
    repo: string,
    profile: string,
    model?: string,
    reasoningEffort?: string,
    writableRoots: readonly string[] = [],
  ): void {
    if (effective.approvalPolicy !== 'never'
      || effective.modelProvider !== 'openai'
      || effective.activePermissionProfile?.id !== profile
      || effective.activePermissionProfile.extends !== ':workspace'
      || effective.approvalsReviewer !== 'user'
      || (model !== undefined && effective.model !== model)
      || (reasoningEffort !== undefined && effective.reasoningEffort !== reasoningEffort)) {
      throw new Error('upstream effective thread authority differs from the manager policy')
    }
    let cwd: string
    try { cwd = realpathSync(effective.cwd) } catch { throw new Error('upstream effective cwd is absent') }
    if (cwd !== repo || effective.runtimeWorkspaceRoots.length !== 1
      || effective.runtimeWorkspaceRoots[0] !== repo) {
      throw new Error('upstream effective workspace roots differ from the registered repo')
    }
    if (!object(effective.sandbox) || effective.sandbox.type !== 'workspaceWrite'
      || effective.sandbox.networkAccess !== false
      || effective.sandbox.excludeTmpdirEnvVar !== true
      || effective.sandbox.excludeSlashTmp !== true
      || !Array.isArray(effective.sandbox.writableRoots)
      // runtimeWorkspaceRoots is the authoritative 0.144.1 materialization
      // of :workspace_roots. The legacy projection must contain only the
      // exact outside-workspace write roots granted for this active turn.
      || effective.sandbox.writableRoots.length !== writableRoots.length
      || effective.sandbox.writableRoots.some((root, index) => root !== writableRoots[index])) {
      throw new Error('upstream effective workspace sandbox differs from the manager policy')
    }
  }

  private activateLease(
    kind: ActiveLease['kind'],
    registration: Registration | null,
    requestId: string,
    ownerSocket: Socket | null,
  ): ActiveLease {
    if (ownerSocket?.destroyed) {
      throw new ManagerHttpError(409, 'turn owner disconnected before lease admission')
    }
    const priorPhase = this.phase
    let resolveTurnReady!: ActiveLease['resolveTurnReady']
    const turnReady = new Promise<{ threadId: string; turnId: string }>(resolve => { resolveTurnReady = resolve })
    const lease: ActiveLease = {
      id: randomCapability(), cleanupToken: randomCapability(), kind, registration,
      requestId, taskId: null, ownerSocket, ownerCloseHandler: null,
      threadId: null, turnId: null, turnReady, resolveTurnReady, cleanupTimer: null,
      cancelReview: null, profile: registration?.profile ?? null,
      pendingRotationState: null, rotation: null, reviewerSlotToken: null,
      terminalResult: null, completionReviewTimer: null, completionReview: null,
    }
    this.lease = lease
    this.drainRecovery = 'none'
    this.phase = 'active'
    if (ownerSocket) {
      const close = () => {
        if (this.phase === 'active' && this.lease === lease) {
          void this.blockAmbiguous('active control connection disconnected')
        }
      }
      lease.ownerCloseHandler = close
      try {
        ownerSocket.once('close', close)
        if (!ownerSocket.destroyed) return lease
        this.detachLeaseOwner(lease)
        this.lease = null
        this.phase = priorPhase
        throw new ManagerHttpError(409, 'turn owner disconnected during lease admission')
      } catch (error) {
        this.detachLeaseOwner(lease)
        if (this.lease === lease) this.lease = null
        this.phase = priorPhase
        throw error
      }
    }
    return lease
  }

  private consumeReservation(reservation: TurnReservation, ownerSocket: Socket | null): ActiveLease {
    if (this.phase !== 'reserved' || this.reservation !== reservation
      || !this.generationHandle || Date.now() >= reservation.expiresAtMs) {
      throw new ManagerHttpError(409, 'turn reservation is no longer admissible')
    }
    // activateLease rolls back to the prior `reserved` phase if the owner
    // socket is already invalid or disconnects while its close listener is
    // being installed.  Keep the capability and expiry timer live until that
    // transition has succeeded so the daemon can revoke ACLs and explicitly
    // cancel rather than stranding the manager in an active state.
    const lease = this.activateLease('turn', reservation.registration, reservation.requestId, ownerSocket)
    if (this.reservation !== reservation || this.phase !== 'active' || this.lease !== lease) {
      throw new Error('turn reservation changed while creating its active lease')
    }
    clearTimeout(reservation.timer)
    this.reservation = null
    return lease
  }

  private releaseReservation(reservation: TurnReservation, restoreIdle: boolean): void {
    if (this.reservation !== reservation) return
    clearTimeout(reservation.timer)
    this.reservation = null
    this.requestIds.delete(reservation.requestId)
    if (!restoreIdle) return
    if (this.phase === 'reserved' && this.generationHandle) {
      this.drainRecovery = 'none'
      this.phase = 'idle'
      return
    }
    this.drainRecovery = 'none'
    this.phase = 'ambiguous'
  }

  private rememberReservationCancel(tombstone: TurnReservationCancelTombstone): void {
    const prior = this.reservationCancelTombstones.findIndex(item =>
      item.registration === tombstone.registration
      && item.registrationToken === tombstone.registrationToken
      && item.reservationToken === tombstone.reservationToken
      && item.requestId === tombstone.requestId
      && item.generation === tombstone.generation)
    if (prior >= 0) this.reservationCancelTombstones.splice(prior, 1)
    this.reservationCancelTombstones.push(tombstone)
    while (this.reservationCancelTombstones.length > MAX_RESERVATION_CANCEL_TOMBSTONES) {
      this.reservationCancelTombstones.shift()
    }
  }

  private clearReservationCancelTombstones(registration?: Registration): void {
    if (!registration) {
      this.reservationCancelTombstones.length = 0
      return
    }
    for (let index = this.reservationCancelTombstones.length - 1; index >= 0; index -= 1) {
      if (this.reservationCancelTombstones[index].registration === registration) {
        this.reservationCancelTombstones.splice(index, 1)
      }
    }
  }

  private expireReservation(reservation: TurnReservation): void {
    if (this.reservation !== reservation || !['reserved', 'ambiguous'].includes(this.phase)) return
    const wasReserved = this.phase === 'reserved'
    // A reserve acknowledgement permits the caller to expose attachment ACLs
    // to the hidden UID.  Timeout cannot prove those ACLs were revoked, so it
    // must never reopen global admission.  Retire the expired capability,
    // block the manager, and reap the upstream generation instead.
    this.releaseReservation(reservation, false)
    this.drainRecovery = 'none'
    this.phase = 'ambiguous'
    if (wasReserved || this.generationHandle) void this.stopGeneration().catch(() => {})
  }

  private armCleanupPendingTimer(lease: ActiveLease): void {
    if (this.lease !== lease || this.phase !== 'terminal-cleanup-pending' || lease.cleanupTimer) {
      throw new Error('cannot arm cleanup timer outside its terminal lease')
    }
    lease.cleanupTimer = setTimeout(() => this.expireCleanupPending(lease), this.cleanupPendingTtlMs)
    lease.cleanupTimer.unref?.()
  }

  private clearCleanupPendingTimer(lease: ActiveLease): void {
    if (lease.cleanupTimer) clearTimeout(lease.cleanupTimer)
    lease.cleanupTimer = null
  }

  private expireCleanupPending(lease: ActiveLease): void {
    if (this.lease !== lease || this.phase !== 'terminal-cleanup-pending') return
    this.clearCleanupPendingTimer(lease)
    // The upstream is already being reaped (or has been reaped), but a lost
    // cleanup acknowledgement cannot prove hidden-UID ACL revocation. Keep
    // the owner lease as a blocked boundary and never restore a generation.
    this.drainRecovery = 'none'
    this.phase = 'ambiguous'
    void this.stopGeneration().catch(() => {})
  }

  private detachLeaseOwner(lease: ActiveLease): void {
    if (lease.ownerSocket && lease.ownerCloseHandler) {
      lease.ownerSocket.removeListener('close', lease.ownerCloseHandler)
    }
    lease.ownerCloseHandler = null
  }

  private bindTurn(lease: ActiveLease, handle: AppServerTurnHandle): void {
    if (this.lease !== lease || this.phase !== 'active') throw new Error('lease changed while accepting turn')
    lease.threadId = handle.threadId
    lease.turnId = handle.turnId
    lease.resolveTurnReady({ threadId: handle.threadId, turnId: handle.turnId })
  }

  private bindReview(lease: ActiveLease, threadId: string, turnId: string): void {
    if (this.lease !== lease || lease.kind !== 'review' || this.phase !== 'active') {
      throw new Error('lease changed while accepting fixed review result')
    }
    lease.threadId = threadId
    lease.turnId = turnId
    lease.resolveTurnReady({ threadId, turnId })
  }

  private async blockAmbiguous(_reason: string, recovery: DrainRecovery = 'none'): Promise<void> {
    const cancelReview = this.lease?.cancelReview ?? null
    if (this.lease) {
      this.detachLeaseOwner(this.lease)
      this.clearCleanupPendingTimer(this.lease)
    }
    if (this.reservation) this.releaseReservation(this.reservation, false)
    this.clearReservationCancelTombstones()
    const recoverable = recovery !== 'none' && this.lease === null
      && (this.phase === 'idle' || this.phase === 'starting' || this.drainRecovery !== 'none')
    this.drainRecovery = recoverable ? recovery : 'none'
    this.phase = 'ambiguous'
    const reviewStopped = cancelReview
      ? await cancelReview().then(() => true, () => false)
      : true
    const generationStopped = await this.stopGeneration().then(() => true, () => false)
    if (!reviewStopped || !generationStopped) this.drainRecovery = 'none'
  }

  private async restoreReadyGeneration(): Promise<void> {
    if (this.lease !== null) throw new Error('cannot restore an App Server generation while a lease exists')
    let lastError: unknown = new Error('App Server generation restore did not run')
    for (let attempt = 0; attempt < MANAGER_RESTORE_ATTEMPTS; attempt += 1) {
      this.phase = 'starting'
      this.drainRecovery = 'none'
      let stage: 'start' | 'resume' | 'stability' = 'start'
      try {
        await this.startGeneration()
        stage = 'resume'
        await this.refreshAllRegistrationHistory()
        stage = 'stability'
        await this.requireStableGeneration()
        this.drainRecovery = 'none'
        this.phase = 'idle'
        return
      } catch (error) {
        lastError = error
        if (error instanceof ManagerGenerationReapError) {
          this.drainRecovery = 'none'
          this.phase = 'ambiguous'
          throw error
        }
        const upstreamFailure = stage === 'start'
          || error instanceof AppServerRequestError
          || this.drainRecovery !== 'none'
          || this.generationHandle === null
        const stopped = await this.stopGeneration().then(() => true, () => false)
        if (!stopped || this.lease !== null) {
          this.drainRecovery = 'none'
          this.phase = 'ambiguous'
          throw error
        }
        if (upstreamFailure && attempt + 1 < MANAGER_RESTORE_ATTEMPTS) {
          this.phase = 'starting'
          this.drainRecovery = 'none'
          await this.delay(MANAGER_RESTORE_RETRY_DELAY_MS)
          continue
        }
        this.phase = 'ambiguous'
        this.drainRecovery = 'prelease-restore-failure'
        throw error
      }
    }
    this.phase = 'ambiguous'
    this.drainRecovery = 'prelease-restore-failure'
    throw lastError
  }

  private async requireStableGeneration(): Promise<void> {
    const handle = this.generationHandle
    const generation = this.generation
    if (!handle) throw new Error('upstream App Server exited while restoring readiness')
    const exited = await Promise.race([
      handle.exited.then(() => true),
      this.delay(MANAGER_GENERATION_STABILITY_MS).then(() => false),
    ])
    if (exited || this.generation !== generation || this.generationHandle !== handle
      || this.phase !== 'starting' || this.lease !== null) {
      throw new Error('upstream App Server did not remain ready while restoring readiness')
    }
  }

  /** Switch only while globally idle; stop/reap always precedes the new home. */
  private async ensureGenerationProfile(profile: string): Promise<void> {
    if (!/^[a-z][a-z0-9_-]{0,31}$/.test(profile)) throw new Error('invalid auth profile')
    if (this.generationProfile === profile && this.generationHandle) return
    this.requireIdle()
    await this.stopGeneration()
    this.generationProfile = profile
    await this.restoreReadyGeneration()
  }

  private async startGeneration(): Promise<void> {
    if (this.generationHandle) throw new Error('App Server generation already active')
    this.clearReservationCancelTombstones()
    this.expectedGenerationStop = false
    const attempt = ++this.generationAttempt
    const profile = this.generationProfile
    const handle = await this.generationFactory({
      onNotification: notification => {
        if (this.generationAttempt !== attempt || this.shuttingDown) return
        this.handleNotification(notification)
      },
      onProtocolError: error => {
        if (this.generationAttempt !== attempt || this.shuttingDown) return
        const phase = this.phase
        const recovery: DrainRecovery = this.lease === null && phase === 'idle'
          ? 'idle-protocol-error'
          : this.lease === null && phase === 'starting'
            ? 'prelease-upstream-failure'
            : 'none'
        this.reportUpstreamFailure('protocol-error', phase, undefined, boundedProtocolDiagnostic(error))
        void this.blockAmbiguous('upstream protocol error', recovery)
      },
    }, profile)
    if (this.generationAttempt !== attempt || this.shuttingDown) {
      try {
        await handle.stop()
      } catch (error) {
        throw new ManagerGenerationReapError(
          'generation start was superseded', boundedInitializationDiagnostic(error),
        )
      }
      throw new Error('App Server generation start was superseded')
    }
    this.generationHandle = handle
    this.generation += 1
    const generation = this.generation
    void handle.exited.then(exit => {
      if (this.generation !== generation || this.generationAttempt !== attempt
        || this.expectedGenerationStop || this.shuttingDown) return
      // The process exit is the terminal signal for this attempt. Invalidate
      // any protocol/notification callback queued by the dead transport before
      // publishing the recoverable or blocked post-exit state.
      this.generationAttempt += 1
      const phase = this.phase
      this.generationHandle = null
      this.clearReservationCancelTombstones()
      this.reportUpstreamFailure('process-exit', phase, exit)
      if (phase === 'reserved' && this.reservation) {
        this.releaseReservation(this.reservation, false)
      }
      if (phase === 'active') {
        void this.blockAmbiguous('upstream exited during an active turn')
      } else if (this.lease === null && phase === 'idle') {
        this.drainRecovery = 'idle-upstream-exit'
        this.phase = 'ambiguous'
      } else if (this.lease === null && phase === 'starting') {
        this.drainRecovery = 'prelease-upstream-failure'
        this.phase = 'ambiguous'
      } else if (phase !== 'terminal-cleanup-pending' && phase !== 'drained') {
        this.drainRecovery = 'none'
        this.phase = 'ambiguous'
      }
    })
  }

  private reportUpstreamFailure(
    kind: 'process-exit' | 'protocol-error',
    phase: ManagerPhase,
    exit?: ManagerGenerationExit,
    detail?: string,
  ): void {
    let status = ''
    if (exit) {
      const code = Number.isSafeInteger(exit.code) && (exit.code as number) >= 0
        && (exit.code as number) <= 255 ? String(exit.code) : 'unknown'
      const signal = typeof exit.signal === 'string' && /^[A-Z0-9]{1,16}$/.test(exit.signal)
        ? exit.signal : 'none'
      status = `; code=${code}; signal=${signal}`
    }
    const diagnostic = detail
      ? `; detail=${JSON.stringify(boundedProtocolDiagnostic(new Error(detail)))}`
      : ''
    try {
      process.stderr.write(
        `app-server-manager: upstream ${kind}; generation=${this.generation}; phase=${phase}; lease=${this.lease ? 'present' : 'absent'}${status}${diagnostic}\n`,
      )
    } catch {}
  }

  private async stopGeneration(): Promise<void> {
    if (this.stopGenerationPromise) return this.stopGenerationPromise
    const handle = this.generationHandle
    if (!handle) return
    // Invalidate notification/protocol callbacks before closing their client;
    // an old transport must never fault or mutate a later healthy generation.
    this.generationAttempt += 1
    this.clearReservationCancelTombstones()
    this.expectedGenerationStop = true
    this.generationHandle = null
    this.stopGenerationPromise = handle.stop().finally(() => { this.stopGenerationPromise = null })
    return this.stopGenerationPromise
  }

  private requireClient(): ManagerClient {
    if (!this.generationHandle) throw new ManagerHttpError(503, 'upstream App Server is stopped')
    return this.generationHandle.client
  }

  private requireIdle(): void {
    if (this.phase !== 'idle' || !this.generationHandle) {
      const retryable = [
        'reserved', 'active', 'completion-review-pending', 'completion-review-complete',
        'terminal-cleanup-pending', 'drained', 'starting',
      ].includes(this.phase)
      throw new ManagerHttpError(409, `manager is ${this.phase}`, retryable)
    }
  }

  private registrationForToken(token: unknown): Registration {
    if (typeof token !== 'string' || !/^[0-9a-f]{64}$/.test(token)) throw new ManagerHttpError(403, 'invalid registration capability')
    const registration = this.tokens.get(token)
    if (!registration) throw new ManagerHttpError(403, 'unknown registration capability')
    return registration
  }

  private assertThreadsUnclaimed(ids: readonly string[], except?: Registration): void {
    for (const registration of this.registrations.values()) {
      if (registration === except) continue
      if (ids.some(id => registration.threads.has(id))) throw new ManagerHttpError(409, 'thread is already bound to another swarm')
    }
  }

  private replacePrimaryThreads(registration: Registration, primaryIds: readonly string[]): void {
    const keep = new Set(primaryIds)
    let changed = true
    while (changed) {
      changed = false
      for (const [child, parent] of registration.parents) {
        if (!keep.has(child) && keep.has(parent)) {
          keep.add(child)
          changed = true
        }
      }
    }
    registration.primaryThreads = new Set(primaryIds)
    registration.threads = keep
    for (const child of [...registration.parents.keys()]) {
      if (!keep.has(child)) registration.parents.delete(child)
    }
  }

  private assertRegistrationAuthority(registration: Registration): void {
    const row = parseCodexRow(this.options.swarmHome, registration.swarm)
    if (realpathSync(row.repo) !== registration.repo
      || row.pool !== registration.pool
      || validatePrivateStateBoundary(registration.stateDir, false) !== registration.stateDir) {
      throw new Error('registration authority changed')
    }
  }

  private async revalidateReservedRegistration(registration: Registration): Promise<void> {
    // Keep this as an awaitable boundary even though the current authority
    // proof is synchronous. Reservation expiry and upstream exit may race this
    // operation; startTurn rechecks the exact reservation and generation after
    // the await before it consumes anything.
    this.assertRegistrationAuthority(registration)
  }

  private async revalidateRegistration(registration: Registration): Promise<void> {
    try {
      this.assertRegistrationAuthority(registration)
    } catch (error) {
      await this.dropRegistration(registration)
      this.reconcileRotationStateWithConfiguredRows()
      throw new ManagerHttpError(409, `registration was revoked: ${error}`)
    }
  }

  private async revalidateAllRegistrations(): Promise<void> {
    for (const registration of [...this.registrations.values()]) {
      await this.revalidateRegistration(registration)
    }
  }

  private async refreshRegistrationHistory(registration: Registration): Promise<void> {
    if (registration.profile === null || registration.profile !== this.generationProfile) {
      throw new Error('cannot refresh threads outside their leased auth profile')
    }
    const client = this.requireClient()
    for (const threadId of registration.threads) {
      let thread: AppServerThread
      try {
        // thread/read preserves the full native history cache without loading
        // or subscribing to the thread. Persisted threads must remain cold so
        // the exact per-turn profile is honored by the subsequent resume.
        thread = await client.readThread(threadId, true)
      } catch (error) {
        // A stale persisted session is not authority and has not mutated a
        // turn. Retain the binding so its next requested turn can perform the
        // one safe missing-thread -> fresh fallback before turn/start.
        if (missingThread(error)) continue
        throw error
      }
      if (thread.id !== threadId) throw new Error('thread/read returned a different thread id')
      let threadCwd: string
      try {
        if (typeof thread.cwd !== 'string') throw new Error('missing cwd')
        threadCwd = realpathSync(thread.cwd)
      } catch {
        throw new Error('thread/read returned a cwd outside the registered repo')
      }
      if (thread.cwd !== threadCwd || threadCwd !== registration.repo) {
        throw new Error('thread/read returned a cwd outside the registered repo')
      }
      const parentThreadId = registration.parents.get(threadId)
      registration.facade.cacheThread(threadId, parentThreadId
        ? { ...thread, parentThreadId }
        : thread)
    }
  }

  private async refreshAllRegistrationHistory(): Promise<void> {
    for (const registration of [...this.registrations.values()]) {
      await this.revalidateRegistration(registration)
      if (registration.profile === this.generationProfile) {
        await this.refreshRegistrationHistory(registration)
      }
    }
  }

  private async dropRegistration(registration: Registration): Promise<void> {
    this.clearReservationCancelTombstones(registration)
    this.registrations.delete(registration.swarm)
    this.tokens.delete(registration.token)
    await registration.facade.close()
  }

  private handleNotification(notification: AppServerNotification): void {
    const threadId = appServerNotificationThreadId(notification)
    if (!threadId) return
    let registration = [...this.registrations.values()].find(item => item.threads.has(threadId))
    if (!registration && notification.method === 'thread/started' && object(notification.params)
      && object(notification.params.thread) && safeToken(notification.params.thread.parentThreadId)) {
      const parent = notification.params.thread.parentThreadId
      registration = [...this.registrations.values()].find(item => item.threads.has(parent))
      if (registration && notification.params.thread.id === threadId) {
        registration.threads.add(threadId)
        registration.parents.set(threadId, parent)
        registration.facade.replaceThreadIds([...registration.threads])
        registration.facade.cacheThread(threadId, notification.params.thread as AppServerThread)
      }
    }
    registration?.facade.publish(notification)
  }

  private validateTurnRoots(registration: Registration, roots: string[], kind: 'read' | 'write'): string[] {
    const writeBoundary = join(registration.stateDir, 'tool-tmp')
    const stateReadBoundaries = [
      join(registration.stateDir, 'inbox'),
      join(registration.stateDir, 'tool-shims'),
    ]
    const readableExamples = kind === 'read'
      ? new Set(discoverWorkspacePolicy(registration.repo).readableExamples)
      : new Set<string>()
    return roots.map(path => {
      const canonical = realpathSync(path)
      if (canonical !== path) throw new ManagerHttpError(400, `${kind} root is noncanonical`)
      const info = lstatSync(canonical)
      const uid = typeof process.getuid === 'function' ? process.getuid() : info.uid
      if (info.isSymbolicLink() || info.uid !== uid || (info.mode & 0o022) !== 0
        || (!info.isDirectory() && !info.isFile())) {
        // Fixed system/toolchain read roots are root-owned rather than
        // operator-owned; their complete directory chain is proved below.
        if (!(kind === 'read' && info.uid === 0 && (info.mode & 0o022) === 0
          && (info.isDirectory() || info.isFile()) && rootControlledReadRoot(canonical))) {
          throw new ManagerHttpError(400, `unsafe ${kind} root`)
        }
      }
      const permitted = kind === 'write'
        ? inside(writeBoundary, canonical)
        : stateReadBoundaries.some(boundary => inside(boundary, canonical))
          || readableExamples.has(canonical)
          || (info.uid === 0 && rootControlledReadRoot(canonical))
      if (!permitted) throw new ManagerHttpError(400, `${kind} root is outside its manager authority`)
      return canonical
    })
  }

  private async withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | null = null
    try {
      return await Promise.race([
        promise,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new ManagerHttpError(409, message)), timeoutMs)
          timer.unref?.()
        }),
      ])
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  private delay(milliseconds: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, milliseconds))
  }

  private async exclusiveOperation<T>(operation: () => Promise<T>): Promise<T> {
    if (this.operationInProgress) {
      throw new ManagerHttpError(409, 'another manager operation is already in progress', true)
    }
    this.operationInProgress = true
    try {
      return await operation()
    } finally {
      this.operationInProgress = false
    }
  }

  private async route(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      if (request.method === 'GET' && request.url === '/v1/health') {
        this.send(response, 200, this.health())
        return
      }
      if (request.method !== 'POST' || !request.url) throw new ManagerHttpError(404, 'unknown endpoint')
      const maxBody = request.url === '/v1/review/start'
        || request.url === '/v1/reviewer/completion/begin' ? this.maxReviewBodyBytes
        : request.url === '/v1/turn/start' ? MANAGER_MAX_TURN_BODY_BYTES
        : this.maxControlBodyBytes
      const body = await this.readBody(request, maxBody)
      switch (request.url) {
        case '/v1/register': this.send(response, 200, await this.register(body as ManagerRegisterRequest)); return
        case '/v1/sessions/replace': this.send(response, 200, await this.replaceSessions(body as ManagerSessionsReplaceRequest)); return
        case '/v1/turn/reserve': this.send(response, 200, await this.reserveTurn(body as ManagerTurnReserveRequest)); return
        case '/v1/turn/reservation-cancel': this.send(
          response, 200,
          await this.cancelTurnReservation(body as ManagerTurnReservationCancelRequest),
        ); return
        case '/v1/turn/start': this.send(
          response, 200,
          await this.startTurn(body as ManagerTurnStartRequest, request.socket),
          MANAGER_MAX_RESULT_BODY_BYTES,
        ); return
        case '/v1/reviewer/scope': this.send(
          response, 200,
          await this.reviewerScope(body as ManagerReviewerScopeRequest, request.socket),
        ); return
        case '/v1/reviewer/completion/begin': this.send(
          response, 200,
          await this.beginCompletionReview(body as ManagerCompletionReviewBeginRequest),
        ); return
        case '/v1/reviewer/completion/status': this.send(
          response, 200,
          this.completionReviewStatus(body as ManagerCompletionReviewPollRequest),
        ); return
        case '/v1/reviewer/completion/consume': this.send(
          response, 200,
          this.consumeCompletionReview(body as ManagerCompletionReviewConsumeRequest),
        ); return
        case '/v1/reviewer/completion/end': this.send(
          response, 200,
          this.endCompletionReview(body as ManagerCompletionReviewEndRequest),
        ); return
        case '/v1/turn/interrupt': this.send(response, 200, await this.interruptTurn(body as ManagerTurnInterruptRequest)); return
        case '/v1/turn/cleanup-complete': this.send(response, 200, await this.cleanupComplete(body as ManagerTurnCleanupRequest)); return
        case '/v1/review/start': {
          const result = await this.startReview(body as ManagerReviewStartRequest, request.socket)
          this.send(response, 200, result, MAX_REVIEW_RESPONSE_BYTES)
          return
        }
        case '/v1/unregister': this.send(response, 200, await this.unregister(body as ManagerUnregisterRequest)); return
        case '/v1/drain': this.send(response, 200, await this.drain()); return
        case '/v1/resume': this.send(response, 200, await this.resume()); return
        case '/v1/shutdown': {
          if (this.operationInProgress || !['idle', 'drained'].includes(this.phase)) {
            throw new ManagerHttpError(409, 'manager is busy or blocked')
          }
          const completion = this.shutdown()
          this.send(response, 200, { stopping: true } satisfies ManagerShutdownResponse)
          void completion.catch(() => {
            try { process.stderr.write('app-server-manager: shutdown cleanup failed\n') } catch {}
          })
          return
        }
        default: throw new ManagerHttpError(404, 'unknown endpoint')
      }
    } catch (error) {
      const status = error instanceof ManagerHttpError ? error.status : 500
      const message = error instanceof Error ? error.message : 'manager request failed'
      const retryable = error instanceof ManagerHttpError ? error.retryable : false
      const parkedUntilMs = error instanceof ManagerHttpError ? error.parkedUntilMs : undefined
      this.send(response, status, {
        error: message.slice(0, 1024), phase: this.phase, retryable,
        ...(parkedUntilMs === undefined ? {} : { parkedUntilMs }),
      } satisfies ManagerErrorResponse)
    }
  }

  private async readBody(request: IncomingMessage, maxBytes: number): Promise<unknown> {
    const declared = request.headers['content-length']
    if (declared && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) throw new ManagerHttpError(413, 'request body too large')
    let timer: ReturnType<typeof setTimeout> | null = null
    const timedOut = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => {
        request.destroy()
        reject(new ManagerHttpError(408, 'request body timeout'))
      }, this.requestBodyTimeoutMs)
      timer.unref?.()
    })
    const read = (async () => {
      const chunks: Buffer[] = []
      let size = 0
      for await (const chunk of request) {
        const bytes = Buffer.from(chunk)
        size += bytes.length
        if (size > maxBytes) throw new ManagerHttpError(413, 'request body too large')
        chunks.push(bytes)
      }
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (!object(value)) throw new Error('body must be an object')
        return value
      } catch {
        throw new ManagerHttpError(400, 'request body must be a JSON object')
      }
    })()
    try { return await Promise.race([read, timedOut]) } finally { if (timer) clearTimeout(timer) }
  }

  private send(response: ServerResponse, status: number, value: unknown, maxBytes = 64 * 1024): void {
    if (response.headersSent || response.destroyed) return
    let body = JSON.stringify(value) + '\n'
    if (Buffer.byteLength(body) > maxBytes) {
      status = 500
      body = JSON.stringify({
        error: 'manager response exceeded its byte bound', phase: this.phase, retryable: false,
      } satisfies ManagerErrorResponse) + '\n'
    }
    response.writeHead(status, {
      'content-type': 'application/json',
      'content-length': String(Buffer.byteLength(body)),
      'cache-control': 'no-store',
    })
    response.end(body)
  }
}

function parseMainArgs(args: string[]): { stateDir: string; swarmHome: string } {
  if (args.length !== 4 || args[0] !== '--state-dir' || args[2] !== '--swarm-home'
    || !isAbsolute(args[1]) || !isAbsolute(args[3])) {
    throw new Error('usage: app-server-manager.ts --state-dir ABS --swarm-home ABS')
  }
  return { stateDir: args[1], swarmHome: args[3] }
}

export async function runAppServerManagerMain(args: string[]): Promise<AppServerManager> {
  const parsed = parseMainArgs(args)
  const manager = await AppServerManager.start(parsed)
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      void manager.shutdown().then(() => process.exit(0), error => {
        process.stderr.write(`app-server-manager: ${error}\n`)
        process.exit(1)
      })
    })
  }
  return manager
}

if (import.meta.main) {
  try {
    await runAppServerManagerMain(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`app-server-manager: ${error}\n`)
    process.exit(1)
  }
}
