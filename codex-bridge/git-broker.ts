import { spawn } from 'child_process'
import { createHash, randomUUID } from 'crypto'
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'path'
import { checkWorkspaceSafety } from './preflight.ts'
import { isOperatorOwnedRelativePath } from './workspace.ts'

export type GitControlCommand =
  | { action: 'commit'; message: string; paths: string[] }
  | { action: 'branch'; name: string }
  | { action: 'retire'; name: string }

export type ParsedGitControl =
  | { matched: false }
  | { matched: true; command: GitControlCommand | null; error?: string }

const PROTECTED_BRANCH_ALIASES = new Set([
  'main', 'master', 'dev', 'develop', 'prod', 'production', 'release', 'trunk', 'staging',
])

function validBranchName(name: string): boolean {
  const normalizedSegments = name.toLowerCase().split('/')
    .map(segment => segment.replace(/[._-]/g, ''))
  return (
    /^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$/.test(name)
    && !name.includes('..')
    && !name.includes('//')
    && !name.includes('@{')
    && !normalizedSegments.some(segment => (
      PROTECTED_BRANCH_ALIASES.has(segment)
      || [...PROTECTED_BRANCH_ALIASES].some(alias => segment.startsWith(alias))
    ))
  )
}

export function parseGitControlMessage(text: string, attachmentCount = 0): ParsedGitControl {
  const input = text.trim()
  if (!input.startsWith('!qofi-git')) return { matched: false }
  if (attachmentCount !== 0) {
    return { matched: true, command: null, error: 'attachments are not allowed' }
  }
  const branchPrefix = '!qofi-git branch '
  if (input.startsWith(branchPrefix)) {
    const name = input.slice(branchPrefix.length)
    if (!validBranchName(name)) {
      return { matched: true, command: null, error: 'invalid or protected branch name' }
    }
    return { matched: true, command: { action: 'branch', name } }
  }

  const retirePrefix = '!qofi-git retire '
  if (input.startsWith(retirePrefix)) {
    const name = input.slice(retirePrefix.length)
    if (!validBranchName(name)) {
      return { matched: true, command: null, error: 'invalid or protected branch name' }
    }
    return { matched: true, command: { action: 'retire', name } }
  }

  const commitPrefix = '!qofi-git commit '
  if (!input.startsWith(commitPrefix)) {
    return { matched: true, command: null, error: 'expected commit, branch, or retire control' }
  }
  const raw = input.slice(commitPrefix.length)
  if (raw.length === 0 || raw.length > 8192) {
    return { matched: true, command: null, error: 'commit JSON exceeds size bound' }
  }
  let value: unknown
  try { value = JSON.parse(raw) } catch {
    return { matched: true, command: null, error: 'invalid commit JSON' }
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return { matched: true, command: null, error: 'commit JSON must be an object' }
  }
  const record = value as Record<string, unknown>
  if (Object.keys(record).sort().join(',') !== 'message,paths') {
    return { matched: true, command: null, error: 'commit JSON keys must be message and paths' }
  }
  if (
    typeof record.message !== 'string'
    || record.message.trim().length === 0
    || record.message.length > 200
    || /[\x00-\x1f\x7f]/.test(record.message)
  ) return { matched: true, command: null, error: 'commit message must be one line, 1..200 chars' }
  if (
    !Array.isArray(record.paths)
    || record.paths.length === 0
    || record.paths.length > 32
    || !record.paths.every(path => typeof path === 'string')
  ) return { matched: true, command: null, error: 'paths must be an array of 1..32 strings' }
  const paths = [...new Set(record.paths as string[])]
  if (paths.length !== record.paths.length) {
    return { matched: true, command: null, error: 'duplicate paths are not allowed' }
  }
  return {
    matched: true,
    command: { action: 'commit', message: record.message.trim(), paths },
  }
}

export type GitBrokerResult =
  | { ok: true; action: 'commit'; commit: string }
  | { ok: true; action: 'branch'; branch: string }
  | { ok: true; action: 'retire'; branch: string }
  | {
      ok: false
      errorKind:
        | 'workspace'
        | 'invalid-path'
        | 'operator-owned'
        | 'staged-changes'
        | 'no-changes'
        | 'branch-exists'
        | 'policy'
        | 'git-failed'
        | 'timeout'
        | 'output-limit'
        | 'aborted'
      detail: string
    }

export type GitBrokerOptions = {
  cwd: string
  stateDir: string
  gitBin: string
  environment: NodeJS.ProcessEnv
  authorName?: string
  authorEmail?: string
  timeoutMs?: number
  maxOutputBytes?: number
  maxFileBytes?: number
  maxTotalBytes?: number
  /** Exact post-turn path fingerprints; commit requests must be a subset. */
  allowedChanges?: Readonly<Record<string, string | null>>
  signal?: AbortSignal
  onChildPid?: (pid: number | null) => void
  /** Test seam invoked after the broker side-ref CAS and before registry finalization. */
  onAfterRefAdvance?: () => void
  /** Test seam invoked after side-ref creation and before registry finalization. */
  onAfterBranchRefAdvance?: () => void
  /** Test seam invoked immediately before a new branch registry is persisted. */
  onBeforeBranchRegistrySave?: () => void
  /** Test seam invoked immediately before the final path/ref transaction check. */
  onBeforeRefTransaction?: () => void
  /** Test-only observer fired after each durable transaction boundary. */
  onDurabilityEvent?: (event: GitBrokerDurabilityEvent) => void
}

export type GitBrokerDurabilityEvent =
  | 'branch-journal-durable'
  | 'branch-ref-cas-complete'
  | 'branch-journal-removed-durable'
  | 'commit-journal-durable'
  | 'commit-ref-cas-complete'
  | 'commit-private-state-removed-durable'
  | 'commit-journal-removed-durable'
  | 'registry-durable'

type ProcessResult = {
  code: number | null
  output: string
  terminal?: 'timeout' | 'output-limit' | 'aborted'
}

function runProcess(
  bin: string,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv,
  options: GitBrokerOptions,
  input?: Buffer | string,
): Promise<ProcessResult> {
  return new Promise(resolveResult => {
    if (options.signal?.aborted) {
      resolveResult({ code: null, output: '', terminal: 'aborted' })
      return
    }
    let child
    try {
      child = spawn(bin, args, {
        cwd,
        env,
        stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
        detached: process.platform !== 'win32',
      })
    } catch (err) {
      resolveResult({ code: null, output: String(err).slice(0, 1000) })
      return
    }
    const timeoutMs = options.timeoutMs ?? 120_000
    const maxOutput = options.maxOutputBytes ?? 256 * 1024
    let output = ''
    let bytes = 0
    let terminal: ProcessResult['terminal']
    let killTimer: ReturnType<typeof setTimeout> | undefined
    let settled = false
    const signalGroup = (signal: NodeJS.Signals) => {
      if (!child.pid) return
      try {
        if (process.platform !== 'win32') process.kill(-child.pid, signal)
        else child.kill(signal)
      } catch { try { child.kill(signal) } catch {} }
    }
    const cancel = (kind: NonNullable<ProcessResult['terminal']>) => {
      if (!terminal) terminal = kind
      signalGroup('SIGTERM')
      if (!killTimer) {
        killTimer = setTimeout(() => signalGroup('SIGKILL'), 500)
        killTimer.unref?.()
      }
    }
    const consume = (data: Buffer) => {
      bytes += data.byteLength
      if (bytes > maxOutput) return cancel('output-limit')
      output += data.toString()
      if (output.length > 32 * 1024) output = output.slice(-32 * 1024)
    }
    child.stdout.on('data', consume)
    child.stderr.on('data', consume)
    if (input !== undefined && child.stdin) {
      child.stdin.on('error', () => {})
      child.stdin.end(input)
    }
    const onAbort = () => cancel('aborted')
    options.signal?.addEventListener('abort', onAbort, { once: true })
    try { options.onChildPid?.(child.pid ?? null) } catch {}
    const timer = setTimeout(() => cancel('timeout'), timeoutMs)
    timer.unref?.()
    child.on('error', err => { output += `\n${err.message}` })
    child.on('close', code => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (killTimer) clearTimeout(killTimer)
      signalGroup('SIGKILL')
      options.signal?.removeEventListener('abort', onAbort)
      try { options.onChildPid?.(null) } catch {}
      resolveResult({ code, output: output.trim().slice(-32 * 1024), terminal })
    })
  })
}

function inside(root: string, path: string): boolean {
  return path === root || path.startsWith(root + sep)
}

type ValidatedPath =
  | { ok: true; path: string; absolute: string; exists: false }
  | { ok: true; path: string; absolute: string; exists: true; mode: '100644' | '100755'; content: Buffer }
  | { ok: false; kind: 'invalid-path' | 'operator-owned'; detail: string }

function validateCommitPath(
  root: string,
  requested: string,
  maxFileBytes: number,
): ValidatedPath {
  if (
    !requested
    || requested.length > 300
    || isAbsolute(requested)
    || requested.includes('\\')
    || /[\x00-\x1f\x7f]/.test(requested)
  ) return { ok: false, kind: 'invalid-path', detail: 'path must be a bounded relative path' }
  const normalized = requested.replace(/^\.\//, '')
  const absolute = resolve(root, normalized)
  if (!inside(root, absolute) || normalized === '.' || relative(root, absolute).startsWith('..')) {
    return { ok: false, kind: 'invalid-path', detail: 'path escapes workspace' }
  }
  const relativePath = relative(root, absolute).split(sep).join('/')
  if (isOperatorOwnedRelativePath(relativePath)) {
    return { ok: false, kind: 'operator-owned', detail: 'path is host/operator managed' }
  }

  let probe = absolute
  while (!existsSync(probe) && probe !== root) probe = dirname(probe)
  try {
    const realProbe = realpathSync(probe)
    if (!inside(root, realProbe)) {
      return { ok: false, kind: 'invalid-path', detail: 'path traverses a symlink outside workspace' }
    }
    if (!existsSync(absolute)) {
      return { ok: true, path: relativePath, absolute, exists: false }
    }
    const before = lstatSync(absolute)
    if (!before.isFile() || before.isSymbolicLink()) {
      return { ok: false, kind: 'invalid-path', detail: 'only regular files and explicit deletions are allowed' }
    }
    if (before.size > maxFileBytes) {
      return { ok: false, kind: 'invalid-path', detail: 'file exceeds broker size bound' }
    }
    const noFollow = typeof constants.O_NOFOLLOW === 'number' ? constants.O_NOFOLLOW : 0
    const fd = openSync(absolute, constants.O_RDONLY | noFollow)
    try {
      const opened = fstatSync(fd)
      if (!opened.isFile() || opened.size > maxFileBytes) {
        return { ok: false, kind: 'invalid-path', detail: 'opened path is not a bounded regular file' }
      }
      const content = readFileSync(fd)
      return {
        ok: true,
        path: relativePath,
        absolute,
        exists: true,
        mode: (opened.mode & 0o111) !== 0 ? '100755' : '100644',
        content,
      }
    } finally {
      closeSync(fd)
    }
  } catch (err) {
    return { ok: false, kind: 'invalid-path', detail: `could not validate path: ${err}`.slice(0, 500) }
  }
}

function safeIdentity(raw: string | undefined, fallback: string, email = false): string {
  if (!raw || raw.length > 200 || /[\x00-\x1f\x7f<>]/.test(raw)) return fallback
  if (email && !/^[^@\s]+@[^@\s]+$/.test(raw)) return fallback
  return raw
}

function brokerEnv(
  options: GitBrokerOptions,
  root: string,
  gitDir: string,
  indexFile?: string,
): NodeJS.ProcessEnv {
  const source = options.environment
  const env: NodeJS.ProcessEnv = {
    PATH: source.PATH,
    TMPDIR: source.TMPDIR,
    TMP: source.TMP,
    TEMP: source.TEMP,
    HOME: options.stateDir,
    XDG_CONFIG_HOME: join(options.stateDir, 'xdg-config'),
    XDG_CACHE_HOME: join(options.stateDir, 'xdg-cache'),
    GIT_DIR: gitDir,
    GIT_WORK_TREE: root,
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_SYSTEM: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_ATTR_NOSYSTEM: '1',
    GIT_TERMINAL_PROMPT: '0',
    GIT_ASKPASS: '/usr/bin/false',
    GIT_EDITOR: '/usr/bin/false',
    GIT_SEQUENCE_EDITOR: '/usr/bin/false',
    GIT_LITERAL_PATHSPECS: '1',
    GIT_NO_REPLACE_OBJECTS: '1',
    GIT_AUTHOR_NAME: safeIdentity(options.authorName, 'Codex Bridge'),
    GIT_AUTHOR_EMAIL: safeIdentity(options.authorEmail, 'codex-bridge@localhost', true),
    GIT_COMMITTER_NAME: safeIdentity(options.authorName, 'Codex Bridge'),
    GIT_COMMITTER_EMAIL: safeIdentity(options.authorEmail, 'codex-bridge@localhost', true),
    LC_ALL: 'C',
  }
  if (indexFile) env.GIT_INDEX_FILE = indexFile
  return env
}

// Every invocation receives these last-precedence overrides. The broker does
// not execute porcelain or a repo hook, but these also suppress hooks used by
// update-ref and prevent hostile local config from enabling fsmonitor,
// attributes, filters, external diffs, or credential helpers.
const SAFE_CONFIG_ARGS = [
  '-c', 'core.hooksPath=/dev/null',
  '-c', 'core.fsmonitor=false',
  '-c', 'core.untrackedCache=false',
  '-c', 'core.attributesFile=/dev/null',
  '-c', 'diff.external=',
  '-c', 'credential.helper=',
  // The broker's own journal is only useful if the Git objects and ref CAS it
  // describes also survive an unclean shutdown. macOS otherwise defaults to
  // writeout-only for several Git durability classes.
  '-c', 'core.fsync=committed,reference',
  '-c', 'core.fsyncMethod=fsync',
] as const

function terminalFailure(result: ProcessResult): GitBrokerResult | null {
  if (!result.terminal) return null
  return {
    ok: false,
    errorKind: result.terminal,
    detail: `git subprocess ${result.terminal}`,
  }
}

function isDocPath(path: string): boolean {
  const parts = path.split('/')
  const name = parts.at(-1) ?? ''
  return (
    /\.mdx?$/i.test(name)
    || parts.some(part => part.toLowerCase() === 'docs')
    || /^ADR-/i.test(name)
    || /^PROJECT_SPEC/i.test(name)
  )
}

const SECRET_PATTERNS: ReadonlyArray<[string, RegExp]> = [
  ['Discord bot token', /MT[A-Za-z0-9._-]{40,}/],
  ['AWS access key', /AKIA[0-9A-Z]{16}/],
  ['GitHub token', /gh[pousr]_[A-Za-z0-9]{36}/],
  ['Slack token', /xox[baprs]-[0-9]{10,}-[A-Za-z0-9-]+/],
  ['PEM private key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['JWT-shaped value', /eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/],
]

function secretPattern(content: Buffer): string | null {
  const text = content.toString('utf8')
  for (const [name, pattern] of SECRET_PATTERNS) {
    if (pattern.test(text)) return name
  }
  return null
}

export function gitFileFingerprint(mode: '100644' | '100755', content: Buffer): string {
  return `${mode}:${createHash('sha256').update(content).digest('hex')}`
}

type BranchRegistry = {
  version: 1
  branches: Record<string, { tip: string }>
}

function branchRegistryPath(stateDir: string): string {
  return join(stateDir, 'branches.json')
}

type DurabilityObserver = GitBrokerOptions['onDurabilityEvent']

function notifyDurability(observer: DurabilityObserver, event: GitBrokerDurabilityEvent): void {
  try { observer?.(event) } catch {}
}

function fsyncDirectory(path: string): void {
  const directoryOnly = typeof constants.O_DIRECTORY === 'number' ? constants.O_DIRECTORY : 0
  const fd = openSync(path, constants.O_RDONLY | directoryOnly)
  try {
    if (!fstatSync(fd).isDirectory()) throw new Error('durability parent is not a directory')
    fsyncSync(fd)
  } finally {
    closeSync(fd)
  }
}

function durableReplaceFile(
  path: string,
  content: string,
  observer: DurabilityObserver,
  event: GitBrokerDurabilityEvent,
): void {
  const parent = dirname(path)
  const temp = join(parent, `.${basename(path)}.tmp-${process.pid}-${randomUUID()}`)
  const noFollow = typeof constants.O_NOFOLLOW === 'number' ? constants.O_NOFOLLOW : 0
  let fd: number | null = null
  try {
    fd = openSync(
      temp,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | noFollow,
      0o600,
    )
    fchmodSync(fd, 0o600)
    writeFileSync(fd, content)
    fsyncSync(fd)
    closeSync(fd)
    fd = null
    renameSync(temp, path)
    fsyncDirectory(parent)
    notifyDurability(observer, event)
  } catch (err) {
    if (fd !== null) {
      try { closeSync(fd) } catch {}
    }
    rmSync(temp, { force: true })
    throw err
  }
}

function durableRemoveFile(
  path: string,
  observer: DurabilityObserver,
  event: GitBrokerDurabilityEvent,
): void {
  rmSync(path, { force: true })
  fsyncDirectory(dirname(path))
  notifyDurability(observer, event)
}

function loadBranchRegistry(stateDir: string): BranchRegistry {
  const path = branchRegistryPath(stateDir)
  try {
    const stat = lstatSync(path)
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || stat.uid !== uid
      || (stat.mode & 0o777) !== 0o600
      || stat.size > 64 * 1024
    ) {
      throw new Error('branch registry is not a bounded regular file')
    }
    const value = JSON.parse(readFileSync(path, 'utf8')) as unknown
    if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid branch registry')
    const record = value as Record<string, unknown>
    if (record.version !== 1 || record.branches === null || typeof record.branches !== 'object' || Array.isArray(record.branches)) {
      throw new Error('invalid branch registry shape')
    }
    const branches: BranchRegistry['branches'] = Object.create(null)
    for (const [name, raw] of Object.entries(record.branches as Record<string, unknown>)) {
      if (!validBranchName(name) || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        throw new Error('invalid registered branch')
      }
      const tip = (raw as Record<string, unknown>).tip
      if (typeof tip !== 'string' || !/^[0-9a-f]{40,64}$/.test(tip)) throw new Error('invalid registered branch tip')
      branches[name] = { tip }
    }
    if (Object.keys(branches).length > 1) throw new Error('branch registry exceeds one active capability')
    return { version: 1, branches }
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      return { version: 1, branches: Object.create(null) }
    }
    throw err
  }
}

function saveBranchRegistry(
  stateDir: string,
  registry: BranchRegistry,
  observer?: DurabilityObserver,
): void {
  const path = branchRegistryPath(stateDir)
  durableReplaceFile(
    path,
    JSON.stringify(registry, null, 2) + '\n',
    observer,
    'registry-durable',
  )
}

const UNSAFE_GIT_STATES = [
  'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG',
  'rebase-merge', 'rebase-apply', 'sequencer',
] as const

function indexFingerprint(path: string): string | null {
  try {
    const stat = lstatSync(path)
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 256 * 1024 * 1024) {
      throw new Error('real index is not a bounded regular file')
    }
    return createHash('sha256').update(readFileSync(path)).digest('hex')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw err
  }
}

type GitTransactionJournal = {
  version: 2
  kind: 'commit'
  ref: string
  branch: string
  oldTip: string
  newTip: string
  tempDir: string
}

type BranchTransactionJournal = {
  version: 2
  kind: 'branch'
  newRef: string
  newBranch: string
  head: string
}

function transactionPath(stateDir: string): string {
  return join(stateDir, 'transaction.json')
}

function branchTransactionPath(stateDir: string): string {
  return join(stateDir, 'branch-transaction.json')
}

function saveTransaction(
  stateDir: string,
  transaction: GitTransactionJournal,
  observer?: DurabilityObserver,
): void {
  const path = transactionPath(stateDir)
  durableReplaceFile(
    path,
    JSON.stringify(transaction, null, 2) + '\n',
    observer,
    'commit-journal-durable',
  )
}

function saveBranchTransaction(
  stateDir: string,
  transaction: BranchTransactionJournal,
  observer?: DurabilityObserver,
): void {
  const path = branchTransactionPath(stateDir)
  durableReplaceFile(
    path,
    JSON.stringify(transaction, null, 2) + '\n',
    observer,
    'branch-journal-durable',
  )
}

function loadBranchTransaction(stateDir: string): BranchTransactionJournal | null {
  const path = branchTransactionPath(stateDir)
  try {
    const stat = lstatSync(path)
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || stat.uid !== uid
      || (stat.mode & 0o777) !== 0o600
      || stat.size > 16 * 1024
    ) throw new Error('unsafe branch transaction journal')
    const value = JSON.parse(readFileSync(path, 'utf8')) as Partial<BranchTransactionJournal>
    if (
      value.version !== 2
      || value.kind !== 'branch'
      || typeof value.newRef !== 'string'
      || typeof value.newBranch !== 'string'
      || typeof value.head !== 'string'
      || value.newRef !== `refs/heads/${value.newBranch}`
      || !validBranchName(value.newBranch)
      || !/^[0-9a-f]{40,64}$/.test(value.head)
    ) throw new Error('malformed branch transaction journal')
    return value as BranchTransactionJournal
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw err
  }
}

function loadTransaction(stateDir: string): GitTransactionJournal | null {
  const path = transactionPath(stateDir)
  try {
    const stat = lstatSync(path)
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || stat.uid !== uid
      || (stat.mode & 0o777) !== 0o600
      || stat.size > 16 * 1024
    ) throw new Error('unsafe Git transaction journal')
    const value = JSON.parse(readFileSync(path, 'utf8')) as Partial<GitTransactionJournal>
    if (
      value.version !== 2
      || value.kind !== 'commit'
      || typeof value.ref !== 'string'
      || typeof value.branch !== 'string'
      || typeof value.oldTip !== 'string'
      || typeof value.newTip !== 'string'
      || typeof value.tempDir !== 'string'
      || value.ref !== `refs/heads/${value.branch}`
      || !validBranchName(value.branch)
      || !/^[0-9a-f]{40,64}$/.test(value.oldTip)
      || !/^[0-9a-f]{40,64}$/.test(value.newTip)
      || value.oldTip === value.newTip
      || !/^git-index-[A-Za-z0-9_-]{6,64}$/.test(value.tempDir)
    ) throw new Error('malformed Git transaction journal')
    return value as GitTransactionJournal
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw err
  }
}

function parseNulList(output: string): string[] {
  return output.split('\0').filter(Boolean)
}

type GitRun = (args: string[], env?: NodeJS.ProcessEnv, input?: Buffer | string) => Promise<ProcessResult>

function parseCheckedOutWorktreeRefs(output: string): Set<string> {
  if (
    output.length === 0
    || Buffer.byteLength(output, 'utf8') > 256 * 1024
    || !output.endsWith('\0\0')
  ) throw new Error('malformed or oversized worktree list')

  const records = output.slice(0, -2).split('\0\0')
  if (records.length === 0 || records.length > 2048 || records.some(record => record.length === 0)) {
    throw new Error('malformed worktree record set')
  }

  const paths = new Set<string>()
  const branches = new Set<string>()
  for (const record of records) {
    const fields = record.split('\0')
    if (fields.length < 2 || fields.length > 8 || fields.some(field => field.length === 0)) {
      throw new Error('malformed worktree record')
    }
    if (!fields[0].startsWith('worktree ') || fields[0].length > 16 * 1024) {
      throw new Error('malformed worktree path')
    }
    const path = fields[0].slice('worktree '.length)
    if (path.length === 0 || paths.has(path)) throw new Error('duplicate or empty worktree path')
    paths.add(path)

    let head = false
    let branch: string | null = null
    let detached = false
    let bare = false
    let locked = false
    let prunable = false
    for (const field of fields.slice(1)) {
      if (field.startsWith('HEAD ')) {
        if (head || !/^HEAD [0-9a-f]{40,64}$/.test(field)) throw new Error('malformed worktree HEAD')
        head = true
      } else if (field.startsWith('branch ')) {
        const ref = field.slice('branch '.length)
        if (
          branch !== null
          || detached
          || bare
          || ref.length > 1024
          || !ref.startsWith('refs/heads/')
          || /[\x00-\x20\x7f]/.test(ref)
        ) throw new Error('malformed worktree branch')
        branch = ref
      } else if (field === 'detached') {
        if (detached || branch !== null || bare) throw new Error('malformed detached worktree')
        detached = true
      } else if (field === 'bare') {
        if (bare || branch !== null || detached) throw new Error('malformed bare worktree')
        bare = true
      } else if (field === 'locked' || field.startsWith('locked ')) {
        if (locked || field.length > 16 * 1024) throw new Error('malformed worktree lock')
        locked = true
      } else if (field === 'prunable' || field.startsWith('prunable ')) {
        if (prunable || field.length > 16 * 1024) throw new Error('malformed prunable worktree')
        prunable = true
      } else {
        throw new Error('unknown worktree field')
      }
    }
    if (bare ? (head || branch !== null || detached) : (!head || (branch === null && !detached))) {
      throw new Error('incomplete worktree record')
    }
    if (branch !== null) branches.add(branch)
  }
  return branches
}

async function refCheckoutFailure(ref: string, run: GitRun): Promise<GitBrokerResult | null> {
  const listed = await run(['worktree', 'list', '--porcelain', '-z'])
  if (terminalFailure(listed)) return terminalFailure(listed)
  if (listed.code !== 0) {
    return { ok: false, errorKind: 'git-failed', detail: listed.output }
  }
  let checkedOut: Set<string>
  try { checkedOut = parseCheckedOutWorktreeRefs(listed.output) } catch (err) {
    return {
      ok: false,
      errorKind: 'workspace',
      detail: `could not safely parse Git worktree state: ${err}`.slice(0, 500),
    }
  }
  if (checkedOut.has(ref)) {
    return {
      ok: false,
      errorKind: 'policy',
      detail: 'broker side ref is checked out in the canonical or a linked worktree',
    }
  }
  return null
}

function registryIsExact(
  registry: BranchRegistry,
  branch: string | null,
  tip: string,
): boolean {
  const entries = Object.entries(registry.branches)
  return branch === null
    ? entries.length === 0
    : entries.length === 1 && entries[0][0] === branch && entries[0][1].tip === tip
}

function cleanupPrivateTransactionDir(
  stateDir: string,
  name: string,
  observer?: DurabilityObserver,
): void {
  if (!/^git-index-[A-Za-z0-9_-]{6,64}$/.test(name)) {
    throw new Error('transaction temp directory name is unsafe')
  }
  const path = join(realpathSync(stateDir), name)
  try {
    const stat = lstatSync(path)
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isDirectory()
      || stat.isSymbolicLink()
      || stat.uid !== uid
      || (stat.mode & 0o777) !== 0o700
      || realpathSync(path) !== path
    ) throw new Error('transaction temp directory is unsafe')
    rmSync(path, { recursive: true })
    fsyncDirectory(dirname(path))
    notifyDurability(observer, 'commit-private-state-removed-durable')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return
    throw err
  }
}

async function recoverBranchTransaction(
  stateDir: string,
  run: GitRun,
  observer?: DurabilityObserver,
): Promise<GitBrokerResult | null> {
  let transaction: BranchTransactionJournal | null
  try { transaction = loadBranchTransaction(stateDir) } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `unsafe branch transaction journal: ${err}`.slice(0, 500) }
  }
  if (!transaction) return null
  if (existsSync(transactionPath(stateDir))) {
    return { ok: false, errorKind: 'workspace', detail: 'overlapping Git transaction journals are not recoverable' }
  }

  let registry: BranchRegistry
  try { registry = loadBranchRegistry(stateDir) } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `could not load interrupted branch registry: ${err}`.slice(0, 500) }
  }
  const registryOld = registryIsExact(registry, null, transaction.head)
  const registryNew = registryIsExact(registry, transaction.newBranch, transaction.head)
  if (!registryOld && !registryNew) {
    return { ok: false, errorKind: 'workspace', detail: 'branch registry changed during interrupted branch transaction' }
  }

  const newRefExists = await run(['show-ref', '--verify', '--quiet', transaction.newRef])
  if (terminalFailure(newRefExists)) return terminalFailure(newRefExists)
  if (newRefExists.code !== 0 && newRefExists.code !== 1) {
    return { ok: false, errorKind: 'git-failed', detail: newRefExists.output }
  }
  const newRefRun = newRefExists.code === 0
    ? await run(['rev-parse', '--verify', `${transaction.newRef}^{commit}`])
    : null
  if (newRefRun && terminalFailure(newRefRun)) return terminalFailure(newRefRun)
  if (newRefRun && newRefRun.code !== 0) {
    return { ok: false, errorKind: 'git-failed', detail: newRefRun.output }
  }
  const newTip = newRefRun?.output.trim() ?? null

  if (newTip === null && registryOld) {
    // The side-ref create never landed. Canonical HEAD/index were never part
    // of this transaction, so there is nothing else to roll back.
    try {
      durableRemoveFile(
        branchTransactionPath(stateDir), observer, 'branch-journal-removed-durable',
      )
    } catch (err) {
      return { ok: false, errorKind: 'workspace', detail: `could not discard interrupted branch transaction: ${err}`.slice(0, 500) }
    }
    return null
  }

  if (newTip !== transaction.head) {
    return { ok: false, errorKind: 'workspace', detail: 'interrupted branch ref state does not match its journal' }
  }

  try {
    registry.branches = { [transaction.newBranch]: { tip: transaction.head } }
    saveBranchRegistry(stateDir, registry, observer)
    durableRemoveFile(
      branchTransactionPath(stateDir), observer, 'branch-journal-removed-durable',
    )
  } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `could not finalize interrupted branch transaction: ${err}`.slice(0, 500) }
  }
  return null
}

async function recoverGitTransaction(
  stateDir: string,
  run: GitRun,
  observer?: DurabilityObserver,
): Promise<GitBrokerResult | null> {
  let transaction: GitTransactionJournal | null
  try { transaction = loadTransaction(stateDir) } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `unsafe Git transaction journal: ${err}`.slice(0, 500) }
  }
  if (!transaction) return null
  let registry: BranchRegistry
  try { registry = loadBranchRegistry(stateDir) } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `could not load interrupted Git registry: ${err}`.slice(0, 500) }
  }
  const registryOld = registryIsExact(registry, transaction.branch, transaction.oldTip)
  const registryNew = registryIsExact(registry, transaction.branch, transaction.newTip)
  if (!registryOld && !registryNew) {
    return { ok: false, errorKind: 'workspace', detail: 'branch registry changed during interrupted Git transaction' }
  }

  const refRun = await run(['rev-parse', '--verify', `${transaction.ref}^{commit}`])
  if (terminalFailure(refRun)) return terminalFailure(refRun)
  if (refRun.code !== 0) {
    return { ok: false, errorKind: 'workspace', detail: 'broker side ref disappeared during interrupted Git transaction' }
  }
  const tip = refRun.output.trim()
  if (tip === transaction.oldTip && registryOld) {
    // Ref CAS did not land. Discard only the inode-validated private index
    // directory named by this journal; canonical metadata was never staged.
    try {
      cleanupPrivateTransactionDir(stateDir, transaction.tempDir, observer)
      durableRemoveFile(
        transactionPath(stateDir), observer, 'commit-journal-removed-durable',
      )
    } catch (err) {
      return { ok: false, errorKind: 'workspace', detail: `could not discard interrupted Git transaction: ${err}`.slice(0, 500) }
    }
    return null
  }
  if (tip !== transaction.newTip) {
    return { ok: false, errorKind: 'workspace', detail: 'interrupted Git transaction state does not match its journal' }
  }

  try {
    registry.branches = { [transaction.branch]: { tip: transaction.newTip } }
    saveBranchRegistry(stateDir, registry, observer)
    cleanupPrivateTransactionDir(stateDir, transaction.tempDir, observer)
    durableRemoveFile(
      transactionPath(stateDir), observer, 'commit-journal-removed-durable',
    )
  } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `could not finalize interrupted Git transaction: ${err}`.slice(0, 500) }
  }
  return null
}

/**
 * Execute the deliberately tiny host Git capability. It never invokes
 * add/commit/checkout/switch, never executes repository hooks or filters, and
 * never accepts a pathspec broader than the operator's explicit file list.
 */
export async function runGitBroker(
  command: GitControlCommand,
  options: GitBrokerOptions,
): Promise<GitBrokerResult> {
  if (options.signal?.aborted) {
    return { ok: false, errorKind: 'aborted', detail: 'Git broker aborted before launch' }
  }
  const safety = checkWorkspaceSafety(options.cwd)
  if (!safety.ok) return { ok: false, errorKind: 'workspace', detail: safety.detail }
  const root = safety.cwd
  const gitDir = join(root, '.git')
  try {
    const stat = lstatSync(gitDir)
    if (!stat.isDirectory() || stat.isSymbolicLink() || realpathSync(gitDir) !== gitDir) {
      return { ok: false, errorKind: 'workspace', detail: 'broker requires a canonical in-repo .git directory' }
    }
  } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `could not validate .git directory: ${err}`.slice(0, 500) }
  }

  for (const state of UNSAFE_GIT_STATES) {
    if (existsSync(join(gitDir, state))) {
      return { ok: false, errorKind: 'workspace', detail: `refusing Git operation during ${state}` }
    }
  }

  mkdirSync(options.stateDir, { recursive: true, mode: 0o700 })
  try { chmodSync(options.stateDir, 0o700) } catch {}
  const baseEnv = brokerEnv(options, root, gitDir)
  const run: GitRun = (
    args: string[],
    env = baseEnv,
    input?: Buffer | string,
  ) => runProcess(options.gitBin, [...SAFE_CONFIG_ARGS, ...args], root, env, options, input)
  const branchRecovery = await recoverBranchTransaction(
    options.stateDir, run, options.onDurabilityEvent,
  )
  if (branchRecovery) return branchRecovery
  const recovery = await recoverGitTransaction(options.stateDir, run, options.onDurabilityEvent)
  if (recovery) return recovery

  let registry: BranchRegistry
  try {
    registry = loadBranchRegistry(options.stateDir)
  } catch (err) {
    return { ok: false, errorKind: 'workspace', detail: `could not load broker branch registry: ${err}`.slice(0, 500) }
  }

  const indexPath = join(gitDir, 'index')
  let tempDir: string | null = null
  try {
    const indexBefore = indexFingerprint(indexPath)
    const currentRefRun = await run(['symbolic-ref', '-q', 'HEAD'])
    if (terminalFailure(currentRefRun)) return terminalFailure(currentRefRun)!
    const currentRef = currentRefRun.output.trim()
    if (currentRefRun.code !== 0 || !/^refs\/heads\/[A-Za-z0-9._/-]+$/.test(currentRef)) {
      return { ok: false, errorKind: 'workspace', detail: 'broker requires an attached local branch' }
    }
    const oldHeadRun = await run(['rev-parse', '--verify', 'HEAD^{commit}'])
    if (terminalFailure(oldHeadRun)) return terminalFailure(oldHeadRun)!
    const oldHead = oldHeadRun.output.trim()
    if (oldHeadRun.code !== 0 || !/^[0-9a-f]{40,64}$/.test(oldHead)) {
      return { ok: false, errorKind: 'workspace', detail: 'could not resolve current commit' }
    }

    const staged = await run(['diff-index', '--cached', '--quiet', oldHead, '--'])
    if (terminalFailure(staged)) return terminalFailure(staged)!
    if (staged.code === 1) {
      return { ok: false, errorKind: 'staged-changes', detail: 'real git index already has staged changes' }
    }
    if (staged.code !== 0) return { ok: false, errorKind: 'git-failed', detail: staged.output }

    if (command.action === 'retire') {
      const active = Object.entries(registry.branches)
      if (active.length !== 1 || active[0][0] !== command.name) {
        return { ok: false, errorKind: 'policy', detail: 'retire requires the exact active broker side ref' }
      }
      const [branchName, branchState] = active[0]
      const branchRef = `refs/heads/${branchName}`
      const sideTip = await run(['rev-parse', '--verify', `${branchRef}^{commit}`])
      if (terminalFailure(sideTip)) return terminalFailure(sideTip)!
      if (sideTip.code !== 0 || sideTip.output.trim() !== branchState.tip) {
        return { ok: false, errorKind: 'policy', detail: 'active broker side ref changed before retirement' }
      }
      const checkoutFailure = await refCheckoutFailure(branchRef, run)
      if (checkoutFailure) return checkoutFailure
      const integrated = await run(['merge-base', '--is-ancestor', branchState.tip, oldHead])
      if (terminalFailure(integrated)) return terminalFailure(integrated)!
      if (integrated.code === 1) {
        return { ok: false, errorKind: 'policy', detail: 'broker side ref is not integrated into canonical HEAD' }
      }
      if (integrated.code !== 0) {
        return { ok: false, errorKind: 'git-failed', detail: integrated.output }
      }
      const latestRef = await run(['symbolic-ref', '-q', 'HEAD'])
      const latestHead = await run(['rev-parse', '--verify', 'HEAD^{commit}'])
      const latestIndex = await run(['diff-index', '--cached', '--quiet', oldHead, '--'])
      const latestSideTip = await run(['rev-parse', '--verify', `${branchRef}^{commit}`])
      if (terminalFailure(latestRef)) return terminalFailure(latestRef)!
      if (terminalFailure(latestHead)) return terminalFailure(latestHead)!
      if (terminalFailure(latestIndex)) return terminalFailure(latestIndex)!
      if (terminalFailure(latestSideTip)) return terminalFailure(latestSideTip)!
      if (
        latestRef.output.trim() !== currentRef
        || latestHead.output.trim() !== oldHead
        || latestIndex.code !== 0
        || indexFingerprint(indexPath) !== indexBefore
        || latestSideTip.code !== 0
        || latestSideTip.output.trim() !== branchState.tip
      ) return { ok: false, errorKind: 'staged-changes', detail: 'repository changed while retiring side ref' }

      registry.branches = Object.create(null)
      try {
        options.onBeforeBranchRegistrySave?.()
        const latestCheckoutFailure = await refCheckoutFailure(branchRef, run)
        if (latestCheckoutFailure) return latestCheckoutFailure
        saveBranchRegistry(options.stateDir, registry, options.onDurabilityEvent)
      } catch (err) {
        return { ok: false, errorKind: 'git-failed', detail: `could not retire branch capability: ${err}`.slice(0, 500) }
      }
      // The integrated historical ref is deliberately retained. Retirement
      // clears only this daemon's capability and never deletes Git history.
      return { ok: true, action: 'retire', branch: branchName }
    }

    if (command.action === 'branch') {
      if (!validBranchName(command.name)) {
        return { ok: false, errorKind: 'workspace', detail: 'invalid or protected branch name' }
      }
      const newRef = `refs/heads/${command.name}`
      const format = await run(['check-ref-format', newRef])
      if (terminalFailure(format)) return terminalFailure(format)!
      if (format.code !== 0) return { ok: false, errorKind: 'git-failed', detail: format.output }
      const checkoutFailure = await refCheckoutFailure(newRef, run)
      if (checkoutFailure) return checkoutFailure
      const priorActive = Object.entries(registry.branches)[0]
      if (priorActive) {
        return {
          ok: false,
          errorKind: 'policy',
          detail: `broker branch ${priorActive[0]} remains active at ${priorActive[1].tip}; integrate it before creating another`,
        }
      }
      const alreadyExists = await run(['show-ref', '--verify', '--quiet', newRef])
      if (terminalFailure(alreadyExists)) return terminalFailure(alreadyExists)!
      if (alreadyExists.code === 0) {
        return { ok: false, errorKind: 'branch-exists', detail: 'branch already exists' }
      }
      if (alreadyExists.code !== 1) {
        return { ok: false, errorKind: 'git-failed', detail: alreadyExists.output }
      }

      // The side-ref is based on the canonical checkout's exact current HEAD,
      // but creation must never attach that checkout to the new ref or install
      // a different index. Refuse if operator Git state moved while validating.
      const latestRef = await run(['symbolic-ref', '-q', 'HEAD'])
      const latestHead = await run(['rev-parse', '--verify', 'HEAD^{commit}'])
      const latestIndex = await run(['diff-index', '--cached', '--quiet', oldHead, '--'])
      if (terminalFailure(latestRef)) return terminalFailure(latestRef)!
      if (terminalFailure(latestHead)) return terminalFailure(latestHead)!
      if (terminalFailure(latestIndex)) return terminalFailure(latestIndex)!
      if (
        latestRef.output.trim() !== currentRef
        || latestHead.output.trim() !== oldHead
        || latestIndex.code !== 0
        || indexFingerprint(indexPath) !== indexBefore
      ) return { ok: false, errorKind: 'staged-changes', detail: 'repository changed while preparing branch' }

      const branchTransaction: BranchTransactionJournal = {
        version: 2,
        kind: 'branch',
        newRef,
        newBranch: command.name,
        head: oldHead,
      }
      try {
        saveBranchTransaction(options.stateDir, branchTransaction, options.onDurabilityEvent)
      } catch (err) {
        return { ok: false, errorKind: 'git-failed', detail: `could not journal branch transaction: ${err}`.slice(0, 500) }
      }
      const latestCheckoutFailure = await refCheckoutFailure(newRef, run)
      if (latestCheckoutFailure) {
        try {
          durableRemoveFile(
            branchTransactionPath(options.stateDir),
            options.onDurabilityEvent,
            'branch-journal-removed-durable',
          )
        } catch (err) {
          return { ok: false, errorKind: 'workspace', detail: `could not discard unlanded branch journal: ${err}`.slice(0, 500) }
        }
        return latestCheckoutFailure
      }
      const createLines = [
        'start',
        `create ${newRef} ${oldHead}`,
        'prepare',
        'commit',
        '',
      ]
      const created = await run(['update-ref', '--stdin'], baseEnv, createLines.join('\n'))
      if (terminalFailure(created)) return terminalFailure(created)!
      if (created.code !== 0) {
        try {
          durableRemoveFile(
            branchTransactionPath(options.stateDir),
            options.onDurabilityEvent,
            'branch-journal-removed-durable',
          )
        } catch (err) {
          return { ok: false, errorKind: 'workspace', detail: `could not discard rejected branch journal: ${err}`.slice(0, 500) }
        }
        return { ok: false, errorKind: 'git-failed', detail: created.output }
      }
      notifyDurability(options.onDurabilityEvent, 'branch-ref-cas-complete')
      options.onAfterBranchRefAdvance?.()
      registry.branches = { [command.name]: { tip: oldHead } }
      try {
        options.onBeforeBranchRegistrySave?.()
        saveBranchRegistry(options.stateDir, registry, options.onDurabilityEvent)
      } catch (err) {
        return { ok: false, errorKind: 'git-failed', detail: `could not persist branch capability: ${err}`.slice(0, 500) }
      }
      try {
        durableRemoveFile(
          branchTransactionPath(options.stateDir),
          options.onDurabilityEvent,
          'branch-journal-removed-durable',
        )
      } catch (err) {
        return { ok: false, errorKind: 'workspace', detail: `branch committed but journal cleanup failed: ${err}`.slice(0, 500) }
      }
      return { ok: true, action: 'branch', branch: command.name }
    }

    const active = Object.entries(registry.branches)
    if (active.length !== 1) {
      return {
        ok: false,
        errorKind: 'policy',
        detail: 'commits require exactly one active broker side ref',
      }
    }
    const [branchName, branchState] = active[0]
    const branchRef = `refs/heads/${branchName}`
    const branchTipRun = await run(['rev-parse', '--verify', `${branchRef}^{commit}`])
    if (terminalFailure(branchTipRun)) return terminalFailure(branchTipRun)!
    const branchTip = branchTipRun.output.trim()
    if (branchTipRun.code !== 0 || branchTip !== branchState.tip) {
      return {
        ok: false,
        errorKind: 'policy',
        detail: 'registered broker side ref is missing or no longer at its exact authorized tip',
      }
    }
    const checkoutFailure = await refCheckoutFailure(branchRef, run)
    if (checkoutFailure) return checkoutFailure
    if (!options.allowedChanges || Object.keys(options.allowedChanges).length === 0) {
      return { ok: false, errorKind: 'policy', detail: 'no latest-turn change capability is available' }
    }

    const maxFileBytes = options.maxFileBytes ?? 10 * 1024 * 1024
    const maxTotalBytes = options.maxTotalBytes ?? 50 * 1024 * 1024
    const validated: Extract<ValidatedPath, { ok: true }>[] = []
    const normalizedSeen = new Set<string>()
    let totalBytes = 0
    for (const requested of command.paths) {
      const checked = validateCommitPath(root, requested, maxFileBytes)
      if (!checked.ok) return { ok: false, errorKind: checked.kind, detail: checked.detail }
      const dedupeKey = checked.path.toLowerCase()
      if (normalizedSeen.has(dedupeKey)) {
        return { ok: false, errorKind: 'invalid-path', detail: 'duplicate normalized paths are not allowed' }
      }
      normalizedSeen.add(dedupeKey)
      if (!Object.prototype.hasOwnProperty.call(options.allowedChanges, checked.path)) {
        return { ok: false, errorKind: 'policy', detail: 'path was not changed by the latest serialized Codex turn' }
      }
      const expected = options.allowedChanges[checked.path]
      const actual = checked.exists ? gitFileFingerprint(checked.mode, checked.content) : null
      if (expected !== actual) {
        return { ok: false, errorKind: 'policy', detail: 'path changed after the latest serialized Codex turn' }
      }
      if (checked.exists) {
        totalBytes += checked.content.byteLength
        if (totalBytes > maxTotalBytes) {
          return { ok: false, errorKind: 'invalid-path', detail: 'files exceed aggregate broker size bound' }
        }
        const secret = secretPattern(checked.content)
        if (secret) {
          return { ok: false, errorKind: 'policy', detail: `changed content matches high-confidence secret pattern: ${secret}` }
        }
      }
      validated.push(checked)
    }

    tempDir = mkdtempSync(join(options.stateDir, 'git-index-'))
    try { chmodSync(tempDir, 0o700) } catch {}
    const indexFile = join(tempDir, 'index')
    const messageFile = join(tempDir, 'message')
    writeFileSync(messageFile, `${command.message}\n`, { mode: 0o600 })
    const tempEnv = brokerEnv(options, root, gitDir, indexFile)
    const readTree = await run(['read-tree', branchTip], tempEnv)
    if (terminalFailure(readTree)) return terminalFailure(readTree)!
    if (readTree.code !== 0) return { ok: false, errorKind: 'git-failed', detail: readTree.output }

    for (const path of validated) {
      if (!path.exists) {
        const removed = await run(['update-index', '--force-remove', '--', path.path], tempEnv)
        if (terminalFailure(removed)) return terminalFailure(removed)!
        if (removed.code !== 0) return { ok: false, errorKind: 'git-failed', detail: removed.output }
        continue
      }
      const hashed = await run(['hash-object', '-w', '--no-filters', '--stdin'], tempEnv, path.content)
      if (terminalFailure(hashed)) return terminalFailure(hashed)!
      const oid = hashed.output.trim()
      if (hashed.code !== 0 || !/^[0-9a-f]{40,64}$/.test(oid)) {
        return { ok: false, errorKind: 'git-failed', detail: hashed.output }
      }
      const updated = await run([
        'update-index', '--add', '--cacheinfo', `${path.mode},${oid},${path.path}`,
      ], tempEnv)
      if (terminalFailure(updated)) return terminalFailure(updated)!
      if (updated.code !== 0) return { ok: false, errorKind: 'git-failed', detail: updated.output }
    }

    const oldTreeRun = await run(['rev-parse', '--verify', `${branchTip}^{tree}`], tempEnv)
    const newTreeRun = await run(['write-tree'], tempEnv)
    if (terminalFailure(oldTreeRun)) return terminalFailure(oldTreeRun)!
    if (terminalFailure(newTreeRun)) return terminalFailure(newTreeRun)!
    const oldTree = oldTreeRun.output.trim()
    const newTree = newTreeRun.output.trim()
    if (oldTreeRun.code !== 0 || newTreeRun.code !== 0 || !/^[0-9a-f]{40,64}$/.test(newTree)) {
      return { ok: false, errorKind: 'git-failed', detail: `${oldTreeRun.output}\n${newTreeRun.output}`.trim() }
    }
    if (oldTree === newTree) return { ok: false, errorKind: 'no-changes', detail: 'listed paths have no changes' }

    const changedRun = await run([
      'diff-tree', '--no-commit-id', '--no-renames', '--name-status', '-r', '-z', oldTree, newTree, '--',
    ], tempEnv)
    if (terminalFailure(changedRun)) return terminalFailure(changedRun)!
    if (changedRun.code !== 0) return { ok: false, errorKind: 'git-failed', detail: changedRun.output }
    const fields = parseNulList(changedRun.output)
    if (fields.length % 2 !== 0) {
      return { ok: false, errorKind: 'git-failed', detail: 'could not parse changed path statuses' }
    }
    const changed = Array.from({ length: fields.length / 2 }, (_, index) => ({
      status: fields[index * 2],
      path: fields[index * 2 + 1],
    }))
    const allowed = new Set(validated.map(path => path.path))
    if (changed.length === 0 || changed.some(entry => !allowed.has(entry.path))) {
      return { ok: false, errorKind: 'invalid-path', detail: 'temporary tree escaped requested path set' }
    }
    if (
      changed.some(entry => !isDocPath(entry.path))
      && !changed.some(entry => entry.status !== 'D' && isDocPath(entry.path))
    ) {
      return { ok: false, errorKind: 'policy', detail: 'source changes require a changed documentation path in the same commit' }
    }

    const commitRun = await run(['commit-tree', newTree, '-p', branchTip, '-F', messageFile], tempEnv)
    if (terminalFailure(commitRun)) return terminalFailure(commitRun)!
    const commit = commitRun.output.trim()
    if (commitRun.code !== 0 || !/^[0-9a-f]{40,64}$/.test(commit)) {
      return { ok: false, errorKind: 'git-failed', detail: commitRun.output }
    }

    try { options.onBeforeRefTransaction?.() } catch (err) {
      return { ok: false, errorKind: 'policy', detail: `final path check interrupted: ${err}`.slice(0, 500) }
    }
    for (const original of validated) {
      const fresh = validateCommitPath(root, original.path, maxFileBytes)
      if (!fresh.ok) return { ok: false, errorKind: fresh.kind, detail: fresh.detail }
      if (fresh.exists !== original.exists) {
        return { ok: false, errorKind: 'policy', detail: 'authorized path existence changed before Git transaction' }
      }
      if (fresh.exists && original.exists && (
        fresh.mode !== original.mode
        || gitFileFingerprint(fresh.mode, fresh.content) !== gitFileFingerprint(original.mode, original.content)
      )) return { ok: false, errorKind: 'policy', detail: 'authorized path changed before Git transaction' }
    }

    // Recheck the canonical checkout, its real index, and the independent
    // broker ref immediately before the compare-and-swap. The broker never
    // installs its private index into the canonical checkout.
    const latestRef = await run(['symbolic-ref', '-q', 'HEAD'])
    const latestHead = await run(['rev-parse', '--verify', 'HEAD^{commit}'])
    const latestIndex = await run(['diff-index', '--cached', '--quiet', oldHead, '--'])
    const latestBranchTip = await run(['rev-parse', '--verify', `${branchRef}^{commit}`])
    if (terminalFailure(latestRef)) return terminalFailure(latestRef)!
    if (terminalFailure(latestHead)) return terminalFailure(latestHead)!
    if (terminalFailure(latestIndex)) return terminalFailure(latestIndex)!
    if (terminalFailure(latestBranchTip)) return terminalFailure(latestBranchTip)!
    if (
      latestRef.output.trim() !== currentRef
      || latestHead.output.trim() !== oldHead
      || latestIndex.code !== 0
      || indexFingerprint(indexPath) !== indexBefore
      || latestBranchTip.code !== 0
      || latestBranchTip.output.trim() !== branchTip
    ) return { ok: false, errorKind: 'staged-changes', detail: 'repository changed while preparing commit' }

    const transaction: GitTransactionJournal = {
      version: 2,
      kind: 'commit',
      ref: branchRef,
      branch: branchName,
      oldTip: branchTip,
      newTip: commit,
      tempDir: basename(tempDir),
    }
    try { saveTransaction(options.stateDir, transaction, options.onDurabilityEvent) } catch (err) {
      return { ok: false, errorKind: 'git-failed', detail: `could not journal Git transaction: ${err}`.slice(0, 500) }
    }

    const latestCheckoutFailure = await refCheckoutFailure(branchRef, run)
    if (latestCheckoutFailure) {
      try {
        cleanupPrivateTransactionDir(
          options.stateDir, basename(tempDir), options.onDurabilityEvent,
        )
        tempDir = null
        durableRemoveFile(
          transactionPath(options.stateDir),
          options.onDurabilityEvent,
          'commit-journal-removed-durable',
        )
      } catch (err) {
        return { ok: false, errorKind: 'workspace', detail: `could not discard unlanded Git journal: ${err}`.slice(0, 500) }
      }
      return latestCheckoutFailure
    }

    const advanced = await run(['update-ref', branchRef, commit, branchTip])
    if (terminalFailure(advanced)) return terminalFailure(advanced)!
    if (advanced.code !== 0) {
      try {
        cleanupPrivateTransactionDir(
          options.stateDir, basename(tempDir), options.onDurabilityEvent,
        )
        tempDir = null
        durableRemoveFile(
          transactionPath(options.stateDir),
          options.onDurabilityEvent,
          'commit-journal-removed-durable',
        )
      } catch (err) {
        return { ok: false, errorKind: 'workspace', detail: `could not discard rejected Git journal: ${err}`.slice(0, 500) }
      }
      return { ok: false, errorKind: 'git-failed', detail: advanced.output }
    }
    notifyDurability(options.onDurabilityEvent, 'commit-ref-cas-complete')
    options.onAfterRefAdvance?.()
    registry.branches[branchName] = { tip: commit }
    try { saveBranchRegistry(options.stateDir, registry, options.onDurabilityEvent) } catch (err) {
      return { ok: false, errorKind: 'git-failed', detail: `could not advance branch capability: ${err}`.slice(0, 500) }
    }
    try {
      cleanupPrivateTransactionDir(
        options.stateDir, basename(tempDir), options.onDurabilityEvent,
      )
      tempDir = null
      durableRemoveFile(
        transactionPath(options.stateDir),
        options.onDurabilityEvent,
        'commit-journal-removed-durable',
      )
    } catch (err) {
      return { ok: false, errorKind: 'workspace', detail: `commit persisted but journal cleanup failed: ${err}`.slice(0, 500) }
    }
    return { ok: true, action: 'commit', commit: commit.slice(0, 12) }
  } finally {
    // Ref/registry journals deliberately survive any exception after a side
    // ref CAS. The next invocation validates the exact old/new tips and either
    // completes the registry write or discards a transaction that never landed.
    if (tempDir) rmSync(tempDir, { recursive: true, force: true })
  }
}
