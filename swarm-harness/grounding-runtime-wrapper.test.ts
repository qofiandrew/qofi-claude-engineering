import { afterEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { NormalizedEventStore } from './event-store.ts'
import { generateProductContextPack } from './product-context-pack.ts'
import type { HarnessParityAdoption } from './parity-adoption.ts'
import {
  createAdoptedGroundingWrapper,
  type SupervisedGroundingWrapper,
} from './grounding-runtime-wrapper.ts'

const TASK = 'task-grounding-wrapper'
const SAME_TIMESTAMP = '2026-07-13T10:00:00Z'

type Runtime = 'claude' | 'codex'

const roots: string[] = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function fixture(runtime: Runtime, maxOperations = 2): Readonly<{
  root: string
  repo: string
  state: string
  wrapper: SupervisedGroundingWrapper
  adoption: Extract<HarnessParityAdoption, { enabled: true }>
  pack: ReturnType<typeof generateProductContextPack>['pack']
  brief: unknown
  eventStore: () => NormalizedEventStore
}> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `qofi-grounding-${runtime}-`)))
  roots.push(root)
  const repo = join(root, 'repo')
  const state = join(root, 'private')
  mkdirSync(repo, { mode: 0o755 })
  mkdirSync(join(repo, 'docs'), { mode: 0o755 })
  writeFileSync(join(repo, 'docs', 'invariants.md'), 'SYNC != LIVE\n', { mode: 0o644 })
  writeFileSync(join(repo, 'docs', 'key-files.md'), 'src/index.ts\n', { mode: 0o644 })
  writeFileSync(join(repo, 'docs', 'module-map.md'), 'api -> database\n', { mode: 0o644 })
  mkdirSync(state, { mode: 0o700 })
  chmodSync(state, 0o700)
  const pack = generateProductContextPack([
    { name: 'invariants', path: 'docs/invariants.md', content: 'SYNC != LIVE\n' },
    { name: 'key-files', path: 'docs/key-files.md', content: 'src/index.ts\n' },
    { name: 'module-map', path: 'docs/module-map.md', content: 'api -> database\n' },
  ]).pack
  const brief = {
    schema: 'qofi-product-context-brief/v1',
    taskId: TASK,
    productContext: { corpusSha256: pack.corpusSha256, refs: ['module-map'] },
  }
  const adoption: Extract<HarnessParityAdoption, { enabled: true }> = {
    enabled: true,
    receiptPath: join(state, 'operator-receipt.json'),
    receiptSha256: 'a'.repeat(64),
    stateRoot: state,
    roadmapRepoRoot: repo,
    drRefs: ['ADR-0023'],
    completionPolicySha256: 'b'.repeat(64),
    swarm: 'press-backend',
  }
  const make = () => createAdoptedGroundingWrapper({
    adoption,
    runtime,
    repoRoot: repo,
    taskId: TASK,
    pack,
    taskBrief: brief,
    budgetPolicy: { maxOperationsBeforeFirstEdit: maxOperations },
    now: () => Date.parse(SAME_TIMESTAMP),
  })
  return {
    root, repo, state, adoption, pack, brief,
    wrapper: make(),
    eventStore: () => new NormalizedEventStore(join(state, 'events'), { repoRoot: repo }),
  }
}

function readRecord(runtime: Runtime, repo: string): unknown {
  const path = join(repo, 'docs', 'module-map.md')
  return runtime === 'claude'
    ? {
      hook_event_name: 'PreToolUse', tool_name: 'Read', timestamp: SAME_TIMESTAMP,
      tool_input: { file_path: path },
    }
    : {
      type: 'response_item', timestamp: SAME_TIMESTAMP,
      payload: { type: 'function_call', name: 'read_file', arguments: { path } },
    }
}

function grepRecord(runtime: Runtime, repo: string, secret: string): unknown {
  return runtime === 'claude'
    ? {
      hook_event_name: 'PreToolUse', tool_name: 'Grep', timestamp: SAME_TIMESTAMP,
      tool_input: { path: repo, pattern: secret },
    }
    : {
      type: 'response_item', timestamp: SAME_TIMESTAMP,
      payload: {
        type: 'function_call', name: 'grep_files',
        arguments: JSON.stringify({ path: repo, query: secret }),
      },
    }
}

function editRecord(runtime: Runtime, repo: string): unknown {
  return runtime === 'claude'
    ? {
      hook_event_name: 'PreToolUse', tool_name: 'Edit', timestamp: SAME_TIMESTAMP,
      tool_input: { file_path: join(repo, 'src', 'change.ts'), new_string: 'SECRET_EDIT_BYTES' },
    }
    : {
      type: 'response_item', timestamp: SAME_TIMESTAMP,
      payload: {
        type: 'function_call', name: 'apply_patch', arguments: 'SECRET_EDIT_BYTES',
      },
    }
}

function opaqueExecRecord(runtime: Runtime): unknown {
  return runtime === 'claude'
    ? { tool_name: 'Bash', tool_input: { command: 'python mutate.py' }, timestamp: SAME_TIMESTAMP }
    : {
      timestamp: SAME_TIMESTAMP,
      payload: { type: 'function_call', name: 'exec_command', arguments: { cmd: 'python mutate.py' } },
    }
}

for (const runtime of ['claude', 'codex'] as const) {
  describe(`${runtime} supervised grounding wrapper`, () => {
    test('requires named refs before exploration and leaves rejected intent out of ground truth', () => {
      const f = fixture(runtime)
      expect(f.wrapper.preload.primaryReadOrder).toEqual(['module-map'])
      expect(f.wrapper.process(grepRecord(runtime, f.repo, 'SECRET_QUERY'))).toMatchObject({
        ok: false, reason: 'named-context-refs-not-consumed', operation_count: 0,
      })
      expect(f.eventStore().replay().map(event => event.type)).toEqual(['grounding.started'])
      expect(f.wrapper.process(opaqueExecRecord(runtime))).toMatchObject({
        ok: false, reason: 'unclassified-pre-edit-exec-refused', operation_count: 0,
      })
      expect(f.wrapper.process(readRecord(runtime, f.repo))).toMatchObject({
        ok: true, operation_count: 1,
      })
      expect(f.wrapper.process(opaqueExecRecord(runtime))).toMatchObject({
        ok: false, reason: 'unclassified-pre-edit-exec-refused', operation_count: 1,
      })
    })

    test('refuses a named ref whose workspace bytes drift from the corpus pack', () => {
      const f = fixture(runtime)
      writeFileSync(join(f.repo, 'docs', 'module-map.md'), 'drifted bytes\n', { mode: 0o644 })
      expect(() => f.wrapper.process(readRecord(runtime, f.repo))).toThrow(
        'does not match the corpus pack',
      )
      expect(f.eventStore().replay().map(event => event.type)).toEqual(['grounding.started'])
    })

    test('N+1 operations hold edit until a durable pack-gap artifact exists', () => {
      const f = fixture(runtime, 2)
      expect(f.wrapper.process(readRecord(runtime, f.repo)).ok).toBe(true)
      expect(f.wrapper.process(grepRecord(runtime, f.repo, 'SECRET_QUERY_ONE'))).toMatchObject({
        ok: true, operation_count: 2, gap_report_required: false,
      })
      expect(f.wrapper.process(grepRecord(runtime, f.repo, 'SECRET_QUERY_TWO'))).toMatchObject({
        ok: true, operation_count: 3, gap_report_required: true,
      })
      expect(f.wrapper.process(editRecord(runtime, f.repo))).toMatchObject({
        ok: false, reason: 'grounding-gap-report-required', first_substantive_edit_seen: false,
      })
      expect(f.wrapper.filePackGap(['database-schema'])).toMatchObject({
        ok: true, reason: 'durable-pack-gap-filed', gap_report_required: false,
      })

      const runtimeState = join(f.state, 'grounding', runtime)
      const taskDirectory = join(runtimeState, readdirSync(runtimeState)[0]!)
      const gap = join(taskDirectory, 'pack-gap.json')
      const info = lstatSync(gap)
      expect(info.isFile()).toBe(true)
      expect(info.nlink).toBe(1)
      expect(info.mode & 0o777).toBe(0o600)
      expect(JSON.parse(readFileSync(gap, 'utf8'))).toMatchObject({
        schema: 'qofi-pack-gap-report/v1',
        task_id: TASK,
        missing_context_refs: ['database-schema'],
        operation_count: 3,
      })

      expect(f.wrapper.process(editRecord(runtime, f.repo))).toMatchObject({
        ok: true, first_substantive_edit_seen: true,
      })
      const events = f.eventStore().replay()
      expect(events.map(event => event.source_seq)).toEqual([0, 1, 2, 3, 4, 5])
      expect(new Set(events.map(event => event.event_id)).size).toBe(6)
      expect(events.map(event => Date.parse(event.ts))).toEqual([
        Date.parse(SAME_TIMESTAMP),
        Date.parse(SAME_TIMESTAMP) + 1,
        Date.parse(SAME_TIMESTAMP) + 2,
        Date.parse(SAME_TIMESTAMP) + 3,
        Date.parse(SAME_TIMESTAMP) + 4,
        Date.parse(SAME_TIMESTAMP) + 5,
      ])
      const durableBytes = events.map(event => readFileSync(
        join(f.state, 'events', `${event.event_id}.json`), 'utf8',
      )).join('')
      for (const forbidden of ['SECRET_QUERY_ONE', 'SECRET_QUERY_TWO', 'SECRET_EDIT_BYTES', f.repo]) {
        expect(durableBytes).not.toContain(forbidden)
      }
    })

    test('under-budget edit is admitted and durable state replays without a gap', () => {
      const f = fixture(runtime, 2)
      expect(f.wrapper.process(readRecord(runtime, f.repo)).ok).toBe(true)
      expect(f.wrapper.process(editRecord(runtime, f.repo))).toMatchObject({
        ok: true,
        operation_count: 1,
        gap_report_required: false,
        first_substantive_edit_seen: true,
      })
      const reconstructed = createAdoptedGroundingWrapper({
        adoption: f.adoption,
        runtime,
        repoRoot: f.repo,
        taskId: TASK,
        pack: f.pack,
        taskBrief: f.brief,
        budgetPolicy: { maxOperationsBeforeFirstEdit: 2 },
        now: () => Date.parse(SAME_TIMESTAMP),
      })
      expect(reconstructed.process(editRecord(runtime, f.repo))).toMatchObject({
        ok: true, first_substantive_edit_seen: true,
      })
      expect(() => reconstructed.filePackGap(['invented-gap'])).toThrow('not due')
    })

    test('repeated identical same-timestamp operations retain distinct monotonic identities', () => {
      const f = fixture(runtime, 10)
      f.wrapper.process(readRecord(runtime, f.repo))
      f.wrapper.process(grepRecord(runtime, f.repo, 'same query'))
      f.wrapper.process(grepRecord(runtime, f.repo, 'same query'))
      const operations = f.eventStore().replay().filter(event => event.type === 'grounding.operation')
      expect(operations).toHaveLength(3)
      expect(operations.map(event => event.source_seq)).toEqual([1, 2, 3])
      expect(new Set(operations.map(event => event.event_id)).size).toBe(3)
    })
  })
}

test('grounding cannot be constructed from a disabled one-runtime self-assertion', () => {
  const f = fixture('claude')
  expect(() => createAdoptedGroundingWrapper({
    adoption: { enabled: false } as any,
    runtime: 'claude',
    repoRoot: f.repo,
    taskId: TASK,
    pack: f.pack,
    taskBrief: f.brief,
    budgetPolicy: { maxOperationsBeforeFirstEdit: 2 },
  })).toThrow('disabled')
})
