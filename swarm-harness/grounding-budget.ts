import { createHash } from 'node:crypto'
import {
  parseNormalizedEvent,
  type NormalizedSwarmEvent,
  type WorkerRuntime,
} from './events.ts'

export const GROUNDING_BUDGET_SCHEMA = 'qofi-grounding-budget/v1' as const
export const PACK_GAP_REPORT_SCHEMA = 'qofi-pack-gap-report/v1' as const

export type GroundingBudgetPolicy = Readonly<{
  maxOperationsBeforeFirstEdit: number
}>

export const DEFAULT_GROUNDING_BUDGET_POLICY: GroundingBudgetPolicy = Object.freeze({
  maxOperationsBeforeFirstEdit: 36,
})

export type PackGapReport = Readonly<{
  schema: typeof PACK_GAP_REPORT_SCHEMA
  task_id: string
  corpus_sha256: string
  missing_context_refs: readonly string[]
  operation_count: number
  report_sha256: string
}>

export type GroundingBudgetState = Readonly<{
  schema: typeof GROUNDING_BUDGET_SCHEMA
  task_id: string
  swarm: string
  runtime: WorkerRuntime
  corpus_sha256: string
  max_operations_before_first_edit: number
  operation_count: number
  tripped: boolean
  gap_report: PackGapReport | null
  first_substantive_edit_seen: boolean
}>

export type GroundingBudgetDecision = Readonly<{
  ok: boolean
  state: GroundingBudgetState
  reason:
    | 'grounding-operation-recorded'
    | 'grounding-budget-tripped'
    | 'grounding-gap-report-required'
    | 'first-substantive-edit-recorded'
    | 'post-edit-event-ignored'
  emit_gap_request: boolean
}>

const LABEL = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
const SWARM = /^[a-z][a-z0-9-]{0,63}$/
const REF = /^[a-z][a-z0-9_.-]{0,63}$/
const SHA256 = /^[a-f0-9]{64}$/

function canonicalReport(value: Omit<PackGapReport, 'report_sha256'>): string {
  return JSON.stringify({
    schema: value.schema,
    task_id: value.task_id,
    corpus_sha256: value.corpus_sha256,
    missing_context_refs: value.missing_context_refs,
    operation_count: value.operation_count,
  })
}

function reportDigest(value: Omit<PackGapReport, 'report_sha256'>): string {
  return createHash('sha256').update(canonicalReport(value)).digest('hex')
}

function validatePolicy(policy: GroundingBudgetPolicy): number {
  const value = policy?.maxOperationsBeforeFirstEdit
  if (!Number.isSafeInteger(value) || value < 1 || value > 1_024) {
    throw new Error('grounding operation budget must be an integer from 1 through 1024')
  }
  return value
}

function validateState(state: GroundingBudgetState): void {
  if (state.schema !== GROUNDING_BUDGET_SCHEMA
    || !LABEL.test(state.task_id) || !SWARM.test(state.swarm)
    || !['claude', 'codex', 'harness'].includes(state.runtime)
    || !SHA256.test(state.corpus_sha256)
    || !Number.isSafeInteger(state.max_operations_before_first_edit)
    || state.max_operations_before_first_edit < 1
    || !Number.isSafeInteger(state.operation_count) || state.operation_count < 0
    || state.tripped !== (state.operation_count > state.max_operations_before_first_edit)
    || typeof state.first_substantive_edit_seen !== 'boolean') {
    throw new Error('grounding budget state is malformed')
  }
  if (state.gap_report !== null) {
    const report = state.gap_report
    const unsigned = {
      schema: report.schema,
      task_id: report.task_id,
      corpus_sha256: report.corpus_sha256,
      missing_context_refs: report.missing_context_refs,
      operation_count: report.operation_count,
    }
    if (report.schema !== PACK_GAP_REPORT_SCHEMA || report.task_id !== state.task_id
      || report.corpus_sha256 !== state.corpus_sha256
      || report.operation_count !== state.operation_count
      || !state.tripped || !Array.isArray(report.missing_context_refs)
      || report.missing_context_refs.length < 1 || report.missing_context_refs.length > 32
      || report.missing_context_refs.some(ref => typeof ref !== 'string' || !REF.test(ref))
      || new Set(report.missing_context_refs).size !== report.missing_context_refs.length
      || JSON.stringify(report.missing_context_refs) !== JSON.stringify([...report.missing_context_refs].sort())
      || !SHA256.test(report.report_sha256)
      || report.report_sha256 !== reportDigest(unsigned)) {
      throw new Error('pack gap report is malformed')
    }
  }
}

export function createGroundingBudgetState(
  scope: Readonly<{
    task_id: string
    swarm: string
    runtime: WorkerRuntime
    corpus_sha256: string
  }>,
  policy: GroundingBudgetPolicy = DEFAULT_GROUNDING_BUDGET_POLICY,
): GroundingBudgetState {
  const maximum = validatePolicy(policy)
  const state: GroundingBudgetState = {
    schema: GROUNDING_BUDGET_SCHEMA,
    task_id: scope.task_id,
    swarm: scope.swarm,
    runtime: scope.runtime,
    corpus_sha256: scope.corpus_sha256,
    max_operations_before_first_edit: maximum,
    operation_count: 0,
    tripped: false,
    gap_report: null,
    first_substantive_edit_seen: false,
  }
  validateState(state)
  return state
}

/**
 * Consume the runtime-blind structural stream. Reads/searches are never blocked:
 * the first operation beyond N trips one deterministic gap requirement. The
 * first substantive edit is held only until the worker files that bounded gap
 * report, after which work proceeds.
 */
export function observeGroundingEvent(
  state: GroundingBudgetState,
  input: NormalizedSwarmEvent,
): GroundingBudgetDecision {
  validateState(state)
  const event = parseNormalizedEvent(input)
  if (event.task_id !== state.task_id || event.swarm !== state.swarm
    || (event.runtime !== state.runtime && event.runtime !== 'harness')) {
    throw new Error('grounding event is outside the active task scope')
  }
  if (state.first_substantive_edit_seen) {
    return { ok: true, state, reason: 'post-edit-event-ignored', emit_gap_request: false }
  }
  if (event.type === 'grounding.operation') {
    const operation_count = state.operation_count + 1
    const tripped = operation_count > state.max_operations_before_first_edit
    const next = { ...state, operation_count, tripped }
    validateState(next)
    return {
      ok: true,
      state: next,
      reason: tripped ? 'grounding-budget-tripped' : 'grounding-operation-recorded',
      emit_gap_request: tripped && !state.tripped,
    }
  }
  if (event.type === 'edit.substantive') {
    if (state.tripped && state.gap_report === null) {
      return {
        ok: false,
        state,
        reason: 'grounding-gap-report-required',
        emit_gap_request: true,
      }
    }
    const next = { ...state, first_substantive_edit_seen: true }
    validateState(next)
    return {
      ok: true,
      state: next,
      reason: 'first-substantive-edit-recorded',
      emit_gap_request: false,
    }
  }
  return { ok: true, state, reason: 'post-edit-event-ignored', emit_gap_request: false }
}

export function filePackGapReport(
  state: GroundingBudgetState,
  missingContextRefs: readonly string[],
): GroundingBudgetState {
  validateState(state)
  if (!state.tripped || state.first_substantive_edit_seen || state.gap_report !== null) {
    throw new Error('pack gap report is not due')
  }
  if (!Array.isArray(missingContextRefs) || missingContextRefs.length < 1
    || missingContextRefs.length > 32
    || missingContextRefs.some(ref => typeof ref !== 'string' || !REF.test(ref))) {
    throw new Error('pack gap report must name bounded missing context refs')
  }
  const refs = [...new Set(missingContextRefs)].sort()
  if (refs.length !== missingContextRefs.length) throw new Error('pack gap report refs are duplicated')
  const unsigned: Omit<PackGapReport, 'report_sha256'> = {
    schema: PACK_GAP_REPORT_SCHEMA,
    task_id: state.task_id,
    corpus_sha256: state.corpus_sha256,
    missing_context_refs: refs,
    operation_count: state.operation_count,
  }
  const next = {
    ...state,
    gap_report: { ...unsigned, report_sha256: reportDigest(unsigned) },
  }
  validateState(next)
  return next
}
