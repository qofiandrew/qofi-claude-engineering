#!/usr/bin/env bun
/**
 * Bun-only bridge from the long-lived Node watcher to the shared TypeScript
 * harness policy. The watcher sends bounded JSON on stdin; reviewed/check-in
 * content is never placed in argv or a shell command.
 *
 * Keep decisions here as calls into swarm-harness. The Node-side adapter owns
 * only Discord transport, correlation, and authenticated-channel provenance.
 */
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'
import {
  CTO_CHECKIN_SCHEMA,
  renderCheckInPing,
  validateCtoCheckIn,
} from '../swarm-harness/checkin.ts'
import {
  NORMALIZED_EVENT_SCHEMA,
  SWARM_STATES,
  type NormalizedSwarmEvent,
} from '../swarm-harness/events.ts'
import { NormalizedEventStore } from '../swarm-harness/event-store.ts'
import {
  ROADMAP_SCHEMA,
  RoadmapStore,
} from '../swarm-harness/roadmap.ts'
import {
  ROADMAP_QUERY_COMMAND,
  formatRoadmapDigest,
  formatRoadmapQuery,
} from '../swarm-harness/discord-roadmap.ts'

const MAX_INPUT_BYTES = 64 * 1024

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

function roadmapStore(input: Record<string, unknown>): RoadmapStore {
  if (typeof input.repoRoot !== 'string' || typeof input.authorityFile !== 'string') {
    throw new Error('roadmap store paths are required')
  }
  return new RoadmapStore(resolve(input.repoRoot), resolve(input.authorityFile))
}

function opaqueTaskLabel(input: Record<string, unknown>): string {
  if (typeof input.swarm !== 'string' || typeof input.state !== 'string' || typeof input.correlation !== 'string') {
    throw new Error('active-task scope is required')
  }
  const digest = createHash('sha256')
    .update(`${NORMALIZED_EVENT_SCHEMA}\0${input.swarm}\0${input.state}\0${input.correlation}`)
    .digest('hex')
    .slice(0, 24)
  return `pending-${digest}`
}

function activeTask(input: Record<string, unknown>): {
  bound: boolean
  current_task: string
  state: string
  event_at: string | null
} {
  const fallback = {
    bound: false,
    current_task: opaqueTaskLabel(input),
    state: input.state as string,
    event_at: null,
  }
  if (typeof input.repoRoot !== 'string' || typeof input.eventStoreDirectory !== 'string') return fallback
  let events: NormalizedSwarmEvent[]
  try {
    events = new NormalizedEventStore(resolve(input.eventStoreDirectory), {
      repoRoot: resolve(input.repoRoot),
    }).replay()
  } catch {
    return fallback
  }
  const lifecycle = new Map<string, { active: boolean, state: string | null, eventAt: string }>()
  for (const event of events) {
    if (event.swarm !== input.swarm) continue
    const prior = lifecycle.get(event.task_id) ?? { active: false, state: null, eventAt: event.ts }
    if (event.type === 'task.started') {
      lifecycle.set(event.task_id, { active: true, state: event.state ?? null, eventAt: event.ts })
    } else if (event.type === 'state.transitioned' && prior.active) {
      lifecycle.set(event.task_id, { active: true, state: event.state ?? prior.state, eventAt: event.ts })
    } else if (event.type === 'task.finished') {
      lifecycle.set(event.task_id, { active: false, state: event.state ?? prior.state, eventAt: event.ts })
    }
  }
  const active = [...lifecycle.entries()].filter(([, value]) => value.active)
  if (active.length !== 1) return fallback
  const [taskId, value] = active[0]!
  if (value.state !== input.state) return fallback
  return { bound: true, current_task: taskId, state: value.state!, event_at: value.eventAt }
}

const bytes = await Bun.stdin.text()
if (Buffer.byteLength(bytes) > MAX_INPUT_BYTES) throw new Error('policy input exceeds bound')
let input: unknown
try { input = bytes.trim() ? JSON.parse(bytes) : {} } catch { throw new Error('policy input is invalid JSON') }
if (!isRecord(input)) throw new Error('policy input must be an object')

const operation = Bun.argv[2]
let output: unknown

switch (operation) {
  case 'contract': {
    const contract = {
      checkin_schema: CTO_CHECKIN_SCHEMA,
      normalized_event_schema: NORMALIZED_EVENT_SCHEMA,
      roadmap_schema: ROADMAP_SCHEMA,
      roadmap_query_command: ROADMAP_QUERY_COMMAND,
      swarm_states: [...SWARM_STATES],
    }
    output = {
      ...contract,
      contract_sha256: createHash('sha256').update(canonical(contract)).digest('hex'),
    }
    break
  }
  case 'checkin.render': {
    if (!isRecord(input.ping)) throw new Error('check-in ping is required')
    const attempt = input.attempt === undefined ? 1 : Number(input.attempt)
    const errors = input.errors === undefined ? [] : input.errors
    if (!Number.isSafeInteger(attempt) || attempt < 1 || !Array.isArray(errors)) {
      throw new Error('check-in render metadata is invalid')
    }
    output = { text: renderCheckInPing(input.ping as never, attempt, errors as string[]) }
    break
  }
  case 'checkin.validate': {
    if (!isRecord(input.expected)) throw new Error('check-in expected truth is required')
    output = validateCtoCheckIn(input.candidate, input.expected as never)
    break
  }
  case 'roadmap.query': {
    output = { text: formatRoadmapQuery(roadmapStore(input).read()) }
    break
  }
  case 'roadmap.digest': {
    const document = roadmapStore(input).read()
    const previous = input.previous === null || input.previous === undefined ? null : input.previous
    output = {
      document,
      text: formatRoadmapDigest(document, previous as never),
    }
    break
  }
  case 'event.active-task': {
    output = activeTask(input)
    break
  }
  default:
    throw new Error('unknown policy operation')
}

process.stdout.write(`${JSON.stringify(output)}\n`)
