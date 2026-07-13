import { describe, expect, test } from 'bun:test'
import { makeHarnessEvent, type WorkerRuntime } from './events.ts'
import {
  createGroundingBudgetState,
  filePackGapReport,
  observeGroundingEvent,
} from './grounding-budget.ts'

const CORPUS = 'c'.repeat(64)

function event(runtime: WorkerRuntime, type: 'grounding.operation' | 'edit.substantive', seq: number) {
  return makeHarnessEvent({
    ts: `2026-07-13T10:00:0${seq}Z`,
    type,
    runtime,
    source: runtime === 'claude' ? 'claude-transcript' : 'codex-rollout',
    swarm: 'press-backend',
    task_id: 'task-grounding',
    dr_refs: ['ADR-0023'],
    ...(type === 'grounding.operation' ? { operation: seq % 2 ? 'read' as const : 'grep' as const } : {}),
  })
}

for (const runtime of ['claude', 'codex'] as const) {
  describe(`${runtime} grounding-budget conformance`, () => {
    test('N+1 trips one pack-gap request, then the report lets the edit proceed', () => {
      let state = createGroundingBudgetState({
        task_id: 'task-grounding', swarm: 'press-backend', runtime, corpus_sha256: CORPUS,
      }, { maxOperationsBeforeFirstEdit: 2 })
      state = observeGroundingEvent(state, event(runtime, 'grounding.operation', 1)).state
      state = observeGroundingEvent(state, event(runtime, 'grounding.operation', 2)).state
      const trip = observeGroundingEvent(state, event(runtime, 'grounding.operation', 3))
      expect(trip).toMatchObject({ ok: true, reason: 'grounding-budget-tripped', emit_gap_request: true })
      state = trip.state
      expect(observeGroundingEvent(state, event(runtime, 'edit.substantive', 4))).toMatchObject({
        ok: false, reason: 'grounding-gap-report-required', emit_gap_request: true,
      })
      state = filePackGapReport(state, ['database-schema', 'module-map'])
      expect(state.gap_report).toMatchObject({
        missing_context_refs: ['database-schema', 'module-map'], operation_count: 3,
      })
      const edit = observeGroundingEvent(state, event(runtime, 'edit.substantive', 4))
      expect(edit).toMatchObject({ ok: true, reason: 'first-substantive-edit-recorded' })
    })

    test('within-budget work needs no synthetic gap report', () => {
      let state = createGroundingBudgetState({
        task_id: 'task-grounding', swarm: 'press-backend', runtime, corpus_sha256: CORPUS,
      }, { maxOperationsBeforeFirstEdit: 2 })
      state = observeGroundingEvent(state, event(runtime, 'grounding.operation', 1)).state
      expect(observeGroundingEvent(state, event(runtime, 'edit.substantive', 2))).toMatchObject({
        ok: true, reason: 'first-substantive-edit-recorded', emit_gap_request: false,
      })
      expect(() => filePackGapReport(state, ['invented-gap'])).toThrow('not due')
    })
  })
}
