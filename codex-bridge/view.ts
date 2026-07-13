#!/usr/bin/env bun
/** Read-only operator view for the bounded/redacted events.jsonl feed. */

import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { StringDecoder } from 'string_decoder'
import type { BridgeEvent } from './events.ts'

export const MAX_EVENT_FILE_WINDOW_BYTES = 1024 * 1024
export const MAX_EVENT_READ_BYTES = 64 * 1024
export const MAX_EVENT_LINE_BYTES = 4 * 1024
export const MAX_EVENTS_PER_READ = 256

/** Remove terminal commands and control characters before writing one display line. */
export function stripTerminalControls(value: string, maxChars = 256): string {
  const input = value.slice(0, Math.max(maxChars * 8, 4096))
  let output = ''
  let index = 0
  const skipStringSequence = (start: number): number => {
    let cursor = start
    while (cursor < input.length) {
      const code = input.charCodeAt(cursor)
      if (code === 0x07 || code === 0x9c) return cursor + 1
      if (code === 0x1b && input.charCodeAt(cursor + 1) === 0x5c) return cursor + 2
      cursor++
    }
    return cursor
  }
  const skipCsi = (start: number): number => {
    let cursor = start
    while (cursor < input.length) {
      const code = input.charCodeAt(cursor++)
      if (code >= 0x40 && code <= 0x7e) break
    }
    return cursor
  }
  while (index < input.length) {
    const code = input.charCodeAt(index)
    if (code === 0x1b) {
      const next = input.charCodeAt(index + 1)
      if (next === 0x5b) index = skipCsi(index + 2)
      else if ([0x50, 0x58, 0x5d, 0x5e, 0x5f].includes(next)) {
        index = skipStringSequence(index + 2)
      } else {
        index += 1
        while (index < input.length && input.charCodeAt(index) >= 0x20
          && input.charCodeAt(index) <= 0x2f) index++
        if (index < input.length) index++
      }
      continue
    }
    if (code === 0x9b) {
      index = skipCsi(index + 1)
      continue
    }
    if ([0x90, 0x98, 0x9d, 0x9e, 0x9f].includes(code)) {
      index = skipStringSequence(index + 1)
      continue
    }
    if (code <= 0x1f || (code >= 0x7f && code <= 0x9f)) {
      index++
      continue
    }
    output += input[index++]
  }
  // Unicode format controls include bidi overrides that can spoof an operator line.
  return [...output.replace(/[\p{Cc}\p{Cf}]/gu, '')].slice(0, maxChars).join('')
}

function field(value: unknown, fallback: string, maxChars = 256): string {
  if (typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean') {
    return fallback
  }
  const sanitized = stripTerminalControls(String(value), maxChars)
  return sanitized || fallback
}

export function formatBridgeEvent(event: BridgeEvent): string {
  const timestamp = field(event?.ts, '?', 64)
  const time = timestamp.length >= 19 ? timestamp.slice(11, 19) : timestamp
  const type = field(event?.type, 'unknown', 100)
  switch (event.type) {
    case 'daemon.started':
    case 'daemon.ready':
    case 'daemon.shutdown':
      return `${time} ${type}`
    case 'queue.changed':
      return `${time} queue waiting=${field(event.waiting, '0')} active=${field(event.active, 'false')}`
    case 'turn.queued':
      return `${time} queued chat=${field(event.chat_id, '?')} message=${field(event.message_id, '?')}`
    case 'turn.started':
      return `${time} turn started chat=${field(event.chat_id, '?')} thread=${field(event.thread_id, 'new')}`
    case 'turn.completed':
      return `${time} turn completed chat=${field(event.chat_id, '?')} status=${field(event.status, 'unknown')}`
    case 'turn.error':
      return `${time} turn error chat=${field(event.chat_id, '?')} kind=${field(event.error_kind, 'unknown')}`
    case 'git.queued':
    case 'git.started':
      return `${time} ${type} action=${field(event.action, '?')}`
    case 'git.completed':
      return `${time} git completed action=${field(event.action, '?')} status=${field(event.status, 'unknown')}`
    case 'git.error':
    case 'git.rejected':
      return `${time} ${type} kind=${field(event.error_kind, 'unknown')}`
    case 'codex.event': {
      const item = event.item_type ? ` item=${field(event.item_type, '?')}` : ''
      const status = event.status ? ` status=${field(event.status, 'unknown')}` : ''
      return `${time} codex ${field(event.event_type, 'event')}${item}${status}`
    }
    default:
      return `${time} ${type}`
  }
}

export class EventFileReader {
  private offset = 0
  private inode: bigint | undefined
  private device: bigint | undefined
  private fd: number | undefined
  private pending = ''
  private decoder = new StringDecoder('utf8')
  private discardingOversizedLine = false

  constructor(private readonly expectedUid = process.getuid?.()) {}

  readNew(file: string): BridgeEvent[] {
    const stat = lstatSync(file, { bigint: true })
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('event log must be a regular non-symlink file')
    if (
      this.expectedUid === undefined
      || stat.uid !== BigInt(this.expectedUid)
      || (stat.mode & 0o777n) !== 0o600n
    ) throw new Error('event log must be owned by the viewer uid and mode 0600')
    if (stat.size > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('event log is too large to address safely')
    if (this.inode !== undefined && (
      stat.ino !== this.inode || stat.dev !== this.device || stat.size < BigInt(this.offset)
    )) {
      this.reset()
    }
    if (this.fd === undefined) {
      const fd = openSync(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
      const opened = fstatSync(fd, { bigint: true })
      if (
        !opened.isFile()
        || opened.ino !== stat.ino
        || opened.dev !== stat.dev
        || opened.uid !== stat.uid
        || opened.mode !== stat.mode
      ) {
        closeSync(fd)
        throw new Error('event log changed while opening')
      }
      this.fd = fd
      this.inode = opened.ino
      this.device = opened.dev
    }

    const size = Number(stat.size)
    const earliest = Math.max(0, size - MAX_EVENT_FILE_WINDOW_BYTES)
    if (this.offset < earliest) {
      this.offset = earliest
      this.pending = ''
      this.decoder = new StringDecoder('utf8')
      this.discardingOversizedLine = earliest > 0
    }

    const events = this.drainPending(MAX_EVENTS_PER_READ)
    if (events.length >= MAX_EVENTS_PER_READ) return events
    const remaining = size - this.offset
    if (remaining <= 0) return events
    const length = Math.min(remaining, MAX_EVENT_READ_BYTES)
    const buffer = Buffer.allocUnsafe(length)
    const bytes = readSync(this.fd, buffer, 0, length, this.offset)
    if (bytes <= 0) return events
    this.offset += bytes
    this.pending += this.decoder.write(buffer.subarray(0, bytes))
    events.push(...this.drainPending(MAX_EVENTS_PER_READ - events.length))
    return events
  }

  private drainPending(limit: number): BridgeEvent[] {
    const events: BridgeEvent[] = []
    while (events.length < limit) {
      const newline = this.pending.indexOf('\n')
      if (newline < 0) break
      const line = this.pending.slice(0, newline)
      this.pending = this.pending.slice(newline + 1)
      if (this.discardingOversizedLine) {
        this.discardingOversizedLine = false
        continue
      }
      if (!line || Buffer.byteLength(line) > MAX_EVENT_LINE_BYTES) continue
      try {
        const value: unknown = JSON.parse(line)
        if (
          value !== null
          && typeof value === 'object'
          && !Array.isArray(value)
          && typeof (value as Record<string, unknown>).type === 'string'
          && typeof (value as Record<string, unknown>).ts === 'string'
        ) events.push(value as BridgeEvent)
      } catch {}
    }
    if (!this.pending.includes('\n') && Buffer.byteLength(this.pending) > MAX_EVENT_LINE_BYTES) {
      this.pending = ''
      this.discardingOversizedLine = true
    }
    return events
  }

  close(): void {
    this.reset()
  }

  private reset(): void {
    if (this.fd !== undefined) {
      try { closeSync(this.fd) } catch {}
    }
    this.fd = undefined
    this.inode = undefined
    this.device = undefined
    this.offset = 0
    this.pending = ''
    this.decoder = new StringDecoder('utf8')
    this.discardingOversizedLine = false
  }
}

export async function followEventLog(file: string, pollMs = 500): Promise<never> {
  const reader = new EventFileReader()
  let lastError = ''
  let lastReportedAt = 0
  for (;;) {
    try {
      for (const event of reader.readNew(file)) {
        process.stdout.write(formatBridgeEvent(event) + '\n')
      }
      lastError = ''
    } catch (err) {
      const detail = stripTerminalControls(err instanceof Error ? err.message : String(err), 500)
        || 'unknown event-log read failure'
      const now = Date.now()
      if (detail !== lastError || now - lastReportedAt >= 5_000) {
        process.stderr.write(`codex-bridge view: ${detail}\n`)
        lastError = detail
        lastReportedAt = now
      }
    }
    await Bun.sleep(pollMs)
  }
}

if (import.meta.main) {
  const stateDir = process.argv[2]
    ?? process.env.DISCORD_STATE_DIR
    ?? join(homedir(), '.codex', 'channels', 'discord')
  const eventFile = join(stateDir, 'events.jsonl')
  process.stdout.write(`codex-bridge events: ${stripTerminalControls(eventFile, 1024)}\n`)
  await followEventLog(eventFile)
}
