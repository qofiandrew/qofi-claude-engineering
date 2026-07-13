import { appendFileSync, chmodSync, mkdirSync, renameSync, statSync, writeFileSync } from 'fs'
import { join } from 'path'

export type BridgeEvent = {
  ts: string
  type: string
  [key: string]: string | number | boolean | null
}

/** Bounded, content-free JSONL operator feed. Prompts and final text never enter it. */
export class BoundedEventLog {
  readonly file: string
  readonly rotatedFile: string

  constructor(readonly stateDir: string, readonly maxBytes = 1024 * 1024) {
    if (!Number.isInteger(maxBytes) || maxBytes < 1024) throw new Error('event log limit too small')
    this.file = join(stateDir, 'events.jsonl')
    this.rotatedFile = `${this.file}.1`
    mkdirSync(stateDir, { recursive: true, mode: 0o700 })
    try { chmodSync(stateDir, 0o700) } catch {}
  }

  emit(type: string, fields: Record<string, string | number | boolean | null> = {}): void {
    try {
      const event: BridgeEvent = { ts: new Date().toISOString(), type: type.slice(0, 100) }
      const allowed = new Set([
        'pid', 'backend', 'waiting', 'active', 'chat_id', 'message_id', 'thread_id',
        'event_type', 'item_type', 'status', 'error_kind', 'action', 'path_count',
        'commit', 'branch',
        'profile', 'previous_profile', 'next_profile', 'pool', 'reason',
        'parked_until_ms', 'attempt',
        'reviewer', 'verdict', 'review_status', 'diff_hash', 'artifact_count',
      ])
      for (const [key, value] of Object.entries(fields)) {
        if (!allowed.has(key)) continue
        event[key.slice(0, 80)] = typeof value === 'string' ? value.slice(0, 256) : value
      }
      const line = JSON.stringify(event) + '\n'
      const current = (() => { try { return statSync(this.file).size } catch { return 0 } })()
      if (current + Buffer.byteLength(line) > this.maxBytes) {
        try { renameSync(this.file, this.rotatedFile) } catch {}
        writeFileSync(this.file, '', { mode: 0o600 })
      }
      appendFileSync(this.file, line, { mode: 0o600 })
    } catch {
      // Observability must never take down the bridge (for example, disk full).
    }
  }
}
