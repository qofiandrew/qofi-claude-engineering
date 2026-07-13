export const FIVE_HOUR_WINDOW_MINUTES = 300 as const
export const WEEKLY_WINDOW_MINUTES = 10_080 as const
export const DEFAULT_ROTATION_THRESHOLD_PERCENT = 95
export const MAX_TELEMETRY_AGE_MS = 30 * 60 * 1_000

const PROFILE_LABEL = /^[a-z][a-z0-9_-]{0,31}$/
const SWARM_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
const TARGET_WINDOWS = new Set<number>([
  FIVE_HOUR_WINDOW_MINUTES,
  WEEKLY_WINDOW_MINUTES,
])
const TOKEN_COUNT_MARKER = /["']type["']\s*:\s*["']token_count["']/

export type QuotaWindowMinutes =
  | typeof FIVE_HOUR_WINDOW_MINUTES
  | typeof WEEKLY_WINDOW_MINUTES

export type ProfileRegistryEntry = Readonly<{
  label: string
  /** Explicit opt-in. Omitted and false profiles are exclusive. */
  shared?: boolean
}>

export type ProfilePoolDeclaration = Readonly<{
  profiles: readonly string[]
  thresholdPercent?: number
}>

export type ValidatedProfilePool = Readonly<{
  profiles: readonly string[]
  thresholdPercent: number
}>

export type QuotaWindowSnapshot = Readonly<{
  windowMinutes: QuotaWindowMinutes
  usedPercent: number
  resetsAtMs: number
}>

export type FreshQuotaTelemetry = Readonly<{
  status: 'fresh'
  observedAtMs: number
  physicalLine: number
  /** Null is a usable partial snapshot: this window is unknown, not zero. */
  fiveHour: QuotaWindowSnapshot | null
  /** Null is a usable partial snapshot: this window is unknown, not zero. */
  weekly: QuotaWindowSnapshot | null
}>

export type UnknownTelemetryReason =
  | 'no_token_count'
  | 'rate_limits_null'
  | 'stale'
  | 'malformed'
  | 'incomplete'

export type UnknownQuotaTelemetry = Readonly<{
  status: 'unknown'
  reason: UnknownTelemetryReason
  observedAtMs: number | null
  physicalLine: number | null
}>

export type QuotaTelemetry = FreshQuotaTelemetry | UnknownQuotaTelemetry

export type SoftCooldownDecision = Readonly<{
  trigger: boolean
  cooldownUntilMs: number | null
  breachedWindows: readonly QuotaWindowMinutes[]
}>

export type HardLimitDecision = Readonly<
  | {
      hardLimit: false
      requeue: false
      cooldownUntilMs: null
      cooldownSource: null
    }
  | {
      hardLimit: true
      requeue: true
      cooldownUntilMs: number
      cooldownSource: 'known_reset' | 'full_window_fallback'
    }
>

export type LeaseMap = Readonly<Record<string, string>>

export type ProfileChoice = Readonly<
  | {
      kind: 'selected'
      profile: string
      /** Null means the profile is eligible but has unknown telemetry. */
      headroomPercent: number | null
      unavailable: readonly ProfileUnavailable[]
    }
  | {
      kind: 'exhausted'
      /** Null means only an external lease/backoff can make progress. */
      resumeAtMs: number | null
      unavailable: readonly ProfileUnavailable[]
    }
>

export type ProfileUnavailable = Readonly<{
  profile: string
  reason: 'cooling' | 'soft_limit' | 'leased'
  untilMs: number | null
}>

export type SwarmProfileState = Readonly<{
  activeProfile: string | null
  cooldowns: Readonly<Record<string, number>>
  telemetry: Readonly<Record<string, QuotaTelemetry>>
}>

export type RotationHarnessState = Readonly<{
  swarms: Readonly<Record<string, SwarmProfileState>>
}>

export type SwarmRotationResult = Readonly<{
  state: RotationHarnessState
  previousProfile: string
  activeProfile: string | null
  parked: boolean
  resumeAtMs: number | null
  choice: ProfileChoice
}>

type TokenCountCandidate = Readonly<
  | { kind: 'malformed'; physicalLine: number }
  | { kind: 'parsed'; physicalLine: number; value: Record<string, unknown> }
>

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function validateRegistry(registry: readonly ProfileRegistryEntry[]): Map<string, ProfileRegistryEntry> {
  if (!Array.isArray(registry) || registry.length === 0) {
    throw new TypeError('profile registry must contain at least one profile')
  }
  const byLabel = new Map<string, ProfileRegistryEntry>()
  for (const entry of registry) {
    if (!isRecord(entry) || typeof entry.label !== 'string' || !PROFILE_LABEL.test(entry.label)) {
      throw new TypeError('profile registry labels must be safe and bounded')
    }
    if (entry.shared !== undefined && typeof entry.shared !== 'boolean') {
      throw new TypeError(`profile ${entry.label} shared must be boolean`)
    }
    if (byLabel.has(entry.label)) throw new TypeError(`duplicate profile registry label: ${entry.label}`)
    byLabel.set(entry.label, { label: entry.label, shared: entry.shared === true })
  }
  return byLabel
}

export function validateProfileRegistry(
  registry: readonly ProfileRegistryEntry[],
): readonly ProfileRegistryEntry[] {
  return [...validateRegistry(registry).values()]
}

export function validateProfilePool(
  registry: readonly ProfileRegistryEntry[],
  declaration: ProfilePoolDeclaration,
): ValidatedProfilePool {
  const byLabel = validateRegistry(registry)
  if (!isRecord(declaration) || !Array.isArray(declaration.profiles) || declaration.profiles.length === 0) {
    throw new TypeError('profile pool must contain at least one ordered profile')
  }
  const profiles: string[] = []
  const seen = new Set<string>()
  for (const label of declaration.profiles) {
    if (typeof label !== 'string' || !PROFILE_LABEL.test(label)) {
      throw new TypeError('profile pool labels must be safe and bounded')
    }
    if (!byLabel.has(label)) throw new TypeError(`profile pool references unknown profile: ${label}`)
    if (seen.has(label)) throw new TypeError(`duplicate profile in pool: ${label}`)
    seen.add(label)
    profiles.push(label)
  }
  const thresholdPercent = declaration.thresholdPercent ?? DEFAULT_ROTATION_THRESHOLD_PERCENT
  if (
    typeof thresholdPercent !== 'number'
    || !Number.isFinite(thresholdPercent)
    || thresholdPercent <= 0
    || thresholdPercent > 100
  ) throw new TypeError('profile pool thresholdPercent must be greater than 0 and at most 100')
  return { profiles, thresholdPercent }
}

function unknownTelemetry(
  reason: UnknownTelemetryReason,
  candidate: TokenCountCandidate | null,
  observedAtMs: number | null = null,
): UnknownQuotaTelemetry {
  return {
    status: 'unknown',
    reason,
    observedAtMs,
    physicalLine: candidate?.physicalLine ?? null,
  }
}

function latestPhysicalTokenCount(jsonl: string): TokenCountCandidate | null {
  let candidate: TokenCountCandidate | null = null
  const lines = jsonl.split(/\r?\n/)
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!.trim()
    if (!line) continue
    let parsed: unknown
    try {
      parsed = JSON.parse(line)
    } catch {
      // A partially written final token_count must suppress an older snapshot.
      if (TOKEN_COUNT_MARKER.test(line)) candidate = { kind: 'malformed', physicalLine: index + 1 }
      continue
    }
    if (
      isRecord(parsed)
      && parsed.type === 'event_msg'
      && isRecord(parsed.payload)
      && parsed.payload.type === 'token_count'
    ) candidate = { kind: 'parsed', physicalLine: index + 1, value: parsed }
  }
  return candidate
}

function parseWindow(value: unknown): QuotaWindowSnapshot | null | 'malformed' | 'unrecognized' {
  if (value === null || value === undefined) return null
  if (!isRecord(value)) return 'malformed'
  const windowMinutes = value.window_minutes
  const usedPercent = value.used_percent
  const resetsAt = value.resets_at
  if (
    typeof windowMinutes !== 'number'
    || !Number.isInteger(windowMinutes)
    || windowMinutes <= 0
    || typeof usedPercent !== 'number'
    || !Number.isFinite(usedPercent)
    || usedPercent < 0
    || usedPercent > 100
    || typeof resetsAt !== 'number'
    || !Number.isSafeInteger(resetsAt)
    || resetsAt <= 0
    || !Number.isSafeInteger(resetsAt * 1_000)
  ) return 'malformed'
  if (!TARGET_WINDOWS.has(windowMinutes)) return 'unrecognized'
  return {
    windowMinutes: windowMinutes as QuotaWindowMinutes,
    usedPercent,
    resetsAtMs: resetsAt * 1_000,
  }
}

/**
 * Parse the physically last persisted token_count event. Embedded timestamps are
 * freshness evidence only; they never reorder append-only JSONL records.
 */
export function parseRolloutTelemetry(
  jsonl: string,
  nowMs = Date.now(),
  maxAgeMs = MAX_TELEMETRY_AGE_MS,
): QuotaTelemetry {
  if (typeof jsonl !== 'string' || !Number.isFinite(nowMs) || maxAgeMs < 0 || !Number.isFinite(maxAgeMs)) {
    throw new TypeError('rollout telemetry inputs are invalid')
  }
  const candidate = latestPhysicalTokenCount(jsonl)
  if (!candidate) return unknownTelemetry('no_token_count', null)
  if (candidate.kind === 'malformed') return unknownTelemetry('malformed', candidate)

  const timestamp = candidate.value.timestamp
  if (typeof timestamp !== 'string') return unknownTelemetry('malformed', candidate)
  const observedAtMs = Date.parse(timestamp)
  if (!Number.isFinite(observedAtMs)) return unknownTelemetry('malformed', candidate)
  if (observedAtMs > nowMs) return unknownTelemetry('stale', candidate, observedAtMs)
  if (nowMs - observedAtMs > maxAgeMs) return unknownTelemetry('stale', candidate, observedAtMs)

  const payload = candidate.value.payload
  if (!isRecord(payload)) return unknownTelemetry('malformed', candidate, observedAtMs)
  if (payload.rate_limits === null) return unknownTelemetry('rate_limits_null', candidate, observedAtMs)
  if (!isRecord(payload.rate_limits)) return unknownTelemetry('incomplete', candidate, observedAtMs)

  const windows = [
    parseWindow(payload.rate_limits.primary),
    parseWindow(payload.rate_limits.secondary),
  ]
  if (windows.includes('malformed')) return unknownTelemetry('malformed', candidate, observedAtMs)
  const parsedWindows = windows.filter(
    (window): window is QuotaWindowSnapshot => typeof window === 'object' && window !== null,
  )
  const fiveHour = parsedWindows.filter(window => window.windowMinutes === FIVE_HOUR_WINDOW_MINUTES)
  const weekly = parsedWindows.filter(window => window.windowMinutes === WEEKLY_WINDOW_MINUTES)
  if (fiveHour.length > 1 || weekly.length > 1) {
    return unknownTelemetry('malformed', candidate, observedAtMs)
  }
  if (fiveHour.length === 0 && weekly.length === 0) {
    return unknownTelemetry('incomplete', candidate, observedAtMs)
  }
  return {
    status: 'fresh',
    observedAtMs,
    physicalLine: candidate.physicalLine,
    fiveHour: fiveHour[0] ?? null,
    weekly: weekly[0] ?? null,
  }
}

export function decideSoftCooldown(
  telemetry: QuotaTelemetry,
  thresholdPercent = DEFAULT_ROTATION_THRESHOLD_PERCENT,
  nowMs = Date.now(),
): SoftCooldownDecision {
  if (
    !Number.isFinite(thresholdPercent)
    || thresholdPercent <= 0
    || thresholdPercent > 100
    || !Number.isFinite(nowMs)
  ) throw new TypeError('soft cooldown inputs are invalid')
  if (telemetry.status !== 'fresh') {
    return { trigger: false, cooldownUntilMs: null, breachedWindows: [] }
  }
  const breached = [telemetry.fiveHour, telemetry.weekly]
    .filter((window): window is QuotaWindowSnapshot => window !== null)
    .filter(window => window.usedPercent >= thresholdPercent && window.resetsAtMs > nowMs)
  if (breached.length === 0) {
    return { trigger: false, cooldownUntilMs: null, breachedWindows: [] }
  }
  return {
    trigger: true,
    cooldownUntilMs: Math.max(...breached.map(window => window.resetsAtMs)),
    breachedWindows: breached.map(window => window.windowMinutes),
  }
}

function normalizedErrorCode(value: string): string {
  return value.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')
}

function parsedResetMs(value: unknown): number | null {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) {
    return value < 1_000_000_000_000 ? value * 1_000 : value
  }
  if (typeof value !== 'string' || value.length > 128) return null
  if (/^\d{10,13}$/.test(value)) return parsedResetMs(Number(value))
  const parsed = Date.parse(value)
  return Number.isFinite(parsed) ? parsed : null
}

function hardFailureEvidence(error: unknown): { hard: boolean; resets: number[] } {
  let hard = false
  const resets: number[] = []
  const seen = new Set<object>()
  const hardCodes = new Set([
    'rate_limit_exceeded',
    'rate_limit_reached',
    'usage_limit_exceeded',
    'usage_limit_reached',
    'too_many_requests',
    'insufficient_quota',
    'workspace_owner_credits_depleted',
    'workspace_member_credits_depleted',
    'workspace_owner_usage_limit_reached',
    'workspace_member_usage_limit_reached',
    'usagelimitexceeded',
  ])
  const inspectText = (text: string): void => {
    const bounded = text.slice(0, 4_096)
    const code = normalizedErrorCode(bounded)
    if (
      hardCodes.has(code)
      || /\b(?:you(?:'ve| have)? hit|hit|reached|exceeded) (?:your |the )?(?:usage|rate) limit\b/i.test(bounded)
      || /\b(?:usage|rate)[ _-]?limit(?:ed)? (?:reached|exceeded)\b/i.test(bounded)
      || /\b(?:workspace is )?out of credits\b/i.test(bounded)
      || /\b429\s+too many requests\b/i.test(bounded)
      || /\bhttp(?:\s+status)?[^\r\n]{0,48}\b429\b/i.test(bounded)
    ) hard = true
  }
  const visit = (value: unknown, key: string | null, depth: number): void => {
    if (depth > 5 || value === null || value === undefined) return
    if (key && /^(?:resets_at|reset_at|resetsAt|resetAt|resets_at_ms|reset_at_ms|resetsAtMs|resetAtMs)$/.test(key)) {
      const reset = parsedResetMs(value)
      if (reset !== null) resets.push(reset)
    }
    if (typeof value === 'string') {
      if (key === null || /^(?:code|type|message|error|errorInfo|detail|reason)$/.test(key)) inspectText(value)
      return
    }
    if (typeof value === 'boolean') {
      if (key === 'quotaLimited' && value) hard = true
      return
    }
    if (typeof value === 'number') {
      if (/^(?:status|statusCode|httpStatus|http_status|http_status_code)$/.test(key ?? '') && value === 429) {
        hard = true
      }
      return
    }
    if (typeof value !== 'object' || seen.has(value)) return
    seen.add(value)
    if (value instanceof Error) {
      inspectText(value.name)
      inspectText(value.message)
      visit(value.cause, 'error', depth + 1)
    }
    if (Array.isArray(value)) {
      for (const item of value.slice(0, 32)) visit(item, key, depth + 1)
      return
    }
    for (const [childKey, child] of Object.entries(value).slice(0, 64)) {
      visit(child, childKey, depth + 1)
    }
  }
  visit(error, null, 0)
  return { hard, resets }
}

export function decideHardLimitCooldown(
  error: unknown,
  nowMs = Date.now(),
  fallbackWindowMinutes: QuotaWindowMinutes = FIVE_HOUR_WINDOW_MINUTES,
): HardLimitDecision {
  if (!Number.isFinite(nowMs) || !TARGET_WINDOWS.has(fallbackWindowMinutes)) {
    throw new TypeError('hard cooldown inputs are invalid')
  }
  const evidence = hardFailureEvidence(error)
  if (!evidence.hard) {
    return { hardLimit: false, requeue: false, cooldownUntilMs: null, cooldownSource: null }
  }
  const futureResets = evidence.resets.filter(reset => reset > nowMs)
  if (futureResets.length > 0) {
    return {
      hardLimit: true,
      requeue: true,
      cooldownUntilMs: Math.max(...futureResets),
      cooldownSource: 'known_reset',
    }
  }
  return {
    hardLimit: true,
    requeue: true,
    cooldownUntilMs: nowMs + fallbackWindowMinutes * 60 * 1_000,
    cooldownSource: 'full_window_fallback',
  }
}

export function profileHeadroom(telemetry: QuotaTelemetry): number | null {
  if (telemetry.status !== 'fresh') return null
  const windows = [telemetry.fiveHour, telemetry.weekly]
    .filter((window): window is QuotaWindowSnapshot => window !== null)
  return windows.length === 0 ? null : 100 - Math.max(...windows.map(window => window.usedPercent))
}

function validateSwarmName(swarmName: string): void {
  if (typeof swarmName !== 'string' || !SWARM_NAME.test(swarmName)) {
    throw new TypeError('swarm name must be safe and bounded')
  }
}

function validateLeaseMap(leases: LeaseMap, registry: Map<string, ProfileRegistryEntry>): void {
  const exclusiveOwners = new Map<string, string>()
  for (const [swarm, profile] of Object.entries(leases)) {
    validateSwarmName(swarm)
    const entry = registry.get(profile)
    if (!entry) throw new TypeError(`lease references unknown profile: ${profile}`)
    if (!entry.shared) {
      const owner = exclusiveOwners.get(profile)
      if (owner) throw new TypeError(`exclusive profile ${profile} is leased by both ${owner} and ${swarm}`)
      exclusiveOwners.set(profile, swarm)
    }
  }
}

export function allocateProfileLease(
  leases: LeaseMap,
  registryEntries: readonly ProfileRegistryEntry[],
  swarmName: string,
  profile: string,
): LeaseMap {
  validateSwarmName(swarmName)
  const registry = validateRegistry(registryEntries)
  validateLeaseMap(leases, registry)
  const entry = registry.get(profile)
  if (!entry) throw new TypeError(`cannot lease unknown profile: ${profile}`)
  if (!entry.shared) {
    const conflict = Object.entries(leases).find(([swarm, leased]) => swarm !== swarmName && leased === profile)
    if (conflict) throw new Error(`profile ${profile} is exclusively leased by ${conflict[0]}`)
  }
  return { ...leases, [swarmName]: profile }
}

export function chooseProfileForSwarm(options: Readonly<{
  registry: readonly ProfileRegistryEntry[]
  pool: ProfilePoolDeclaration
  leases: LeaseMap
  swarmName: string
  telemetry: Readonly<Record<string, QuotaTelemetry>>
  cooldowns: Readonly<Record<string, number>>
  nowMs?: number
  excludeProfiles?: readonly string[]
}>): ProfileChoice {
  const nowMs = options.nowMs ?? Date.now()
  if (!Number.isFinite(nowMs)) throw new TypeError('profile selection nowMs is invalid')
  validateSwarmName(options.swarmName)
  const registry = validateRegistry(options.registry)
  const pool = validateProfilePool(options.registry, options.pool)
  validateLeaseMap(options.leases, registry)
  const excluded = new Set(options.excludeProfiles ?? [])
  const unavailable: ProfileUnavailable[] = []
  const candidates: Array<{ profile: string; headroomPercent: number | null; order: number }> = []

  for (let order = 0; order < pool.profiles.length; order += 1) {
    const profile = pool.profiles[order]!
    if (excluded.has(profile)) continue
    const rawCooldown = options.cooldowns[profile]
    if (rawCooldown !== undefined && (!Number.isFinite(rawCooldown) || rawCooldown < 0)) {
      throw new TypeError(`invalid cooldown for profile: ${profile}`)
    }
    if (rawCooldown !== undefined && rawCooldown > nowMs) {
      unavailable.push({ profile, reason: 'cooling', untilMs: rawCooldown })
      continue
    }
    const entry = registry.get(profile)!
    if (
      !entry.shared
      && Object.entries(options.leases).some(([swarm, leased]) => swarm !== options.swarmName && leased === profile)
    ) {
      unavailable.push({ profile, reason: 'leased', untilMs: null })
      continue
    }
    const telemetry = options.telemetry[profile]
    if (telemetry) {
      const soft = decideSoftCooldown(telemetry, pool.thresholdPercent, nowMs)
      if (soft.trigger) {
        unavailable.push({ profile, reason: 'soft_limit', untilMs: soft.cooldownUntilMs })
        continue
      }
    }
    candidates.push({
      profile,
      headroomPercent: telemetry ? profileHeadroom(telemetry) : null,
      order,
    })
  }
  candidates.sort((left, right) => {
    if (left.headroomPercent === null && right.headroomPercent !== null) return 1
    if (left.headroomPercent !== null && right.headroomPercent === null) return -1
    if (left.headroomPercent !== null && right.headroomPercent !== null) {
      const headroom = right.headroomPercent - left.headroomPercent
      if (headroom !== 0) return headroom
    }
    return left.order - right.order
  })
  const selected = candidates[0]
  if (selected) {
    return {
      kind: 'selected',
      profile: selected.profile,
      headroomPercent: selected.headroomPercent,
      unavailable,
    }
  }
  const resetCandidates = unavailable
    .map(item => item.untilMs)
    .filter((until): until is number => until !== null && until > nowMs)
  return {
    kind: 'exhausted',
    resumeAtMs: resetCandidates.length > 0 ? Math.min(...resetCandidates) : null,
    unavailable,
  }
}

export function leasesFromHarnessState(state: RotationHarnessState): LeaseMap {
  const leases: Record<string, string> = {}
  for (const [swarm, swarmState] of Object.entries(state.swarms)) {
    validateSwarmName(swarm)
    if (swarmState.activeProfile !== null) leases[swarm] = swarmState.activeProfile
  }
  return leases
}

/** Rotate exactly one swarm after its active task has ended. Other swarm objects are untouched. */
export function rotateSwarmProfile(options: Readonly<{
  state: RotationHarnessState
  registry: readonly ProfileRegistryEntry[]
  pool: ProfilePoolDeclaration
  swarmName: string
  coolingProfile: string
  cooldownUntilMs: number
  nowMs?: number
}>): SwarmRotationResult {
  const nowMs = options.nowMs ?? Date.now()
  validateSwarmName(options.swarmName)
  const current = options.state.swarms[options.swarmName]
  if (!current) throw new Error(`unknown swarm rotation state: ${options.swarmName}`)
  if (current.activeProfile !== options.coolingProfile) {
    throw new Error('rotation may cool only the triggering swarm active profile')
  }
  if (!Number.isFinite(options.cooldownUntilMs) || options.cooldownUntilMs <= nowMs) {
    throw new TypeError('rotation cooldown must end in the future')
  }
  const targetState: SwarmProfileState = {
    ...current,
    cooldowns: { ...current.cooldowns, [options.coolingProfile]: options.cooldownUntilMs },
  }
  const choice = chooseProfileForSwarm({
    registry: options.registry,
    pool: options.pool,
    leases: leasesFromHarnessState(options.state),
    swarmName: options.swarmName,
    telemetry: targetState.telemetry,
    cooldowns: targetState.cooldowns,
    nowMs,
  })
  const activeProfile = choice.kind === 'selected' ? choice.profile : null
  const nextTarget: SwarmProfileState = { ...targetState, activeProfile }
  return {
    state: {
      ...options.state,
      swarms: { ...options.state.swarms, [options.swarmName]: nextTarget },
    },
    previousProfile: options.coolingProfile,
    activeProfile,
    parked: choice.kind === 'exhausted',
    resumeAtMs: choice.kind === 'exhausted' ? choice.resumeAtMs : null,
    choice,
  }
}
