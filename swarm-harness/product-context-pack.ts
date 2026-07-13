import { createHash } from 'crypto'

export const PRODUCT_CONTEXT_PACK_SCHEMA = 'qofi-product-context-pack/v1' as const
export const PRODUCT_CONTEXT_BRIEF_SCHEMA = 'qofi-product-context-brief/v1' as const
export const PRODUCT_CONTEXT_GROUNDING_SCHEMA = 'qofi-product-context-grounding/v1' as const
export const PRODUCT_CONTEXT_GAP_SCHEMA = 'qofi-product-context-gap/v1' as const
export const PRODUCT_CONTEXT_PRELOAD_SCHEMA = 'qofi-product-context-preload/v1' as const

export const MAX_PRODUCT_CONTEXT_REFS = 32
export const MAX_PRODUCT_CONTEXT_REF_BYTES = 512 * 1024
export const MAX_PRODUCT_CONTEXT_PACK_BYTES = 2 * 1024 * 1024

export type ProductCorpusSource = Readonly<{
  name: string
  path: string
  content: string
}>

export type ProductContextRef = Readonly<{
  name: string
  path: string
  contentSha256: string
  bytes: number
  content: string
}>

export type ProductContextPack = Readonly<{
  schema: typeof PRODUCT_CONTEXT_PACK_SCHEMA
  packKey: string
  corpusSha256: string
  refs: readonly ProductContextRef[]
}>

export type ProductContextTaskBrief = Readonly<{
  schema: typeof PRODUCT_CONTEXT_BRIEF_SCHEMA
  taskId: string
  productContext: Readonly<{
    corpusSha256: string
    refs: readonly string[]
  }>
}>

export type GroundingPolicy = Readonly<{
  maxReads: number
  maxGreps: number
  minimumGreps: number
}>

export const DEFAULT_GROUNDING_POLICY: GroundingPolicy = Object.freeze({
  maxReads: 32,
  maxGreps: 4,
  minimumGreps: 0,
})

export type GroundingState = Readonly<{
  schema: typeof PRODUCT_CONTEXT_GROUNDING_SCHEMA
  taskId: string
  corpusSha256: string
  requiredRefs: readonly string[]
  availableRefs: readonly string[]
  policy: GroundingPolicy
  reads: readonly string[]
  greps: readonly Readonly<{ ref: string; querySha256: string }>[]
  firstSubstantiveEditAuthorized: boolean
}>

export type ProductContextGapReport = Readonly<{
  schema: typeof PRODUCT_CONTEXT_GAP_SCHEMA
  taskId: string
  corpusSha256: string
  missingRefs: readonly string[]
  unreadRefs: readonly string[]
  grepShortfall: number
  gaps: readonly string[]
  readyForSubstantiveEdit: boolean
}>

export type ProductContextMetricEvent = Readonly<{
  type: 'context_pack_generated' | 'context_pack_validated' | 'context_pack_gap'
    | 'context_grounding_action' | 'context_edit_gate' | 'context_warm_subagent'
  outcome: 'accepted' | 'rejected' | 'ready' | 'gap'
  reason: string
  corpusSha256: string
  refCount?: number
  missingRefCount?: number
  unreadRefCount?: number
  readCount?: number
  grepCount?: number
}>

export type ProductContextPreloadPlan = Readonly<{
  schema: typeof PRODUCT_CONTEXT_PRELOAD_SCHEMA
  corpusSha256: string
  packKey: string
  requiredRefs: readonly Readonly<{
    name: string
    path: string
    contentSha256: string
  }>[]
  groundingPolicy: GroundingPolicy
  primaryReadOrder: readonly string[]
  warmSubagentContract: Readonly<{
    corpusSha256: string
    refs: readonly string[]
    requireExactMatch: true
  }>
  doctrine: string
  doctrineSha256: string
}>

const SAFE_NAME = /^[a-z][a-z0-9_.-]{0,63}$/
const SAFE_TASK = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/
const SHA256 = /^[0-9a-f]{64}$/

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  return Object.keys(value).length === expected.length
    && expected.every(key => Object.prototype.hasOwnProperty.call(value, key))
}

function safePath(value: unknown): value is string {
  if (typeof value !== 'string' || value.length < 1 || value.length > 512
    || value.startsWith('/') || value.startsWith('./') || value.includes('\\')
    || value.includes('\0') || value.includes('//')) return false
  return value.split('/').every(part => part !== '' && part !== '.' && part !== '..')
}

function sha256(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex')
}

const compareStable = (left: string, right: string): number => left < right ? -1 : left > right ? 1 : 0

function canonicalCorpusDescriptor(refs: readonly ProductContextRef[]): string {
  return JSON.stringify(refs.map(ref => ({
    name: ref.name,
    path: ref.path,
    contentSha256: ref.contentSha256,
    bytes: ref.bytes,
  })))
}

function validContent(value: unknown): value is string {
  return typeof value === 'string'
    && !value.includes('\0')
    && Buffer.byteLength(value, 'utf8') <= MAX_PRODUCT_CONTEXT_REF_BYTES
}

function normalizePolicy(value: GroundingPolicy): GroundingPolicy {
  if (!object(value)
    || !exactKeys(value, ['maxReads', 'maxGreps', 'minimumGreps'])
    || !Number.isSafeInteger(value.maxReads) || value.maxReads < 1
    || value.maxReads > MAX_PRODUCT_CONTEXT_REFS
    || !Number.isSafeInteger(value.maxGreps) || value.maxGreps < 1 || value.maxGreps > 16
    || !Number.isSafeInteger(value.minimumGreps) || value.minimumGreps < 0
    || value.minimumGreps > value.maxGreps) {
    throw new Error('product context grounding policy is malformed')
  }
  return {
    maxReads: value.maxReads as number,
    maxGreps: value.maxGreps as number,
    minimumGreps: value.minimumGreps as number,
  }
}

function sortedUniqueNames(value: unknown, maximum = MAX_PRODUCT_CONTEXT_REFS): value is string[] {
  return Array.isArray(value) && value.length <= maximum
    && value.every(name => typeof name === 'string' && SAFE_NAME.test(name))
    && new Set(value).size === value.length
    && JSON.stringify(value) === JSON.stringify([...value].sort())
}

function assertGroundingState(value: GroundingState): void {
  if (!object(value) || !exactKeys(value, [
    'schema', 'taskId', 'corpusSha256', 'requiredRefs', 'availableRefs', 'policy',
    'reads', 'greps', 'firstSubstantiveEditAuthorized',
  ]) || value.schema !== PRODUCT_CONTEXT_GROUNDING_SCHEMA
    || typeof value.taskId !== 'string' || !SAFE_TASK.test(value.taskId)
    || typeof value.corpusSha256 !== 'string' || !SHA256.test(value.corpusSha256)
    || !sortedUniqueNames(value.requiredRefs) || value.requiredRefs.length < 1
    || !sortedUniqueNames(value.availableRefs)
    || value.availableRefs.some(ref => !value.requiredRefs.includes(ref))
    || !sortedUniqueNames(value.reads)
    || value.reads.some(ref => !value.availableRefs.includes(ref))
    || typeof value.firstSubstantiveEditAuthorized !== 'boolean') {
    throw new Error('product context grounding state is malformed')
  }
  const policy = normalizePolicy(value.policy)
  if (value.requiredRefs.length > policy.maxReads || value.reads.length > policy.maxReads
    || !Array.isArray(value.greps) || value.greps.length > policy.maxGreps) {
    throw new Error('product context grounding state is malformed')
  }
  let previous = ''
  const seen = new Set<string>()
  for (const grep of value.greps) {
    if (!object(grep) || !exactKeys(grep, ['ref', 'querySha256'])
      || typeof grep.ref !== 'string' || !value.availableRefs.includes(grep.ref)
      || typeof grep.querySha256 !== 'string' || !SHA256.test(grep.querySha256)) {
      throw new Error('product context grounding state is malformed')
    }
    const key = `${grep.ref}:${grep.querySha256}`
    if (seen.has(key) || (previous && compareStable(previous, key) > 0)) {
      throw new Error('product context grounding state is malformed')
    }
    seen.add(key)
    previous = key
  }
}

export function generateProductContextPack(
  sources: readonly ProductCorpusSource[],
): Readonly<{ pack: ProductContextPack; metrics: readonly ProductContextMetricEvent[] }> {
  if (!Array.isArray(sources) || sources.length < 1 || sources.length > MAX_PRODUCT_CONTEXT_REFS) {
    throw new Error('product context corpus must contain bounded named refs')
  }
  const names = new Set<string>()
  const paths = new Set<string>()
  const refs: ProductContextRef[] = sources.map(source => {
    if (!object(source) || !exactKeys(source, ['name', 'path', 'content'])
      || typeof source.name !== 'string' || !SAFE_NAME.test(source.name)
      || !safePath(source.path) || !validContent(source.content)) {
      throw new Error('product context corpus ref is malformed')
    }
    if (names.has(source.name) || paths.has(source.path)) {
      throw new Error('product context corpus ref is duplicated')
    }
    names.add(source.name)
    paths.add(source.path)
    return {
      name: source.name,
      path: source.path,
      contentSha256: sha256(source.content),
      bytes: Buffer.byteLength(source.content, 'utf8'),
      content: source.content,
    }
  }).sort((left, right) => compareStable(left.name, right.name) || compareStable(left.path, right.path))
  const corpusSha256 = sha256(canonicalCorpusDescriptor(refs))
  const pack: ProductContextPack = {
    schema: PRODUCT_CONTEXT_PACK_SCHEMA,
    packKey: `product-context:${corpusSha256}`,
    corpusSha256,
    refs,
  }
  if (Buffer.byteLength(JSON.stringify(pack), 'utf8') > MAX_PRODUCT_CONTEXT_PACK_BYTES) {
    throw new Error('product context pack exceeds its byte bound')
  }
  return {
    pack,
    metrics: [{
      type: 'context_pack_generated', outcome: 'accepted', reason: 'corpus-hash-keyed',
      corpusSha256, refCount: refs.length,
    }],
  }
}

export function validateProductContextPack(
  value: unknown,
  expectedCorpusSha256?: string,
): Readonly<{ pack: ProductContextPack; metrics: readonly ProductContextMetricEvent[] }> {
  if (!object(value) || !exactKeys(value, ['schema', 'packKey', 'corpusSha256', 'refs'])
    || value.schema !== PRODUCT_CONTEXT_PACK_SCHEMA
    || typeof value.corpusSha256 !== 'string' || !SHA256.test(value.corpusSha256)
    || value.packKey !== `product-context:${value.corpusSha256}`
    || !Array.isArray(value.refs) || value.refs.length < 1
    || value.refs.length > MAX_PRODUCT_CONTEXT_REFS
    || Buffer.byteLength(JSON.stringify(value), 'utf8') > MAX_PRODUCT_CONTEXT_PACK_BYTES) {
    throw new Error('product context pack is malformed')
  }
  const refs: ProductContextRef[] = []
  const names = new Set<string>()
  const paths = new Set<string>()
  for (const raw of value.refs) {
    if (!object(raw) || !exactKeys(raw, ['name', 'path', 'contentSha256', 'bytes', 'content'])
      || typeof raw.name !== 'string' || !SAFE_NAME.test(raw.name)
      || !safePath(raw.path) || !validContent(raw.content)
      || typeof raw.contentSha256 !== 'string' || !SHA256.test(raw.contentSha256)
      || raw.contentSha256 !== sha256(raw.content)
      || !Number.isSafeInteger(raw.bytes) || raw.bytes !== Buffer.byteLength(raw.content, 'utf8')
      || names.has(raw.name) || paths.has(raw.path)) {
      throw new Error('product context pack ref is malformed')
    }
    names.add(raw.name)
    paths.add(raw.path)
    refs.push(raw as unknown as ProductContextRef)
  }
  const sorted = [...refs].sort((left, right) => compareStable(left.name, right.name)
    || compareStable(left.path, right.path))
  if (refs.some((ref, index) => ref.name !== sorted[index].name || ref.path !== sorted[index].path)) {
    throw new Error('product context pack refs are not canonical')
  }
  const corpusSha256 = sha256(canonicalCorpusDescriptor(refs))
  if (corpusSha256 !== value.corpusSha256
    || (expectedCorpusSha256 !== undefined && expectedCorpusSha256 !== corpusSha256)) {
    throw new Error('product context corpus hash mismatch')
  }
  const pack = value as unknown as ProductContextPack
  return {
    pack,
    metrics: [{
      type: 'context_pack_validated', outcome: 'accepted', reason: 'corpus-hash-matched',
      corpusSha256, refCount: refs.length,
    }],
  }
}

export function parseProductContextTaskBrief(value: unknown): ProductContextTaskBrief {
  if (!object(value) || !exactKeys(value, ['schema', 'taskId', 'productContext'])
    || value.schema !== PRODUCT_CONTEXT_BRIEF_SCHEMA
    || typeof value.taskId !== 'string' || !SAFE_TASK.test(value.taskId)
    || !object(value.productContext)
    || !exactKeys(value.productContext, ['corpusSha256', 'refs'])
    || typeof value.productContext.corpusSha256 !== 'string'
    || !SHA256.test(value.productContext.corpusSha256)
    || !Array.isArray(value.productContext.refs)
    || value.productContext.refs.length < 1
    || value.productContext.refs.length > MAX_PRODUCT_CONTEXT_REFS
    || value.productContext.refs.some(ref => typeof ref !== 'string' || !SAFE_NAME.test(ref))
    || new Set(value.productContext.refs).size !== value.productContext.refs.length) {
    throw new Error('task brief must declare bounded named product context refs')
  }
  return {
    schema: PRODUCT_CONTEXT_BRIEF_SCHEMA,
    taskId: value.taskId,
    productContext: {
      corpusSha256: value.productContext.corpusSha256,
      refs: [...value.productContext.refs].sort(),
    },
  }
}

export function createGroundingState(
  packValue: unknown,
  briefValue: unknown,
  policyValue: GroundingPolicy = DEFAULT_GROUNDING_POLICY,
): GroundingState {
  const { pack } = validateProductContextPack(packValue)
  const brief = parseProductContextTaskBrief(briefValue)
  const policy = normalizePolicy(policyValue)
  if (brief.productContext.corpusSha256 !== pack.corpusSha256) {
    throw new Error('task brief product corpus hash does not match pack')
  }
  if (brief.productContext.refs.length > policy.maxReads) {
    throw new Error('grounding read budget cannot cover all required refs')
  }
  const available = new Set(pack.refs.map(ref => ref.name))
  return {
    schema: PRODUCT_CONTEXT_GROUNDING_SCHEMA,
    taskId: brief.taskId,
    corpusSha256: pack.corpusSha256,
    requiredRefs: brief.productContext.refs,
    availableRefs: brief.productContext.refs.filter(ref => available.has(ref)),
    policy,
    reads: [],
    greps: [],
    firstSubstantiveEditAuthorized: false,
  }
}

export type GroundingAction = Readonly<{
  kind: 'read' | 'grep'
  ref: string
  query?: string
}>

export type GroundingActionDecision = Readonly<{
  ok: boolean
  state: GroundingState
  reason: string
  metrics: readonly ProductContextMetricEvent[]
}>

export function recordGroundingAction(
  state: GroundingState,
  action: GroundingAction,
): GroundingActionDecision {
  assertGroundingState(state)
  const reject = (reason: string): GroundingActionDecision => ({
    ok: false,
    state,
    reason,
    metrics: [{
      type: 'context_grounding_action', outcome: 'rejected', reason,
      corpusSha256: state.corpusSha256, readCount: state.reads.length,
      grepCount: state.greps.length,
    }],
  })
  if (state.firstSubstantiveEditAuthorized) return reject('grounding-window-closed')
  if (!SAFE_NAME.test(action.ref) || !state.requiredRefs.includes(action.ref)
    || !state.availableRefs.includes(action.ref)) return reject('grounding-ref-unavailable')
  if (action.kind === 'read') {
    if (action.query !== undefined) return reject('read-action-has-query')
    if (state.reads.includes(action.ref)) return reject('grounding-read-duplicated')
    if (state.reads.length >= state.policy.maxReads) return reject('grounding-read-budget-exhausted')
    const next = { ...state, reads: [...state.reads, action.ref].sort() }
    return {
      ok: true, state: next, reason: 'grounding-read-recorded',
      metrics: [{
        type: 'context_grounding_action', outcome: 'accepted',
        reason: 'grounding-read-recorded', corpusSha256: state.corpusSha256,
        readCount: next.reads.length, grepCount: next.greps.length,
      }],
    }
  }
  if (action.kind !== 'grep' || typeof action.query !== 'string'
    || action.query.length < 1 || action.query.length > 256
    || /[\0\r\n]/.test(action.query)) return reject('grounding-grep-invalid')
  if (state.availableRefs.some(ref => !state.reads.includes(ref))) {
    return reject('grounding-refs-not-read-before-grep')
  }
  if (state.greps.length >= state.policy.maxGreps) return reject('grounding-grep-budget-exhausted')
  const querySha256 = sha256(action.query)
  if (state.greps.some(grep => grep.ref === action.ref && grep.querySha256 === querySha256)) {
    return reject('grounding-grep-duplicated')
  }
  const next = {
    ...state,
    greps: [...state.greps, { ref: action.ref, querySha256 }]
      .sort((left, right) => compareStable(left.ref, right.ref)
        || compareStable(left.querySha256, right.querySha256)),
  }
  return {
    ok: true, state: next, reason: 'grounding-grep-recorded',
    metrics: [{
      type: 'context_grounding_action', outcome: 'accepted',
      reason: 'grounding-grep-recorded', corpusSha256: state.corpusSha256,
      readCount: next.reads.length, grepCount: next.greps.length,
    }],
  }
}

export function buildProductContextGapReport(
  packValue: unknown,
  briefValue: unknown,
  grounding?: GroundingState,
): Readonly<{ report: ProductContextGapReport; metrics: readonly ProductContextMetricEvent[] }> {
  const { pack } = validateProductContextPack(packValue)
  const brief = parseProductContextTaskBrief(briefValue)
  if (brief.productContext.corpusSha256 !== pack.corpusSha256) {
    throw new Error('task brief product corpus hash does not match pack')
  }
  if (grounding && (grounding.taskId !== brief.taskId
    || grounding.corpusSha256 !== pack.corpusSha256
    || JSON.stringify(grounding.requiredRefs) !== JSON.stringify(brief.productContext.refs))) {
    throw new Error('grounding state is outside task context scope')
  }
  if (grounding) assertGroundingState(grounding)
  const present = new Set(pack.refs.map(ref => ref.name))
  const reads = new Set(grounding?.reads ?? [])
  const missingRefs = brief.productContext.refs.filter(ref => !present.has(ref)).sort()
  const unreadRefs = brief.productContext.refs
    .filter(ref => present.has(ref) && !reads.has(ref)).sort()
  const minimumGreps = grounding?.policy.minimumGreps ?? DEFAULT_GROUNDING_POLICY.minimumGreps
  const grepShortfall = Math.max(0, minimumGreps - (grounding?.greps.length ?? 0))
  const gaps = [
    ...missingRefs.map(ref => `missing-ref:${ref}`),
    ...unreadRefs.map(ref => `unread-ref:${ref}`),
    ...(grepShortfall > 0 ? [`grep-shortfall:${grepShortfall}`] : []),
  ]
  // A missing pack ref must be named for regeneration, but it cannot deadlock
  // the task that discovered it. Once every available named ref is read (and
  // any explicitly configured grep floor is met), emitting this report is the
  // act that permits work to proceed.
  const readyForSubstantiveEdit = unreadRefs.length === 0 && grepShortfall === 0
  const report: ProductContextGapReport = {
    schema: PRODUCT_CONTEXT_GAP_SCHEMA,
    taskId: brief.taskId,
    corpusSha256: pack.corpusSha256,
    missingRefs,
    unreadRefs,
    grepShortfall,
    gaps,
    readyForSubstantiveEdit,
  }
  return {
    report,
    metrics: [{
      type: 'context_pack_gap', outcome: gaps.length === 0 ? 'ready' : 'gap',
      reason: gaps.length === 0 ? 'grounding-complete' : 'pack-gap-reported',
      corpusSha256: pack.corpusSha256,
      refCount: brief.productContext.refs.length,
      missingRefCount: missingRefs.length,
      unreadRefCount: unreadRefs.length,
      readCount: grounding?.reads.length ?? 0,
      grepCount: grounding?.greps.length ?? 0,
    }],
  }
}

export type SubstantiveEditDecision = Readonly<{
  ok: boolean
  state: GroundingState
  report: ProductContextGapReport
  reason: string
  metrics: readonly ProductContextMetricEvent[]
}>

export function assessFirstSubstantiveEdit(
  pack: unknown,
  brief: unknown,
  state: GroundingState,
): SubstantiveEditDecision {
  const gap = buildProductContextGapReport(pack, brief, state)
  if (!gap.report.readyForSubstantiveEdit) {
    return {
      ok: false,
      state,
      report: gap.report,
      reason: 'product-context-grounding-incomplete',
      metrics: [...gap.metrics, {
        type: 'context_edit_gate', outcome: 'rejected',
        reason: 'product-context-grounding-incomplete',
        corpusSha256: state.corpusSha256,
        readCount: state.reads.length, grepCount: state.greps.length,
      }],
    }
  }
  const next = { ...state, firstSubstantiveEditAuthorized: true }
  const hasGap = gap.report.gaps.length > 0
  return {
    ok: true,
    state: next,
    report: gap.report,
    reason: hasGap ? 'product-context-gap-reported-proceed' : 'product-context-grounding-complete',
    metrics: [...gap.metrics, {
      type: 'context_edit_gate', outcome: 'accepted',
      reason: hasGap ? 'product-context-gap-reported-proceed' : 'product-context-grounding-complete',
      corpusSha256: state.corpusSha256,
      readCount: state.reads.length, grepCount: state.greps.length,
    }],
  }
}

export function buildProductContextPreloadPlan(
  packValue: unknown,
  briefValue: unknown,
  policyValue: GroundingPolicy = DEFAULT_GROUNDING_POLICY,
): ProductContextPreloadPlan {
  const { pack } = validateProductContextPack(packValue)
  const brief = parseProductContextTaskBrief(briefValue)
  const policy = normalizePolicy(policyValue)
  if (brief.productContext.corpusSha256 !== pack.corpusSha256) {
    throw new Error('task brief product corpus hash does not match pack')
  }
  const byName = new Map(pack.refs.map(ref => [ref.name, ref]))
  const missing = brief.productContext.refs.filter(ref => !byName.has(ref))
  if (missing.length > 0) throw new Error(`product context pack gap: ${missing.sort().join(',')}`)
  if (brief.productContext.refs.length > policy.maxReads) {
    throw new Error('grounding read budget cannot cover all required refs')
  }
  const requiredRefs = brief.productContext.refs.map(name => {
    const ref = byName.get(name)!
    return { name, path: ref.path, contentSha256: ref.contentSha256 }
  })
  const refNames = requiredRefs.map(ref => ref.name)
  const lines = [
    `PRODUCT_CONTEXT corpus_sha256=${pack.corpusSha256} pack_key=${pack.packKey}`,
    ...requiredRefs.map((ref, index) => (
      `PRIMARY_PRELOAD ${index + 1} name=${ref.name} path=${ref.path} sha256=${ref.contentSha256}`
    )),
    `GROUNDING before_first_substantive_edit reads=${requiredRefs.length}/${policy.maxReads} greps=${policy.minimumGreps}/${policy.maxGreps}`,
    `WARM_SUBAGENT corpus_sha256=${pack.corpusSha256} refs=${refNames.join(',')}`,
    'WARM_SUBAGENT_REQUIRE exact corpus hash and named-ref set; discard mismatched output and emit a pack-gap metric.',
  ]
  const doctrine = `${lines.join('\n')}\n`
  return {
    schema: PRODUCT_CONTEXT_PRELOAD_SCHEMA,
    corpusSha256: pack.corpusSha256,
    packKey: pack.packKey,
    requiredRefs,
    groundingPolicy: policy,
    primaryReadOrder: refNames,
    warmSubagentContract: {
      corpusSha256: pack.corpusSha256,
      refs: refNames,
      requireExactMatch: true,
    },
    doctrine,
    doctrineSha256: sha256(doctrine),
  }
}

export type WarmSubagentContextClaim = Readonly<{
  corpusSha256: string
  refs: readonly string[]
}>

export function assessWarmSubagentContext(
  plan: ProductContextPreloadPlan,
  claim: WarmSubagentContextClaim,
): Readonly<{
  ok: boolean
  reason: string
  metrics: readonly ProductContextMetricEvent[]
}> {
  const valid = object(claim)
    && exactKeys(claim, ['corpusSha256', 'refs'])
    && claim.corpusSha256 === plan.warmSubagentContract.corpusSha256
    && sortedUniqueNames(claim.refs)
    && JSON.stringify(claim.refs) === JSON.stringify(plan.warmSubagentContract.refs)
  const reason = valid ? 'warm-context-exact' : 'warm-context-mismatch'
  return {
    ok: valid,
    reason,
    metrics: [{
      type: 'context_warm_subagent', outcome: valid ? 'accepted' : 'rejected',
      reason, corpusSha256: plan.corpusSha256,
      refCount: plan.requiredRefs.length,
    }],
  }
}
