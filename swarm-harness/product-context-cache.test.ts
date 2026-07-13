import { describe, expect, test } from 'bun:test'
import { resolveProductContextPack } from './product-context-cache.ts'

const sources = [
  { name: 'module-map', path: 'product/module-map.md', content: 'api -> worker\n' },
  { name: 'key-files', path: 'product/key-files.md', content: 'src/api.ts\n' },
  { name: 'invariants', path: 'product/invariants.md', content: 'SYNC != LIVE\n' },
  { name: 'task-api', path: 'product/task-api.md', content: 'named task context\n' },
]

describe('corpus-commit product context cache', () => {
  test('reuses exact pack bytes across tasks at the same corpus commit', () => {
    const first = resolveProductContextPack({ corpusCommit: 'a'.repeat(40), sources })
    const second = resolveProductContextPack({
      corpusCommit: 'a'.repeat(40), sources: [...sources].reverse(), cached: first.entry,
    })
    expect(first).toMatchObject({ action: 'regenerated', reason: 'cache-empty' })
    expect(second).toMatchObject({ action: 'reused', reason: 'corpus-commit-unchanged' })
    expect(second.entry).toEqual(first.entry)
  })

  test('regenerates only when the corpus commit changes', () => {
    const first = resolveProductContextPack({ corpusCommit: 'a'.repeat(40), sources })
    const changedSources = sources.map(source => source.name === 'module-map'
      ? { ...source, content: 'api -> worker -> queue\n' }
      : source)
    expect(() => resolveProductContextPack({
      corpusCommit: 'a'.repeat(40), sources: changedSources, cached: first.entry,
    })).toThrow('bytes changed without a commit change')
    const next = resolveProductContextPack({
      corpusCommit: 'b'.repeat(40), sources: changedSources, cached: first.entry,
    })
    expect(next).toMatchObject({ action: 'regenerated', reason: 'corpus-commit-changed' })
    expect(next.entry.pack.corpusSha256).not.toBe(first.entry.pack.corpusSha256)
  })

  test('requires the module map, key-file inventory, and invariant registry', () => {
    expect(() => resolveProductContextPack({
      corpusCommit: 'a'.repeat(40), sources: sources.filter(source => source.name !== 'invariants'),
    })).toThrow('lacks core refs: invariants')
  })
})
