import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'fs'
import { join } from 'path'
import {
  assessTerminalTransition,
  createCompletionReviewGate,
  parseCompletionReviewPolicy,
  recordTaskReviewArtifact,
  requestTaskReview,
  type CompletionReviewPolicy,
  type ReviewPhase,
  type ReviewVerdict,
} from './completion-review-policy.ts'

const policy = parseCompletionReviewPolicy(JSON.parse(readFileSync(
  join(import.meta.dir, 'completion-review-policy.json'), 'utf8',
)))
const DIFF_HASH = 'a'.repeat(64)

const artifact = (taskId: string, phase: ReviewPhase, verdict: ReviewVerdict = 'approve') => ({
  artifactId: `${phase}-artifact`, taskId, phase,
  artifactSha256: 'b'.repeat(64), reviewedDiffSha256: DIFF_HASH, verdict,
})

describe('runtime-blind completion review gate', () => {
  test('requires exactly one completion verdict artifact before stop or done', () => {
    let state = createCompletionReviewGate('task-1', policy)
    expect(assessTerminalTransition(state, policy, 'done')).toMatchObject({
      ok: false, reason: 'completion-review-not-requested', reviewStatus: 'missing',
    })

    const requested = requestTaskReview(state, policy, 'completion', ['src/change.ts'], DIFF_HASH)
    expect(requested.ok).toBe(true)
    state = requested.state
    expect(assessTerminalTransition(state, policy, 'stop')).toMatchObject({
      ok: false, reason: 'completion-verdict-or-artifact-missing',
    })

    const recorded = recordTaskReviewArtifact(state, policy, artifact('task-1', 'completion'))
    expect(recorded.ok).toBe(true)
    state = recorded.state
    const done = assessTerminalTransition(state, policy, 'done')
    expect(done).toMatchObject({ ok: true, reason: 'terminal-transition-allowed', reviewStatus: 'complete' })
    expect(done.state.terminal).toBe('done')
    expect(requestTaskReview(state, policy, 'completion', [], DIFF_HASH)).toMatchObject({
      ok: false, reason: 'completion-review-already-used',
    })
  })

  test('allows at most one targeted early exception and still requires completion review', () => {
    let state = createCompletionReviewGate('task-2', policy)
    expect(requestTaskReview(
      state, policy, 'early-exception', ['src/ordinary.ts'], DIFF_HASH,
    )).toMatchObject({
      ok: false, reason: 'mid-task-review-not-excepted',
    })
    const early = requestTaskReview(
      state, policy, 'early-exception',
      ['codex-bridge/security.ts', 'templates/_base/codex/rules/qofi-hard-floor.rules'],
      DIFF_HASH,
    )
    expect(early.ok).toBe(true)
    expect(early.request?.paths).toEqual([
      'codex-bridge/security.ts',
      'templates/_base/codex/rules/qofi-hard-floor.rules',
    ])
    state = recordTaskReviewArtifact(
      early.state, policy, artifact('task-2', 'early-exception', 'needs-changes'),
    ).state
    expect(requestTaskReview(
      state, policy, 'early-exception', ['codex-bridge/security.ts'], DIFF_HASH,
    ))
      .toMatchObject({ ok: false, reason: 'early-exception-already-used' })
    expect(assessTerminalTransition(state, policy, 'done')).toMatchObject({
      ok: false, reason: 'completion-review-not-requested',
    })
  })

  test('unavailable completion remains an artifact-backed pending result, never silent approval', () => {
    let state = createCompletionReviewGate('task-3', policy)
    state = requestTaskReview(state, policy, 'completion', [], DIFF_HASH).state
    state = recordTaskReviewArtifact(
      state, policy, artifact('task-3', 'completion', 'review-unavailable'),
    ).state
    const done = assessTerminalTransition(state, policy, 'done')
    expect(done).toMatchObject({ ok: true, reviewStatus: 'pending' })
    expect(done.metrics).toEqual([expect.objectContaining({
      type: 'review_gate_terminal', outcome: 'accepted', reviewStatus: 'pending',
    })])
  })

  test('binds a task to the repo-controlled exception policy and exact artifact scope', () => {
    const state = createCompletionReviewGate('task-4', policy)
    const changed = parseCompletionReviewPolicy({
      ...policy,
      earlyExceptions: [...policy.earlyExceptions, {
        class: 'security', pattern: 'src/new-exception.ts',
      }],
    })
    expect(() => requestTaskReview(state, changed, 'completion', [], DIFF_HASH))
      .toThrow('policy changed during task')

    const requested = requestTaskReview(state, policy, 'completion', [], DIFF_HASH)
    expect(recordTaskReviewArtifact(requested.state, policy, {
      ...artifact('another-task', 'completion'), taskId: 'another-task',
    })).toMatchObject({ ok: false, reason: 'review-artifact-invalid' })

    expect(recordTaskReviewArtifact(requested.state, policy, {
      ...artifact('task-4', 'completion'), reviewedDiffSha256: 'c'.repeat(64),
    })).toMatchObject({ ok: false, reason: 'reviewed-diff-hash-mismatch' })
  })

  test('uses one ordinary completion call plus a separately classified early allowance', () => {
    expect(policy.maxCallsPerTask).toBe(1)
    expect(policy.maxEarlyExceptionCallsPerTask).toBe(1)
    const reviewerPolicy = JSON.parse(readFileSync(
      join(import.meta.dir, '..', 'fable-reviewer.json'), 'utf8',
    ))
    expect(reviewerPolicy.defaults.maxCallsPerTask).toBe(1)
    expect(() => parseCompletionReviewPolicy({ ...policy, maxCallsPerTask: 2 }))
      .toThrow('policy is malformed')
    expect(() => parseCompletionReviewPolicy({
      ...policy, maxEarlyExceptionCallsPerTask: 2,
    })).toThrow('policy is malformed')
    expect(policy.earlyExceptions.map(entry => entry.pattern)).toEqual([
      'bin/qofi-codex-runner',
      'bin/swarm-codex-runtime.py',
      'codex-bridge/git-broker.ts',
      'codex-bridge/runtime-acl.ts',
      'codex-bridge/security.ts',
      'templates/_base/codex/fable-reviewer-doctrine.md',
      'templates/_base/codex/rules/**',
    ])
  })
})
