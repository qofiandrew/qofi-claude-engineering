import { afterEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  HARNESS_TASK_BASELINE_SCHEMA,
  baselinePath,
  readTaskBaseline,
  removeTaskBaseline,
  writeTaskBaseline,
} from './authority-state.ts'
import { canonicalAuthorityJsonLine } from './parity-adoption.ts'

const roots: string[] = []
afterEach(() => {
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true })
})

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-authority-state.')))
  chmodSync(root, 0o700)
  roots.push(root)
  const repo = join(root, 'repo')
  mkdirSync(repo, { mode: 0o700 })
  const baseline = {
    schema: HARNESS_TASK_BASELINE_SCHEMA,
    runtime: 'claude' as const,
    swarm: 'press-backend',
    scope_id: 'session-1',
    parent_task_id: 'task-1',
    started_at: '2026-07-13T12:00:00.000Z',
    snapshot: {
      root: repo,
      maxFileBytes: 1024,
      files: { 'src/a.ts': `100644:${'a'.repeat(64)}` },
    },
  }
  return { root, baseline }
}

describe('root lifecycle authority state', () => {
  test('baseline publication is canonical, replaceable at a new task boundary, and removable', () => {
    const f = fixture()
    const path = writeTaskBaseline(f.root, f.baseline)
    expect(path).toBe(baselinePath(f.root, 'claude', 'press-backend', 'session-1'))
    expect(readTaskBaseline(f.root, 'claude', 'press-backend', 'session-1')).toEqual(f.baseline)
    const replacement = { ...f.baseline, parent_task_id: 'task-2', started_at: '2026-07-13T12:01:00.000Z' }
    writeTaskBaseline(f.root, replacement)
    expect(readTaskBaseline(f.root, 'claude', 'press-backend', 'session-1').parent_task_id).toBe('task-2')
    expect(readFileSync(path, 'utf8')).toBe(canonicalAuthorityJsonLine({
      parent_task_id: 'task-2',
      runtime: 'claude',
      schema: HARNESS_TASK_BASELINE_SCHEMA,
      scope_id: 'session-1',
      snapshot: replacement.snapshot,
      started_at: replacement.started_at,
      swarm: 'press-backend',
    }))
    removeTaskBaseline(f.root, 'claude', 'press-backend', 'session-1')
    expect(() => readTaskBaseline(f.root, 'claude', 'press-backend', 'session-1')).toThrow()
  })

  test('hard-linked or noncanonical records are never accepted as baselines', () => {
    const f = fixture()
    const path = writeTaskBaseline(f.root, f.baseline)
    linkSync(path, `${path}.attacker`)
    expect(() => readTaskBaseline(f.root, 'claude', 'press-backend', 'session-1')).toThrow('single-link')

    rmSync(`${path}.attacker`)
    writeFileSync(path, `${JSON.stringify(f.baseline, null, 2)}\n`, { mode: 0o600 })
    expect(() => readTaskBaseline(f.root, 'claude', 'press-backend', 'session-1')).toThrow('not canonical')
  })

  test('subagent scopes cannot collide with their parent or siblings', () => {
    const f = fixture()
    const parent = baselinePath(f.root, 'claude', 'press-backend', 'session-1')
    const first = baselinePath(f.root, 'claude', 'press-backend', 'session-1:agent:a')
    const second = baselinePath(f.root, 'claude', 'press-backend', 'session-1:agent:b')
    expect(new Set([parent, first, second]).size).toBe(3)
  })
})
