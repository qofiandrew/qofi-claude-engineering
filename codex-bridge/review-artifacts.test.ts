import { afterEach, describe, expect, test } from 'bun:test'
import { chmodSync, linkSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  readFableReviewArtifacts,
  snapshotFableReviewArtifactBaseline,
  type FableReviewArtifact,
} from './review-artifacts.ts'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

function fixture(verdict: FableReviewArtifact['result']['verdict'] = 'approve') {
  const state = mkdtempSync(join(tmpdir(), 'qofi-review-artifacts.'))
  roots.push(state)
  const task = '123456789'
  const profile = 'default'
  const taskDir = join(state, 'review-artifacts', task)
  const dir = join(taskDir, profile)
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  chmodSync(join(state, 'review-artifacts'), 0o700)
  chmodSync(taskDir, 0o700)
  chmodSync(dir, 0o700)
  const artifact = {
    schema: 'qofi-fable-review-artifact/v1', reviewer: 'claude-fable', model: 'claude-fable-5',
    swarm: 'alpha', profile: 'default', task_id: task, mode: 'code',
    reviewed_diff_sha256: 'a'.repeat(64), created_at: '2026-07-13T10:11:12.123456Z',
    result: {
      schema: 'qofi-adversarial-review-output/v2', verdict,
      summary: verdict === 'review-unavailable' ? 'review timed out' : 'bounded review',
      checked: verdict === 'approve' ? ['standing invariants'] : [],
      not_checked: verdict === 'approve' ? ['live deployment']
        : verdict === 'review-unavailable' ? ['review timed out before checks completed'] : [],
      findings: verdict === 'block' ? [{
        severity: 'high', locus: 'daemon.ts', claim: 'unsafe transition',
        evidence: 'the transition precedes cleanup', suggested_test: 'assert cleanup order',
      }] : [],
      next_steps: [],
    },
  }
  const path = join(dir, 'fable-review-20260713T101112123456Z-0123456789abcdef.json')
  writeFileSync(path, JSON.stringify(artifact), { mode: 0o600 })
  chmodSync(path, 0o600)
  return { state, task, taskDir, dir, path, artifact }
}

describe('Fable review artifact intake', () => {
  test('an existing shared root with no directory for this task is an empty result set', () => {
    const prior = fixture()
    expect(readFableReviewArtifacts(prior.state, '987654321', 'alpha', 'default')).toEqual([])
  })

  test('accepts an exact private artifact and preserves unavailable as a distinct pending verdict', () => {
    const f = fixture('review-unavailable')
    const read = readFableReviewArtifacts(f.state, f.task, 'alpha', 'default')
    expect(read).toHaveLength(1)
    expect(read[0]).toMatchObject({
      reviewed_diff_sha256: 'a'.repeat(64), result: { verdict: 'review-unavailable' },
    })
    expect(read[0].result.verdict).not.toBe('approve')
  })

  test('accepts 32 review calls plus one upserted budget record without suppressing a block', () => {
    const f = fixture('block')
    for (let index = 1; index < 32; index++) {
      const micros = String(index).padStart(6, '0')
      const suffix = index.toString(16).padStart(16, '0')
      const path = join(f.dir, `fable-review-20260713T101112${micros}Z-${suffix}.json`)
      writeFileSync(path, JSON.stringify({
        ...f.artifact,
        created_at: `2026-07-13T10:11:12.${micros}Z`,
      }), { mode: 0o600 })
      chmodSync(path, 0o600)
    }
    const exhaustionPath = join(f.dir, 'fable-review-budget-exhausted.json')
    writeFileSync(exhaustionPath, JSON.stringify({
      ...f.artifact,
      created_at: '2026-07-13T10:12:13.123456Z',
      result: {
        ...f.artifact.result,
        verdict: 'review-unavailable',
        summary: 'task review-call budget exhausted',
        checked: [],
        not_checked: ['the requested material was not reviewed'],
        findings: [],
      },
    }), { mode: 0o600 })
    chmodSync(exhaustionPath, 0o600)

    const read = readFableReviewArtifacts(f.state, f.task, 'alpha', 'default')
    expect(read).toHaveLength(33)
    expect(read.map(item => item.result.verdict)).toContain('block')
    expect(read.map(item => item.result.verdict)).toContain('review-unavailable')

    const overflowPath = join(f.dir, 'fable-review-20260713T101113000001Z-ffffffffffffffff.json')
    writeFileSync(overflowPath, JSON.stringify({
      ...f.artifact, created_at: '2026-07-13T10:11:13.000001Z',
    }), { mode: 0o600 })
    chmodSync(overflowPath, 0o600)
    expect(() => readFableReviewArtifacts(f.state, f.task, 'alpha', 'default'))
      .toThrow('too many review artifacts')
  })

  test('isolates two hard-rotation attempts for the same task by profile', () => {
    const attemptA = fixture('block')
    const profileB = 'reserve'
    const dirB = join(attemptA.taskDir, profileB)
    mkdirSync(dirB, { mode: 0o700 })
    chmodSync(dirB, 0o700)
    const artifactB = {
      ...attemptA.artifact,
      profile: profileB,
      reviewed_diff_sha256: 'b'.repeat(64),
      created_at: '2026-07-13T10:13:14.123456Z',
    }
    const pathB = join(dirB, 'fable-review-20260713T101314123456Z-fedcba9876543210.json')
    writeFileSync(pathB, JSON.stringify(artifactB), { mode: 0o600 })
    chmodSync(pathB, 0o600)

    const readA = readFableReviewArtifacts(attemptA.state, attemptA.task, 'alpha', 'default')
    const readB = readFableReviewArtifacts(attemptA.state, attemptA.task, 'alpha', profileB)
    expect(readA).toHaveLength(1)
    expect(readA[0].profile).toBe('default')
    expect(readA[0].reviewed_diff_sha256).toBe('a'.repeat(64))
    expect(readB).toHaveLength(1)
    expect(readB[0].profile).toBe(profileB)
    expect(readB[0].result.verdict).toBe('block')
    expect(readB[0].reviewed_diff_sha256).toBe('b'.repeat(64))
  })

  test('a same-profile retry reads only artifacts created or changed after its baseline', () => {
    const prior = fixture('block')
    const baseline = snapshotFableReviewArtifactBaseline(
      prior.state, prior.task, 'alpha', 'default',
    )
    expect(readFableReviewArtifacts(
      prior.state, prior.task, 'alpha', 'default', baseline,
    )).toEqual([])

    const nextPath = join(prior.dir, 'fable-review-20260713T101415123456Z-1111111111111111.json')
    writeFileSync(nextPath, JSON.stringify({
      ...prior.artifact,
      reviewed_diff_sha256: 'c'.repeat(64),
      created_at: '2026-07-13T10:14:15.123456Z',
    }), { mode: 0o600 })
    chmodSync(nextPath, 0o600)

    const delta = readFableReviewArtifacts(
      prior.state, prior.task, 'alpha', 'default', baseline,
    )
    expect(delta).toHaveLength(1)
    expect(delta[0].reviewed_diff_sha256).toBe('c'.repeat(64))
  })

  test('rejects mismatched provenance, rubber-stamp approval, and non-private files', () => {
    const mismatched = fixture()
    writeFileSync(mismatched.path, JSON.stringify({ ...mismatched.artifact, profile: 'other' }), { mode: 0o600 })
    expect(() => readFableReviewArtifacts(mismatched.state, mismatched.task, 'alpha', 'default'))
      .toThrow('outside the active task scope')

    const rubber = fixture()
    writeFileSync(rubber.path, JSON.stringify({
      ...rubber.artifact,
      result: { ...rubber.artifact.result, checked: [], not_checked: [] },
    }), { mode: 0o600 })
    expect(() => readFableReviewArtifacts(rubber.state, rubber.task, 'alpha', 'default'))
      .toThrow('lacks checked/not-checked provenance')

    const publicFile = fixture('block')
    chmodSync(publicFile.path, 0o644)
    expect(() => readFableReviewArtifacts(publicFile.state, publicFile.task, 'alpha', 'default'))
      .toThrow('mode 0600')
  })

  test('does not follow a task-directory or artifact symlink', () => {
    const linkedTask = fixture()
    const real = join(linkedTask.state, 'elsewhere')
    mkdirSync(real, { mode: 0o700 })
    rmSync(linkedTask.taskDir, { recursive: true })
    symlinkSync(real, linkedTask.taskDir)
    expect(() => readFableReviewArtifacts(linkedTask.state, linkedTask.task, 'alpha', 'default'))
      .toThrow('owner-real')

    const linkedFile = fixture()
    const target = join(linkedFile.state, 'target.json')
    writeFileSync(target, '{}', { mode: 0o600 })
    rmSync(linkedFile.path)
    symlinkSync(target, linkedFile.path)
    expect(() => readFableReviewArtifacts(linkedFile.state, linkedFile.task, 'alpha', 'default'))
      .toThrow('owner-regular')
  })

  test('rejects a hard-linked review artifact', () => {
    const linked = fixture()
    linkSync(linked.path, join(linked.state, 'artifact-alias.json'))
    expect(() => readFableReviewArtifacts(linked.state, linked.task, 'alpha', 'default'))
      .toThrow('owner-regular')
  })
})
