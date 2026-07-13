import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { makeHarnessEvent, type NormalizedSwarmEvent } from './events.ts'
import { NormalizedEventStore, rebuildRoadmapFromEventStore } from './event-store.ts'
import { ROADMAP_FILENAME, RoadmapStore } from './roadmap.ts'

function lifecycle(
  type: 'task.started' | 'task.finished' | 'result.landed',
  ts: string,
): NormalizedSwarmEvent {
  const common = {
    ts,
    type,
    runtime: 'codex' as const,
    source: type === 'result.landed' ? 'result-set' as const : 'harness' as const,
    swarm: 'press-backend',
    task_id: 'task-journal',
    dr_refs: ['ADR-0023'],
  }
  if (type === 'task.started') return makeHarnessEvent({ ...common, type, state: 'DRIVING' })
  if (type === 'task.finished') {
    return makeHarnessEvent({ ...common, type, outcome: 'completed', state: 'STOOD_DOWN' })
  }
  return makeHarnessEvent({ ...common, type, result_kind: 'review', result_status: 'passed' })
}

describe('owner-private normalized event store', () => {
  let root: string
  let repo: string
  let eventsDir: string
  let authorityDir: string

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'qofi-event-store-'))
    repo = join(root, 'repo')
    eventsDir = join(root, 'private', 'events')
    authorityDir = join(root, 'private', 'roadmap')
    mkdirSync(repo, { mode: 0o755 })
    mkdirSync(eventsDir, { recursive: true, mode: 0o700 })
    mkdirSync(authorityDir, { mode: 0o700 })
    chmodSync(eventsDir, 0o700)
    chmodSync(authorityDir, 0o700)
  })
  afterEach(() => rmSync(root, { recursive: true, force: true }))

  const store = (options: { maxEvents?: number, maxBytes?: number } = {}) =>
    new NormalizedEventStore(eventsDir, { repoRoot: repo, ...options })

  test('atomically appends once, replays canonically, and stores no prompt/prose fields', () => {
    const journal = store()
    const started = lifecycle('task.started', '2026-07-13T10:00:00Z')
    expect(journal.append(started)).toBe('created')
    expect(journal.append(started)).toBe('duplicate')
    expect(journal.replay()).toEqual([started])
    const names = readdirSync(eventsDir)
    expect(names).toEqual([`${started.event_id}.json`])
    const path = join(eventsDir, names[0])
    expect(lstatSync(path).mode & 0o777).toBe(0o600)
    expect(lstatSync(path).nlink).toBe(1)
    const bytes = readFileSync(path, 'utf8')
    expect(bytes).toBe(`${JSON.stringify(started)}\n`)
    expect(bytes).not.toMatch(/prompt|summary|prose|account|profile|token/i)
  })

  test('strict parsing rejects extra content fields and tampered canonical bytes', () => {
    const journal = store()
    const started = lifecycle('task.started', '2026-07-13T10:00:00Z')
    expect(() => journal.append({ ...started, prompt: 'do not persist me' } as NormalizedSwarmEvent))
      .toThrow('unsupported field')
    journal.append(started)
    const path = join(eventsDir, `${started.event_id}.json`)
    writeFileSync(path, `${JSON.stringify({ ...started, state: 'STOOD_DOWN' })}\n`, { mode: 0o600 })
    expect(() => journal.replay()).toThrow()
  })

  test('enforces replay count/byte bounds', () => {
    const countBound = store({ maxEvents: 2 })
    for (let source_seq = 0; source_seq < 2; source_seq++) {
      countBound.append(makeHarnessEvent({
        ts: `2026-07-13T10:00:0${source_seq}Z`, type: 'runtime.activity',
        runtime: 'codex', source: 'codex-rollout', swarm: 'press-backend',
        task_id: 'bounded-task', dr_refs: ['ADR-0023'], source_seq,
      }))
    }
    expect(() => countBound.append(makeHarnessEvent({
      ts: '2026-07-13T10:00:03Z', type: 'runtime.activity',
      runtime: 'codex', source: 'codex-rollout', swarm: 'press-backend',
      task_id: 'bounded-task', dr_refs: ['ADR-0023'], source_seq: 3,
    }))).toThrow('event bound')

    rmSync(eventsDir, { recursive: true })
    mkdirSync(eventsDir, { mode: 0o700 })
    chmodSync(eventsDir, 0o700)
    const byteBound = store({ maxEvents: 100, maxBytes: 4096 })
    let refused = false
    for (let source_seq = 0; source_seq < 100; source_seq++) {
      const observed = makeHarnessEvent({
        ts: `2026-07-13T10:00:${String(source_seq % 60).padStart(2, '0')}Z`,
        type: 'runtime.activity', runtime: 'claude', source: 'claude-transcript',
        swarm: 'press-backend', task_id: 'byte-bounded', dr_refs: ['ADR-0023'], source_seq,
      })
      try { byteBound.append(observed) } catch (error) {
        expect(String(error)).toContain('byte bound')
        refused = true
        break
      }
    }
    expect(refused).toBe(true)
  })

  test('rejects unknown entries, loose files, symlinks, and hard links', () => {
    writeFileSync(join(eventsDir, 'unknown'), 'x', { mode: 0o600 })
    expect(() => store().replay()).toThrow('unknown entry')
    rmSync(join(eventsDir, 'unknown'))

    const started = lifecycle('task.started', '2026-07-13T10:00:00Z')
    store().append(started)
    const path = join(eventsDir, `${started.event_id}.json`)
    chmodSync(path, 0o644)
    expect(() => store().replay()).toThrow('unsafe identity')
    chmodSync(path, 0o600)
    const outside = join(root, 'linked-event')
    linkSync(path, outside)
    expect(() => store().replay()).toThrow('unsafe identity')
    rmSync(outside)
    rmSync(path)
    writeFileSync(outside, `${JSON.stringify(started)}\n`, { mode: 0o600 })
    symlinkSync(outside, path)
    expect(() => store().replay()).toThrow('unsafe identity')
  })

  test('requires an owner-real 0700 directory outside the repository', () => {
    chmodSync(eventsDir, 0o755)
    expect(() => store()).toThrow('mode 0700')
    chmodSync(eventsDir, 0o700)
    const inRepo = join(repo, 'events')
    mkdirSync(inRepo, { mode: 0o700 })
    expect(() => new NormalizedEventStore(inRepo, { repoRoot: repo })).toThrow('outside')
  })

  test('rebuild helper consumes the complete replay and materializes no fabricated seed', () => {
    const journal = store()
    expect(() => lstatSync(join(repo, ROADMAP_FILENAME))).toThrow()
    // Append deliberately out of time order; replay/derivation sorts ground truth.
    journal.append(lifecycle('task.finished', '2026-07-13T10:00:02Z'))
    journal.append(lifecycle('task.started', '2026-07-13T10:00:00Z'))
    journal.append(lifecycle('result.landed', '2026-07-13T10:00:01Z'))
    const roadmap = new RoadmapStore(repo, join(authorityDir, 'authority.json'))
    const document = rebuildRoadmapFromEventStore(journal, roadmap)
    expect(document.items['ADR-0023'].status).toBe('STOOD_DOWN')
    expect(roadmap.read()).toEqual(document)
    expect(lstatSync(join(repo, ROADMAP_FILENAME)).mode & 0o777).toBe(0o644)
  })
})
