/** Fixed host-side one-shot invocation of the capability-minimal Fable shim. */

import { spawn, type ChildProcess } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
} from 'node:fs'
import type { Writable } from 'node:stream'

export const FIXED_FABLE_REVIEWER = '/usr/local/libexec/qofi-fable-reviewer-mcp.py'
export const FABLE_ONE_SHOT_REQUEST_SCHEMA = 'qofi-fable-reviewer-one-shot-request/v1' as const
export const FABLE_ONE_SHOT_RESULT_SCHEMA = 'qofi-fable-reviewer-one-shot-result/v1' as const
export const MAX_FABLE_ONE_SHOT_BYTES = 3 * 1024 * 1024
const MAX_RESULT_BYTES = 1024 * 1024
const MAX_DIAGNOSTIC_BYTES = 64 * 1024

export type FableCompletionReviewExecution = Readonly<{
  completed: Promise<unknown>
  stopAndWait: () => Promise<void>
}>

export type FableCompletionReviewRunner = (
  request: Readonly<Record<string, unknown>>,
) => FableCompletionReviewExecution

export type SpawnFableCompletionReviewOptions = Readonly<{
  cwd: string
  expectedReviewerSha256?: string
  spawnProcess?: typeof spawn
}>

function attestFixedReviewer(expectedSha256: string | undefined): void {
  if (expectedSha256 === undefined) return
  if (!/^[0-9a-f]{64}$/.test(expectedSha256)) {
    throw new Error('fixed Fable reviewer attestation digest is invalid')
  }
  const before = lstatSync(FIXED_FABLE_REVIEWER)
  if (!before.isFile() || before.isSymbolicLink() || before.uid !== 0
    || before.nlink !== 1 || (before.mode & 0o022) !== 0
    || (before.mode & 0o111) === 0 || before.size < 1 || before.size > 1024 * 1024) {
    throw new Error('fixed Fable reviewer authority is unsafe')
  }
  const fd = openSync(FIXED_FABLE_REVIEWER, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = fstatSync(fd)
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.uid !== before.uid
      || opened.mode !== before.mode || opened.nlink !== 1 || opened.size !== before.size) {
      throw new Error('fixed Fable reviewer changed while opening')
    }
    const bytes = readFileSync(fd)
    const after = fstatSync(fd)
    if (after.dev !== opened.dev || after.ino !== opened.ino || after.nlink !== 1
      || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs
      || after.ctimeMs !== opened.ctimeMs
      || createHash('sha256').update(bytes).digest('hex') !== expectedSha256) {
      throw new Error('fixed Fable reviewer differs from root runtime attestation')
    }
  } finally {
    closeSync(fd)
  }
}

/**
 * The argv is fixed and has no scope/path/profile switches. All bounded review
 * data travels over a private stdin pipe authored by the manager. The shim's
 * own supervisor owns and reaps the terminal Claude process group.
 */
export function spawnFixedFableCompletionReview(
  options: SpawnFableCompletionReviewOptions,
  request: Readonly<Record<string, unknown>>,
): FableCompletionReviewExecution {
  attestFixedReviewer(options.expectedReviewerSha256)
  const encoded = Buffer.from(`${JSON.stringify(request)}\n`, 'utf8')
  if (encoded.byteLength < 2 || encoded.byteLength > MAX_FABLE_ONE_SHOT_BYTES) {
    throw new Error('Fable completion review request exceeds its fixed bound')
  }
  const spawnProcess = options.spawnProcess ?? spawn
  const child = spawnProcess('/usr/bin/python3', [
    '-I', '-B', FIXED_FABLE_REVIEWER, '--one-shot', '--parent-fd', '3',
  ], {
    cwd: options.cwd,
    env: {
      HOME: process.env.HOME,
      USER: process.env.USER,
      LOGNAME: process.env.LOGNAME,
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      LANG: 'C.UTF-8',
      LC_ALL: 'C.UTF-8',
    },
    // fd 3 is a manager-liveness pipe. The manager never writes to it; EOF is
    // an unforgeable parent-death signal that makes the shim close its Claude
    // supervisor control pipe and reap the complete terminal process group.
    stdio: ['pipe', 'pipe', 'pipe', 'pipe'],
  }) as ChildProcess
  const stdin = child.stdin
  const stdoutStream = child.stdout
  const stderrStream = child.stderr
  const parentLiveness = child.stdio[3] as Writable | null
  if (!stdin || !stdoutStream || !stderrStream || !parentLiveness) {
    try { child.kill('SIGKILL') } catch {}
    throw new Error('fixed Fable reviewer stdio authority is unavailable')
  }

  let stdout = Buffer.alloc(0)
  let stderr = Buffer.alloc(0)
  let exceeded = false
  let stopped = false
  let settled = false
  let resolve!: (value: unknown) => void
  let reject!: (error: Error) => void
  const completed = new Promise<unknown>((ok, fail) => { resolve = ok; reject = fail })
  const stop = () => {
    if (stopped) return
    stopped = true
    try { stdin.destroy() } catch {}
    try { parentLiveness.destroy() } catch {}
    try { child.kill('SIGTERM') } catch {}
  }
  const append = (prior: Buffer, chunk: Buffer, maximum: number): Buffer => (
    prior.byteLength >= maximum
      ? prior
      : Buffer.concat([prior, chunk.subarray(0, maximum - prior.byteLength)])
  )
  stdoutStream.on('data', chunk => {
    const value = Buffer.from(chunk)
    if (stdout.byteLength + value.byteLength > MAX_RESULT_BYTES) {
      exceeded = true
      stop()
    }
    stdout = append(stdout, value, MAX_RESULT_BYTES)
  })
  stderrStream.on('data', chunk => {
    stderr = append(stderr, Buffer.from(chunk), MAX_DIAGNOSTIC_BYTES)
  })
  child.on('error', error => {
    if (settled) return
    settled = true
    reject(new Error(`fixed Fable reviewer launch failed: ${error.message.slice(0, 256)}`))
  })
  child.on('close', (code, signal) => {
    if (settled) return
    settled = true
    try { parentLiveness.destroy() } catch {}
    if (code !== 0 || signal !== null || exceeded) {
      reject(new Error('fixed Fable reviewer did not produce a successful bounded result'))
      return
    }
    try {
      const text = stdout.toString('utf8')
      if (!text.endsWith('\n') || text.indexOf('\n') !== text.length - 1) {
        throw new Error('fixed Fable reviewer output framing is invalid')
      }
      resolve(JSON.parse(text))
    } catch {
      reject(new Error('fixed Fable reviewer output is malformed'))
    }
  })
  try {
    stdin.end(encoded)
  } catch {
    stop()
  }

  return {
    completed,
    stopAndWait: async () => {
      stop()
      let killTimer: ReturnType<typeof setTimeout> | null = setTimeout(() => {
        try { child.kill('SIGKILL') } catch {}
      }, 3_000)
      killTimer.unref?.()
      let failureTimer: ReturnType<typeof setTimeout> | null = null
      try {
        await Promise.race([
          completed.catch(() => undefined),
          new Promise<void>((_resolve, fail) => {
            failureTimer = setTimeout(
              () => fail(new Error('fixed Fable reviewer did not stop after SIGKILL')),
              30_000,
            )
            failureTimer.unref?.()
          }),
        ])
      } finally {
        if (killTimer) clearTimeout(killTimer)
        if (failureTimer) clearTimeout(failureTimer)
        killTimer = null
        failureTimer = null
      }
    },
  }
}
