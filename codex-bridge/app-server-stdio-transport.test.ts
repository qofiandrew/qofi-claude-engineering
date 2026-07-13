import { describe, expect, test } from 'bun:test'
import { EventEmitter } from 'events'
import { PassThrough } from 'stream'
import type { ChildProcessWithoutNullStreams } from 'child_process'
import { CodexAppServerClient } from './app-server-client.ts'
import {
  JsonLineStdioTransport,
  APP_SERVER_SUPERVISOR_KILL_GRACE_MS,
  QOFI_CODEX_APP_SERVER_ARGS,
  QOFI_CODEX_RUNNER,
  readFixedProfileTelemetry,
  spawnFixedAppServerRunner,
  type AppServerRunnerSpawn,
} from './app-server-stdio-transport.ts'

function fakeChild() {
  const child = new EventEmitter() as ChildProcessWithoutNullStreams & {
    kills: NodeJS.Signals[]
  }
  child.stdin = new PassThrough()
  child.stdout = new PassThrough()
  child.stderr = new PassThrough()
  child.kills = []
  child.kill = ((signal?: NodeJS.Signals) => {
    child.kills.push(signal ?? 'SIGTERM')
    return true
  }) as typeof child.kill
  return child
}

describe('fixed App Server runner spawn', () => {
  test('uses the exact sudo/root-runner stdio capability and a scrubbed environment', () => {
    const child = fakeChild()
    let observed: Parameters<AppServerRunnerSpawn> | null = null
    const transport = spawnFixedAppServerRunner({
      parentPid: 4242,
      cwd: '/private/tmp',
      spawnProcess: ((...args) => {
        observed = args
        return child
      }) as AppServerRunnerSpawn,
    })

    expect(observed?.[0]).toBe('/usr/bin/sudo')
    expect(observed?.[1]).toEqual([
      '-n', '--', QOFI_CODEX_RUNNER,
      '--mode', 'app-server', '--profile', 'default', '--parent-pid', '4242', '--',
      ...QOFI_CODEX_APP_SERVER_ARGS,
    ])
    expect(observed?.[2].stdio).toEqual(['pipe', 'pipe', 'pipe'])
    expect(observed?.[2].env.PATH).toBe('/usr/bin:/bin:/usr/sbin:/sbin')
    expect(Object.keys(observed?.[2].env ?? {}).sort()).toEqual([
      'HOME', 'LANG', 'LC_ALL', 'LOGNAME', 'PATH', 'USER',
    ])
    expect(QOFI_CODEX_APP_SERVER_ARGS.slice(0, 4)).toEqual([
      'app-server', '--listen', 'stdio://', '--strict-config',
    ])
    expect(QOFI_CODEX_APP_SERVER_ARGS.join(' ')).not.toContain('unix://')
    expect(QOFI_CODEX_APP_SERVER_ARGS.join(' ')).not.toContain('ws://')
    expect(QOFI_CODEX_APP_SERVER_ARGS).not.toContain('mcp_servers={}')
    expect(APP_SERVER_SUPERVISOR_KILL_GRACE_MS).toBeGreaterThan(3_000)
    transport.close()
  })

  test('binds a validated non-secret auth profile into the fixed runner argv', () => {
    const child = fakeChild()
    let observed: Parameters<AppServerRunnerSpawn> | null = null
    const transport = spawnFixedAppServerRunner({
      parentPid: 4242,
      cwd: '/private/tmp',
      profile: 'max_b',
      spawnProcess: ((...args) => {
        observed = args
        return child
      }) as AppServerRunnerSpawn,
    })
    expect(observed?.[1].slice(0, 9)).toEqual([
      '-n', '--', QOFI_CODEX_RUNNER,
      '--mode', 'app-server', '--profile', 'max_b', '--parent-pid', '4242',
    ])
    transport.close()
    expect(() => spawnFixedAppServerRunner({
      parentPid: 4242, cwd: '/private/tmp', profile: '../bad',
    })).toThrow('safe Codex auth-profile handle')
  })
})

describe('fixed profile telemetry reader', () => {
  test('uses the exact read-only profile capability and accepts only sanitized JSON', async () => {
    const child = fakeChild()
    let observed: Parameters<AppServerRunnerSpawn> | null = null
    const pending = readFixedProfileTelemetry('max_b', {
      parentPid: 4242,
      cwd: '/private/tmp',
      spawnProcess: ((...args) => {
        observed = args
        return child
      }) as AppServerRunnerSpawn,
    })
    child.stdout.write(JSON.stringify({
      timestamp: '2026-07-13T01:59:00.000Z',
      rate_limits: { primary: null, secondary: null },
    }))
    child.emit('close', 0, null)
    expect(await pending).toEqual({
      timestamp: '2026-07-13T01:59:00.000Z',
      rate_limits: { primary: null, secondary: null },
    })
    expect(observed?.[1]).toEqual([
      '-n', '--', QOFI_CODEX_RUNNER,
      '--telemetry', '--profile', 'max_b', '--parent-pid', '4242',
    ])
  })
})

describe('bounded JSONL stdio transport', () => {
  test('frames fragmented and coalesced lines without interpreting payloads', async () => {
    const child = fakeChild()
    const transport = new JsonLineStdioTransport(child)
    const received: string[] = []
    transport.setHandlers({
      message: value => received.push(Buffer.from(value).toString('utf8')),
      close: () => {},
    })

    child.stdout.write('{"id":1')
    child.stdout.write('}\n{"method":"ready"}\r\n')
    expect(received).toEqual(['{"id":1}', '{"method":"ready"}'])

    let written = ''
    child.stdin.on('data', chunk => { written += chunk.toString('utf8') })
    await transport.send('{"method":"initialized"}')
    expect(written).toBe('{"method":"initialized"}\n')
    transport.close()
  })

  test('fails closed on an oversized unterminated frame and bounds diagnostics', () => {
    const child = fakeChild()
    const transport = new JsonLineStdioTransport(child, {
      maxMessageBytes: 256,
      maxDiagnosticBytes: 1024,
      killGraceMs: 50,
    })
    const closes: string[] = []
    transport.setHandlers({ message: () => {}, close: value => closes.push(value?.reason ?? '') })
    child.stderr.write('secret diagnostic '.repeat(200))
    child.stdout.write('x'.repeat(257))
    expect(closes).toEqual(['inbound App Server JSONL message exceeded its byte bound'])
    expect(child.kills).toContain('SIGTERM')
  })

  test('rejects multiline or oversized outbound messages', async () => {
    const child = fakeChild()
    const transport = new JsonLineStdioTransport(child, { maxMessageBytes: 256 })
    transport.setHandlers({ message: () => {}, close: () => {} })
    await expect(transport.send('{}\n{}')).rejects.toThrow('malformed or oversized')
    await expect(transport.send('x'.repeat(257))).rejects.toThrow('malformed or oversized')
    transport.close()
  })

  test('terminates a child that closes stdout without exiting', async () => {
    const child = fakeChild()
    const transport = new JsonLineStdioTransport(child, { killGraceMs: 50 })
    const closes: string[] = []
    transport.setHandlers({ message: () => {}, close: value => closes.push(value?.reason ?? '') })
    child.stdout.end()
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(closes).toEqual(['App Server stdout ended'])
    expect(child.kills).toContain('SIGTERM')
  })

  test('retains the bounded fixed-runner diagnostic for a raced initialize send', async () => {
    const child = fakeChild()
    const transport = new JsonLineStdioTransport(child)
    transport.setHandlers({ message: () => {}, close: () => {} })
    child.stdout.end()
    child.stderr.write('qofi-codex-runner: exact \x1b]8;;unsafe\x07bounded failure\n')
    child.emit('exit', 69, null)
    expect(transport.boundedFailureReason()).toBe(
      'fixed App Server runner exited (69): qofi-codex-runner: exact ]8;;unsafe bounded failure',
    )
    expect(transport.boundedFailureReason()).not.toContain('\x1b')
  })

  test('captures the exit diagnostic after a real pending initialize EOF race', async () => {
    const child = fakeChild()
    const transport = new JsonLineStdioTransport(child)
    const connecting = CodexAppServerClient.connect(transport, {
      clientInfo: { name: 'transport-race-test', title: 'Transport Race Test', version: '1.0.0' },
      onNotification: () => {},
      onProtocolError: () => {},
    })
    const outcome = connecting.then<Error | null>(() => null, error => error as Error)
    await new Promise(resolve => setTimeout(resolve, 0))
    child.stdout.end()
    await new Promise(resolve => setTimeout(resolve, 0))
    child.stderr.write('qofi-codex-runner: initialize failed\n')
    child.emit('exit', 69, null)

    expect((await outcome)?.message).toContain('initialize: App Server stdout ended')
    expect(transport.boundedFailureReason()).toBe(
      'fixed App Server runner exited (69): qofi-codex-runner: initialize failed',
    )
  })
})
