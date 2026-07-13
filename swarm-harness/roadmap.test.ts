import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { makeHarnessEvent, type HarnessEventInput, type NormalizedSwarmEvent } from './events.ts'
import {
  ROADMAP_FILENAME,
  RoadmapStore,
  deriveRoadmap,
  parseRoadmap,
} from './roadmap.ts'
import {
  RoadmapDigestScheduler,
  RoadmapDiscordSurface,
  formatRoadmapDigest,
  formatRoadmapQuery,
} from './discord-roadmap.ts'

function event(input: Partial<HarnessEventInput> & Pick<HarnessEventInput, 'ts' | 'type'>): NormalizedSwarmEvent {
  const runtimeObserved = ['grounding.operation', 'edit.substantive', 'runtime.activity'].includes(input.type)
  return makeHarnessEvent({
    runtime: 'claude',
    source: input.type === 'result.landed'
      ? 'result-set'
      : runtimeObserved ? 'claude-transcript' : 'harness',
    swarm: 'press-backend',
    task_id: 'task-123',
    dr_refs: ['ADR-0023'],
    ...input,
  } as HarnessEventInput)
}

const journal = [
  event({ ts: '2026-07-13T10:00:00Z', type: 'task.started', state: 'DRIVING' }),
  event({ ts: '2026-07-13T10:00:01Z', type: 'grounding.started' }),
  event({ ts: '2026-07-13T10:00:03Z', type: 'grounding.operation', operation: 'read' }),
  event({ ts: '2026-07-13T10:00:06Z', type: 'edit.substantive' }),
  event({
    ts: '2026-07-13T10:00:07Z', type: 'result.landed', result_kind: 'review', result_status: 'passed',
  }),
  event({ ts: '2026-07-13T10:00:08Z', type: 'task.finished', outcome: 'completed', state: 'STOOD_DOWN' }),
]

describe('ground-truth roadmap derivation', () => {
  test('the same harness scenario derives byte-equivalent roadmap state for Claude and Codex', () => {
    const forRuntime = (runtime: 'claude' | 'codex', source: 'claude-transcript' | 'codex-rollout') => [
      makeHarnessEvent({
        ts: '2026-07-13T09:00:00Z', type: 'task.started', runtime, source: 'harness',
        swarm: 'press-backend', task_id: 'parity-task', dr_refs: ['ADR-0023'], state: 'DRIVING',
      }),
      makeHarnessEvent({
        ts: '2026-07-13T09:00:05Z', type: 'edit.substantive', runtime, source,
        swarm: 'press-backend', task_id: 'parity-task', dr_refs: ['ADR-0023'],
      }),
      makeHarnessEvent({
        ts: '2026-07-13T09:00:06Z', type: 'result.landed', runtime, source: 'result-set',
        swarm: 'press-backend', task_id: 'parity-task', dr_refs: ['ADR-0023'],
        result_kind: 'review', result_status: 'passed',
      }),
      makeHarnessEvent({
        ts: '2026-07-13T09:00:07Z', type: 'task.finished', runtime, source: 'harness',
        swarm: 'press-backend', task_id: 'parity-task', dr_refs: ['ADR-0023'],
        outcome: 'completed', state: 'STOOD_DOWN',
      }),
    ]
    expect(deriveRoadmap(forRuntime('claude', 'claude-transcript')))
      .toEqual(deriveRoadmap(forRuntime('codex', 'codex-rollout')))
  })

  test('is deterministic, idempotent, DR-keyed, and contains no task/account ids', () => {
    const ordered = deriveRoadmap(journal)
    const shuffled = deriveRoadmap([journal[4], journal[1], ...journal, journal[0]])
    expect(shuffled).toEqual(ordered)
    expect(Object.keys(ordered.items)).toEqual(['ADR-0023'])
    expect(ordered.parity_matrix).toBe('docs/RUNTIME-PARITY.md')
    expect(ordered.items['ADR-0023']).toMatchObject({
      status: 'STOOD_DOWN',
      owning_swarm: 'press-backend',
      last_result_status: 'passed',
      result_sets: { passed: 1, failed: 0, pending: 0, blocked: 0 },
      grounding: { latest_ms: 5000, previous_ms: null, delta_ms: null, samples: 1 },
    })
    const serialized = JSON.stringify(ordered)
    expect(serialized).not.toContain('task-123')
    expect(serialized).not.toMatch(/account|profile|token|user_id|chat_id|message_id/i)
  })

  test('result-set and transition ground truth drive blocked/completed state', () => {
    const blocked = deriveRoadmap([
      journal[0],
      event({
        ts: '2026-07-13T10:00:02Z', type: 'result.landed', result_kind: 'review', result_status: 'blocked',
      }),
    ])
    expect(blocked.items['ADR-0023'].status).toBe('WAITING_FOR_OPERATOR')
    expect(blocked.items['ADR-0023'].result_sets.blocked).toBe(1)
    const invalidDone = deriveRoadmap([
      ...[journal[0]],
      event({
        ts: '2026-07-13T10:00:02Z', type: 'result.landed', result_kind: 'review', result_status: 'pending',
      }),
      event({
        ts: '2026-07-13T10:00:03Z', type: 'task.finished', outcome: 'completed', state: 'STOOD_DOWN',
      }),
    ])
    expect(invalidDone.items['ADR-0023'].status).toBe('WAITING_FOR_OPERATOR')
    const noGateArtifact = deriveRoadmap([
      journal[0],
      event({
        ts: '2026-07-13T10:00:03Z', type: 'task.finished', outcome: 'completed', state: 'STOOD_DOWN',
      }),
    ])
    expect(noGateArtifact.items['ADR-0023'].status).toBe('WAITING_FOR_OPERATOR')

    const resumed = deriveRoadmap([
      ...journal.slice(0, 2),
      event({
        ts: '2026-07-13T10:00:04Z', type: 'state.transitioned',
        previous_state: 'WAITING_FOR_OPERATOR', state: 'DRIVING',
      }),
    ])
    expect(resumed.items['ADR-0023'].status).toBe('DRIVING')
  })

  test('measures grounding before/after at first substantive edit and counts pack gaps', () => {
    const secondTask = [
      event({
        ts: '2026-07-13T11:00:00Z', type: 'task.started', task_id: 'task-456', state: 'DRIVING',
      }),
      event({ ts: '2026-07-13T11:00:04Z', type: 'edit.substantive', task_id: 'task-456' }),
      event({ ts: '2026-07-13T11:00:05Z', type: 'edit.substantive', task_id: 'task-456' }),
      event({ ts: '2026-07-13T11:00:06Z', type: 'grounding.gap_reported', task_id: 'task-456' }),
    ]
    const roadmap = deriveRoadmap([...journal, ...secondTask])
    expect(roadmap.items['ADR-0023'].grounding).toEqual({
      latest_ms: 4000,
      previous_ms: 5000,
      delta_ms: -1000,
      samples: 2,
      gap_reports: 1,
    })
  })

  test('refuses two swarms claiming the same active DR', () => {
    const secondOwner = makeHarnessEvent({
      ts: '2026-07-13T10:00:01Z', type: 'task.started', runtime: 'codex', source: 'harness',
      swarm: 'reserve-web', task_id: 'other-task', dr_refs: ['ADR-0023'], state: 'DRIVING',
    })
    expect(() => deriveRoadmap([journal[0], secondOwner])).toThrow('active ownership conflict')
  })

  test('strict parsing rejects unapproved fields and unsafe labels before Discord formatting', () => {
    const roadmap = deriveRoadmap(journal)
    expect(() => parseRoadmap({
      ...roadmap,
      items: { 'ADR-0023': { ...roadmap.items['ADR-0023'], account: 'provider-user@example.test' } },
    })).toThrow('unsupported field')
    expect(() => parseRoadmap({ ...roadmap, parity_matrix: 'https://attacker.invalid/matrix' }))
      .toThrow('parity matrix link')
    expect(() => parseRoadmap({
      ...roadmap,
      items: { 'ADR-0023': { ...roadmap.items['ADR-0023'], owning_swarm: 'provider@example.test' } },
    })).toThrow('owner is invalid')
    expect(() => parseRoadmap({
      ...roadmap,
      items: { 'ADR-0023': { ...roadmap.items['ADR-0023'], owning_swarm: 'xoxb-123456789012345678901234' } },
    })).toThrow('owner is invalid')
  })
})

describe('CAS-protected living roadmap artifact', () => {
  let root: string
  let repo: string
  let state: string

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'qofi-roadmap-'))
    repo = join(root, 'repo')
    state = join(root, 'private', 'roadmap-authority.json')
    mkdirSync(repo, { recursive: true })
    mkdirSync(join(root, 'private'), { mode: 0o700 })
    chmodSync(repo, 0o755)
  })
  afterEach(() => rmSync(root, { recursive: true, force: true }))

  test('writes, reads, and deterministically rebuilds an owner artifact', () => {
    const store = new RoadmapStore(repo, state)
    const first = store.writeDerived(journal)
    expect(store.read()).toEqual(first)
    const before = readFileSync(join(repo, ROADMAP_FILENAME), 'utf8')
    store.writeDerived([...journal].reverse())
    expect(readFileSync(join(repo, ROADMAP_FILENAME), 'utf8')).toBe(before)
  })

  test('hardblocks cross-owner root publication without descriptor-bound rename authority', () => {
    expect(() => new RoadmapStore(repo, state, {
      authorityUid: 0,
      roadmapOwnerUid: 501,
    })).toThrow('descriptor-bound root helper')
    expect(() => lstatSync(state)).toThrow()
    expect(() => lstatSync(join(repo, ROADMAP_FILENAME))).toThrow()
  })

  test('refuses outside/manual edits rather than overwriting them', () => {
    const store = new RoadmapStore(repo, state)
    store.writeDerived(journal)
    writeFileSync(join(repo, ROADMAP_FILENAME), '{}\n', { mode: 0o644 })
    expect(() => store.writeDerived(journal)).toThrow('changed outside the harness')
  })

  test('refuses a pre-existing unbound or symlinked roadmap', () => {
    writeFileSync(join(repo, ROADMAP_FILENAME), '{}\n', { mode: 0o644 })
    expect(() => new RoadmapStore(repo, state).writeDerived(journal)).toThrow('without private authority')
    rmSync(join(repo, ROADMAP_FILENAME))
    const target = join(root, 'target')
    writeFileSync(target, '{}\n', { mode: 0o644 })
    symlinkSync(target, join(repo, ROADMAP_FILENAME))
    expect(() => new RoadmapStore(repo, state).writeDerived(journal)).toThrow('owner-regular')
  })

  test('does not chmod through a substituted authority-directory symlink', () => {
    const privateDir = join(root, 'private')
    rmSync(privateDir, { recursive: true })
    const target = join(root, 'authority-target')
    mkdirSync(target, { mode: 0o755 })
    chmodSync(target, 0o755)
    symlinkSync(target, privateDir)
    expect(() => new RoadmapStore(repo, state).writeDerived(journal)).toThrow('owner-real directory')
    expect(lstatSync(target).mode & 0o777).toBe(0o755)
  })
})

describe('phone-readable Discord roadmap surfaces', () => {
  test('query and digest contain only validated labels, states, and metrics', () => {
    const prior = deriveRoadmap(journal.slice(0, 4))
    const current = deriveRoadmap(journal)
    const query = formatRoadmapQuery(current)
    const digest = formatRoadmapDigest(current, prior)
    expect(query).toContain('ADR-0023 · STOOD_DOWN · press-backend · passed')
    expect(query).toContain('Parity · docs/RUNTIME-PARITY.md')
    expect(digest).toContain('DRIVING→STOOD_DOWN')
    expect(digest).toContain('Grounding')
    expect(digest.length).toBeLessThanOrEqual(1800)
    for (const output of [query, digest]) {
      expect(output).not.toMatch(/task-123|account|profile|token|chat_id|message_id/i)
    }
  })

  test('on-demand command is exact and authorization-gated', () => {
    const surface = new RoadmapDiscordSurface(() => deriveRoadmap(journal))
    expect(surface.handle('!watcher roadmap', false)).toBeNull()
    expect(surface.handle('roadmap please', true)).toBeNull()
    expect(surface.handle('  !WATCHER ROADMAP  ', true)).toContain('🧭 Roadmap')
  })

  test('scheduled failure remains due and successful delivery advances snapshot', async () => {
    const delivered: string[] = []
    let fail = true
    const scheduler = new RoadmapDigestScheduler(60_000, async message => {
      if (fail) throw new Error('Discord unavailable')
      delivered.push(message)
    })
    const current = deriveRoadmap(journal)
    await expect(scheduler.tick(100_000, current)).rejects.toThrow('Discord unavailable')
    expect(scheduler.due(100_001)).toBe(true)
    fail = false
    await scheduler.tick(100_001, current)
    expect(delivered).toHaveLength(1)
    expect(scheduler.due(120_000)).toBe(false)
    expect(await scheduler.tick(120_000, current)).toBeNull()
    expect(scheduler.due(160_001)).toBe(true)
  })
})
