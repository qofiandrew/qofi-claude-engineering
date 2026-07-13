import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, statSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { RuntimeStateStore } from './runtime.ts'

describe('RuntimeStateStore', () => {
  let dir: string
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'codex-runtime-')) })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))

  test('writes the v1 state atomically with private permissions', () => {
    const store = new RuntimeStateStore(dir, new Date('2026-07-11T00:00:00Z'))
    store.update({
      ready: true,
      active: true,
      queue_depth: 2,
      child_pid: 123,
      turn_started_at: '2026-07-11T00:01:00.000Z',
    }, new Date('2026-07-11T00:01:01Z'))
    const state = JSON.parse(readFileSync(join(dir, 'runtime.json'), 'utf8'))
    expect(state.schema).toBe('codex-bridge-runtime/v1')
    expect(state.ready).toBe(true)
    expect(state.active).toBe(true)
    expect(state.queue_depth).toBe(2)
    expect(state.child_pid).toBe(123)
    expect(state.backend).toBe('exec')
    expect(state.app_server_endpoint).toBeNull()
    expect(state.updated_at).toBe('2026-07-11T00:01:01.000Z')
    expect(statSync(join(dir, 'runtime.json')).mode & 0o777).toBe(0o600)
  })

  test('bounds last_error', () => {
    const store = new RuntimeStateStore(dir)
    store.update({ last_error: 'x'.repeat(1000) })
    expect(store.snapshot().last_error?.length).toBe(500)
  })

  test('publishes an explicitly configured Unix App Server facade', () => {
    const endpoint = `unix://${join(dir, 'viewer.sock')}`
    const store = new RuntimeStateStore(
      dir,
      new Date('2026-07-11T00:00:00Z'),
      { appServerEndpoint: endpoint },
    )
    const state = store.snapshot()
    expect(state.backend).toBe('app-server')
    expect(state.app_server_endpoint).toBe(endpoint)
    store.update({ child_pid: 999, active: true })
    expect(store.snapshot().child_pid).toBeNull()
  })

  test('refuses remote, relative, or delimiter-bearing App Server endpoints', () => {
    for (const appServerEndpoint of [
      'ws://127.0.0.1:4500',
      'unix://relative.sock',
      `unix://${join(dir, '..', 'outside.sock')}`,
      `unix://${dir}`,
      `unix://${join(dir, 'viewer.sock')}|extra`,
      `unix://${join(dir, 'viewer.sock')}\nextra`,
    ]) {
      expect(() => new RuntimeStateStore(dir, { appServerEndpoint })).toThrow(
        'safe absolute unix:// endpoint',
      )
    }
  })
})
