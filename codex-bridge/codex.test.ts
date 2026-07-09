import { describe, test, expect, beforeEach, afterEach } from 'bun:test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { parseCodexEvents, buildCodexArgs, SessionStore, type CodexConfig } from './codex.ts'

// Captured verbatim from codex-cli 0.142.3 `codex exec --json`.
const HAPPY = [
  '{"type":"thread.started","thread_id":"019f4576-8f36-72b2-80f6-0ab9a3adbed4"}',
  '{"type":"turn.started"}',
  '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pong"}}',
  '{"type":"turn.completed","usage":{"input_tokens":12387,"cached_input_tokens":9600,"output_tokens":20,"reasoning_output_tokens":13}}',
].join('\n')

describe('parseCodexEvents', () => {
  test('happy path: thread id + final message', () => {
    const r = parseCodexEvents(HAPPY)
    expect(r.ok).toBe(true)
    expect(r.threadId).toBe('019f4576-8f36-72b2-80f6-0ab9a3adbed4')
    expect(r.messages).toEqual(['pong'])
  })

  test('multiple agent messages: all collected, in order', () => {
    const jsonl = [
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"working on it"}}',
      '{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls"}}',
      '{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"done"}}',
      '{"type":"turn.completed","usage":{}}',
    ].join('\n')
    const r = parseCodexEvents(jsonl)
    expect(r.messages).toEqual(['working on it', 'done'])
    expect(r.messages.at(-1)).toBe('done')
  })

  test('turn.failed surfaces the error', () => {
    const jsonl = [
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"turn.failed","error":{"message":"model overloaded"}}',
    ].join('\n')
    const r = parseCodexEvents(jsonl)
    expect(r.ok).toBe(false)
    expect(r.error).toBe('model overloaded')
    expect(r.threadId).toBe('t1') // still captured — session may be resumable
  })

  test('truncated stream (no turn.completed) is not ok', () => {
    const r = parseCodexEvents('{"type":"thread.started","thread_id":"t1"}\n{"type":"turn.started"}')
    expect(r.ok).toBe(false)
  })

  test('non-JSON noise between events is ignored', () => {
    const r = parseCodexEvents('some warning\n' + HAPPY + '\ntrailing junk')
    expect(r.ok).toBe(true)
    expect(r.messages).toEqual(['pong'])
  })

  test('empty stream is not ok', () => {
    expect(parseCodexEvents('').ok).toBe(false)
  })
})

describe('buildCodexArgs', () => {
  const cfg: CodexConfig = { cwd: '/x', sandbox: 'workspace-write', timeoutMs: 1000 }

  test('fresh thread uses exec with stdin prompt', () => {
    const args = buildCodexArgs(null, cfg)
    expect(args[0]).toBe('exec')
    expect(args).toContain('--json')
    expect(args).toContain('--skip-git-repo-check')
    expect(args.at(-1)).toBe('-')
    expect(args.join(' ')).toContain('sandbox_mode="workspace-write"')
    expect(args).not.toContain('resume')
  })

  test('existing thread uses exec resume <id>', () => {
    const args = buildCodexArgs('t-123', cfg)
    expect(args.slice(0, 3)).toEqual(['exec', 'resume', 't-123'])
    expect(args.at(-1)).toBe('-')
    // resume rejects -s/-m flags — sandbox/model must ride as -c overrides
    expect(args).not.toContain('-s')
    expect(args).not.toContain('-m')
  })

  test('model and profile are passed when set', () => {
    const args = buildCodexArgs(null, { ...cfg, model: 'gpt-5.4-codex', profile: 'swarm' })
    expect(args.join(' ')).toContain('model="gpt-5.4-codex"')
    expect(args).toContain('-p')
    expect(args).toContain('swarm')
  })
})

describe('SessionStore', () => {
  let dir: string
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'codex-bridge-sess-')) })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))

  test('get/set/delete roundtrip', () => {
    const s = new SessionStore(dir)
    expect(s.get('chat1')).toBeNull()
    s.set('chat1', 'thread-a')
    s.set('chat2', 'thread-b')
    expect(s.get('chat1')).toBe('thread-a')
    expect(new SessionStore(dir).get('chat2')).toBe('thread-b') // persisted
    s.delete('chat1')
    expect(s.get('chat1')).toBeNull()
    expect(s.get('chat2')).toBe('thread-b')
  })
})
