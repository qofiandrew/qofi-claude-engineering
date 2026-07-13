import { createHash } from 'crypto'
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  statSync,
  unlinkSync,
  utimesSync,
  writeFileSync,
} from 'fs'
import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  captureWorkspaceSnapshot,
  diffWorkspaceSnapshots,
  AGGREGATE_METADATA_FINGERPRINT_PREFIX,
  INELIGIBLE_OVERSIZE_FINGERPRINT,
} from './turn-changes.ts'

describe('latest serialized turn change capability', () => {
  test('includes only eligible add/change/delete deltas and ignores pre-existing dirt', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-turn-changes-'))
    try {
      writeFileSync(join(root, 'unchanged-dirty.ts'), 'already dirty\n')
      writeFileSync(join(root, 'changed.ts'), 'before\n')
      writeFileSync(join(root, 'deleted.md'), 'remove\n')
      mkdirSync(join(root, '.codex'))
      writeFileSync(join(root, '.codex', 'config.toml'), 'managed\n')
      writeFileSync(join(root, '.env'), 'secret\n')
      const before = captureWorkspaceSnapshot(root)

      writeFileSync(join(root, 'changed.ts'), 'after\n')
      chmodSync(join(root, 'changed.ts'), 0o755)
      writeFileSync(join(root, 'added.md'), '# docs\n')
      writeFileSync(join(root, '.codex', 'config.toml'), 'tampered\n')
      writeFileSync(join(root, '.env'), 'new secret\n')
      unlinkSync(join(root, 'deleted.md'))
      const after = captureWorkspaceSnapshot(root)
      const changed = diffWorkspaceSnapshots(before, after)

      expect(Object.keys(changed).sort()).toEqual(['added.md', 'changed.ts', 'deleted.md'])
      expect(changed['changed.ts']).toStartWith('100755:')
      expect(changed['deleted.md']).toBeNull()
      expect(changed['unchanged-dirty.ts']).toBeUndefined()
      expect(changed['.env']).toBeUndefined()
      expect(changed['.codex/config.toml']).toBeUndefined()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('records pre-existing oversized regular files without collapsing the capability', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-turn-changes-'))
    try {
      writeFileSync(join(root, 'large.pdf'), '12345')
      writeFileSync(join(root, 'eligible.md'), 'ok')
      const before = captureWorkspaceSnapshot(root, {
        maxFileBytes: 4,
        maxTotalBytes: 2,
      })

      expect(before.files['large.pdf']).toBe(INELIGIBLE_OVERSIZE_FINGERPRINT)
      expect(before.files['eligible.md']).toStartWith('100644:')

      writeFileSync(join(root, 'large.pdf'), 'abcde')
      const after = captureWorkspaceSnapshot(root, {
        maxFileBytes: 4,
        maxTotalBytes: 2,
      })
      expect(diffWorkspaceSnapshots(before, after)).toEqual({})
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('detects when an eligible file becomes oversized', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-turn-changes-'))
    try {
      writeFileSync(join(root, 'growing.md'), '1234')
      const before = captureWorkspaceSnapshot(root, { maxFileBytes: 4 })

      writeFileSync(join(root, 'growing.md'), '12345')
      const after = captureWorkspaceSnapshot(root, { maxFileBytes: 4 })
      expect(diffWorkspaceSnapshots(before, after)).toEqual({
        'growing.md': INELIGIBLE_OVERSIZE_FINGERPRINT,
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('leaves an unchanged aggregate-excluded asset forest out of the turn delta', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-turn-changes-'))
    try {
      writeFileSync(join(root, 'a-budget.bin'), '1234')
      for (const name of ['b-asset.pdf', 'c-asset.pptx', 'd-asset.pdf']) {
        writeFileSync(join(root, name), 'asset')
      }
      const before = captureWorkspaceSnapshot(root, {
        maxFileBytes: 16,
        maxTotalBytes: 4,
      })
      const after = captureWorkspaceSnapshot(root, {
        maxFileBytes: 16,
        maxTotalBytes: 4,
      })

      expect(before.files['a-budget.bin']).toStartWith('100644:')
      for (const name of ['b-asset.pdf', 'c-asset.pptx', 'd-asset.pdf']) {
        expect(before.files[name]).toStartWith(AGGREGATE_METADATA_FINGERPRINT_PREFIX)
        expect(after.files[name]).toBe(before.files[name])
      }
      expect(diffWorkspaceSnapshots(before, after)).toEqual({})
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('re-fingerprints a changed aggregate-excluded small file into a real capability', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-turn-changes-'))
    try {
      writeFileSync(join(root, 'a-budget.bin'), '1234')
      const excluded = join(root, 'z-excluded.md')
      writeFileSync(excluded, 'old!')
      const before = captureWorkspaceSnapshot(root, {
        maxFileBytes: 4,
        maxTotalBytes: 4,
      })
      const original = statSync(excluded)
      expect(before.files['z-excluded.md']).toStartWith(AGGREGATE_METADATA_FINGERPRINT_PREFIX)

      writeFileSync(excluded, 'new!')
      utimesSync(excluded, original.atime, original.mtime)
      const after = captureWorkspaceSnapshot(root, {
        maxFileBytes: 4,
        maxTotalBytes: 4,
      })
      expect(after.files['z-excluded.md']).toStartWith(AGGREGATE_METADATA_FINGERPRINT_PREFIX)
      expect(after.files['z-excluded.md']).not.toBe(before.files['z-excluded.md'])

      const hash = createHash('sha256').update('new!').digest('hex')
      expect(diffWorkspaceSnapshots(before, after)).toEqual({
        'z-excluded.md': `100644:${hash}`,
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('selects aggregate-budget content deterministically and ignores selection churn', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-turn-changes-'))
    try {
      writeFileSync(join(root, 'z-last.md'), 'zzzz')
      writeFileSync(join(root, 'a-first.md'), 'aaaa')
      const before = captureWorkspaceSnapshot(root, {
        maxFileBytes: 4,
        maxTotalBytes: 4,
      })
      expect(before.files['a-first.md']).toStartWith('100644:')
      expect(before.files['z-last.md']).toStartWith(AGGREGATE_METADATA_FINGERPRINT_PREFIX)

      writeFileSync(join(root, '00-added.md'), '0000')
      const after = captureWorkspaceSnapshot(root, {
        maxFileBytes: 4,
        maxTotalBytes: 4,
      })
      expect(after.files['00-added.md']).toStartWith('100644:')
      expect(after.files['a-first.md']).toStartWith(AGGREGATE_METADATA_FINGERPRINT_PREFIX)
      expect(after.files['z-last.md']).toStartWith(AGGREGATE_METADATA_FINGERPRINT_PREFIX)
      expect(Object.keys(diffWorkspaceSnapshots(before, after))).toEqual(['00-added.md'])

      unlinkSync(join(root, '00-added.md'))
      const restored = captureWorkspaceSnapshot(root, {
        maxFileBytes: 4,
        maxTotalBytes: 4,
      })
      expect(restored.files['a-first.md']).toStartWith('100644:')
      expect(Object.keys(diffWorkspaceSnapshots(after, restored))).toEqual(['00-added.md'])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
