import { createHash } from 'crypto'

export const COMPLETION_REVIEW_POLICY_SCHEMA = 'qofi-completion-review-policy/v1' as const
export const COMPLETION_REVIEW_GATE_SCHEMA = 'qofi-completion-review-gate/v1' as const
export const DEFAULT_REVIEW_CALLS_PER_TASK = 1
export const DEFAULT_EARLY_EXCEPTION_CALLS_PER_TASK = 1

export type ReviewVerdict = 'approve' | 'needs-changes' | 'block' | 'review-unavailable'
export type ReviewPhase = 'early-exception' | 'completion'
export type TerminalAction = 'stop' | 'done'
export type EarlyExceptionClass = 'standing-invariant' | 'security'

export type EarlyReviewException = Readonly<{
  class: EarlyExceptionClass
  pattern: string
}>

export type CompletionReviewPolicy = Readonly<{
  schema: typeof COMPLETION_REVIEW_POLICY_SCHEMA
  maxCallsPerTask: typeof DEFAULT_REVIEW_CALLS_PER_TASK
  maxEarlyExceptionCallsPerTask: typeof DEFAULT_EARLY_EXCEPTION_CALLS_PER_TASK
  earlyExceptions: readonly EarlyReviewException[]
}>

export type ReviewRequestState = Readonly<{
  phase: ReviewPhase
  requestId: string
  paths: readonly string[]
  expectedReviewedDiffSha256: string
  status: 'requested' | 'recorded'
  artifactId?: string
  artifactSha256?: string
  reviewedDiffSha256?: string
  verdict?: ReviewVerdict
}>

export type CompletionReviewGateState = Readonly<{
  schema: typeof COMPLETION_REVIEW_GATE_SCHEMA
  taskId: string
  policySha256: string
  earlyReview: ReviewRequestState | null
  completionReview: ReviewRequestState | null
  terminal: 'open' | TerminalAction
}>

export type CompletionReviewMetricEvent = Readonly<{
  type: 'review_gate_request' | 'review_gate_artifact' | 'review_gate_terminal'
  phase?: ReviewPhase
  outcome: 'accepted' | 'rejected'
  reason: string
  pathCount?: number
  verdict?: ReviewVerdict
  reviewStatus?: 'complete' | 'pending'
}>

export type ReviewArtifactEvidence = Readonly<{
  artifactId: string
  artifactSha256: string
  taskId: string
  phase: ReviewPhase
  reviewedDiffSha256: string
  verdict: ReviewVerdict
}>

const SAFE_TASK = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/
const SAFE_ARTIFACT = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$/
const SHA256 = /^[0-9a-f]{64}$/

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  return Object.keys(value).length === expected.length
    && expected.every(key => Object.prototype.hasOwnProperty.call(value, key))
}

function safeRepoPath(value: unknown, allowTreePattern = false): value is string {
  if (typeof value !== 'string' || value.length < 1 || value.length > 512
    || value.startsWith('/') || value.startsWith('./') || value.includes('\\')
    || value.includes('\0') || value.includes('//')) return false
  const candidate = allowTreePattern && value.endsWith('/**') ? value.slice(0, -3) : value
  if (!candidate || candidate.endsWith('/')) return false
  const parts = candidate.split('/')
  return parts.every(part => part !== '' && part !== '.' && part !== '..' && !part.includes('*'))
}

function compactJson(value: unknown): string {
  return JSON.stringify(value)
}

const compareStable = (left: string, right: string): number => left < right ? -1 : left > right ? 1 : 0

function canonicalPolicy(policy: CompletionReviewPolicy): CompletionReviewPolicy {
  return {
    schema: COMPLETION_REVIEW_POLICY_SCHEMA,
    maxCallsPerTask: DEFAULT_REVIEW_CALLS_PER_TASK,
    maxEarlyExceptionCallsPerTask: DEFAULT_EARLY_EXCEPTION_CALLS_PER_TASK,
    earlyExceptions: [...policy.earlyExceptions]
      .sort((left, right) => compareStable(left.pattern, right.pattern)
        || compareStable(left.class, right.class)),
  }
}

export function parseCompletionReviewPolicy(value: unknown): CompletionReviewPolicy {
  if (!object(value) || !exactKeys(value, [
    'schema', 'maxCallsPerTask', 'maxEarlyExceptionCallsPerTask', 'earlyExceptions',
  ])
    || value.schema !== COMPLETION_REVIEW_POLICY_SCHEMA
    || value.maxCallsPerTask !== DEFAULT_REVIEW_CALLS_PER_TASK
    || value.maxEarlyExceptionCallsPerTask !== DEFAULT_EARLY_EXCEPTION_CALLS_PER_TASK
    || !Array.isArray(value.earlyExceptions)
    || value.earlyExceptions.length > 64) {
    throw new Error('completion review policy is malformed')
  }
  const seen = new Set<string>()
  const earlyExceptions: EarlyReviewException[] = value.earlyExceptions.map(entry => {
    if (!object(entry) || !exactKeys(entry, ['class', 'pattern'])
      || (entry.class !== 'standing-invariant' && entry.class !== 'security')
      || !safeRepoPath(entry.pattern, true)) {
      throw new Error('completion review exception is malformed')
    }
    const key = `${entry.class}:${entry.pattern}`
    if (seen.has(key)) throw new Error('completion review exception is duplicated')
    seen.add(key)
    return { class: entry.class, pattern: entry.pattern }
  })
  return canonicalPolicy({
    schema: COMPLETION_REVIEW_POLICY_SCHEMA,
    maxCallsPerTask: DEFAULT_REVIEW_CALLS_PER_TASK,
    maxEarlyExceptionCallsPerTask: DEFAULT_EARLY_EXCEPTION_CALLS_PER_TASK,
    earlyExceptions,
  })
}

export function completionReviewPolicySha256(policy: CompletionReviewPolicy): string {
  return createHash('sha256').update(compactJson(canonicalPolicy(policy))).digest('hex')
}

export function createCompletionReviewGate(
  taskId: string,
  policy: CompletionReviewPolicy,
): CompletionReviewGateState {
  if (!SAFE_TASK.test(taskId)) throw new Error('completion review task id is invalid')
  const parsed = parseCompletionReviewPolicy(policy)
  return {
    schema: COMPLETION_REVIEW_GATE_SCHEMA,
    taskId,
    policySha256: completionReviewPolicySha256(parsed),
    earlyReview: null,
    completionReview: null,
    terminal: 'open',
  }
}

function assertBoundPolicy(
  state: CompletionReviewGateState,
  policy: CompletionReviewPolicy,
): CompletionReviewPolicy {
  if (!object(state) || !exactKeys(state, [
    'schema', 'taskId', 'policySha256', 'earlyReview', 'completionReview', 'terminal',
  ]) || state.schema !== COMPLETION_REVIEW_GATE_SCHEMA
    || typeof state.taskId !== 'string' || !SAFE_TASK.test(state.taskId)
    || typeof state.policySha256 !== 'string' || !SHA256.test(state.policySha256)
    || !['open', 'stop', 'done'].includes(String(state.terminal))) {
    throw new Error('completion review gate state is malformed')
  }
  const parsed = parseCompletionReviewPolicy(policy)
  if (state.policySha256 !== completionReviewPolicySha256(parsed)) {
    throw new Error('completion review policy changed during task')
  }
  validateRequestState(state.earlyReview, 'early-exception', state.taskId, parsed)
  validateRequestState(state.completionReview, 'completion', state.taskId, parsed)
  return parsed
}

function validateRequestState(
  value: unknown,
  phase: ReviewPhase,
  taskId: string,
  policy: CompletionReviewPolicy,
): void {
  if (value === null) return
  if (!object(value) || value.phase !== phase
    || value.requestId !== `${phase}:${taskId}`
    || !Array.isArray(value.paths) || value.paths.length > 128
    || value.paths.some(path => !safeRepoPath(path))
    || new Set(value.paths).size !== value.paths.length
    || JSON.stringify(value.paths) !== JSON.stringify([...value.paths].sort())
    || typeof value.expectedReviewedDiffSha256 !== 'string'
    || !SHA256.test(value.expectedReviewedDiffSha256)) {
    throw new Error('completion review request state is malformed')
  }
  if (phase === 'early-exception' && (value.paths.length === 0
    || value.paths.some(path => exceptionForPath(path, policy.earlyExceptions) === null))) {
    throw new Error('completion review request state is malformed')
  }
  if (value.status === 'requested') {
    if (!exactKeys(value, [
      'phase', 'requestId', 'paths', 'expectedReviewedDiffSha256', 'status',
    ])) {
      throw new Error('completion review request state is malformed')
    }
    return
  }
  if (value.status !== 'recorded' || !exactKeys(value, [
    'phase', 'requestId', 'paths', 'expectedReviewedDiffSha256', 'status',
    'artifactId', 'artifactSha256', 'reviewedDiffSha256', 'verdict',
  ]) || typeof value.artifactId !== 'string' || !SAFE_ARTIFACT.test(value.artifactId)
    || typeof value.artifactSha256 !== 'string' || !SHA256.test(value.artifactSha256)
    || typeof value.reviewedDiffSha256 !== 'string' || !SHA256.test(value.reviewedDiffSha256)
    || !['approve', 'needs-changes', 'block', 'review-unavailable'].includes(String(value.verdict))) {
    throw new Error('completion review request state is malformed')
  }
}

function exceptionForPath(
  path: string,
  exceptions: readonly EarlyReviewException[],
): EarlyReviewException | null {
  for (const exception of exceptions) {
    if (exception.pattern.endsWith('/**')) {
      const prefix = exception.pattern.slice(0, -3)
      if (path === prefix || path.startsWith(`${prefix}/`)) return exception
    } else if (path === exception.pattern) {
      return exception
    }
  }
  return null
}

export type ReviewRequestDecision = Readonly<{
  ok: boolean
  state: CompletionReviewGateState
  reason: string
  request?: ReviewRequestState
  metrics: readonly CompletionReviewMetricEvent[]
}>

export function requestTaskReview(
  state: CompletionReviewGateState,
  policy: CompletionReviewPolicy,
  phase: ReviewPhase,
  paths: readonly string[],
  expectedReviewedDiffSha256: string,
): ReviewRequestDecision {
  const bound = assertBoundPolicy(state, policy)
  const reject = (reason: string): ReviewRequestDecision => ({
    ok: false,
    state,
    reason,
    metrics: [{
      type: 'review_gate_request', phase, outcome: 'rejected', reason,
      pathCount: paths.length,
    }],
  })
  if (state.terminal !== 'open') return reject('task-already-terminal')
  if (phase !== 'early-exception' && phase !== 'completion') return reject('invalid-review-phase')
  if (!Array.isArray(paths) || paths.length > 128
    || paths.some(path => !safeRepoPath(path))
    || new Set(paths).size !== paths.length) return reject('invalid-review-paths')
  if (!SHA256.test(expectedReviewedDiffSha256)) return reject('invalid-reviewed-diff-hash')

  if (phase === 'early-exception') {
    if (state.earlyReview) return reject('early-exception-already-used')
    if (state.completionReview) return reject('completion-review-already-started')
    if (paths.length === 0
      || paths.some(path => exceptionForPath(path, bound.earlyExceptions) === null)) {
      return reject('mid-task-review-not-excepted')
    }
  } else {
    if (state.completionReview) return reject('completion-review-already-used')
    if (state.earlyReview?.status === 'requested') return reject('early-exception-artifact-pending')
  }

  const request: ReviewRequestState = {
    phase,
    requestId: `${phase}:${state.taskId}`,
    paths: [...paths].sort(),
    expectedReviewedDiffSha256,
    status: 'requested',
  }
  const next: CompletionReviewGateState = phase === 'early-exception'
    ? { ...state, earlyReview: request }
    : { ...state, completionReview: request }
  return {
    ok: true,
    state: next,
    reason: 'review-requested',
    request,
    metrics: [{
      type: 'review_gate_request', phase, outcome: 'accepted',
      reason: 'review-requested', pathCount: paths.length,
    }],
  }
}

export type ReviewArtifactDecision = Readonly<{
  ok: boolean
  state: CompletionReviewGateState
  reason: string
  metrics: readonly CompletionReviewMetricEvent[]
}>

export function recordTaskReviewArtifact(
  state: CompletionReviewGateState,
  policy: CompletionReviewPolicy,
  evidence: ReviewArtifactEvidence,
): ReviewArtifactDecision {
  assertBoundPolicy(state, policy)
  const current = evidence.phase === 'early-exception' ? state.earlyReview : state.completionReview
  const reject = (reason: string): ReviewArtifactDecision => ({
    ok: false,
    state,
    reason,
    metrics: [{
      type: 'review_gate_artifact', phase: evidence.phase,
      outcome: 'rejected', reason,
    }],
  })
  if (state.terminal !== 'open') return reject('task-already-terminal')
  if (!current || current.status !== 'requested') return reject('review-not-requested')
  if (!object(evidence) || !exactKeys(evidence, [
    'artifactId', 'artifactSha256', 'taskId', 'phase', 'reviewedDiffSha256', 'verdict',
  ]) || evidence.taskId !== state.taskId || !SAFE_ARTIFACT.test(evidence.artifactId)
    || !SHA256.test(evidence.artifactSha256)
    || !SHA256.test(evidence.reviewedDiffSha256)
    || !['approve', 'needs-changes', 'block', 'review-unavailable'].includes(evidence.verdict)) {
    return reject('review-artifact-invalid')
  }
  if (evidence.reviewedDiffSha256 !== current.expectedReviewedDiffSha256) {
    return reject('reviewed-diff-hash-mismatch')
  }
  const recorded: ReviewRequestState = {
    ...current,
    status: 'recorded',
    artifactId: evidence.artifactId,
    artifactSha256: evidence.artifactSha256,
    reviewedDiffSha256: evidence.reviewedDiffSha256,
    verdict: evidence.verdict,
  }
  return {
    ok: true,
    state: evidence.phase === 'early-exception'
      ? { ...state, earlyReview: recorded }
      : { ...state, completionReview: recorded },
    reason: 'review-artifact-recorded',
    metrics: [{
      type: 'review_gate_artifact', phase: evidence.phase,
      outcome: 'accepted', reason: 'review-artifact-recorded',
      verdict: evidence.verdict,
      reviewStatus: evidence.verdict === 'review-unavailable' ? 'pending' : 'complete',
    }],
  }
}

export type TerminalTransitionDecision = Readonly<{
  ok: boolean
  state: CompletionReviewGateState
  reason: string
  reviewStatus: 'complete' | 'pending' | 'missing'
  metrics: readonly CompletionReviewMetricEvent[]
}>

export function assessTerminalTransition(
  state: CompletionReviewGateState,
  policy: CompletionReviewPolicy,
  action: TerminalAction,
): TerminalTransitionDecision {
  assertBoundPolicy(state, policy)
  const reject = (reason: string): TerminalTransitionDecision => ({
    ok: false,
    state,
    reason,
    reviewStatus: 'missing',
    metrics: [{
      type: 'review_gate_terminal', outcome: 'rejected', reason,
      reviewStatus: 'pending',
    }],
  })
  if (action !== 'stop' && action !== 'done') return reject('terminal-action-invalid')
  if (state.terminal !== 'open') return reject('task-already-terminal')
  if (state.earlyReview?.status === 'requested') return reject('early-exception-artifact-pending')
  if (!state.completionReview) return reject('completion-review-not-requested')
  if (state.completionReview.status !== 'recorded'
    || !state.completionReview.artifactId
    || !state.completionReview.artifactSha256
    || !state.completionReview.verdict) {
    return reject('completion-verdict-or-artifact-missing')
  }
  const reviewStatus = state.completionReview.verdict === 'review-unavailable'
    ? 'pending' as const
    : 'complete' as const
  return {
    ok: true,
    state: { ...state, terminal: action },
    reason: 'terminal-transition-allowed',
    reviewStatus,
    metrics: [{
      type: 'review_gate_terminal', outcome: 'accepted',
      reason: 'terminal-transition-allowed', reviewStatus,
    }],
  }
}
