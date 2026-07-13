import { spawnSync } from 'child_process'
import { lstatSync, readdirSync, realpathSync } from 'fs'
import { join, relative, sep } from 'path'
import { listExtendedAclEntries } from './security.ts'

const SEARCH = 'search,readattr,readextattr,readsecurity'
const READ_DIR = `list,${SEARCH}`
const READ_FILE = 'read,readattr,readextattr,readsecurity'
const EXEC_FILE = `${READ_FILE},execute`
const WRITE_DIR = [
  'list', 'search', 'add_file', 'add_subdirectory', 'delete_child',
  'readattr', 'writeattr', 'readextattr', 'writeextattr', 'readsecurity',
].join(',')

export type RuntimeAclEntry = { path: string; permissions: string }
export type RuntimeAclCommand = (args: readonly string[]) => {
  status: number | null
  error?: unknown
  stderr?: string | Buffer | null
}
export type RuntimeAclInspector = (path: string) => readonly string[]

const defaultAclCommand: RuntimeAclCommand = args => spawnSync('/bin/chmod', [...args], {
  encoding: 'utf8',
  timeout: 2000,
  maxBuffer: 64 * 1024,
  env: { PATH: '/usr/bin:/bin', LC_ALL: 'C', LANG: 'C' },
})
const defaultAclInspector: RuntimeAclInspector = path => listExtendedAclEntries(path)

function safeUser(user: string): void {
  if (!/^[a-z_][a-z0-9_-]{0,31}$/.test(user)) throw new Error('invalid runtime ACL user')
}

function expectedAce(user: string, entry: RuntimeAclEntry): string {
  safeUser(user)
  if (!/^[a-z_]+(?:,[a-z_]+)*$/.test(entry.permissions) || entry.permissions.length > 512) {
    throw new Error('invalid dedicated runtime ACL permissions')
  }
  return `user:${user} allow ${entry.permissions}`
}

function equivalentAce(observed: string, expected: string): boolean {
  const parse = (ace: string): { prefix: string; permissions: string[] } | null => {
    const match = ace.match(/^(user:[a-z_][a-z0-9_-]{0,31} allow) ([a-z_]+(?:,[a-z_]+)*)$/)
    if (!match) return null
    const permissions = match[2].split(',')
    if (new Set(permissions).size !== permissions.length) return null
    return { prefix: match[1], permissions: permissions.sort() }
  }
  const left = parse(observed)
  const right = parse(expected)
  return left !== null
    && right !== null
    && left.prefix === right.prefix
    && left.permissions.join(',') === right.permissions.join(',')
}

function canonicalEntry(entry: RuntimeAclEntry): RuntimeAclEntry {
  const stat = lstatSync(entry.path)
  const canonical = realpathSync(entry.path)
  if (stat.isSymbolicLink() || canonical !== entry.path) {
    throw new Error(`unsafe managed path while changing runtime ACL: ${entry.path}`)
  }
  return { path: canonical, permissions: entry.permissions }
}

function canonicalEntries(entries: readonly RuntimeAclEntry[]): RuntimeAclEntry[] {
  const canonical = entries.map(canonicalEntry)
  if (new Set(canonical.map(entry => entry.path)).size !== canonical.length) {
    throw new Error('duplicate managed path in dedicated runtime ACL plan')
  }
  return canonical
}

function inspectAcl(
  entry: RuntimeAclEntry,
  inspector: RuntimeAclInspector,
): readonly string[] {
  try {
    return inspector(entry.path)
  } catch (err) {
    throw new Error(`could not verify dedicated runtime ACL on ${entry.path}: ${err}`)
  }
}

function preflightGrant(
  user: string,
  entries: readonly RuntimeAclEntry[],
  inspector: RuntimeAclInspector,
): void {
  // Inspect the complete plan before the first mutation. An exact stale ACE
  // from a crashed daemon is recoverable; inherited, broader, or foreign ACEs
  // are refused without disturbing the operator's filesystem policy.
  for (const entry of entries) {
    const expected = expectedAce(user, entry)
    const observed = inspectAcl(entry, inspector)
    if (observed.some(ace => !equivalentAce(ace, expected))) {
      throw new Error(`unrelated or over-broad extended ACL on managed path: ${entry.path}`)
    }
  }
}

function persistentAclState(
  user: string,
  entry: RuntimeAclEntry,
  inspector: RuntimeAclInspector,
): 'missing' | 'exact' {
  const expected = expectedAce(user, entry)
  const observed = inspectAcl(entry, inspector)
  if (observed.length === 0) return 'missing'
  if (observed.length === 1 && equivalentAce(observed[0], expected)) return 'exact'
  if (observed.length > 1 && observed.every(ace => equivalentAce(ace, expected))) {
    throw new Error(`duplicate exact persistent runtime ACL on shared path: ${entry.path}`)
  }
  throw new Error(`unrelated or over-broad extended ACL on managed path: ${entry.path}`)
}

function preflightPersistentGrant(
  user: string,
  entries: readonly RuntimeAclEntry[],
  inspector: RuntimeAclInspector,
): void {
  for (const entry of entries) persistentAclState(user, entry, inspector)
}

function clearAcl(
  entry: RuntimeAclEntry,
  command: RuntimeAclCommand,
  inspector: RuntimeAclInspector,
): void {
  const removed = command(['-N', entry.path])
  if (removed.error || removed.status !== 0) {
    throw new Error(`could not clear dedicated runtime ACL on ${entry.path}: ${removed.stderr || removed.error}`)
  }
  if (inspectAcl(entry, inspector).length !== 0) {
    throw new Error(`extended ACL remains on managed path after cleanup: ${entry.path}`)
  }
}

function applyAcl(
  user: string,
  entry: RuntimeAclEntry,
  command: RuntimeAclCommand,
  inspector: RuntimeAclInspector,
): void {
  const ace = expectedAce(user, entry)
  try {
    // Remove every exact stale copy before adding the one allowed active ACE.
    clearAcl(entry, command, inspector)
    const added = command(['+a', ace, entry.path])
    if (added.error || added.status !== 0) {
      throw new Error(`could not grant dedicated runtime ACL on ${entry.path}: ${added.stderr || added.error}`)
    }
    const observed = inspectAcl(entry, inspector)
    if (observed.length !== 1 || !equivalentAce(observed[0], ace)) {
      throw new Error(`dedicated runtime ACL verification failed on ${entry.path}`)
    }
  } catch (grantError) {
    let cleanup = ''
    try { clearAcl(entry, command, inspector) } catch (err) {
      cleanup = `; ACL cleanup incomplete: ${err}`
    }
    throw new Error(`${grantError}${cleanup}`)
  }
}

function applyPersistentAcl(
  user: string,
  entry: RuntimeAclEntry,
  command: RuntimeAclCommand,
  inspector: RuntimeAclInspector,
): void {
  // Shared traversal ACEs outlive any one daemon. Never clear an exact ACE:
  // another daemon may actively rely on it. Re-inspection also makes an ACE
  // installed after preflight an idempotent success rather than a duplicate.
  if (persistentAclState(user, entry, inspector) === 'exact') return
  const ace = expectedAce(user, entry)
  const added = command(['+a', ace, entry.path])
  if (added.error || added.status !== 0) {
    throw new Error(`could not grant persistent runtime ACL on ${entry.path}: ${added.stderr || added.error}`)
  }
  if (persistentAclState(user, entry, inspector) !== 'exact') {
    throw new Error(`persistent runtime ACL verification failed on ${entry.path}`)
  }
}

function removeAcl(
  entry: RuntimeAclEntry,
  command: RuntimeAclCommand,
  inspector: RuntimeAclInspector,
): void {
  let canonical: RuntimeAclEntry
  try { canonical = canonicalEntry(entry) } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return
    throw err
  }
  // Revocation is fail-closed: strip the ACL as a whole so an ACE injected
  // during the active window cannot survive merely because it is not ours.
  clearAcl(canonical, command, inspector)
}

function grantAclEntries(
  runtimeUser: string,
  entries: readonly RuntimeAclEntry[],
  command: RuntimeAclCommand,
  inspector: RuntimeAclInspector,
): void {
  safeUser(runtimeUser)
  const plan = canonicalEntries(entries)
  preflightGrant(runtimeUser, plan, inspector)
  grantPreflightedAclEntries(runtimeUser, plan, command, inspector)
}

function grantPreflightedAclEntries(
  user: string,
  entries: readonly RuntimeAclEntry[],
  command: RuntimeAclCommand,
  inspector: RuntimeAclInspector,
): void {
  const granted: RuntimeAclEntry[] = []
  try {
    for (const entry of entries) {
      applyAcl(user, entry, command, inspector)
      granted.push(entry)
    }
  } catch (grantError) {
    const rollbackErrors: string[] = []
    for (const entry of granted.reverse()) {
      try { removeAcl(entry, command, inspector) } catch (err) { rollbackErrors.push(String(err)) }
    }
    const rollback = rollbackErrors.length > 0
      ? `; ACL rollback incomplete: ${rollbackErrors.join('; ')}`
      : ''
    throw new Error(`${grantError}${rollback}`)
  }
}

function revokeAclEntries(
  runtimeUser: string,
  entries: readonly RuntimeAclEntry[],
  command: RuntimeAclCommand,
  inspector: RuntimeAclInspector,
): void {
  safeUser(runtimeUser)
  const errors: string[] = []
  for (const entry of [...entries].reverse()) {
    try { removeAcl(entry, command, inspector) } catch (err) { errors.push(String(err)) }
  }
  if (errors.length > 0) throw new Error(`dedicated runtime ACL revocation incomplete: ${errors.join('; ')}`)
}

function verifyAclEntries(
  runtimeUser: string,
  entries: readonly RuntimeAclEntry[],
  inspector: RuntimeAclInspector,
): void {
  safeUser(runtimeUser)
  const plan = canonicalEntries(entries)
  for (const entry of plan) {
    const expected = expectedAce(runtimeUser, entry)
    const observed = inspectAcl(entry, inspector)
    if (observed.length !== 1 || !equivalentAce(observed[0], expected)) {
      throw new Error(`managed path does not have its exact dedicated runtime ACL: ${entry.path}`)
    }
  }
}

function privateAncestorEntries(operatorHome: string, stateDir: string): RuntimeAclEntry[] {
  const home = realpathSync(operatorHome)
  const state = realpathSync(stateDir)
  const rel = relative(home, state)
  if (!rel || rel === '..' || rel.startsWith(`..${sep}`)) {
    throw new Error('state directory must be inside the operator home for dedicated ACL traversal')
  }
  const entries: RuntimeAclEntry[] = []
  let current = home
  for (const component of ['', ...rel.split(sep)]) {
    if (component) current = join(current, component)
    const stat = lstatSync(current)
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isDirectory()
      || stat.isSymbolicLink()
      || (stat.uid !== uid && stat.uid !== 0)
      || (stat.mode & 0o022) !== 0
      || realpathSync(current) !== current
    ) throw new Error(`unsafe private ancestor for runtime traversal: ${current}`)

    // Do not claim ACL ownership of an ancestor that already permits every
    // user to traverse it through the POSIX mode. In particular, a normal
    // 0755 macOS home may carry an unrelated protective "deny delete" ACE;
    // neither replacing nor requiring an ACL there is necessary for search.
    // The state directory itself is always included because it begins the
    // daemon-owned portion of the plan, independent of its current mode.
    if (current === state || (stat.mode & 0o001) === 0) {
      entries.push({ path: current, permissions: SEARCH })
    }
  }
  return entries
}

export function baseRuntimeAclEntries(
  operatorHome: string,
  stateDir: string,
  inboxDir: string,
  toolTempRoot: string,
  toolShimDir: string,
): RuntimeAclEntry[] {
  const plan = baseRuntimeAclPlan(operatorHome, stateDir, inboxDir, toolTempRoot, toolShimDir)
  return [...plan.sharedTraversal, ...plan.stateUnique]
}

type BaseRuntimeAclPlan = {
  // Ancestors above stateDir that still need an explicit traversal grant may
  // be shared by sibling daemons. Their ACEs are persistent and deliberately
  // not owned by any one daemon.
  sharedTraversal: RuntimeAclEntry[]
  // stateDir and everything below it belong to exactly one daemon lifecycle.
  stateUnique: RuntimeAclEntry[]
}

function baseRuntimeAclPlan(
  operatorHome: string,
  stateDir: string,
  inboxDir: string,
  toolTempRoot: string,
  toolShimDir: string,
): BaseRuntimeAclPlan {
  const ancestors = privateAncestorEntries(operatorHome, stateDir)
  const entries: RuntimeAclEntry[] = canonicalEntries([
    ...ancestors,
    { path: realpathSync(inboxDir), permissions: SEARCH },
    { path: realpathSync(toolTempRoot), permissions: SEARCH },
    { path: realpathSync(toolShimDir), permissions: READ_DIR },
  ])
  for (const name of readdirSync(toolShimDir)) {
    const path = join(toolShimDir, name)
    const stat = lstatSync(path)
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('unsafe tool shim while granting runtime ACL')
    entries.push(...canonicalEntries([{ path: realpathSync(path), permissions: EXEC_FILE }]))
  }
  return {
    sharedTraversal: entries.slice(0, ancestors.length - 1),
    stateUnique: entries.slice(ancestors.length - 1),
  }
}

/**
 * Grant base access using two ownership models: traversal ancestors above the
 * state directory are persistent shared ACEs, while state-local paths are
 * replaceable ACEs owned by this daemon lifecycle.
 */
export function grantBaseRuntimeAccess(
  runtimeUser: string,
  operatorHome: string,
  stateDir: string,
  inboxDir: string,
  toolTempRoot: string,
  toolShimDir: string,
  command: RuntimeAclCommand = defaultAclCommand,
  inspector: RuntimeAclInspector = defaultAclInspector,
): void {
  safeUser(runtimeUser)
  const plan = baseRuntimeAclPlan(operatorHome, stateDir, inboxDir, toolTempRoot, toolShimDir)

  // Inspect both ownership sets before the first mutation. Persistent entries
  // reject duplicates; state-local entries retain stale-copy replacement.
  preflightPersistentGrant(runtimeUser, plan.sharedTraversal, inspector)
  preflightGrant(runtimeUser, plan.stateUnique, inspector)

  // A failure must not roll back shared entries: a sibling daemon may have
  // begun relying on them. State-local entries keep full reverse rollback.
  for (const entry of plan.sharedTraversal) {
    applyPersistentAcl(runtimeUser, entry, command, inspector)
  }
  grantPreflightedAclEntries(runtimeUser, plan.stateUnique, command, inspector)
}

export function verifyBaseRuntimeAccess(
  runtimeUser: string,
  operatorHome: string,
  stateDir: string,
  inboxDir: string,
  toolTempRoot: string,
  toolShimDir: string,
  inspector: RuntimeAclInspector = defaultAclInspector,
): void {
  const plan = baseRuntimeAclPlan(operatorHome, stateDir, inboxDir, toolTempRoot, toolShimDir)
  // Verification intentionally covers both persistent shared traversal and
  // daemon-owned state paths; each must have exactly one equivalent ACE.
  verifyAclEntries(runtimeUser, plan.sharedTraversal, inspector)
  verifyAclEntries(runtimeUser, plan.stateUnique, inspector)
}

export function revokeBaseRuntimeAccess(
  runtimeUser: string,
  operatorHome: string,
  stateDir: string,
  inboxDir: string,
  toolTempRoot: string,
  toolShimDir: string,
  command: RuntimeAclCommand = defaultAclCommand,
  inspector: RuntimeAclInspector = defaultAclInspector,
): void {
  // Per-daemon revocation owns only state-local entries. Shared traversal ACEs
  // are persistent and must remain for any sibling daemon using the same home.
  const plan = baseRuntimeAclPlan(operatorHome, stateDir, inboxDir, toolTempRoot, toolShimDir)
  revokeAclEntries(runtimeUser, plan.stateUnique, command, inspector)
}

export function turnRuntimeAclEntries(
  turnTempDir: string,
  turnInboxDir: string | null,
  attachmentPaths: readonly string[],
): RuntimeAclEntry[] {
  return [
    { path: realpathSync(turnTempDir), permissions: WRITE_DIR },
    ...(turnInboxDir ? [{ path: realpathSync(turnInboxDir), permissions: READ_DIR }] : []),
    ...attachmentPaths.map(path => ({ path: realpathSync(path), permissions: READ_FILE })),
  ]
}

export function grantTurnRuntimeAccess(
  runtimeUser: string,
  turnTempDir: string,
  turnInboxDir: string | null,
  attachmentPaths: readonly string[],
  command: RuntimeAclCommand = defaultAclCommand,
  inspector: RuntimeAclInspector = defaultAclInspector,
): void {
  grantAclEntries(
    runtimeUser,
    turnRuntimeAclEntries(turnTempDir, turnInboxDir, attachmentPaths),
    command,
    inspector,
  )
}

export function revokeTurnRuntimeAccess(
  runtimeUser: string,
  turnTempDir: string,
  turnInboxDir: string | null,
  attachmentPaths: readonly string[],
  command: RuntimeAclCommand = defaultAclCommand,
  inspector: RuntimeAclInspector = defaultAclInspector,
): void {
  // Use the already-canonical active paths directly instead of resolving the
  // complete set up front. A deleted attachment then counts as cleaned while
  // revocation still proceeds for every path that remains.
  const entries: RuntimeAclEntry[] = [
    { path: turnTempDir, permissions: WRITE_DIR },
    ...(turnInboxDir ? [{ path: turnInboxDir, permissions: READ_DIR }] : []),
    ...attachmentPaths.map(path => ({ path, permissions: READ_FILE })),
  ]
  revokeAclEntries(
    runtimeUser,
    entries,
    command,
    inspector,
  )
}
