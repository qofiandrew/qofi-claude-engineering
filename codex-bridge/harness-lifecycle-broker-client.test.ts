import { describe, expect, test } from 'bun:test'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import {
  completeCodexTaskViaRootBroker,
  HARNESS_BROKER_TIMEOUT_MS,
  QOFI_HARNESS_LIFECYCLE_BROKER,
} from './harness-lifecycle-broker-client.ts'

function fakeBroker(result: unknown, code = 0) {
  let input = ''
  let argv: readonly string[] = []
  const spawnProcess = ((_executable: string, selected: readonly string[]) => {
    argv = selected
    const child = new EventEmitter() as ChildProcessWithoutNullStreams
    child.stdin = new PassThrough()
    child.stdout = new PassThrough()
    child.stderr = new PassThrough()
    child.kill = (() => true) as typeof child.kill
    child.stdin.on('data', chunk => { input += chunk.toString('utf8') })
    child.stdin.on('finish', () => queueMicrotask(() => {
      child.stdout.end(`${JSON.stringify(result)}\n`)
      child.stderr.end()
      child.emit('close', code, null)
    }))
    return child
  }) as any
  return { spawnProcess, input: () => input, argv: () => argv }
}

describe('root lifecycle broker Codex client', () => {
  test('default timeout leaves margin beyond manager, runtime, and reap bounds', () => {
    expect(HARNESS_BROKER_TIMEOUT_MS).toBeGreaterThanOrEqual(90_000)
  })

  test('sends only an opaque manager token and task labels over fixed no-argv sudo', async () => {
    const receipt = 'b'.repeat(64)
    const fake = fakeBroker({
      schema: 'qofi-harness-broker-result/v1',
      accepted: true,
      task_id: 'task-123',
      receipt_sha256: receipt,
      stop_disposition: 'queued',
    })
    expect(await completeCodexTaskViaRootBroker({
      swarm: 'press-backend', completionToken: 'a'.repeat(64),
      taskId: 'task-123', turnId: 'turn-456', summary: 'bounded completion',
      spawnProcess: fake.spawnProcess,
    })).toEqual({
      schema: 'qofi-harness-broker-result/v1', accepted: true,
      task_id: 'task-123', receipt_sha256: receipt, stop_disposition: 'queued',
    })
    expect(fake.argv()).toEqual(['-n', '--', QOFI_HARNESS_LIFECYCLE_BROKER])
    const request = JSON.parse(fake.input())
    expect(request).toEqual({
      schema: 'qofi-harness-broker-request/v1', operation: 'task-complete',
      runtime: 'codex', swarm: 'press-backend',
      payload: {
        completion_token: 'a'.repeat(64), task_id: 'task-123',
        turn_id: 'turn-456', summary: 'bounded completion',
      },
    })
    for (const forbidden of ['repo', 'path', 'hash', 'verdict', 'profile', 'channel', 'token_material']) {
      expect(Object.keys(request.payload).join(',')).not.toContain(forbidden)
    }
  })

  test('fails closed on broker refusal or malformed success', async () => {
    const refused = fakeBroker({ decision: 'block' }, 2)
    await expect(completeCodexTaskViaRootBroker({
      swarm: 'press-backend', completionToken: 'a'.repeat(64),
      taskId: 'task-123', turnId: 'turn-456', summary: 'bounded completion',
      spawnProcess: refused.spawnProcess,
    })).rejects.toThrow('refused or failed')

    const malformed = fakeBroker({
      schema: 'qofi-harness-broker-result/v1', accepted: true,
      task_id: 'other-task', receipt_sha256: 'b'.repeat(64), stop_disposition: 'delivered',
    })
    await expect(completeCodexTaskViaRootBroker({
      swarm: 'press-backend', completionToken: 'a'.repeat(64),
      taskId: 'task-123', turnId: 'turn-456', summary: 'bounded completion',
      spawnProcess: malformed.spawnProcess,
    })).rejects.toThrow('malformed result')
  })
})
