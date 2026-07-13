import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import {
  appendFileSync,
  chmodSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { BoundedEventLog } from './events.ts'
import {
  EventFileReader,
  formatBridgeEvent,
  MAX_EVENT_FILE_WINDOW_BYTES,
  MAX_EVENT_LINE_BYTES,
  MAX_EVENTS_PER_READ,
} from './view.ts'

describe('bounded operator events', () => {
  let dir: string
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'codex-events-')) })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))

  test('allows only redacted metadata fields', () => {
    const log = new BoundedEventLog(dir)
    log.emit('turn.started', {
      chat_id: 'chat-1',
      status: 'running',
      prompt: 'must never be logged',
      token: 'must never be logged',
    })
    const line = readFileSync(join(dir, 'events.jsonl'), 'utf8')
    expect(line).toContain('chat-1')
    expect(line).not.toContain('must never be logged')
    expect(line).not.toContain('prompt')
    expect(line).not.toContain('token')
  })

  test('rotates before exceeding the configured bound', () => {
    const log = new BoundedEventLog(dir, 1024)
    for (let i = 0; i < 100; i++) log.emit('codex.event', { event_type: `item-${i}` })
    expect(readFileSync(join(dir, 'events.jsonl'), 'utf8').length).toBeLessThanOrEqual(1024)
    expect(readFileSync(join(dir, 'events.jsonl.1'), 'utf8').length).toBeGreaterThan(0)
  })

  test('view renders concise lifecycle and tool lines', () => {
    expect(formatBridgeEvent({
      ts: '2026-07-11T12:34:56.000Z', type: 'codex.event',
      event_type: 'item.completed', item_type: 'command_execution', status: 'completed',
    })).toBe('12:34:56 codex item.completed item=command_execution status=completed')
    expect(formatBridgeEvent({
      ts: '2026-07-11T12:34:56.000Z', type: 'git.completed',
      action: 'commit', status: 'ok',
    })).toBe('12:34:56 git completed action=commit status=ok')
  })

  test('view strips CSI, OSC, C0/C1, and bidi controls from every terminal field', () => {
    const rendered = formatBridgeEvent({
      ts: '2026-07-11T12:34:56.000Z',
      type: 'codex.event',
      event_type: '\x1b]8;;https://example.invalid\x07click\x1b]8;;\x07\x1b[31mred\x1b[0m',
      item_type: '\x9b32mcommand\x9b0m\nexecution',
      status: 'com\u202epleted',
    })
    expect(rendered).toBe('12:34:56 codex clickred item=commandexecution status=completed')
    expect(rendered).not.toMatch(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/)
    expect(formatBridgeEvent({
      ts: '2026-07-11T12:34:56.000Z', type: 'queue.changed',
      waiting: '\x1b[31m7\x1b[0m', active: '\x1b]0;spoof\x07false',
    })).toBe('12:34:56 queue waiting=7 active=false')
  })

  test('reader consumes only appended bytes and resets across rotation with UTF-8', () => {
    const file = join(dir, 'events.jsonl')
    const reader = new EventFileReader()
    writeFileSync(
      file,
      JSON.stringify({ ts: '2026-07-11T00:00:00Z', type: 'codex.event', item_type: 'café' }) + '\n',
      { mode: 0o600 },
    )
    expect(reader.readNew(file).map(event => event.item_type)).toEqual(['café'])
    expect(reader.readNew(file)).toEqual([])
    appendFileSync(file, JSON.stringify({ ts: '2026-07-11T00:00:01Z', type: 'turn.completed' }) + '\n')
    expect(reader.readNew(file).map(event => event.type)).toEqual(['turn.completed'])
    renameSync(file, `${file}.1`)
    writeFileSync(
      file,
      JSON.stringify({ ts: '2026-07-11T00:00:02Z', type: 'daemon.ready' }) + '\n',
      { mode: 0o600 },
    )
    expect(reader.readNew(file).map(event => event.type)).toEqual(['daemon.ready'])
    reader.close()
  })

  test('reader bounds oversized files, lines, read batches, and resumes at valid events', () => {
    const file = join(dir, 'events.jsonl')
    const valid = JSON.stringify({ ts: '2026-07-11T00:00:02Z', type: 'daemon.ready' })
    writeFileSync(file, `${'x'.repeat(MAX_EVENT_FILE_WINDOW_BYTES * 2)}\n${valid}\n`, { mode: 0o600 })
    const reader = new EventFileReader()
    const observed = []
    for (let index = 0; index < 24; index++) observed.push(...reader.readNew(file))
    expect(observed.map(event => event.type)).toEqual(['daemon.ready'])

    writeFileSync(file, `${'x'.repeat(MAX_EVENT_LINE_BYTES + 1)}\n${valid}\n`, { mode: 0o600 })
    expect(reader.readNew(file).map(event => event.type)).toEqual(['daemon.ready'])

    renameSync(file, `${file}.oversized-line`)
    writeFileSync(file, Array.from({ length: MAX_EVENTS_PER_READ + 20 }, (_, index) =>
      JSON.stringify({ ts: '2026-07-11T00:00:02Z', type: `event.${index}` }),
    ).join('\n') + '\n', { mode: 0o600 })
    expect(reader.readNew(file)).toHaveLength(MAX_EVENTS_PER_READ)
    expect(reader.readNew(file)).toHaveLength(20)
    reader.close()
  })

  test('reader rejects wrong-mode and symlinked event files', () => {
    const file = join(dir, 'events.jsonl')
    writeFileSync(file, '{"ts":"2026-07-11T00:00:00Z","type":"daemon.ready"}\n', { mode: 0o600 })
    const uid = process.getuid?.() ?? 501
    expect(() => new EventFileReader(uid + 1).readNew(file)).toThrow('viewer uid')
    chmodSync(file, 0o644)
    expect(() => new EventFileReader().readNew(file)).toThrow('mode 0600')
    rmSync(file)
    const target = join(dir, 'target.jsonl')
    writeFileSync(target, '{}\n', { mode: 0o600 })
    symlinkSync(target, file)
    expect(() => new EventFileReader().readNew(file)).toThrow('non-symlink')
  })
})
