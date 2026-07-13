/** Fixed no-argv client for the root-owned cross-runtime lifecycle broker. */

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'

export const QOFI_HARNESS_LIFECYCLE_BROKER =
  '/Library/PrivilegedHelperTools/qofi-harness-lifecycle-broker'
export const HARNESS_BROKER_REQUEST_SCHEMA = 'qofi-harness-broker-request/v1' as const
export const HARNESS_BROKER_RESULT_SCHEMA = 'qofi-harness-broker-result/v1' as const
// Root admission may spend up to 10s on the manager proof plus 55s in the
// attested coordinator and a bounded reap. Keep a real margin outside that
// envelope so the client does not terminate sudo while root still owns a
// live coordinator process group.
export const HARNESS_BROKER_TIMEOUT_MS = 90_000
const MAX_REQUEST_BYTES = 64 * 1024
const MAX_RESULT_BYTES = 128 * 1024
const SAFE_SWARM = /^[a-z][a-z0-9-]{0,63}$/
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$/
const SHA256 = /^[0-9a-f]{64}$/

export type CodexBrokerCompletionResult = Readonly<{
  schema: typeof HARNESS_BROKER_RESULT_SCHEMA
  accepted: true
  task_id: string
  receipt_sha256: string
  stop_disposition: 'delivered' | 'queued'
}>

export type CodexBrokerCompletionOptions = Readonly<{
  swarm: string
  completionToken: string
  taskId: string
  turnId: string
  summary: string
  spawnProcess?: typeof spawn
  timeoutMs?: number
}>

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  const record = value as Record<string, unknown>
  return `{${Object.keys(record).sort().map(key => (
    `${JSON.stringify(key)}:${canonicalJson(record[key])}`
  )).join(',')}}`
}

function boundedSummary(value: string): boolean {
  return typeof value === 'string' && value.length >= 1
    && Buffer.byteLength(value, 'utf8') <= 16 * 1024
    && !value.includes('\0')
    && [...value].every(char => {
      const code = char.charCodeAt(0)
      return code >= 0x20 || char === '\n' || char === '\t'
    })
}

function validateResult(value: unknown, taskId: string): CodexBrokerCompletionResult {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('root lifecycle broker returned a malformed result')
  }
  const record = value as Record<string, unknown>
  if (Object.keys(record).sort().join(',') !== [
    'accepted', 'receipt_sha256', 'schema', 'stop_disposition', 'task_id',
  ].sort().join(',')
    || record.schema !== HARNESS_BROKER_RESULT_SCHEMA || record.accepted !== true
    || record.task_id !== taskId || typeof record.receipt_sha256 !== 'string'
    || !SHA256.test(record.receipt_sha256)
    || (record.stop_disposition !== 'delivered' && record.stop_disposition !== 'queued')) {
    throw new Error('root lifecycle broker returned a malformed result')
  }
  return record as unknown as CodexBrokerCompletionResult
}

export async function completeCodexTaskViaRootBroker(
  options: CodexBrokerCompletionOptions,
): Promise<CodexBrokerCompletionResult> {
  if (!SAFE_SWARM.test(options.swarm) || !SHA256.test(options.completionToken)
    || !SAFE_ID.test(options.taskId) || !SAFE_ID.test(options.turnId)
    || !boundedSummary(options.summary)) {
    throw new Error('root lifecycle broker completion input is invalid')
  }
  const request = {
    schema: HARNESS_BROKER_REQUEST_SCHEMA,
    operation: 'task-complete',
    runtime: 'codex',
    swarm: options.swarm,
    payload: {
      completion_token: options.completionToken,
      task_id: options.taskId,
      turn_id: options.turnId,
      summary: options.summary,
    },
  }
  const encoded = Buffer.from(`${canonicalJson(request)}\n`, 'utf8')
  if (encoded.byteLength > MAX_REQUEST_BYTES) {
    throw new Error('root lifecycle broker completion request exceeds its bound')
  }
  const child = (options.spawnProcess ?? spawn)('/usr/bin/sudo', [
    '-n', '--', QOFI_HARNESS_LIFECYCLE_BROKER,
  ], {
    cwd: '/',
    env: {
      HOME: process.env.HOME,
      USER: process.env.USER,
      LOGNAME: process.env.LOGNAME,
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      LANG: 'C.UTF-8',
      LC_ALL: 'C.UTF-8',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  }) as ChildProcessWithoutNullStreams
  let stdout = Buffer.alloc(0)
  let overflow = false
  child.stdout.on('data', chunk => {
    const bytes = Buffer.from(chunk)
    if (stdout.byteLength + bytes.byteLength > MAX_RESULT_BYTES) {
      overflow = true
      try { child.kill('SIGTERM') } catch {}
    }
    if (stdout.byteLength < MAX_RESULT_BYTES) {
      stdout = Buffer.concat([
        stdout, bytes.subarray(0, MAX_RESULT_BYTES - stdout.byteLength),
      ])
    }
  })
  // Never project root/runtime diagnostics into a worker-visible result.
  child.stderr.resume()
  const completed = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    child.once('error', reject)
    child.once('close', (code, signal) => resolve({ code, signal }))
  })
  child.stdin.end(encoded)
  const timeoutMs = options.timeoutMs ?? HARNESS_BROKER_TIMEOUT_MS
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1_000 || timeoutMs > 180_000) {
    try { child.kill('SIGKILL') } catch {}
    throw new Error('root lifecycle broker timeout is invalid')
  }
  let timeout: ReturnType<typeof setTimeout> | null = null
  let timedOut = false
  try {
    const status = await Promise.race([
      completed,
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(() => {
          timedOut = true
          try { child.kill('SIGTERM') } catch {}
          reject(new Error('root lifecycle broker timed out'))
        }, timeoutMs)
        timeout.unref?.()
      }),
    ])
    if (status.code !== 0 || status.signal !== null || overflow) {
      throw new Error('root lifecycle broker refused or failed the Codex completion')
    }
    const text = stdout.toString('utf8')
    if (!text.endsWith('\n') || text.indexOf('\n') !== text.length - 1) {
      throw new Error('root lifecycle broker result framing is invalid')
    }
    return validateResult(JSON.parse(text), options.taskId)
  } finally {
    if (timeout) clearTimeout(timeout)
    if (timedOut) {
      const kill = setTimeout(() => {
        try { child.kill('SIGKILL') } catch {}
      }, 2_000)
      kill.unref?.()
    }
  }
}
