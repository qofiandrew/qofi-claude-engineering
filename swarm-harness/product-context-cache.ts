import {
  generateProductContextPack,
  validateProductContextPack,
  type ProductContextPack,
  type ProductCorpusSource,
} from './product-context-pack.ts'

export const PRODUCT_CONTEXT_CACHE_SCHEMA = 'qofi-product-context-cache/v1' as const

export type ProductContextCacheEntry = Readonly<{
  schema: typeof PRODUCT_CONTEXT_CACHE_SCHEMA
  corpus_commit: string
  pack: ProductContextPack
}>

export type ProductContextCacheDecision = Readonly<{
  entry: ProductContextCacheEntry
  action: 'reused' | 'regenerated'
  reason: 'corpus-commit-unchanged' | 'corpus-commit-changed' | 'cache-empty'
}>

const COMMIT = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/
const REQUIRED_REFS = ['invariants', 'key-files', 'module-map'] as const

function validateCommit(value: unknown): asserts value is string {
  if (typeof value !== 'string' || !COMMIT.test(value)) {
    throw new Error('product context corpus commit must be a full hexadecimal object id')
  }
}

function validateCoreRefs(sources: readonly ProductCorpusSource[]): void {
  const names = new Set(sources.map(source => source?.name))
  const missing = REQUIRED_REFS.filter(name => !names.has(name))
  if (missing.length > 0) {
    throw new Error(`product context corpus lacks core refs: ${missing.join(',')}`)
  }
}

export function parseProductContextCacheEntry(value: unknown): ProductContextCacheEntry {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('product context cache entry is malformed')
  }
  const record = value as Record<string, unknown>
  if (Object.keys(record).sort().join(',') !== 'corpus_commit,pack,schema'
    || record.schema !== PRODUCT_CONTEXT_CACHE_SCHEMA) {
    throw new Error('product context cache entry is malformed')
  }
  validateCommit(record.corpus_commit)
  const pack = validateProductContextPack(record.pack).pack
  return { schema: PRODUCT_CONTEXT_CACHE_SCHEMA, corpus_commit: record.corpus_commit, pack }
}

/**
 * Cache identity is the corpus Git commit. A task never regenerates a pack:
 * unchanged commit + unchanged corpus bytes reuses it exactly. Bytes changing
 * beneath the same commit is a provenance violation, not a cache refresh.
 */
export function resolveProductContextPack(input: Readonly<{
  corpusCommit: string
  sources: readonly ProductCorpusSource[]
  cached?: ProductContextCacheEntry | null
}>): ProductContextCacheDecision {
  validateCommit(input.corpusCommit)
  validateCoreRefs(input.sources)
  const generated = generateProductContextPack(input.sources).pack
  if (input.cached) {
    const cached = parseProductContextCacheEntry(input.cached)
    if (cached.corpus_commit === input.corpusCommit) {
      if (cached.pack.corpusSha256 !== generated.corpusSha256) {
        throw new Error('product context corpus bytes changed without a commit change')
      }
      return { entry: cached, action: 'reused', reason: 'corpus-commit-unchanged' }
    }
  }
  return {
    entry: {
      schema: PRODUCT_CONTEXT_CACHE_SCHEMA,
      corpus_commit: input.corpusCommit,
      pack: generated,
    },
    action: 'regenerated',
    reason: input.cached ? 'corpus-commit-changed' : 'cache-empty',
  }
}
