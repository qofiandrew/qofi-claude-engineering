import { describe, expect, test } from 'bun:test'
import {
  assessFirstSubstantiveEdit,
  assessWarmSubagentContext,
  buildProductContextGapReport,
  buildProductContextPreloadPlan,
  createGroundingState,
  generateProductContextPack,
  parseProductContextTaskBrief,
  recordGroundingAction,
  validateProductContextPack,
} from './product-context-pack.ts'

const sources = [
  { name: 'requirements', path: 'product/requirements.md', content: '# Requirements\nFast and safe.\n' },
  { name: 'users', path: 'product/users.md', content: '# Users\nOperators.\n' },
  { name: 'vision', path: 'product/vision.md', content: '# Vision\nUseful.\n' },
]

function brief(corpusSha256: string, refs = ['requirements', 'users']) {
  return {
    schema: 'qofi-product-context-brief/v1',
    taskId: 'task-product-1',
    productContext: { corpusSha256, refs },
  }
}

describe('corpus-hash keyed product context packs', () => {
  test('generation is deterministic across input order and validation detects tampering', () => {
    const first = generateProductContextPack(sources)
    const second = generateProductContextPack([...sources].reverse())
    expect(second.pack).toEqual(first.pack)
    expect(first.pack.packKey).toBe(`product-context:${first.pack.corpusSha256}`)
    expect(first.metrics).toEqual([expect.objectContaining({
      type: 'context_pack_generated', outcome: 'accepted', refCount: 3,
    })])
    expect(validateProductContextPack(first.pack, first.pack.corpusSha256).metrics)
      .toEqual([expect.objectContaining({ type: 'context_pack_validated' })])

    const changed = generateProductContextPack([
      { ...sources[0], content: `${sources[0].content}Changed.\n` }, ...sources.slice(1),
    ])
    expect(changed.pack.corpusSha256).not.toBe(first.pack.corpusSha256)
    expect(() => validateProductContextPack({
      ...first.pack,
      refs: first.pack.refs.map((ref, index) => index === 0 ? { ...ref, content: 'tampered' } : ref),
    })).toThrow('ref is malformed')
  })

  test('task briefs require named refs and gap reports are stable and sorted', () => {
    const { pack } = generateProductContextPack(sources)
    expect(() => parseProductContextTaskBrief(brief(pack.corpusSha256, [])))
      .toThrow('must declare bounded named')
    const withGap = brief(pack.corpusSha256, ['users', 'missing-ref', 'requirements'])
    const report = buildProductContextGapReport(pack, withGap).report
    expect(report).toEqual({
      schema: 'qofi-product-context-gap/v1',
      taskId: 'task-product-1',
      corpusSha256: pack.corpusSha256,
      missingRefs: ['missing-ref'],
      unreadRefs: ['requirements', 'users'],
      grepShortfall: 0,
      gaps: [
        'missing-ref:missing-ref',
        'unread-ref:requirements',
        'unread-ref:users',
      ],
      readyForSubstantiveEdit: false,
    })
  })

  test('read and grep grounding budgets gate the first substantive edit', () => {
    const { pack } = generateProductContextPack(sources)
    const taskBrief = brief(pack.corpusSha256)
    let state = createGroundingState(pack, taskBrief, {
      maxReads: 2, maxGreps: 1, minimumGreps: 1,
    })
    expect(assessFirstSubstantiveEdit(pack, taskBrief, state)).toMatchObject({
      ok: false,
      reason: 'product-context-grounding-incomplete',
      report: { unreadRefs: ['requirements', 'users'], grepShortfall: 1 },
    })
    expect(recordGroundingAction(state, {
      kind: 'grep', ref: 'requirements', query: 'latency|safety',
    })).toMatchObject({ ok: false, reason: 'grounding-refs-not-read-before-grep' })
    state = recordGroundingAction(state, { kind: 'read', ref: 'users' }).state
    state = recordGroundingAction(state, { kind: 'read', ref: 'requirements' }).state
    expect(recordGroundingAction(state, { kind: 'read', ref: 'requirements' }))
      .toMatchObject({ ok: false, reason: 'grounding-read-duplicated' })
    state = recordGroundingAction(state, {
      kind: 'grep', ref: 'requirements', query: 'latency|safety',
    }).state
    expect(recordGroundingAction(state, {
      kind: 'grep', ref: 'users', query: 'operator',
    })).toMatchObject({ ok: false, reason: 'grounding-grep-budget-exhausted' })

    const edit = assessFirstSubstantiveEdit(pack, taskBrief, state)
    expect(edit).toMatchObject({
      ok: true,
      reason: 'product-context-grounding-complete',
      report: { gaps: [], readyForSubstantiveEdit: true },
    })
    expect(edit.metrics.map(event => event.type)).toEqual([
      'context_pack_gap', 'context_edit_gate',
    ])
    expect(recordGroundingAction(edit.state, { kind: 'read', ref: 'users' }))
      .toMatchObject({ ok: false, reason: 'grounding-window-closed' })
  })

  test('a missing named ref emits a pack gap and then permits the first edit', () => {
    const { pack } = generateProductContextPack(sources)
    const taskBrief = brief(pack.corpusSha256, ['missing-ref', 'requirements'])
    let state = createGroundingState(pack, taskBrief, {
      maxReads: 2, maxGreps: 1, minimumGreps: 0,
    })
    state = recordGroundingAction(state, { kind: 'read', ref: 'requirements' }).state
    const edit = assessFirstSubstantiveEdit(pack, taskBrief, state)
    expect(edit).toMatchObject({
      ok: true,
      reason: 'product-context-gap-reported-proceed',
      report: {
        missingRefs: ['missing-ref'], unreadRefs: [],
        gaps: ['missing-ref:missing-ref'], readyForSubstantiveEdit: true,
      },
    })
  })

  test('preload and warm-subagent doctrine is byte-deterministic and scope-bound', () => {
    const { pack } = generateProductContextPack(sources)
    const taskBrief = brief(pack.corpusSha256, ['users', 'requirements'])
    const first = buildProductContextPreloadPlan(pack, taskBrief, {
      maxReads: 2, maxGreps: 2, minimumGreps: 1,
    })
    const second = buildProductContextPreloadPlan(pack, taskBrief, {
      maxReads: 2, maxGreps: 2, minimumGreps: 1,
    })
    expect(second).toEqual(first)
    expect(first.primaryReadOrder).toEqual(['requirements', 'users'])
    expect(first.warmSubagentContract).toEqual({
      corpusSha256: pack.corpusSha256,
      refs: ['requirements', 'users'],
      requireExactMatch: true,
    })
    expect(first.doctrine).toContain('before_first_substantive_edit')
    expect(first.doctrine).toContain('WARM_SUBAGENT_REQUIRE exact corpus hash and named-ref set')
    expect(first.doctrineSha256).toMatch(/^[0-9a-f]{64}$/)
    expect(assessWarmSubagentContext(first, {
      corpusSha256: pack.corpusSha256,
      refs: ['requirements', 'users'],
    })).toMatchObject({ ok: true, reason: 'warm-context-exact' })
    expect(assessWarmSubagentContext(first, {
      corpusSha256: 'c'.repeat(64),
      refs: ['requirements', 'users'],
    })).toMatchObject({ ok: false, reason: 'warm-context-mismatch' })
  })

  test('a brief cannot silently bind a stale corpus or an impossible read budget', () => {
    const { pack } = generateProductContextPack(sources)
    expect(() => createGroundingState(pack, brief('b'.repeat(64))))
      .toThrow('corpus hash does not match')
    expect(() => createGroundingState(pack, brief(pack.corpusSha256), {
      maxReads: 1, maxGreps: 1, minimumGreps: 1,
    })).toThrow('read budget cannot cover')
  })
})
