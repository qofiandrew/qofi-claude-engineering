/** Bounded JSONL transport from the operator manager to the hidden-UID App Server. */

import { spawn, type ChildProcessWithoutNullStreams } from 'child_process'
import type {
  AppServerTransport,
  AppServerTransportHandlers,
} from './app-server-client.ts'

export const QOFI_CODEX_RUNNER = '/usr/local/libexec/qofi-codex-runner'
export const APP_SERVER_SUPERVISOR_KILL_GRACE_MS = 15_000
export const QOFI_CODEX_REVIEW_MODEL = 'gpt-5.6-sol'
export const QOFI_CODEX_REVIEW_REASONING_EFFORT = 'ultra'
export const QOFI_CODEX_REVIEW_DISABLED_FEATURES = [
  'hooks', 'plugins', 'plugin_sharing', 'remote_plugin', 'apps',
  'browser_use', 'browser_use_external', 'browser_use_full_cdp_access',
  'in_app_browser', 'computer_use', 'image_generation',
  'skill_mcp_dependency_install', 'tool_call_mcp_elicitation',
  'auth_elicitation', 'tool_suggest', 'code_mode_host', 'goals',
  'memories', 'chronicle', 'multi_agent', 'workspace_dependencies',
  'shell_snapshot', 'shell_tool', 'unified_exec',
] as const
// The root runner proves the selected home's deterministic config before
// accepting this argv. Production must inherit its one Fable reviewer server;
// the separate internal Codex review argv below still clears every MCP server.
export const QOFI_CODEX_APP_SERVER_ARGS = [
  'app-server', '--listen', 'stdio://', '--strict-config',
  '--enable', 'multi_agent',
  ...[
    'plugins', 'plugin_sharing', 'remote_plugin', 'apps', 'browser_use',
    'browser_use_external', 'browser_use_full_cdp_access', 'in_app_browser',
    'computer_use', 'image_generation', 'skill_mcp_dependency_install',
    'tool_call_mcp_elicitation', 'auth_elicitation', 'tool_suggest',
    'code_mode_host', 'goals', 'memories', 'chronicle',
    'workspace_dependencies', 'shell_snapshot', 'hooks',
  ].flatMap(feature => ['--disable', feature]),
  '-c', 'approval_policy="never"',
  '-c', 'forced_login_method="chatgpt"',
  '-c', 'cli_auth_credentials_store="file"',
  '-c', 'model_provider="openai"',
  '-c', 'model_providers={}',
  '-c', 'allow_login_shell=false',
  '-c', 'web_search="disabled"',
  '-c', 'shell_environment_policy.inherit="none"',
  '-c', 'shell_environment_policy.set={}',
  '-c', 'shell_environment_policy.experimental_use_profile=false',
  '-c', 'shell_environment_policy.ignore_default_excludes=false',
  '-c', 'analytics.enabled=false',
] as const

export function qofiCodexReviewArgs(cwd: string): readonly string[] {
  return [
    'exec', '--ignore-user-config', '--ignore-rules', '--ephemeral',
    '--skip-git-repo-check', '-C', cwd,
    ...QOFI_CODEX_REVIEW_DISABLED_FEATURES.flatMap(feature => ['--disable', feature]),
    '-c', 'default_permissions="qofi-review-readonly"',
    '-c', 'permissions.qofi-review-readonly.filesystem={":root"="deny",":minimal"="read",":workspace_roots"={"."="deny"},":tmpdir"="deny",":slash_tmp"="deny"}',
    '-c', 'permissions.qofi-review-readonly.network.enabled=false',
    '-c', 'allow_login_shell=false',
    '-c', 'web_search="disabled"',
    '-c', 'approval_policy="never"',
    '-c', 'forced_login_method="chatgpt"',
    '-c', 'cli_auth_credentials_store="file"',
    '-c', 'project_doc_max_bytes=0',
    '-c', 'mcp_servers={}',
    '-c', 'shell_environment_policy.inherit="core"',
    '-c', 'shell_environment_policy.ignore_default_excludes=false',
    '-c', `model="${QOFI_CODEX_REVIEW_MODEL}"`,
    '-c', `model_reasoning_effort="${QOFI_CODEX_REVIEW_REASONING_EFFORT}"`,
    'review', '-',
  ]
}

export type AppServerRunnerSpawn = (
  executable: string,
  args: readonly string[],
  options: {
    cwd: string
    env: NodeJS.ProcessEnv
    stdio: ['pipe', 'pipe', 'pipe']
  },
) => ChildProcessWithoutNullStreams

export type FixedReviewRunnerResult = {
  code: number | null
  signal: NodeJS.Signals | null
  stdout: string
  stderr: string
  timedOut: boolean
  outputExceeded: boolean
  inputFailed: boolean
}

export type FixedReviewExecution = {
  completed: Promise<FixedReviewRunnerResult>
  stopAndWait: () => Promise<void>
}

export type FixedReviewRunner = (prompt: string) => FixedReviewExecution

export type SpawnFixedReviewRunnerOptions = {
  parentPid?: number
  cwd: string
  spawnProcess?: AppServerRunnerSpawn
  timeoutMs?: number
  maxOutputBytes?: number
  maxDiagnosticBytes?: number
  killGraceMs?: number
  stopTimeoutMs?: number
}

export type JsonLineStdioTransportOptions = {
  maxMessageBytes?: number
  maxDiagnosticBytes?: number
  killGraceMs?: number
  onDiagnostic?: (text: string) => void
}

const encoder = new TextEncoder()

function boundedProcessDiagnostic(value: Buffer): string {
  // This text may reach an operator tmux pane. Retain only printable ASCII so
  // stderr can never inject terminal controls, bidi state, or OSC payloads.
  return value.toString('utf8')
    .replace(/[^\x20-\x7e]/g, ' ')
    .replace(/ +/g, ' ')
    .trim()
    .slice(0, 512)
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  min: number,
  max: number,
  label: string,
): number {
  const selected = value ?? fallback
  if (!Number.isSafeInteger(selected) || selected < min || selected > max) {
    throw new TypeError(`${label} must be an integer from ${min} to ${max}`)
  }
  return selected
}

/**
 * Run the tool-less advisory review through its fixed root-runner capability.
 * Completion is reported only after the supervisor and all stdio have closed;
 * callers can therefore restore the shared App Server without overlapping the
 * hidden UID or its global runner lock.
 */
export function spawnFixedReviewRunner(
  options: SpawnFixedReviewRunnerOptions,
  prompt: string,
): FixedReviewExecution {
  const parentPid = options.parentPid ?? process.pid
  if (!Number.isSafeInteger(parentPid) || parentPid <= 1) throw new TypeError('parentPid must be greater than 1')
  if (typeof prompt !== 'string') throw new TypeError('review prompt must be a string')
  const timeoutMs = boundedInteger(options.timeoutMs, 180_000, 10, 300_000, 'review timeoutMs')
  const maxOutputBytes = boundedInteger(
    options.maxOutputBytes, 1024 * 1024, 1024, 8 * 1024 * 1024, 'review maxOutputBytes',
  )
  const maxDiagnosticBytes = boundedInteger(
    options.maxDiagnosticBytes, 64 * 1024, 1024, 1024 * 1024, 'review maxDiagnosticBytes',
  )
  const killGraceMs = boundedInteger(
    options.killGraceMs, APP_SERVER_SUPERVISOR_KILL_GRACE_MS, 50, 30_000, 'review killGraceMs',
  )
  const stopTimeoutMs = boundedInteger(
    options.stopTimeoutMs, 25_000, 100, 60_000, 'review stopTimeoutMs',
  )
  const spawnProcess = options.spawnProcess ?? ((executable, args, spawnOptions) => (
    spawn(executable, [...args], spawnOptions) as ChildProcessWithoutNullStreams
  ))
  const child = spawnProcess('/usr/bin/sudo', [
    '-n', '--', QOFI_CODEX_RUNNER,
    '--mode', 'review', '--parent-pid', String(parentPid), '--',
    ...qofiCodexReviewArgs(options.cwd),
  ], {
    cwd: options.cwd,
    env: {
      HOME: process.env.HOME,
      USER: process.env.USER,
      LOGNAME: process.env.LOGNAME,
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      LANG: 'C',
      LC_ALL: 'C',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })

  let stdout = Buffer.alloc(0)
  let stderr = Buffer.alloc(0)
  let timedOut = false
  let outputExceeded = false
  let inputFailed = false
  let terminating = false
  let killTimer: ReturnType<typeof setTimeout> | null = null
  let timeoutTimer: ReturnType<typeof setTimeout> | null = null
  let resolveCompleted!: (value: FixedReviewRunnerResult) => void
  const completed = new Promise<FixedReviewRunnerResult>(resolve => { resolveCompleted = resolve })

  const terminate = () => {
    if (terminating) return
    terminating = true
    try { child.stdin.end() } catch {}
    try { child.kill('SIGTERM') } catch {}
    killTimer = setTimeout(() => {
      try { child.kill('SIGKILL') } catch {}
    }, killGraceMs)
    killTimer.unref?.()
  }
  const appendBounded = (prior: Buffer, chunk: Buffer, limit: number): Buffer => {
    if (prior.length >= limit) return prior
    return Buffer.concat([prior, chunk.subarray(0, limit - prior.length)])
  }
  child.stdout.on('data', chunk => {
    const value = Buffer.from(chunk)
    if (stdout.length + value.length > maxOutputBytes) {
      outputExceeded = true
      terminate()
    }
    stdout = appendBounded(stdout, value, maxOutputBytes)
  })
  child.stderr.on('data', chunk => {
    stderr = appendBounded(stderr, Buffer.from(chunk), maxDiagnosticBytes)
  })
  child.stdout.on('error', () => {
    inputFailed = true
    terminate()
  })
  child.stderr.on('error', () => {
    inputFailed = true
    terminate()
  })
  child.stdin.on('error', () => {
    inputFailed = true
    terminate()
  })
  child.on('error', error => {
    inputFailed = true
    stderr = appendBounded(stderr, Buffer.from(error.message), maxDiagnosticBytes)
    terminate()
  })
  child.on('close', (code, signal) => {
    if (timeoutTimer) clearTimeout(timeoutTimer)
    if (killTimer) clearTimeout(killTimer)
    timeoutTimer = null
    killTimer = null
    resolveCompleted({
      code, signal, stdout: stdout.toString('utf8'), stderr: stderr.toString('utf8'),
      timedOut, outputExceeded, inputFailed,
    })
  })
  timeoutTimer = setTimeout(() => {
    timedOut = true
    terminate()
  }, timeoutMs)
  timeoutTimer.unref?.()
  try {
    child.stdin.end(prompt)
  } catch {
    inputFailed = true
    terminate()
  }

  return {
    completed,
    stopAndWait: async () => {
      terminate()
      let timer: ReturnType<typeof setTimeout> | null = null
      try {
        await Promise.race([
          completed,
          new Promise<never>((_resolve, reject) => {
            timer = setTimeout(
              () => reject(new Error('fixed review runner did not exit after termination')),
              stopTimeoutMs,
            )
            timer.unref?.()
          }),
        ])
      } finally {
        if (timer) clearTimeout(timer)
      }
    },
  }
}

/**
 * App Server's stdio transport is one JSON object per line.  This adapter is
 * message-oriented for CodexAppServerClient while retaining strict stream and
 * diagnostic bounds.  It never interprets or logs protocol payloads.
 */
export class JsonLineStdioTransport implements AppServerTransport {
  private readonly maxMessageBytes: number
  private readonly maxDiagnosticBytes: number
  private readonly killGraceMs: number
  private readonly onDiagnostic?: (text: string) => void
  private handlers: AppServerTransportHandlers | null = null
  private stdoutBuffer = Buffer.alloc(0)
  private stderrBuffer = Buffer.alloc(0)
  private closed = false
  private closeNotified = false
  private closeReason = 'JSONL transport is closed'
  private processExitObserved = false
  private killTimer: ReturnType<typeof setTimeout> | null = null
  private resolveExit!: (value: { code: number | null; signal: NodeJS.Signals | null }) => void
  readonly exited: Promise<{ code: number | null; signal: NodeJS.Signals | null }>

  constructor(
    readonly child: ChildProcessWithoutNullStreams,
    options: JsonLineStdioTransportOptions = {},
  ) {
    this.maxMessageBytes = boundedInteger(
      options.maxMessageBytes, 2 * 1024 * 1024, 256, 80 * 1024 * 1024,
      'maxMessageBytes',
    )
    this.maxDiagnosticBytes = boundedInteger(
      options.maxDiagnosticBytes, 64 * 1024, 1024, 1024 * 1024,
      'maxDiagnosticBytes',
    )
    // The root runner performs its own TERM wait followed by UID-wide cleanup.
    // Do not SIGKILL that supervisor at the edge of its three-second child grace.
    this.killGraceMs = boundedInteger(
      options.killGraceMs, APP_SERVER_SUPERVISOR_KILL_GRACE_MS, 50, 30_000, 'killGraceMs',
    )
    this.onDiagnostic = options.onDiagnostic
    this.exited = new Promise(resolve => { this.resolveExit = resolve })

    child.stdout.on('data', chunk => this.consumeStdout(Buffer.from(chunk)))
    // EOF is a process-lifetime failure, not merely a protocol disconnect: a
    // wedged child with closed stdout would otherwise retain the root flock.
    child.stdout.on('end', () => this.fail('App Server stdout ended'))
    child.stdout.on('error', () => this.fail('App Server stdout failed'))
    child.stdin.on('error', () => this.fail('App Server stdin failed'))
    child.stderr.on('data', chunk => this.consumeStderr(Buffer.from(chunk)))
    child.on('error', () => this.fail('could not execute fixed App Server runner'))
    child.on('exit', (code, signal) => {
      this.resolveExit({ code, signal })
      if (this.killTimer) clearTimeout(this.killTimer)
      this.killTimer = null
      const diagnostic = boundedProcessDiagnostic(this.stderrBuffer)
      this.notifyClose(
        `fixed App Server runner exited (${signal ?? code ?? 'unknown'})${diagnostic ? `: ${diagnostic}` : ''}`,
        true,
      )
    })
  }

  setHandlers(handlers: AppServerTransportHandlers): () => void {
    if (this.handlers) throw new Error('JSONL transport already has handlers')
    this.handlers = handlers
    return () => {
      if (this.handlers === handlers) this.handlers = null
    }
  }

  send(message: string): Promise<void> {
    if (this.closed) return Promise.reject(new Error(this.closeReason))
    if (message.includes('\n') || message.includes('\r') || encoder.encode(message).byteLength > this.maxMessageBytes) {
      return Promise.reject(new Error('outbound App Server JSONL message is malformed or oversized'))
    }
    return new Promise((resolve, reject) => {
      this.child.stdin.write(`${message}\n`, error => error ? reject(error) : resolve())
    })
  }

  boundedFailureReason(): string {
    return this.closeReason
  }

  close(_code?: number, _reason?: string): void {
    if (this.closed) return
    this.closed = true
    try { this.child.stdin.end() } catch {}
    try { this.child.kill('SIGTERM') } catch {}
    this.killTimer = setTimeout(() => {
      try { this.child.kill('SIGKILL') } catch {}
    }, this.killGraceMs)
    this.killTimer.unref?.()
  }

  async stopAndWait(timeoutMs = 25_000): Promise<void> {
    const timeout = boundedInteger(timeoutMs, 25_000, 100, 60_000, 'stop timeout')
    this.close()
    let timer: ReturnType<typeof setTimeout> | null = null
    try {
      await Promise.race([
        this.exited,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error('fixed App Server runner did not exit after termination')), timeout)
          timer.unref?.()
        }),
      ])
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  private consumeStdout(chunk: Buffer): void {
    if (this.closed || chunk.length === 0) return
    this.stdoutBuffer = Buffer.concat([this.stdoutBuffer, chunk])
    if (this.stdoutBuffer.length > this.maxMessageBytes && !this.stdoutBuffer.includes(0x0a)) {
      this.fail('inbound App Server JSONL message exceeded its byte bound')
      return
    }
    for (;;) {
      const newline = this.stdoutBuffer.indexOf(0x0a)
      if (newline < 0) break
      let line = this.stdoutBuffer.subarray(0, newline)
      this.stdoutBuffer = this.stdoutBuffer.subarray(newline + 1)
      if (line.at(-1) === 0x0d) line = line.subarray(0, -1)
      if (line.length === 0 || line.length > this.maxMessageBytes) {
        this.fail('inbound App Server JSONL message was empty or oversized')
        return
      }
      this.handlers?.message(new Uint8Array(line))
      if (this.closed) return
    }
    if (this.stdoutBuffer.length > this.maxMessageBytes) {
      this.fail('inbound App Server JSONL message exceeded its byte bound')
    }
  }

  private consumeStderr(chunk: Buffer): void {
    if (chunk.length === 0) return
    this.stderrBuffer = Buffer.concat([this.stderrBuffer, chunk])
    if (this.stderrBuffer.length > this.maxDiagnosticBytes) {
      this.stderrBuffer = this.stderrBuffer.subarray(this.stderrBuffer.length - this.maxDiagnosticBytes)
    }
    if (this.onDiagnostic) {
      const text = chunk.toString('utf8').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
      if (text) this.onDiagnostic(text.slice(0, this.maxDiagnosticBytes))
    }
  }

  private fail(reason: string): void {
    if (!this.closed) this.close(1011, reason)
    this.notifyClose(reason)
  }

  private notifyClose(reason: string, processExit = false): void {
    // Preserve the newest bounded process-exit diagnostic even when stdout
    // EOF won the close-notification race.  Initialization can otherwise see
    // only the useless "transport is closed" error after the fixed runner
    // has already supplied an actionable, size-bounded stderr reason.
    if (processExit) {
      this.processExitObserved = true
      this.closeReason = reason
    } else if (!this.processExitObserved) {
      this.closeReason = reason
    }
    if (this.closeNotified) return
    this.closeNotified = true
    this.closed = true
    this.handlers?.close({ code: 1011, reason })
  }
}

export type SpawnAppServerRunnerOptions = JsonLineStdioTransportOptions & {
  parentPid?: number
  cwd: string
  /** Non-secret auth-profile handle; the fixed runner resolves its CODEX_HOME. */
  profile?: string
  spawnProcess?: AppServerRunnerSpawn
}

export type FixedProfileTelemetryResult =
  | { timestamp: string; rate_limits: unknown }
  | { status: 'unknown'; reason: string }

/** Read only the runner-sanitized latest token_count quota envelope. */
export async function readFixedProfileTelemetry(
  profile: string,
  options: { parentPid?: number; cwd: string; spawnProcess?: AppServerRunnerSpawn; timeoutMs?: number },
): Promise<FixedProfileTelemetryResult> {
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(profile)) throw new TypeError('invalid telemetry profile')
  const parentPid = options.parentPid ?? process.pid
  if (!Number.isSafeInteger(parentPid) || parentPid <= 1) throw new TypeError('parentPid must be greater than 1')
  const spawnProcess = options.spawnProcess ?? ((executable, args, spawnOptions) => (
    spawn(executable, [...args], spawnOptions) as ChildProcessWithoutNullStreams
  ))
  const child = spawnProcess('/usr/bin/sudo', [
    '-n', '--', QOFI_CODEX_RUNNER,
    '--telemetry', '--profile', profile, '--parent-pid', String(parentPid),
  ], {
    cwd: options.cwd,
    env: {
      HOME: process.env.HOME, USER: process.env.USER, LOGNAME: process.env.LOGNAME,
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  child.stdin.end()
  child.stderr.resume()
  return new Promise((resolve, reject) => {
    let stdout = Buffer.alloc(0)
    let failed = false
    const rejectOnce = (error: Error) => {
      if (failed) return
      failed = true
      try { child.kill('SIGTERM') } catch {}
      reject(error)
    }
    const timer = setTimeout(() => rejectOnce(new Error('profile telemetry reader timed out')), options.timeoutMs ?? 15_000)
    timer.unref?.()
    child.stdout.on('data', chunk => {
      if (failed) return
      const bytes = Buffer.from(chunk)
      if (stdout.length + bytes.length > 64 * 1024) return rejectOnce(new Error('profile telemetry output exceeded bound'))
      stdout = Buffer.concat([stdout, bytes])
    })
    child.on('error', error => rejectOnce(error))
    child.on('close', code => {
      clearTimeout(timer)
      if (failed) return
      if (code !== 0) return rejectOnce(new Error(`profile telemetry reader exited ${code ?? 'unknown'}`))
      try {
        const value: unknown = JSON.parse(stdout.toString('utf8'))
        if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('not an object')
        const record = value as Record<string, unknown>
        if (record.status === 'unknown' && typeof record.reason === 'string'
          && Object.keys(record).sort().join(',') === 'reason,status') {
          resolve({ status: 'unknown', reason: record.reason.slice(0, 64) })
          return
        }
        if (typeof record.timestamp !== 'string'
          || !Object.prototype.hasOwnProperty.call(record, 'rate_limits')
          || Object.keys(record).sort().join(',') !== 'rate_limits,timestamp') {
          throw new Error('unexpected fields')
        }
        resolve({ timestamp: record.timestamp, rate_limits: record.rate_limits })
      } catch {
        rejectOnce(new Error('profile telemetry reader returned malformed output'))
      }
    })
  })
}

export function spawnFixedAppServerRunner(
  options: SpawnAppServerRunnerOptions,
): JsonLineStdioTransport {
  const parentPid = options.parentPid ?? process.pid
  if (!Number.isSafeInteger(parentPid) || parentPid <= 1) throw new TypeError('parentPid must be greater than 1')
  const profile = options.profile ?? 'default'
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(profile)) {
    throw new TypeError('profile must be a safe Codex auth-profile handle')
  }
  const spawnProcess = options.spawnProcess ?? ((executable, args, spawnOptions) => (
    spawn(executable, [...args], spawnOptions) as ChildProcessWithoutNullStreams
  ))
  const child = spawnProcess('/usr/bin/sudo', [
    '-n', '--', QOFI_CODEX_RUNNER,
    '--mode', 'app-server', '--profile', profile, '--parent-pid', String(parentPid), '--',
    ...QOFI_CODEX_APP_SERVER_ARGS,
  ], {
    cwd: options.cwd,
    env: {
      HOME: process.env.HOME,
      USER: process.env.USER,
      LOGNAME: process.env.LOGNAME,
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      LANG: 'C',
      LC_ALL: 'C',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  return new JsonLineStdioTransport(child, options)
}
