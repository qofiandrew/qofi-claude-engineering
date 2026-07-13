import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'fs'
import { join } from 'path'
import {
  DEFAULT_ROTATION_THRESHOLD_PERCENT,
  FIVE_HOUR_WINDOW_MINUTES,
  MAX_TELEMETRY_AGE_MS,
  WEEKLY_WINDOW_MINUTES,
  allocateProfileLease,
  chooseProfileForSwarm,
  decideHardLimitCooldown,
  decideSoftCooldown,
  parseRolloutTelemetry,
  profileHeadroom,
  rotateSwarmProfile,
  validateProfilePool,
  validateProfileRegistry,
  type FreshQuotaTelemetry,
  type ProfileRegistryEntry,
  type QuotaTelemetry,
  type RotationHarnessState,
} from './profile-rotation.ts'

const NOW = Date.parse('2026-07-12T12:00:00.000Z')
const FIVE_HOUR_RESET = Date.parse('2026-07-12T13:00:00.000Z')
const WEEKLY_RESET = Date.parse('2026-07-17T00:00:00.000Z')
const FIXTURES = join(import.meta.dir, 'fixtures', 'profile-rotation')
const REGISTRY: readonly ProfileRegistryEntry[] = [
  { label: 'profile_a' },
  { label: 'profile_b' },
  { label: 'profile_c' },
  { label: 'shared_d', shared: true },
]

function fixture(name: string): string {
  return readFileSync(join(FIXTURES, name), 'utf8')
}

function fresh(fiveHour: number, weekly: number): FreshQuotaTelemetry {
  return {
    status: 'fresh',
    observedAtMs: NOW - 60_000,
    physicalLine: 1,
    fiveHour: {
      windowMinutes: FIVE_HOUR_WINDOW_MINUTES,
      usedPercent: fiveHour,
      resetsAtMs: FIVE_HOUR_RESET,
    },
    weekly: {
      windowMinutes: WEEKLY_WINDOW_MINUTES,
      usedPercent: weekly,
      resetsAtMs: WEEKLY_RESET,
    },
  }
}

describe('profile registry and ordered pools', () => {
  test('normalizes omitted shared flags to exclusive and rejects duplicate labels', () => {
    expect(validateProfileRegistry([{ label: 'profile_a' }, { label: 'shared_d', shared: true }]))
      .toEqual([{ label: 'profile_a', shared: false }, { label: 'shared_d', shared: true }])
    expect(() => validateProfileRegistry([{ label: 'profile_a' }, { label: 'profile_a' }]))
      .toThrow('duplicate profile registry label')
  })

  test('preserves order and supplies the 95 percent default', () => {
    expect(DEFAULT_ROTATION_THRESHOLD_PERCENT).toBe(95)
    expect(validateProfilePool(REGISTRY, { profiles: ['profile_c', 'profile_a'] })).toEqual({
      profiles: ['profile_c', 'profile_a'],
      thresholdPercent: DEFAULT_ROTATION_THRESHOLD_PERCENT,
    })
    expect(validateProfilePool(REGISTRY, {
      profiles: ['profile_a'],
      thresholdPercent: 95,
    }).thresholdPercent).toBe(95)
  })

  test('rejects unsafe, duplicate, missing, and invalid declarations', () => {
    expect(() => validateProfilePool([{ label: 'Profile_A' }], { profiles: ['Profile_A'] }))
      .toThrow('labels must be safe')
    expect(() => validateProfilePool([{ label: 'a.b' }], { profiles: ['a.b'] }))
      .toThrow('labels must be safe')
    expect(() => validateProfilePool(REGISTRY, { profiles: ['profile_a', 'profile_a'] }))
      .toThrow('duplicate profile')
    expect(() => validateProfilePool(REGISTRY, { profiles: ['missing'] }))
      .toThrow('unknown profile')
    expect(() => validateProfilePool(REGISTRY, { profiles: ['profile_a'], thresholdPercent: 0 }))
      .toThrow('greater than 0')
    expect(() => validateProfilePool(REGISTRY, { profiles: ['profile_a'], thresholdPercent: 101 }))
      .toThrow('at most 100')
  })
})

describe('local rollout telemetry', () => {
  test('uses the physically latest token_count and classifies windows by duration', () => {
    const telemetry = parseRolloutTelemetry(fixture('rollout-fresh.jsonl'), NOW)
    expect(telemetry.status).toBe('fresh')
    if (telemetry.status !== 'fresh') throw new Error('expected fresh fixture')
    // The physical last event is deliberately timestamped before the earlier line.
    expect(telemetry.physicalLine).toBe(3)
    expect(telemetry.observedAtMs).toBe(Date.parse('2026-07-12T11:50:00.000Z'))
    expect(telemetry.fiveHour.usedPercent).toBe(84)
    expect(telemetry.fiveHour.windowMinutes).toBe(300)
    expect(telemetry.weekly.usedPercent).toBe(82)
    expect(telemetry.weekly.windowMinutes).toBe(10_080)
  })

  test('a newer null rate_limits event suppresses an older usable snapshot', () => {
    expect(parseRolloutTelemetry(fixture('rollout-null.jsonl'), NOW)).toEqual({
      status: 'unknown',
      reason: 'rate_limits_null',
      observedAtMs: Date.parse('2026-07-12T11:59:00.000Z'),
      physicalLine: 2,
    })
  })

  test('weekly-only telemetry remains fresh and triggers from its known window', () => {
    const telemetry = parseRolloutTelemetry(fixture('rollout-weekly-only.jsonl'), NOW)
    expect(telemetry).toMatchObject({
      status: 'fresh',
      fiveHour: null,
      weekly: { windowMinutes: WEEKLY_WINDOW_MINUTES, usedPercent: 95 },
    })
    expect(decideSoftCooldown(telemetry, 85, NOW)).toEqual({
      trigger: true,
      cooldownUntilMs: WEEKLY_RESET,
      breachedWindows: [WEEKLY_WINDOW_MINUTES],
    })
    expect(profileHeadroom(telemetry)).toBe(5)
  })

  test('telemetry older than 30 minutes is unknown, while exactly 30 minutes is fresh', () => {
    expect(parseRolloutTelemetry(fixture('rollout-stale.jsonl'), NOW).status).toBe('unknown')
    const exactlyThirty = fixture('rollout-fresh.jsonl')
      .replace('2026-07-12T11:50:00.000Z', '2026-07-12T11:30:00.000Z')
    expect(parseRolloutTelemetry(exactlyThirty, NOW, MAX_TELEMETRY_AGE_MS).status).toBe('fresh')
  })

  test('future-dated telemetry is unknown', () => {
    const future = fixture('rollout-fresh.jsonl')
      .replace('2026-07-12T11:50:00.000Z', '2026-07-12T12:00:00.001Z')
    expect(parseRolloutTelemetry(future, NOW)).toMatchObject({
      status: 'unknown',
      reason: 'stale',
      observedAtMs: NOW + 1,
      physicalLine: 3,
    })
  })

  test('a later valid token_count supersedes an earlier malformed candidate', () => {
    const malformed = '{"type":"event_msg","payload":{"type":"token_count"\n'
    expect(parseRolloutTelemetry(malformed + fixture('rollout-fresh.jsonl'), NOW)).toMatchObject({
      status: 'fresh',
      physicalLine: 4,
      fiveHour: { usedPercent: 84 },
      weekly: { usedPercent: 82 },
    })
  })

  test('malformed and incomplete latest token_count records fail closed', () => {
    const valid = fixture('rollout-fresh.jsonl')
    expect(parseRolloutTelemetry(`${valid}{"type":"event_msg","payload":{"type":"token_count"`, NOW))
      .toMatchObject({ status: 'unknown', reason: 'malformed', physicalLine: 4 })

    const partial = JSON.stringify({
      timestamp: '2026-07-12T11:59:00.000Z',
      type: 'event_msg',
      payload: {
        type: 'token_count',
        rate_limits: {
          primary: { used_percent: 50, window_minutes: 300, resets_at: 1783861200 },
          secondary: null,
        },
      },
    })
    expect(parseRolloutTelemetry(partial, NOW)).toMatchObject({
      status: 'fresh',
      fiveHour: { windowMinutes: FIVE_HOUR_WINDOW_MINUTES, usedPercent: 50 },
      weekly: null,
    })

    const incomplete = partial
      .replace('"window_minutes":300', '"window_minutes":60')
    expect(parseRolloutTelemetry(incomplete, NOW)).toMatchObject({
      status: 'unknown',
      reason: 'incomplete',
    })

    const malformed = partial.replace('"used_percent":50', '"used_percent":150')
    expect(parseRolloutTelemetry(malformed, NOW)).toMatchObject({
      status: 'unknown',
      reason: 'malformed',
    })

    const duplicate = JSON.stringify({
      timestamp: '2026-07-12T11:59:00.000Z',
      type: 'event_msg',
      payload: {
        type: 'token_count',
        rate_limits: {
          primary: { used_percent: 50, window_minutes: 300, resets_at: 1783861200 },
          secondary: { used_percent: 60, window_minutes: 300, resets_at: 1783861200 },
        },
      },
    })
    expect(parseRolloutTelemetry(duplicate, NOW)).toMatchObject({
      status: 'unknown',
      reason: 'malformed',
    })
  })

  test('a rollout without a token_count has unknown telemetry', () => {
    expect(parseRolloutTelemetry('{"type":"event_msg","payload":{"type":"task_started"}}\n', NOW))
      .toEqual({ status: 'unknown', reason: 'no_token_count', observedAtMs: null, physicalLine: null })
  })
})

describe('soft and hard cooldown decisions', () => {
  test('the threshold is inclusive and cooling lasts through every breached window', () => {
    const decision = decideSoftCooldown(fresh(85, 91), 85, NOW)
    expect(decision).toEqual({
      trigger: true,
      cooldownUntilMs: WEEKLY_RESET,
      breachedWindows: [FIVE_HOUR_WINDOW_MINUTES, WEEKLY_WINDOW_MINUTES],
    })
    expect(decideSoftCooldown(fresh(84.99, 84.99), 85, NOW).trigger).toBe(false)
  })

  test('unknown telemetry alone never triggers rotation', () => {
    const variants: QuotaTelemetry[] = [
      { status: 'unknown', reason: 'rate_limits_null', observedAtMs: NOW, physicalLine: 1 },
      { status: 'unknown', reason: 'stale', observedAtMs: NOW - 3_600_000, physicalLine: 1 },
      { status: 'unknown', reason: 'incomplete', observedAtMs: NOW, physicalLine: 1 },
    ]
    for (const telemetry of variants) expect(decideSoftCooldown(telemetry, 85, NOW).trigger).toBe(false)
  })

  test('429 and usage-limit failures requeue with a known reset when available', () => {
    const known = decideHardLimitCooldown({
      error: {
        http_status_code: 429,
        rate_limits: {
          primary: { resets_at: FIVE_HOUR_RESET / 1_000 },
          secondary: { resets_at: WEEKLY_RESET / 1_000 },
        },
      },
    }, NOW)
    expect(known).toEqual({
      hardLimit: true,
      requeue: true,
      cooldownUntilMs: WEEKLY_RESET,
      cooldownSource: 'known_reset',
    })
    expect(decideHardLimitCooldown({
      quotaLimited: true,
      telemetry: fresh(100, 100),
    }, NOW).cooldownUntilMs).toBe(WEEKLY_RESET)
  })

  test('a hard failure without reset evidence cools for one full selected window', () => {
    expect(decideHardLimitCooldown("You've hit your usage limit.", NOW)).toEqual({
      hardLimit: true,
      requeue: true,
      cooldownUntilMs: NOW + FIVE_HOUR_WINDOW_MINUTES * 60_000,
      cooldownSource: 'full_window_fallback',
    })
    expect(decideHardLimitCooldown(
      { code: 'rate_limit_exceeded' },
      NOW,
      WEEKLY_WINDOW_MINUTES,
    ).cooldownUntilMs).toBe(NOW + WEEKLY_WINDOW_MINUTES * 60_000)
    expect(decideHardLimitCooldown({ quotaLimited: true }, NOW).requeue).toBe(true)
    expect(decideHardLimitCooldown({ errorInfo: 'usageLimitExceeded' }, NOW).requeue).toBe(true)
    expect(decideHardLimitCooldown(new Error('rate limit exceeded'), NOW).requeue).toBe(true)
  })

  test('ordinary failures and unrelated numbers do not rotate or requeue', () => {
    for (const error of [
      { status: 500, message: 'upstream unavailable' },
      { message: 'processed 429 files successfully' },
      'the output size limit was reached',
    ]) expect(decideHardLimitCooldown(error, NOW).hardLimit).toBe(false)
  })
})

describe('headroom, leases, exhaustion, and isolation', () => {
  test('headroom is governed by the more-consumed window', () => {
    expect(profileHeadroom(fresh(20, 70))).toBe(30)
    expect(profileHeadroom({ ...fresh(20, 70), fiveHour: null })).toBe(30)
    expect(profileHeadroom({
      status: 'unknown', reason: 'stale', observedAtMs: NOW - 3_600_000, physicalLine: 1,
    })).toBeNull()
  })

  test('selects the eligible profile with most known headroom and keeps pool order on ties', () => {
    const chosen = chooseProfileForSwarm({
      registry: REGISTRY,
      pool: { profiles: ['profile_a', 'profile_b', 'profile_c'] },
      leases: {},
      swarmName: 'swarm-a',
      telemetry: {
        profile_a: fresh(70, 70),
        profile_b: fresh(10, 20),
        profile_c: fresh(20, 20),
      },
      cooldowns: {},
      nowMs: NOW,
    })
    expect(chosen).toMatchObject({ kind: 'selected', profile: 'profile_b', headroomPercent: 80 })

    const tie = chooseProfileForSwarm({
      registry: REGISTRY,
      pool: { profiles: ['profile_c', 'profile_b'] },
      leases: {},
      swarmName: 'swarm-a',
      telemetry: { profile_b: fresh(20, 20), profile_c: fresh(20, 20) },
      cooldowns: {},
      nowMs: NOW,
    })
    expect(tie).toMatchObject({ kind: 'selected', profile: 'profile_c' })
  })

  test('known headroom outranks unknown, but unknown remains eligible as a fallback', () => {
    const unknown = { status: 'unknown', reason: 'rate_limits_null', observedAtMs: NOW, physicalLine: 1 } as const
    expect(chooseProfileForSwarm({
      registry: REGISTRY,
      pool: { profiles: ['profile_a', 'profile_b'] },
      leases: {},
      swarmName: 'swarm-a',
      telemetry: { profile_a: unknown, profile_b: fresh(80, 80) },
      cooldowns: {},
      nowMs: NOW,
    })).toMatchObject({ kind: 'selected', profile: 'profile_b' })
    expect(chooseProfileForSwarm({
      registry: REGISTRY,
      pool: { profiles: ['profile_a'] },
      leases: {},
      swarmName: 'swarm-a',
      telemetry: { profile_a: unknown },
      cooldowns: {},
      nowMs: NOW,
    })).toMatchObject({ kind: 'selected', profile: 'profile_a', headroomPercent: null })
  })

  test('exclusive profiles cannot be double-leased while explicitly shared profiles can', () => {
    const original = { 'swarm-a': 'profile_a' }
    expect(() => allocateProfileLease(original, REGISTRY, 'swarm-b', 'profile_a'))
      .toThrow('exclusively leased')
    expect(allocateProfileLease(original, REGISTRY, 'swarm-b', 'profile_b')).toEqual({
      'swarm-a': 'profile_a',
      'swarm-b': 'profile_b',
    })
    expect(original).toEqual({ 'swarm-a': 'profile_a' })
    expect(allocateProfileLease(
      { 'swarm-a': 'shared_d' }, REGISTRY, 'swarm-b', 'shared_d',
    )).toEqual({ 'swarm-a': 'shared_d', 'swarm-b': 'shared_d' })
  })

  test('all cooling profiles exhaust the pool until its earliest reset', () => {
    const choice = chooseProfileForSwarm({
      registry: REGISTRY,
      pool: { profiles: ['profile_a', 'profile_b'] },
      leases: {},
      swarmName: 'swarm-a',
      telemetry: { profile_b: fresh(96, 96) },
      cooldowns: { profile_a: FIVE_HOUR_RESET },
      nowMs: NOW,
    })
    expect(choice).toMatchObject({ kind: 'exhausted', resumeAtMs: FIVE_HOUR_RESET })
    expect(choice.unavailable).toEqual([
      { profile: 'profile_a', reason: 'cooling', untilMs: FIVE_HOUR_RESET },
      { profile: 'profile_b', reason: 'soft_limit', untilMs: WEEKLY_RESET },
    ])
  })

  test('two-swarm rotation modifies only the triggering swarm lease and state', () => {
    const swarmB = {
      activeProfile: 'profile_b',
      cooldowns: {},
      telemetry: { profile_b: fresh(10, 10) },
    } as const
    const state: RotationHarnessState = {
      swarms: {
        'swarm-a': {
          activeProfile: 'profile_a',
          cooldowns: {},
          telemetry: {
            profile_a: fresh(90, 90),
            profile_c: fresh(20, 20),
          },
        },
        'swarm-b': swarmB,
      },
    }
    const rotated = rotateSwarmProfile({
      state,
      registry: REGISTRY,
      pool: { profiles: ['profile_a', 'profile_b', 'profile_c'] },
      swarmName: 'swarm-a',
      coolingProfile: 'profile_a',
      cooldownUntilMs: WEEKLY_RESET,
      nowMs: NOW,
    })
    expect(rotated).toMatchObject({
      previousProfile: 'profile_a',
      activeProfile: 'profile_c',
      parked: false,
    })
    expect(rotated.state.swarms['swarm-a']?.cooldowns).toEqual({ profile_a: WEEKLY_RESET })
    expect(rotated.state.swarms['swarm-b']).toBe(swarmB)
    expect(rotated.state.swarms['swarm-b']).toEqual(state.swarms['swarm-b']!)
    expect(state.swarms['swarm-a']?.activeProfile).toBe('profile_a')
    expect(state.swarms['swarm-b']?.activeProfile).toBe('profile_b')
  })
})
