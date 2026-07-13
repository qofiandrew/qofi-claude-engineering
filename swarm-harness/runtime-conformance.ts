import { createHash, randomBytes } from 'node:crypto'
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { spawnSync } from 'node:child_process'

export const RUNTIME_CONFORMANCE_SCHEMA = 'qofi.runtime-conformance/v1' as const
export const RUNTIME_CONFORMANCE_MAX_RECORD_BYTES = 16 * 1024
export const RUNTIME_CONFORMANCE_MAX_EXECUTABLE_BYTES = 512 * 1024 * 1024
export const RUNTIME_CONFORMANCE_MAX_HELP_BYTES = 256 * 1024
export const RUNTIME_CONFORMANCE_SUITE_FILES = [
  'bin/codex-manager-control.py',
  'bin/qofi-codex-manager-launcher',
  'bin/qofi-codex-runner',
  'bin/swarm-grounding-gate.ts',
  'bin/swarm-harness-authority-boundary.ts',
  'bin/swarm-lib.sh',
  'bin/qofi-harness-lifecycle-broker',
  'bin/qofi-fable-reviewer-mcp.py',
  'bin/qofi-review-normalize.py',
  'bin/swarm-account.sh',
  'bin/swarm-runtime-conformance.ts',
  'bin/swarm-restart.sh',
  'bin/swarm-codex-manager.sh',
  'bin/swarm-codex-runtime.py',
  'bin/swarm-codex-runtime.sh',
  'bin/swarm-stop-hook.ts',
  'bin/swarm-up.sh',
  'bridge/binding.ts',
  'bridge/normalize.ts',
  'codex-bridge/app-server-client.ts',
  'codex-bridge/app-server-manager.test.ts',
  'codex-bridge/app-server-manager-client.ts',
  'codex-bridge/app-server-manager-client.test.ts',
  'codex-bridge/app-server-manager.ts',
  'codex-bridge/app-server-native-facade.ts',
  'codex-bridge/app-server-stdio-transport.ts',
  'codex-bridge/app-server-stdio-transport.test.ts',
  'codex-bridge/app-server-unix-socket.ts',
  'codex-bridge/attachments.ts',
  'codex-bridge/attention.ts',
  'codex-bridge/chunk.ts',
  'codex-bridge/codex.ts',
  'codex-bridge/dedicated-runtime.ts',
  'codex-bridge/daemon-lifecycle.ts',
  'codex-bridge/daemon-lifecycle.test.ts',
  'codex-bridge/daemon-lifecycle-contract.test.ts',
  'codex-bridge/daemon-manager-contract.test.ts',
  'codex-bridge/daemon.ts',
  'codex-bridge/events.ts',
  'codex-bridge/fable-completion-review-runner.ts',
  'codex-bridge/gate.ts',
  'codex-bridge/git-broker.ts',
  'codex-bridge/harness-lifecycle-broker-client.ts',
  'codex-bridge/harness-lifecycle-broker-client.test.ts',
  'codex-bridge/lock.ts',
  'codex-bridge/model.ts',
  'codex-bridge/policy.ts',
  'codex-bridge/preflight.ts',
  'codex-bridge/profile-rotation.ts',
  'codex-bridge/prompt.ts',
  'codex-bridge/queue.ts',
  'codex-bridge/repo-lease.ts',
  'codex-bridge/retry-notices.ts',
  'codex-bridge/review-artifacts.ts',
  'codex-bridge/runtime-acl.ts',
  'codex-bridge/runtime.ts',
  'codex-bridge/security.ts',
  'codex-bridge/toolchain.ts',
  'codex-bridge/turn-changes.ts',
  'codex-bridge/workspace.ts',
  'cto-watcher/checkin-coordinator.js',
  'cto-watcher/checkin-coordinator.test.js',
  'cto-watcher/checkin-metrics.js',
  'cto-watcher/checkin-metrics.test.js',
  'cto-watcher/deadletter.js',
  'cto-watcher/deadletter.test.js',
  'cto-watcher/harness-policy-client.js',
  'cto-watcher/harness-policy-client.test.js',
  'cto-watcher/harness-policy-helper.ts',
  'cto-watcher/index.js',
  'cto-watcher/queue.js',
  'cto-watcher/queue.test.js',
  'cto-watcher/roadmap-coordinator.js',
  'cto-watcher/roadmap-coordinator.test.js',
  'cto-watcher/routing.js',
  'cto-watcher/routing.test.js',
  'fable-reviewer.json',
  'swarm-harness/authority-state.ts',
  'swarm-harness/authority-state.test.ts',
  'swarm-harness/checkin.ts',
  'swarm-harness/checkin.test.ts',
  'swarm-harness/cto-checkin.schema.json',
  'swarm-harness/claude-completion-authority.ts',
  'swarm-harness/claude-completion-authority.test.ts',
  'swarm-harness/completion-review-policy.json',
  'swarm-harness/completion-review-policy.ts',
  'swarm-harness/completion-review-policy.test.ts',
  'swarm-harness/event-store.ts',
  'swarm-harness/event-store.test.ts',
  'swarm-harness/events.ts',
  'swarm-harness/events.test.ts',
  'swarm-harness/grounding-budget.ts',
  'swarm-harness/grounding-budget.test.ts',
  'swarm-harness/grounding-gate-cli.test.ts',
  'swarm-harness/grounding-runtime-wrapper.ts',
  'swarm-harness/grounding-runtime-wrapper.test.ts',
  'swarm-harness/parity-adoption.ts',
  'swarm-harness/parity-adoption.test.ts',
  'swarm-harness/parity-conformance.test.ts',
  'swarm-harness/product-context-pack.ts',
  'swarm-harness/product-context-pack.test.ts',
  'swarm-harness/product-context-cache.ts',
  'swarm-harness/product-context-cache.test.ts',
  'swarm-harness/review-data-boundary.ts',
  'swarm-harness/roadmap.ts',
  'swarm-harness/roadmap.test.ts',
  'swarm-harness/discord-roadmap.ts',
  'swarm-harness/runtime-adapters.ts',
  'swarm-harness/runtime-adapters.test.ts',
  'swarm-harness/runtime-conformance.ts',
  'swarm-harness/runtime-conformance.test.ts',
  'swarm-harness/stop-delivery.ts',
  'swarm-harness/stop-delivery.test.ts',
  'swarm-harness/task-boundary.ts',
  'swarm-harness/task-boundary.test.ts',
  'templates/cpo/hooks/discord-reply-nudge.sh',
  'templates/cpo/settings.example.json',
  'templates/engineering-cto/hooks/discord-reply-nudge.sh',
  'templates/engineering-cto/settings.example.json',
  'templates/_base/codex/adversarial-review-output.schema.json',
  'templates/_base/codex/config.toml.template',
  'templates/_base/codex/fable-reviewer-doctrine.md',
  'tests/fixtures/fable-reviewer/claude-sensitive.json',
  'tests/fixtures/fable-reviewer/claude-success.json',
  'tests/fixtures/fable-reviewer/codex-companion-v1-job.json',
  'tests/fixtures/fable-reviewer/diff.patch',
  'tests/fixtures/fable-reviewer/fake-claude.py',
  'tests/fixtures/fable-reviewer/injection.patch',
  'tests/fixtures/fable-reviewer/legacy-v1.json',
  'tests/fixtures/fable-reviewer/synthetic-sensitive-output-tokens.json',
  'tests/test-cpo-discord-reply-nudge.sh',
  'tests/test-claude-runtime-authority.py',
  'tests/test-discord-reply-nudge.sh',
  'tests/test-fable-reviewer-mcp.py',
  'tests/test-harness-lifecycle-broker.py',
  'tests/test-harness-root-authority.sh',
  'tests/test-qofi-review-normalize.py',
  'tests/test-runtime-conformance-launch-gate.sh',
] as const

export type ConformanceRuntime = 'claude' | 'codex'

export interface RuntimeInvocation {
  runtime: ConformanceRuntime
  binary: string
  argvFiles?: readonly string[]
  timeoutMs?: number
}

export interface ConformanceFileIdentity {
  path: string
  size: number
  sha256: string
}

export interface RuntimeIdentity {
  runtime: ConformanceRuntime
  version: string
  binary: ConformanceFileIdentity
  argv_files: ConformanceFileIdentity[]
}

export interface RuntimeConformanceRecord extends RuntimeIdentity {
  schema: typeof RUNTIME_CONFORMANCE_SCHEMA
  suite_sha256: string
  outcome: 'passed' | 'failed'
  completed_at: string
  diagnostic: string | null
}

export type RuntimeConformanceDecision =
  | { ok: true, reason: 'accepted', record: RuntimeConformanceRecord }
  | {
      ok: false
      reason: 'missing' | 'unsafe-record' | 'not-passed' | 'runtime-changed' | 'suite-changed'
      detail: string
    }

export interface RuntimeDiagnosticResult {
  ok: boolean
  record: RuntimeConformanceRecord
}

export interface RuntimeDiagnosticOptions {
  invocation: RuntimeInvocation
  repoRoot: string
  store: RuntimeConformanceStore
  runSuite: () => { ok: boolean, diagnostic?: string }
  now?: () => Date
}

const SHA256 = /^[a-f0-9]{64}$/
const VERSION = /^\d+\.\d+\.\d+$/
const MAX_DIAGNOSTIC_CHARS = 500

function assertRuntime(runtime: string): asserts runtime is ConformanceRuntime {
  if (runtime !== 'claude' && runtime !== 'codex') throw new Error('runtime must be claude or codex')
}

function safeDiagnostic(value: unknown): string {
  return String(value ?? '')
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ')
    .replace(/\b(?:sk|rk|pk)-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}\b/gi, '[REDACTED]')
    .replace(/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/g, '[REDACTED]')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_DIAGNOSTIC_CHARS)
}

function isInside(parent: string, child: string): boolean {
  const rel = relative(parent, child)
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel))
}

function assertPrivateStateRoot(root: string, repoRoot: string): void {
  const rootInfo = lstatSync(root)
  const uid = process.getuid?.()
  if (uid === undefined || !rootInfo.isDirectory() || rootInfo.isSymbolicLink()
    || rootInfo.uid !== uid || (rootInfo.mode & 0o777) !== 0o700) {
    throw new Error('runtime conformance state must be an owner-real mode 0700 directory')
  }
  const canonicalRoot = realpathSync(root)
  const canonicalRepo = realpathSync(repoRoot)
  if (canonicalRoot !== resolve(root)) throw new Error('runtime conformance state path contains symlink indirection')
  if (isInside(canonicalRepo, canonicalRoot)) {
    throw new Error('runtime conformance state must live outside the repository')
  }
}

/** Create a private diagnostic state root, but never repair or follow an unsafe one. */
export function prepareRuntimeConformanceState(root: string, repoRoot: string): void {
  if (!isAbsolute(root) || !isAbsolute(repoRoot)) throw new Error('runtime conformance paths must be absolute')
  const normalized = resolve(root)
  if (!existsSync(normalized)) {
    // Walk one component at a time. `mkdir({recursive:true})` would follow a
    // linked missing parent before the final canonicality check and could
    // create state outside the operator-selected authority boundary.
    let cursor = sep
    for (const component of normalized.slice(sep.length).split(sep).filter(Boolean)) {
      cursor = join(cursor, component)
      try {
        const info = lstatSync(cursor)
        if (!info.isDirectory() || info.isSymbolicLink()) {
          throw new Error('runtime conformance state path contains a linked or non-directory component')
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
        mkdirSync(cursor, { mode: 0o700 })
        const created = lstatSync(cursor)
        const uid = process.getuid?.()
        if (!created.isDirectory() || created.isSymbolicLink() || created.uid !== uid
          || (created.mode & 0o777) !== 0o700) {
          throw new Error('runtime conformance state component was not created privately')
        }
      }
    }
  }
  assertPrivateStateRoot(normalized, resolve(repoRoot))
}

function readBoundedIdentity(path: string, executable: boolean): ConformanceFileIdentity {
  if (!isAbsolute(path)) throw new Error('runtime executable identities require absolute paths')
  const canonical = realpathSync(resolve(path))
  const before = lstatSync(canonical)
  const uid = process.getuid?.()
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
    || (before.uid !== 0 && before.uid !== uid) || (before.mode & 0o022) !== 0
    || (executable && (before.mode & 0o111) === 0)
    || before.size < 1 || before.size > RUNTIME_CONFORMANCE_MAX_EXECUTABLE_BYTES) {
    throw new Error('runtime executable or argv file has unsafe identity, ownership, mode, or size')
  }
  const fd = openSync(canonical, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = fstatSync(fd)
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size
      || opened.mode !== before.mode || opened.uid !== before.uid) {
      throw new Error('runtime executable changed while opening')
    }
    const hash = createHash('sha256')
    const buffer = Buffer.allocUnsafe(1024 * 1024)
    let offset = 0
    while (offset < opened.size) {
      const count = readSync(fd, buffer, 0, Math.min(buffer.length, opened.size - offset), offset)
      if (count <= 0) throw new Error('runtime executable ended before its attested size')
      hash.update(buffer.subarray(0, count))
      offset += count
    }
    const after = fstatSync(fd)
    if (after.dev !== opened.dev || after.ino !== opened.ino || after.size !== opened.size
      || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) {
      throw new Error('runtime executable changed while hashing')
    }
    return { path: canonical, size: opened.size, sha256: hash.digest('hex') }
  } finally {
    closeSync(fd)
  }
}

function sameFileIdentity(left: ConformanceFileIdentity, right: ConformanceFileIdentity): boolean {
  return left.path === right.path && left.size === right.size && left.sha256 === right.sha256
}

export function sameRuntimeIdentity(left: RuntimeIdentity, right: RuntimeIdentity): boolean {
  return left.runtime === right.runtime && left.version === right.version
    && sameFileIdentity(left.binary, right.binary)
    && left.argv_files.length === right.argv_files.length
    && left.argv_files.every((entry, index) => sameFileIdentity(entry, right.argv_files[index]))
}

function parsedVersion(runtime: ConformanceRuntime, output: string): string | null {
  const normalized = output.replace(/\r\n/g, '\n').replace(/\n$/, '')
  if (runtime === 'claude') return normalized.match(/^(\d+\.\d+\.\d+) \(Claude Code\)$/)?.[1] ?? null
  return normalized.match(/^codex-cli (\d+\.\d+\.\d+)$/)?.[1] ?? null
}

/** Probe and bind the exact executable bytes on both sides of `--version`. */
export function probeRuntime(invocation: RuntimeInvocation): RuntimeIdentity {
  assertRuntime(invocation.runtime)
  const timeoutMs = invocation.timeoutMs ?? 10_000
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 60_000) {
    throw new Error('runtime version timeout is invalid')
  }
  const binary = readBoundedIdentity(invocation.binary, true)
  const argvFiles = [...(invocation.argvFiles ?? [])].map(path => readBoundedIdentity(path, false))
  if (argvFiles.length > 4) throw new Error('runtime argv file count exceeds bound')
  const run = spawnSync(binary.path, [...argvFiles.map(item => item.path), '--version'], {
    encoding: 'utf8',
    timeout: timeoutMs,
    maxBuffer: 16 * 1024,
    env: {
      HOME: process.env.HOME,
      PATH: `${dirname(binary.path)}:/usr/bin:/bin:/usr/sbin:/sbin`,
      LANG: 'C',
      LC_ALL: 'C',
    },
  })
  if (run.error || run.status !== 0 || (run.stderr ?? '') !== '') {
    throw new Error(`runtime version probe failed: ${safeDiagnostic(run.error?.message ?? `exit ${run.status}`)}`)
  }
  const version = parsedVersion(invocation.runtime, run.stdout ?? '')
  if (!version || !VERSION.test(version)) throw new Error('runtime version output has an unsupported exact form')
  const afterBinary = readBoundedIdentity(binary.path, true)
  const afterArgv = argvFiles.map(item => readBoundedIdentity(item.path, false))
  const identity = { runtime: invocation.runtime, version, binary, argv_files: argvFiles }
  const after = { runtime: invocation.runtime, version, binary: afterBinary, argv_files: afterArgv }
  if (!sameRuntimeIdentity(identity, after)) throw new Error('runtime changed during its version probe')
  return identity
}

function runExactRuntimeHelp(
  identity: RuntimeIdentity,
  args: readonly string[],
  timeoutMs: number,
): string {
  const argv = [identity.binary.path, ...identity.argv_files.map(item => item.path), ...args]
  const run = spawnSync(argv[0]!, argv.slice(1), {
    encoding: 'utf8',
    timeout: timeoutMs,
    maxBuffer: RUNTIME_CONFORMANCE_MAX_HELP_BYTES,
    env: {
      HOME: process.env.HOME,
      PATH: `${dirname(identity.binary.path)}:/usr/bin:/bin:/usr/sbin:/sbin`,
      LANG: 'C',
      LC_ALL: 'C',
      NO_COLOR: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (run.error || run.status !== 0 || (run.stderr ?? '') !== '') {
    throw new Error(
      `runtime production help probe failed for ${args.join(' ')}: `
      + safeDiagnostic(run.error?.message ?? `exit ${run.status}`),
    )
  }
  const output = String(run.stdout ?? '').replace(/\r\n/g, '\n')
  if (Buffer.byteLength(output) < 1 || Buffer.byteLength(output) > RUNTIME_CONFORMANCE_MAX_HELP_BYTES) {
    throw new Error('runtime production help probe returned invalid output bounds')
  }
  return output
}

function requireHelpLines(output: string, patterns: readonly RegExp[], runtime: ConformanceRuntime): void {
  for (const pattern of patterns) {
    pattern.lastIndex = 0
    if (!pattern.test(output)) {
      throw new Error(`${runtime} production surface is incompatible: missing ${pattern.source}`)
    }
  }
}

/**
 * No-network compatibility proof for the actual production CLI surfaces. The
 * exact descriptor-attested executable/argv-prefix is used for every probe;
 * PATH lookup never participates after identity capture.
 */
export function probeRuntimeProductionSurface(invocation: RuntimeInvocation): RuntimeIdentity {
  const timeoutMs = invocation.timeoutMs ?? 10_000
  const before = probeRuntime(invocation)
  if (invocation.runtime === 'claude') {
    const help = runExactRuntimeHelp(before, ['--help'], timeoutMs)
    requireHelpLines(help, [
      /^\s+-p, --print\b/m,
      /^\s+--output-format <format>\s/m,
      /^\s+--model <model>\s/m,
      /^\s+--tools <tools\.\.\.>\s/m,
      /^\s+--strict-mcp-config\b/m,
      /^\s+--setting-sources <sources>\s/m,
      /^\s+--settings <file-or-json>\s/m,
      /^\s+--safe-mode\b/m,
    ], 'claude')
  } else {
    const help = runExactRuntimeHelp(before, ['--help'], timeoutMs)
    requireHelpLines(help, [
      /^\s+exec\s+Run Codex non-interactively\b/m,
      /^\s+app-server\s+/m,
      /^\s+--remote <ADDR>\s/m,
      /^\s+--strict-config\b/m,
      /^\s+--no-alt-screen\b/m,
    ], 'codex')
    const execHelp = runExactRuntimeHelp(before, ['exec', '--help'], timeoutMs)
    requireHelpLines(execHelp, [
      /^Usage: codex exec\b/m,
      /^\s+--strict-config\b/m,
      /^\s+--json\b/m,
    ], 'codex')
    const appServerHelp = runExactRuntimeHelp(before, ['app-server', '--help'], timeoutMs)
    requireHelpLines(appServerHelp, [
      /^Usage: codex app-server\b/m,
      /^\s+--listen <URL>\s/m,
      /^\s+--strict-config\b/m,
    ], 'codex')
  }
  const after = probeRuntime(invocation)
  if (!sameRuntimeIdentity(before, after)) {
    throw new Error('runtime changed during its production-surface probe')
  }
  return before
}

function readSuiteFile(repoRoot: string, relativePath: string): Buffer {
  const path = join(repoRoot, relativePath)
  const info = lstatSync(path)
  const uid = process.getuid?.()
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1
    || (info.uid !== 0 && info.uid !== uid) || (info.mode & 0o022) !== 0
    || info.size < 1 || info.size > 2 * 1024 * 1024 || realpathSync(path) !== path) {
    throw new Error(`conformance suite source is unsafe: ${relativePath}`)
  }
  return readFileSync(path)
}

/** Hash every policy and fixture consumed by the shared parity scenario suite. */
export function runtimeConformanceSuiteDigest(repoRoot: string): string {
  if (!isAbsolute(repoRoot)) throw new Error('repository root must be absolute')
  const root = realpathSync(resolve(repoRoot))
  const rootInfo = statSync(root)
  if (!rootInfo.isDirectory()) throw new Error('repository root is not a directory')
  const hash = createHash('sha256')
  for (const relativePath of RUNTIME_CONFORMANCE_SUITE_FILES) {
    const bytes = readSuiteFile(root, relativePath)
    hash.update(relativePath).update('\0').update(String(bytes.length)).update('\0').update(bytes)
  }
  return hash.digest('hex')
}

function canonicalRecord(record: RuntimeConformanceRecord): string {
  return `${JSON.stringify(record)}\n`
}

function parseFileIdentity(value: unknown): ConformanceFileIdentity {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid file identity')
  const entry = value as Record<string, unknown>
  if (Object.keys(entry).sort().join(',') !== 'path,sha256,size'
    || typeof entry.path !== 'string' || !isAbsolute(entry.path)
    || typeof entry.size !== 'number' || !Number.isSafeInteger(entry.size) || entry.size < 1
    || typeof entry.sha256 !== 'string' || !SHA256.test(entry.sha256)) {
    throw new Error('invalid file identity')
  }
  return { path: entry.path, size: entry.size, sha256: entry.sha256 }
}

function parseRecord(value: unknown): RuntimeConformanceRecord {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid conformance record')
  const entry = value as Record<string, unknown>
  const expectedKeys = [
    'argv_files', 'binary', 'completed_at', 'diagnostic', 'outcome', 'runtime',
    'schema', 'suite_sha256', 'version',
  ].sort().join(',')
  if (Object.keys(entry).sort().join(',') !== expectedKeys
    || entry.schema !== RUNTIME_CONFORMANCE_SCHEMA
    || (entry.runtime !== 'claude' && entry.runtime !== 'codex')
    || typeof entry.version !== 'string' || !VERSION.test(entry.version)
    || !Array.isArray(entry.argv_files) || entry.argv_files.length > 4
    || typeof entry.suite_sha256 !== 'string' || !SHA256.test(entry.suite_sha256)
    || (entry.outcome !== 'passed' && entry.outcome !== 'failed')
    || typeof entry.completed_at !== 'string' || !Number.isFinite(Date.parse(entry.completed_at))
    || (entry.diagnostic !== null && (typeof entry.diagnostic !== 'string'
      || entry.diagnostic.length > MAX_DIAGNOSTIC_CHARS))) {
    throw new Error('invalid conformance record')
  }
  return {
    schema: RUNTIME_CONFORMANCE_SCHEMA,
    runtime: entry.runtime,
    version: entry.version,
    binary: parseFileIdentity(entry.binary),
    argv_files: entry.argv_files.map(parseFileIdentity),
    suite_sha256: entry.suite_sha256,
    outcome: entry.outcome,
    completed_at: entry.completed_at,
    diagnostic: entry.diagnostic,
  }
}

export class RuntimeConformanceStore {
  readonly root: string
  readonly repoRoot: string

  constructor(root: string, repoRoot: string) {
    if (!isAbsolute(root) || !isAbsolute(repoRoot)) throw new Error('runtime conformance paths must be absolute')
    this.root = resolve(root)
    this.repoRoot = resolve(repoRoot)
    assertPrivateStateRoot(this.root, this.repoRoot)
  }

  private path(runtime: ConformanceRuntime): string {
    assertRuntime(runtime)
    return join(this.root, `${runtime}.json`)
  }

  read(runtime: ConformanceRuntime): RuntimeConformanceRecord | null {
    const path = this.path(runtime)
    if (!existsSync(path)) return null
    const before = lstatSync(path)
    const uid = process.getuid?.()
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
      || before.uid !== uid || (before.mode & 0o777) !== 0o600
      || before.size < 2 || before.size > RUNTIME_CONFORMANCE_MAX_RECORD_BYTES) {
      throw new Error('runtime conformance record is not a private real file')
    }
    const fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    try {
      const opened = fstatSync(fd)
      if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size
        || opened.mode !== before.mode || opened.uid !== before.uid || opened.nlink !== before.nlink) {
        throw new Error('runtime conformance record changed while opening')
      }
      const bytes = readFileSync(fd)
      const after = fstatSync(fd)
      if (after.dev !== opened.dev || after.ino !== opened.ino || after.size !== opened.size
        || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) {
        throw new Error('runtime conformance record changed while reading')
      }
      let parsed: unknown
      try { parsed = JSON.parse(bytes.toString('utf8')) } catch { throw new Error('invalid conformance record JSON') }
      const record = parseRecord(parsed)
      if (record.runtime !== runtime || canonicalRecord(record) !== bytes.toString('utf8')) {
        throw new Error('runtime conformance record identity or canonical bytes mismatch')
      }
      return record
    } finally {
      closeSync(fd)
    }
  }

  write(record: RuntimeConformanceRecord): void {
    const validated = parseRecord(record)
    const path = this.path(validated.runtime)
    assertPrivateStateRoot(this.root, this.repoRoot)
    if (existsSync(path)) this.read(validated.runtime)
    const bytes = canonicalRecord(validated)
    if (Buffer.byteLength(bytes) > RUNTIME_CONFORMANCE_MAX_RECORD_BYTES) {
      throw new Error('runtime conformance record exceeds byte bound')
    }
    const temp = join(this.root, `.${validated.runtime}.tmp.${process.pid}.${randomBytes(8).toString('hex')}`)
    let fd: number | undefined
    try {
      fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL
        | (constants.O_NOFOLLOW ?? 0), 0o600)
      writeFileSync(fd, bytes)
      fsyncSync(fd)
      closeSync(fd)
      fd = undefined
      renameSync(temp, path)
      const directoryFd = openSync(this.root, constants.O_RDONLY)
      try { fsyncSync(directoryFd) } finally { closeSync(directoryFd) }
      const written = this.read(validated.runtime)
      if (!written || canonicalRecord(written) !== bytes) throw new Error('conformance record publication failed')
    } finally {
      if (fd !== undefined) try { closeSync(fd) } catch {}
      rmSync(temp, { force: true })
    }
  }
}

export function evaluateRuntimeConformance(
  invocation: RuntimeInvocation,
  repoRoot: string,
  store: RuntimeConformanceStore,
): RuntimeConformanceDecision {
  let record: RuntimeConformanceRecord | null
  try { record = store.read(invocation.runtime) } catch (error) {
    return { ok: false, reason: 'unsafe-record', detail: safeDiagnostic(error) }
  }
  if (!record) return { ok: false, reason: 'missing', detail: 'no conformance record exists' }
  if (record.outcome !== 'passed') {
    return { ok: false, reason: 'not-passed', detail: record.diagnostic ?? 'the last conformance run failed' }
  }
  let identity: RuntimeIdentity
  try { identity = probeRuntime(invocation) } catch (error) {
    return { ok: false, reason: 'runtime-changed', detail: safeDiagnostic(error) }
  }
  if (!sameRuntimeIdentity(record, identity)) {
    return { ok: false, reason: 'runtime-changed', detail: 'installed runtime identity or version changed' }
  }
  let suiteDigest: string
  try { suiteDigest = runtimeConformanceSuiteDigest(repoRoot) } catch (error) {
    return { ok: false, reason: 'suite-changed', detail: safeDiagnostic(error) }
  }
  if (record.suite_sha256 !== suiteDigest) {
    return { ok: false, reason: 'suite-changed', detail: 'parity conformance suite changed' }
  }
  return { ok: true, reason: 'accepted', record }
}

/** Run operator-UID probes/suite and record a non-authoritative diagnostic outcome. */
export function runRuntimeDiagnostic(options: RuntimeDiagnosticOptions): RuntimeDiagnosticResult {
  const beforeIdentity = probeRuntime(options.invocation)
  const beforeSuite = runtimeConformanceSuiteDigest(options.repoRoot)
  let surfaceOk = false
  let surfaceDiagnostic = ''
  try {
    const surfaceIdentity = probeRuntimeProductionSurface(options.invocation)
    surfaceOk = sameRuntimeIdentity(beforeIdentity, surfaceIdentity)
    if (!surfaceOk) surfaceDiagnostic = 'runtime identity changed before production-surface proof'
  } catch (error) {
    surfaceDiagnostic = safeDiagnostic(error)
  }
  let suite: { ok: boolean, diagnostic?: string }
  if (surfaceOk) {
    try { suite = options.runSuite() } catch (error) {
      suite = { ok: false, diagnostic: safeDiagnostic(error) }
    }
  } else {
    suite = { ok: false, diagnostic: surfaceDiagnostic || 'runtime production surface is incompatible' }
  }
  let unchanged = false
  let changeDiagnostic = ''
  try {
    const afterIdentity = probeRuntimeProductionSurface(options.invocation)
    const afterSuite = runtimeConformanceSuiteDigest(options.repoRoot)
    unchanged = sameRuntimeIdentity(beforeIdentity, afterIdentity) && beforeSuite === afterSuite
    if (!unchanged) changeDiagnostic = 'runtime or conformance suite changed while tests were running'
  } catch (error) {
    changeDiagnostic = safeDiagnostic(error)
  }
  const ok = surfaceOk && suite.ok && unchanged
  const diagnostic = ok ? null : safeDiagnostic(
    surfaceDiagnostic || changeDiagnostic || suite.diagnostic || 'production lifecycle suite failed',
  )
  const record: RuntimeConformanceRecord = {
    schema: RUNTIME_CONFORMANCE_SCHEMA,
    ...beforeIdentity,
    suite_sha256: beforeSuite,
    outcome: ok ? 'passed' : 'failed',
    completed_at: (options.now ?? (() => new Date()))().toISOString(),
    diagnostic,
  }
  options.store.write(record)
  return { ok, record }
}
