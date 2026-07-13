import {
  accessSync,
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from 'fs'
import { spawnSync } from 'child_process'
import { userInfo } from 'os'
import { delimiter, dirname, isAbsolute, join, parse, resolve, sep } from 'path'

function inside(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(root + sep)
}

function currentUid(): number | null {
  return typeof process.getuid === 'function' ? process.getuid() : null
}

function ownerControlled(stat: ReturnType<typeof lstatSync>): boolean {
  const uid = currentUid()
  if (uid !== null && stat.uid !== uid && stat.uid !== 0) return false
  return (stat.mode & 0o022) === 0
}

function canonicalIfPresent(path: string): string | null {
  try { return realpathSync(resolve(path)) } catch { return null }
}

export type ExtendedAclListCommand = (path: string) => {
  status: number | null
  error?: unknown
  stdout?: string | Buffer | null
  stderr?: string | Buffer | null
}

const MAX_ACL_OUTPUT_BYTES = 64 * 1024
const MAX_ACL_ENTRIES = 32

const defaultExtendedAclListCommand: ExtendedAclListCommand = path => {
  // The dedicated runtime is macOS-only. Keep ordinary state validation a
  // no-op for ACLs on other hosts, where BSD ls(1)'s -e format is unavailable.
  if (process.platform !== 'darwin') return { status: 0, stdout: '' }
  return spawnSync('/bin/ls', ['-lde', path], {
    encoding: 'utf8',
    timeout: 2000,
    maxBuffer: MAX_ACL_OUTPUT_BYTES,
    env: { PATH: '/usr/bin:/bin', LC_ALL: 'C', LANG: 'C' },
  })
}

function boundedAclPath(path: string): void {
  if (!isAbsolute(path) || path.length > 4096 || /[\0\r\n]/.test(path)) {
    throw new Error('unsafe path while inspecting extended ACL')
  }
}

/** Return canonical macOS ACE bodies (without the numeric `ls -le` prefix). */
export function listExtendedAclEntries(
  path: string,
  command: ExtendedAclListCommand = defaultExtendedAclListCommand,
): string[] {
  boundedAclPath(path)
  const result = command(path)
  if (result.error || result.status !== 0) {
    const detail = String(result.stderr || result.error || 'unknown error').slice(0, 500)
    throw new Error(`could not inspect extended ACL on ${path}: ${detail}`)
  }
  const stdout = String(result.stdout ?? '')
  if (Buffer.byteLength(stdout) > MAX_ACL_OUTPUT_BYTES) {
    throw new Error(`extended ACL listing exceeded the output cap: ${path}`)
  }
  // Non-macOS tests and hosts deliberately return an empty listing.
  if (!stdout) return []
  const lines = stdout.replace(/\n$/, '').split('\n')
  const mode = lines[0]?.match(/^\s*(\S+)/)?.[1]
  if (!mode) throw new Error(`malformed extended ACL listing: ${path}`)
  const bodies = lines.slice(1).filter(line => line.trim().length > 0)
  const advertisesAcl = mode.endsWith('+')
  const advertisesXattrs = mode.endsWith('@')
  if (bodies.length === 0) {
    if (advertisesAcl) {
      throw new Error(`invalid extended ACL entry count: ${path}`)
    }
    return []
  }
  // Darwin gives the xattr marker precedence when a file has both xattrs and
  // an ACL: `ls -lde` can therefore print a mode ending in `@` followed by
  // numbered ACEs. An `@` with no ACE bodies is an xattr-only file.
  if (!advertisesAcl && !advertisesXattrs) {
    throw new Error(`inconsistent extended ACL listing: ${path}`)
  }
  if (bodies.length > MAX_ACL_ENTRIES) {
    throw new Error(`invalid extended ACL entry count: ${path}`)
  }
  return bodies.map((line, index) => {
    const match = line.match(/^\s*(\d+): ([^\0\r\n]{1,2048})$/)
    if (!match || Number(match[1]) !== index) {
      throw new Error(`malformed extended ACL entry: ${path}`)
    }
    return match[2]
  })
}

/** Sensitive operator state never permits an extended ACL, regardless of mode. */
export function assertNoExtendedAcl(
  path: string,
  context = 'sensitive file',
  command: ExtendedAclListCommand = defaultExtendedAclListCommand,
): void {
  if (listExtendedAclEntries(path, command).length > 0) {
    throw new Error(`${context} must not have an extended ACL: ${path}`)
  }
}

function assertSafeDirectory(path: string, privateMode = false): void {
  const stat = lstatSync(path)
  if (!stat.isDirectory() || stat.isSymbolicLink() || realpathSync(path) !== path) {
    throw new Error(`unsafe symlink/non-directory boundary: ${path}`)
  }
  if (!ownerControlled(stat)) throw new Error(`directory is not owner-controlled: ${path}`)
  if (privateMode && (stat.mode & 0o777) !== 0o700) {
    throw new Error(`directory must have mode 0700: ${path}`)
  }
}

function assertSafeParentChain(path: string): void {
  const root = parse(path).root
  let current = path
  for (;;) {
    assertSafeDirectory(current)
    if (current === root) break
    current = dirname(current)
  }
}

const SENSITIVE_STATE_FILES = [
  '.env', 'discord-token', 'access.json', 'sessions.json', 'retry-notices.json', 'parked-turns.json',
  'runtime.json', 'rotation-state.json', 'profile-rotation-state.json',
  'fable-review-budget.json', 'fable-review-budget.lock',
  'events.jsonl', 'events.jsonl.1',
] as const
const PRIVATE_STATE_DIRS = [
  'approved', 'inbox', 'tool-tmp', 'tool-shims', 'git-broker', 'daemon.lock',
  'native-view',
  'review-artifacts', 'fable-review-tmp',
] as const
const RUNTIME_ACL_MANAGED_STATE_DIRS = new Set(['inbox', 'tool-tmp', 'tool-shims'])
const RECURSIVE_PRIVATE_STATE_DIRS = new Set(['review-artifacts', 'fable-review-tmp'])

function assertPrivateStateTree(root: string): void {
  const pending = [root]
  while (pending.length > 0) {
    const current = pending.pop()!
    assertSafeDirectory(current, true)
    assertNoExtendedAcl(current, 'private reviewer state directory')
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const path = join(current, entry.name)
      const info = lstatSync(path)
      if (info.isDirectory() && !info.isSymbolicLink()) {
        pending.push(path)
      } else if (info.isFile() && !info.isSymbolicLink()
        && info.uid === (currentUid() ?? info.uid) && (info.mode & 0o777) === 0o600) {
        assertNoExtendedAcl(path, 'private reviewer state file')
      } else {
        throw new Error(`reviewer state entry must be owner regular 0600 or directory 0700: ${path}`)
      }
    }
  }
}

/** Establish and revalidate the host-private state capability before any read. */
export function validatePrivateStateBoundary(rawStateDir: string, create = true): string {
  if (!isAbsolute(rawStateDir)) throw new Error('state directory must be absolute')
  const lexical = resolve(rawStateDir)
  let existing = lexical
  while (existing !== parse(existing).root) {
    try { lstatSync(existing); break } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
      existing = dirname(existing)
    }
  }
  assertSafeParentChain(existing)
  if (existing !== lexical) {
    if (!create) throw new Error('state directory is missing')
    mkdirSync(lexical, { recursive: true, mode: 0o700 })
    chmodSync(lexical, 0o700)
  }
  const canonical = realpathSync(lexical)
  if (canonical !== lexical) throw new Error('state directory path must be canonical and non-symlinked')
  assertSafeDirectory(canonical, true)

  for (const name of SENSITIVE_STATE_FILES) {
    const path = join(canonical, name)
    try {
      const stat = lstatSync(path)
      if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== (currentUid() ?? stat.uid) || (stat.mode & 0o777) !== 0o600) {
        throw new Error(`sensitive state file must be owner regular mode 0600: ${path}`)
      }
      assertNoExtendedAcl(path, 'sensitive state file')
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
    }
  }
  for (const name of PRIVATE_STATE_DIRS) {
    const path = join(canonical, name)
    try {
      assertSafeDirectory(path, true)
      // These three directories are verified against their exact runtime ACE
      // by runtime-acl.ts while the daemon is active. Every other private
      // state directory must remain ACL-free at all times.
      if (!RUNTIME_ACL_MANAGED_STATE_DIRS.has(name)) {
        assertNoExtendedAcl(path, 'private state directory')
      }
      if (RECURSIVE_PRIVATE_STATE_DIRS.has(name)) assertPrivateStateTree(path)
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
    }
  }
  return canonical
}

/** Read the only accepted Discord credential source without following links. */
export function readPrivateDiscordTokenFile(stateDir: string, requestedPath: string | undefined): string {
  const canonicalState = validatePrivateStateBoundary(stateDir, false)
  const expected = join(canonicalState, 'discord-token')
  if (!requestedPath || !isAbsolute(requestedPath) || resolve(requestedPath) !== expected) {
    throw new Error(`CODEX_BRIDGE_DISCORD_TOKEN_FILE must equal ${expected}`)
  }
  const before = lstatSync(expected)
  const uid = currentUid()
  if (
    !before.isFile()
    || before.isSymbolicLink()
    || (uid !== null && before.uid !== uid)
    || (before.mode & 0o777) !== 0o600
    || before.size < 20
    || before.size > 512
    || realpathSync(expected) !== expected
  ) throw new Error('Discord token file must be owner regular mode 0600 and bounded')
  assertNoExtendedAcl(expected, 'Discord token file')
  const fd = openSync(expected, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const opened = fstatSync(fd)
    if (
      opened.dev !== before.dev
      || opened.ino !== before.ino
      || opened.size !== before.size
      || opened.mode !== before.mode
      || opened.uid !== before.uid
      || opened.ctimeMs !== before.ctimeMs
    ) throw new Error('Discord token file changed while opening')
    assertNoExtendedAcl(expected, 'Discord token file')
    const raw = readFileSync(fd, 'utf8')
    const after = fstatSync(fd)
    if (
      after.dev !== opened.dev
      || after.ino !== opened.ino
      || after.size !== opened.size
      || after.mode !== opened.mode
      || after.uid !== opened.uid
      || after.ctimeMs !== opened.ctimeMs
    ) throw new Error('Discord token file changed while being read')
    assertNoExtendedAcl(expected, 'Discord token file')
    const token = raw.endsWith('\n') ? raw.slice(0, -1) : raw
    if (!/^[A-Za-z0-9._-]{20,256}$/.test(token)) {
      throw new Error('Discord token file has invalid content')
    }
    return token
  } finally {
    closeSync(fd)
  }
}

export type CodexAuthBoundary = { home: string; codexHome: string }

/** Pin subscription state to the OS account home, never ambient repo env. */
export function validateCodexAuthBoundary(
  sourceEnv: NodeJS.ProcessEnv,
  workspaceRoot: string,
  stateDir: string,
  readableRoots: readonly string[] = [],
  systemHomeOverride?: string,
): CodexAuthBoundary {
  const home = realpathSync(resolve(systemHomeOverride ?? userInfo().homedir))
  assertSafeDirectory(home)
  if (sourceEnv.HOME && realpathSync(resolve(sourceEnv.HOME)) !== home) {
    throw new Error('ambient HOME does not match the OS account home')
  }
  const expectedCodexHome = realpathSync(join(home, '.codex'))
  const requestedCodexHome = sourceEnv.CODEX_BRIDGE_CODEX_HOME ?? sourceEnv.CODEX_HOME
  if (requestedCodexHome && realpathSync(resolve(requestedCodexHome)) !== expectedCodexHome) {
    throw new Error('Codex home override does not match the pinned account Codex home')
  }
  assertSafeDirectory(expectedCodexHome, true)

  const workspace = realpathSync(resolve(workspaceRoot))
  const state = realpathSync(resolve(stateDir))
  if (inside(workspace, home) || inside(workspace, expectedCodexHome) || inside(state, expectedCodexHome)) {
    throw new Error('Codex auth home overlaps workspace/state')
  }
  for (const root of readableRoots) {
    const canonical = canonicalIfPresent(root)
    if (canonical && inside(canonical, expectedCodexHome)) {
      throw new Error('Codex auth home falls under a sandbox-readable root')
    }
  }
  const authFile = join(expectedCodexHome, 'auth.json')
  try {
    const stat = lstatSync(authFile)
    const uid = currentUid()
    if (!stat.isFile() || stat.isSymbolicLink() || (uid !== null && stat.uid !== uid) || (stat.mode & 0o777) !== 0o600) {
      throw new Error('Codex auth.json must be owner regular mode 0600')
    }
    assertNoExtendedAcl(authFile, 'Codex auth.json')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
  }
  return { home, codexHome: expectedCodexHome }
}

function findRequestedPath(
  requested: string,
  pathValue: string | undefined,
  requireExecutable: boolean,
): string {
  if (requested.includes(sep)) {
    if (!isAbsolute(requested)) throw new Error('Codex executable path must be absolute')
    return requested
  }
  for (const dir of (pathValue ?? '').split(delimiter)) {
    if (!dir || !isAbsolute(dir)) continue
    const candidate = join(dir, requested)
    try {
      accessSync(candidate, requireExecutable ? constants.X_OK : constants.R_OK)
      return candidate
    } catch {}
  }
  throw new Error('Codex executable was not found')
}

export type TrustedCodexOptions = {
  workspaceRoot: string
  stateDir: string
  sourceEnv?: NodeJS.ProcessEnv
  deniedRoots?: readonly string[]
  trustedRoots?: readonly string[]
  systemHomeOverride?: string
}

/** Resolve CODEX_BIN, then prove its canonical install chain is host-controlled. */
function resolveTrustedCodexPath(
  requested: string,
  options: TrustedCodexOptions,
  kind: 'executable' | 'script',
): string {
  const source = options.sourceEnv ?? process.env
  const home = realpathSync(resolve(options.systemHomeOverride ?? userInfo().homedir))
  const candidate = findRequestedPath(requested, source.PATH, kind === 'executable')
  const canonical = realpathSync(candidate)
  const stat = lstatSync(canonical)
  if (
    !stat.isFile()
    || stat.isSymbolicLink()
    || !ownerControlled(stat)
    || (kind === 'executable' && (stat.mode & 0o111) === 0)
    || (kind === 'script' && stat.size > 1024 * 1024)
  ) {
    throw new Error(`Codex ${kind} is not an owner-controlled bounded regular file`)
  }
  if (kind === 'executable') {
    const header = readFileSync(canonical).subarray(0, 128).toString('utf8')
    if (header.startsWith('#!')) {
      throw new Error('Codex executable uses interpreter indirection; pin an absolute interpreter plus CODEX_BRIDGE_CODEX_ARGV_PREFIX')
    }
  }

  const denied = [
    options.workspaceRoot,
    options.stateDir,
    source.SWARM_HOME,
    source.TMPDIR,
    source.TMP,
    source.TEMP,
    ...(options.deniedRoots ?? []),
  ].filter((value): value is string => Boolean(value)).map(value => canonicalIfPresent(value)).filter(Boolean) as string[]
  if (denied.some(root => inside(root, canonical))) {
    throw new Error('Codex executable resolves inside a mutable workspace/state/temp root')
  }

  const defaults = [
    join(home, '.nvm', 'versions', 'node'),
    join(home, '.local'),
    join(home, '.bun'),
    '/usr', '/usr/local', '/opt/homebrew', '/Applications', '/Library',
  ]
  const trusted = (options.trustedRoots ?? defaults)
    .map(value => canonicalIfPresent(value))
    .filter((value): value is string => Boolean(value))
  const installRoot = trusted
    .filter(root => inside(root, canonical))
    .sort((a, b) => b.length - a.length)[0]
  if (!installRoot) throw new Error('Codex executable is outside trusted install roots')
  let current = dirname(canonical)
  for (;;) {
    assertSafeDirectory(current)
    if (current === installRoot) break
    if (!inside(installRoot, current)) throw new Error('Codex executable escaped trusted install root')
    current = dirname(current)
  }
  return canonical
}

export function resolveTrustedCodexExecutable(
  requested: string,
  options: TrustedCodexOptions,
): string {
  return resolveTrustedCodexPath(requested, options, 'executable')
}

export function resolveTrustedCodexScript(
  requested: string,
  options: TrustedCodexOptions,
): string {
  if (!isAbsolute(requested)) throw new Error('CODEX_BRIDGE_CODEX_ARGV_PREFIX must be an absolute path')
  return resolveTrustedCodexPath(requested, options, 'script')
}
