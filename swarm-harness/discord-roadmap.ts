import {
  RUNTIME_PARITY_MATRIX_PATH,
  parseRoadmap,
  type RoadmapDocument,
  type RoadmapItem,
} from './roadmap.ts'

export const ROADMAP_QUERY_COMMAND = '!watcher roadmap' as const
export const DEFAULT_DISCORD_ROADMAP_LIMIT = 1800

type DigestDelivery = (message: string) => Promise<void> | void

function orderedItems(document: RoadmapDocument): Array<[string, RoadmapItem]> {
  return Object.entries(document.items).sort(([a], [b]) => a.localeCompare(b))
}

function capLines(lines: string[], maxChars: number): string {
  if (!Number.isSafeInteger(maxChars) || maxChars < 200 || maxChars > 2000) {
    throw new Error('roadmap Discord limit is invalid')
  }
  const kept: string[] = []
  let length = 0
  for (const line of lines) {
    const addition = (kept.length ? 1 : 0) + line.length
    if (length + addition > maxChars - 2) {
      if (kept.at(-1) !== '…') kept.push('…')
      break
    }
    kept.push(line)
    length += addition
  }
  return kept.join('\n')
}

function activityDay(value: string): string {
  return value.slice(0, 10)
}

function milliseconds(value: number): string {
  const sign = value < 0 ? '-' : ''
  const magnitude = Math.abs(value)
  if (magnitude < 1000) return `${sign}${magnitude}ms`
  const seconds = Math.round(magnitude / 100) / 10
  return `${sign}${seconds}s`
}

function groundingLine(dr: string, item: RoadmapItem): string | null {
  const current = item.grounding.latest_ms
  if (current === null) return null
  const prior = item.grounding.previous_ms
  const comparison = prior === null
    ? ''
    : ` · was ${milliseconds(prior)} (${item.grounding.delta_ms! > 0 ? '+' : ''}${milliseconds(item.grounding.delta_ms!)})`
  const gaps = item.grounding.gap_reports > 0 ? ` · gaps ${item.grounding.gap_reports}` : ''
  return `${dr} · ${item.owning_swarm} · ${milliseconds(current)}${comparison}${gaps}`
}

/** On-demand, phone-readable view. It consumes only a strictly parsed artifact. */
export function formatRoadmapQuery(
  input: RoadmapDocument,
  options: { maxChars?: number, maxItems?: number } = {},
): string {
  const document = parseRoadmap(input)
  const maxItems = options.maxItems ?? 24
  if (!Number.isSafeInteger(maxItems) || maxItems < 1 || maxItems > 100) throw new Error('roadmap item limit is invalid')
  const rows = orderedItems(document)
  const lines = ['🧭 Roadmap', `Parity · ${RUNTIME_PARITY_MATRIX_PATH}`]
  if (rows.length === 0) lines.push('No harness-derived items yet.')
  for (const [dr, item] of rows.slice(0, maxItems)) {
    const result = item.last_result_status ? ` · ${item.last_result_status}` : ''
    lines.push(`${dr} · ${item.status} · ${item.owning_swarm}${result} · ${activityDay(item.last_activity)}`)
  }
  if (rows.length > maxItems) lines.push(`… ${rows.length - maxItems} more`)
  return capLines(lines, options.maxChars ?? DEFAULT_DISCORD_ROADMAP_LIMIT)
}

function resultTotal(item: RoadmapItem): number {
  return Object.values(item.result_sets).reduce((sum, value) => sum + value, 0)
}

/** Scheduled digest: moved, blocked, next, and measured grounding deltas. */
export function formatRoadmapDigest(
  currentInput: RoadmapDocument,
  previousInput: RoadmapDocument | null = null,
  options: { maxChars?: number, maxPerSection?: number } = {},
): string {
  const current = parseRoadmap(currentInput)
  const previous = previousInput ? parseRoadmap(previousInput) : null
  const max = options.maxPerSection ?? 6
  if (!Number.isSafeInteger(max) || max < 1 || max > 20) throw new Error('roadmap digest section limit is invalid')

  const moved: string[] = []
  for (const [dr, item] of orderedItems(current)) {
    const prior = previous?.items[dr]
    if (!prior) moved.push(`${dr} · NEW→${item.status} · ${item.owning_swarm}`)
    else if (prior.status !== item.status) moved.push(`${dr} · ${prior.status}→${item.status} · ${item.owning_swarm}`)
    else if (resultTotal(prior) !== resultTotal(item)) {
      moved.push(`${dr} · result ${item.last_result_status ?? 'landed'} · ${item.owning_swarm}`)
    }
  }
  const blocked = orderedItems(current)
    .filter(([, item]) => item.status === 'WAITING_FOR_OPERATOR')
    .map(([dr, item]) => `${dr} · ${item.owning_swarm}`)
  const driving = orderedItems(current)
    .filter(([, item]) => item.status === 'DRIVING')
    .sort(([, a], [, b]) => b.last_activity.localeCompare(a.last_activity))
    .map(([dr, item]) => `${dr} · ${item.owning_swarm}`)
  const grounding = orderedItems(current)
    .map(([dr, item]) => groundingLine(dr, item))
    .filter((line): line is string => line !== null)

  const section = (label: string, rows: string[]) => [
    label,
    ...(rows.length ? rows.slice(0, max) : ['—']),
    ...(rows.length > max ? [`… ${rows.length - max} more`] : []),
  ]
  const lines = [
    `📍 Roadmap digest · ${current.generated_at?.slice(0, 10) ?? 'no-events'}`,
    `Parity · ${RUNTIME_PARITY_MATRIX_PATH}`,
    ...section('Moved', moved),
    ...section('Blocked', blocked),
    ...section('Next', driving),
    ...section('Grounding', grounding),
  ]
  return capLines(lines, options.maxChars ?? DEFAULT_DISCORD_ROADMAP_LIMIT)
}

/**
 * Harness-owned scheduled delivery. A failed send advances neither the schedule
 * nor the comparison snapshot, so the same ground-truth digest remains due.
 */
export class RoadmapDigestScheduler {
  private lastDeliveredAt: number | null = null
  private previous: RoadmapDocument | null = null

  constructor(
    readonly intervalMs: number,
    private readonly deliver: DigestDelivery,
  ) {
    if (!Number.isSafeInteger(intervalMs) || intervalMs < 60_000 || intervalMs > 31 * 24 * 60 * 60 * 1000) {
      throw new Error('roadmap digest interval is invalid')
    }
  }

  due(nowMs: number): boolean {
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) throw new Error('roadmap scheduler time is invalid')
    return this.lastDeliveredAt === null || nowMs - this.lastDeliveredAt >= this.intervalMs
  }

  async tick(nowMs: number, input: RoadmapDocument): Promise<string | null> {
    const current = parseRoadmap(input)
    if (!this.due(nowMs)) return null
    const message = formatRoadmapDigest(current, this.previous)
    await this.deliver(message)
    this.previous = current
    this.lastDeliveredAt = nowMs
    return message
  }
}

/** Runtime-blind on-demand dispatcher; Discord adapters supply authorization. */
export class RoadmapDiscordSurface {
  constructor(private readonly load: () => RoadmapDocument) {}

  handle(content: string, authorized: boolean): string | null {
    if (typeof content !== 'string' || content.trim().toLowerCase() !== ROADMAP_QUERY_COMMAND) return null
    if (!authorized) return null
    return formatRoadmapQuery(this.load())
  }
}
