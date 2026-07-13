import {
  assessTerminalTransition,
  type CompletionReviewGateState,
  type CompletionReviewPolicy,
  type TerminalTransitionDecision,
} from './completion-review-policy.ts'
import { type RuntimeStopAdapter } from './runtime-adapters.ts'
import {
  type StopDeliveryPipeline,
  type StopOutcome,
} from './stop-delivery.ts'

export const TASK_BOUNDARY_RESULT_SCHEMA = 'qofi-task-boundary-result/v1' as const

export type TaskBoundaryResult = Readonly<{
  schema: typeof TASK_BOUNDARY_RESULT_SCHEMA
  accepted: boolean
  review_status: 'complete' | 'pending' | 'missing'
  gate: TerminalTransitionDecision
  gate_state: CompletionReviewGateState
  stop: StopOutcome
}>

/**
 * The one completion seam used by both runtime adapters. Policy is evaluated
 * before transport. The gate becomes terminal only after Discord delivery is
 * proven delivered-or-queued; a transport failure keeps the task open.
 */
export async function enforceTaskCompletionBoundary<Input>(options: Readonly<{
  adapter: RuntimeStopAdapter<Input>
  pipeline: StopDeliveryPipeline
  input: Input
  gateState: CompletionReviewGateState
  policy: CompletionReviewPolicy
}>): Promise<TaskBoundaryResult> {
  const event = options.adapter.normalizeStop(options.input)
  const gate = assessTerminalTransition(options.gateState, options.policy, 'stop')
  if (!gate.ok) {
    const stop = await options.pipeline.recordBlockedAttempt(event, gate.reason)
    return {
      schema: TASK_BOUNDARY_RESULT_SCHEMA,
      accepted: false,
      review_status: gate.reviewStatus,
      gate,
      gate_state: options.gateState,
      stop,
    }
  }

  // Reuse the exact event already assessed. Adapters are translation-only, but
  // callers may supply a moving clock/transcript reader; normalizing twice
  // would make the audit bytes depend on timing between policy and delivery.
  const stop = await options.pipeline.execute(event)
  const accepted = stop.stopped
    && (stop.disposition === 'delivered' || stop.disposition === 'queued')
  return {
    schema: TASK_BOUNDARY_RESULT_SCHEMA,
    accepted,
    review_status: gate.reviewStatus,
    gate,
    gate_state: accepted ? gate.state : options.gateState,
    stop,
  }
}
