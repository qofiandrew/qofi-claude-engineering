import { spawnSync } from 'child_process'
import { createHash } from 'crypto'
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fchmodSync,
  fchownSync,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { dirname, isAbsolute, join, resolve, sep } from 'path'
import {
  buildPermissionProfileArgs,
  CODEX_PERMISSION_PROFILE,
  safeExecutionOverrides,
  sanitizedCodexEnv,
} from './codex.ts'
import { assertNoExtendedAcl } from './security.ts'
import { DEDICATED_PNPM_VERSION } from './toolchain.ts'
import { isOperatorOwnedRelativePath, isSensitiveRelativePath } from './workspace.ts'

export const DEDICATED_RUNTIME_ATTESTATION = '/private/etc/qofi-codex-runtime.json'
export const DEDICATED_RUNTIME_SCHEMA = 'qofi-codex-runtime/v2'
export const DEDICATED_RUNTIME_RUNNER = '/usr/local/libexec/qofi-codex-runner'
export const DEDICATED_FABLE_REVIEWER = '/usr/local/libexec/qofi-fable-reviewer-mcp.py'
export const DEDICATED_FABLE_DOCTRINE = '/usr/local/libexec/qofi-fable-reviewer-doctrine.md'
export const DEDICATED_FABLE_SCHEMA = '/usr/local/libexec/qofi-adversarial-review-output.schema.json'
/** Exceeds runner's 3s child TERM wait plus bounded service-uid cleanup. */
export const DEDICATED_RUNNER_KILL_GRACE_MS = 8_000

const EXACT_ATTESTATION_KEYS = [
  'schema', 'operator_uid', 'runtime_uid', 'runtime_user', 'runtime_home',
  'runtime_gid', 'runtime_group',
  'codex_home', 'runner_path', 'runner_sha256', 'node_path', 'node_sha256',
  'codex_script', 'codex_script_sha256',
  'launchd_canary_name', 'launchd_canary_sha256',
  'fable_reviewer_path', 'fable_reviewer_sha256',
  'fable_doctrine_path', 'fable_doctrine_sha256',
  'fable_schema_path', 'fable_schema_sha256',
  'fable_reviewer_config_sha256', 'codex_config_sha256',
].sort()

export type DedicatedRuntimePlan = {
  operatorUid: number
  runtimeUid: number
  runtimeUser: string
  runtimeGid: number
  runtimeGroup: string
  runtimeHome: string
  codexHome: string
  runtimeTemp: string
  nodePath: string
  codexScript: string
  runnerPath: string
  launchdCanaryName: string
  launchdCanarySha256: string
  sudoPath: '/usr/bin/sudo'
  /** Fields inserted before Codex CLI arguments. */
  sudoArgvPrefix: string[]
}

export type DedicatedRuntimeValidationOptions = {
  workspaceRoot: string
  stateDir: string
  trustedNodePath: string
  trustedCodexScript: string
  readableRoots?: readonly string[]
  /** Test-only dependency seams; the daemon uses none of these. */
  attestationPath?: string
  expectedAttestationUid?: number
  filesystemRuntimeUid?: number
  expectedRuntimeParentUid?: number
  skipAccountLookup?: boolean
  skipWorkspaceGroupValidation?: boolean
  runnerPathOverride?: string
  expectedRunnerUid?: number
  expectedExecutableUid?: number
  fableReviewerPathOverride?: string
  fableDoctrinePathOverride?: string
  fableSchemaPathOverride?: string
  daemonUid?: number
  accountCommand?: (
    command: '/usr/bin/id' | '/usr/bin/dscacheutil' | '/usr/bin/python3',
    args: readonly string[],
  ) => { status: number | null; stdout: string }
  currentProcessGroups?: readonly number[]
}

export type WorkspaceDeviceForPath = (path: string, actualDev: number) => number

function inside(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(root + sep)
}

function isOpaqueOperatorSubtreeRoot(rel: string): boolean {
  return rel.split(sep).join('/') === '.claude/worktrees'
}

function isPackageDependencyPath(rel: string): boolean {
  return rel.split(sep).join('/').split('/').includes('node_modules')
}

function assertWorkspaceEntryBasics(
  path: string,
  stat: ReturnType<typeof lstatSync>,
  rootDevice: number,
  deviceForPath: WorkspaceDeviceForPath | undefined,
): number {
  const device = deviceForPath?.(path, stat.dev) ?? stat.dev
  if (device !== rootDevice) {
    throw new Error(`workspace path crosses device boundary: ${path}`)
  }
  if (stat.isFile() && (stat.mode & 0o7000) !== 0) {
    throw new Error(`workspace regular file must not have setuid, setgid, or sticky bits: ${path}`)
  }
  return device
}

function assertSafeDependencyHardlink(
  path: string,
  rel: string,
  stat: ReturnType<typeof lstatSync>,
  ownerUid: number,
  operatorUid: number,
): void {
  if (
    !isPackageDependencyPath(rel)
    || isSensitiveRelativePath(rel)
    || isOperatorOwnedRelativePath(rel)
  ) {
    throw new Error(`workspace regular file has a hard-linked or duplicate inode: ${path}`)
  }
  if (ownerUid !== operatorUid) {
    throw new Error(`workspace package hard link must be owned by the attested operator: ${path}`)
  }
  if ((stat.mode & 0o022) !== 0) {
    throw new Error(`workspace package hard link must not be group/world writable: ${path}`)
  }
  if ((stat.mode & 0o004) === 0 || ((stat.mode & 0o100) !== 0 && (stat.mode & 0o001) === 0)) {
    throw new Error(`workspace package hard link must be runtime-readable/executable: ${path}`)
  }
}

function assertWorkspaceEntryIdentity(
  path: string,
  rel: string,
  stat: ReturnType<typeof lstatSync>,
  rootDevice: number,
  seenRegularFiles: Set<string>,
  provenDependencyHardlinks: ReadonlyMap<string, number>,
  operatorUid: number,
  deviceForPath: WorkspaceDeviceForPath | undefined,
  ownerUid = stat.uid,
): boolean {
  const device = assertWorkspaceEntryBasics(path, stat, rootDevice, deviceForPath)
  if (!stat.isFile()) return false
  const identity = `${device}:${stat.ino}`
  const provenLinks = provenDependencyHardlinks.get(identity)
  if (provenLinks !== undefined) {
    if (stat.nlink !== provenLinks) {
      throw new Error(`workspace package hard-link set changed after preflight: ${path}`)
    }
    assertSafeDependencyHardlink(path, rel, stat, ownerUid, operatorUid)
    return true
  }
  if (stat.nlink !== 1 || seenRegularFiles.has(identity)) {
    throw new Error(`workspace regular file has a hard-linked or duplicate inode: ${path}`)
  }
  seenRegularFiles.add(identity)
  return false
}

/**
 * Complete the non-mutating identity scan before reconciliation or validation.
 * Keep the same deliberate traversal boundaries as the corresponding workspace
 * passes: Git metadata is checked at its root, and Claude worktrees are opaque.
 */
function preflightWorkspaceEntryIdentities(
  root: string,
  operatorUid: number,
  maxEntries: number,
  capError: string,
  deviceForPath: WorkspaceDeviceForPath | undefined,
  ownerUidForPath: ((path: string, actualUid: number) => number) | undefined = undefined,
): Map<string, number> {
  const rootStat = lstatSync(root)
  const rootDevice = deviceForPath?.(root, rootStat.dev) ?? rootStat.dev
  const regularAliases = new Map<string, Array<{
    path: string
    rel: string
    stat: ReturnType<typeof lstatSync>
    ownerUid: number
  }>>()
  const pending = [root]
  let entries = 0
  while (pending.length > 0) {
    const path = pending.pop()!
    const stat = lstatSync(path)
    entries++
    if (entries > maxEntries) throw new Error(capError)
    const rel = path === root ? '' : path.slice(root.length + 1)
    const device = assertWorkspaceEntryBasics(path, stat, rootDevice, deviceForPath)
    if (stat.isFile()) {
      const identity = `${device}:${stat.ino}`
      const aliases = regularAliases.get(identity) ?? []
      aliases.push({
        path,
        rel,
        stat,
        ownerUid: ownerUidForPath?.(path, stat.uid) ?? stat.uid,
      })
      regularAliases.set(identity, aliases)
    }
    if (
      stat.isDirectory()
      && rel !== '.git'
      && !isOpaqueOperatorSubtreeRoot(rel)
    ) {
      for (const child of readdirSync(path, { withFileTypes: true })) {
        pending.push(join(path, child.name))
      }
    }
  }
  const proven = new Map<string, number>()
  for (const [identity, aliases] of regularAliases) {
    const linkCounts = new Set(aliases.map(alias => alias.stat.nlink))
    if (linkCounts.size === 1 && linkCounts.has(1) && aliases.length === 1) continue
    const linkCount = linkCounts.size === 1 ? aliases[0]!.stat.nlink : -1
    if (linkCount < 2 || aliases.length !== linkCount) {
      throw new Error(
        `workspace hard-linked regular file is not a closed in-workspace alias set: ${aliases[0]!.path}`,
      )
    }
    for (const alias of aliases) {
      assertSafeDependencyHardlink(
        alias.path, alias.rel, alias.stat, alias.ownerUid, operatorUid,
      )
    }
    proven.set(identity, linkCount)
  }
  return proven
}

function desiredOperatorSharedMode(stat: ReturnType<typeof lstatSync>): number {
  if (stat.isDirectory()) {
    return ((stat.mode & 0o7777) | 0o2070) & ~0o002
  }
  // Regular-file privilege bits are never carried into an fchmod mode, even
  // though the preflight rejects them before reconciliation can begin.
  const ordinaryMode = stat.mode & 0o0777
  return (ordinaryMode | 0o060 | ((ordinaryMode & 0o100) !== 0 ? 0o010 : 0)) & ~0o002
}

function assertOwnerChain(path: string, ownerUid: number): void {
  let current = realpathSync(path)
  for (;;) {
    const stat = lstatSync(current)
    if (
      !stat.isDirectory()
      || stat.isSymbolicLink()
      || (stat.uid !== 0 && stat.uid !== ownerUid)
      || (stat.mode & 0o022) !== 0
    ) throw new Error(`attestation parent is not root-controlled: ${current}`)
    const parent = dirname(current)
    if (parent === current) break
    current = parent
  }
}

function assertRuntimeDirectory(path: string, runtimeUid: number, mode: number): string {
  if (!isAbsolute(path)) throw new Error('runtime path must be absolute')
  const canonical = resolve(path)
  if (canonical !== path) throw new Error('runtime path must be lexically canonical')
  // Do not call Node/Bun realpathSync inside the hidden 0700 home. On macOS it
  // can demand broader directory access than lstat even when the operator has
  // the installer-managed search/readattr ACL. The caller proves the external
  // parent chain; each component below is then a no-symlink real directory.
  const stat = lstatSync(canonical)
  if (
    !stat.isDirectory()
    || stat.isSymbolicLink()
    || stat.uid !== runtimeUid
    || (stat.mode & 0o777) !== mode
  ) throw new Error(`runtime directory must be uid ${runtimeUid} mode ${mode.toString(8)}: ${canonical}`)
  return canonical
}

function numericField(value: unknown, name: string): number {
  if (!Number.isSafeInteger(value) || Number(value) < 0) throw new Error(`invalid attestation ${name}`)
  return Number(value)
}

function fileSha256(path: string, maxBytes: number): string {
  const stat = lstatSync(path)
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 || stat.size > maxBytes) {
    throw new Error(`attested executable is not a bounded regular file: ${path}`)
  }
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

/**
 * Reconcile only ordinary paths owned by the daemon operator. This repairs
 * umask-022 files created after privileged setup without granting the runtime
 * account write authority over doctrine, Git metadata, or secrets.
 */
export function reconcileOperatorWorkspacePaths(
  workspaceRoot: string,
  runtimeGid: number,
  operatorUid: number,
  maxEntries = 200_000,
  /** Deterministic device fault injection for boundary tests only. */
  deviceForPath: WorkspaceDeviceForPath | undefined = undefined,
): void {
  const root = realpathSync(workspaceRoot)
  const provenDependencyHardlinks = preflightWorkspaceEntryIdentities(
    root,
    operatorUid,
    maxEntries,
    'workspace reconciliation exceeds entry cap',
    deviceForPath,
  )
  const rootStat = lstatSync(root)
  const rootDevice = deviceForPath?.(root, rootStat.dev) ?? rootStat.dev
  const seenRegularFiles = new Set<string>()
  const pending = [root]
  let entries = 0
  while (pending.length > 0) {
    const path = pending.pop()!
    const before = lstatSync(path)
    const rel = path === root ? '' : path.slice(root.length + 1)
    entries++
    if (entries > maxEntries) throw new Error('workspace reconciliation exceeds entry cap')
    const immutableDependencyHardlink = assertWorkspaceEntryIdentity(
      path,
      rel,
      before,
      rootDevice,
      seenRegularFiles,
      provenDependencyHardlinks,
      operatorUid,
      deviceForPath,
    )
    if (immutableDependencyHardlink) continue
    const protectedPath = rel !== ''
      && (isSensitiveRelativePath(rel) || isOperatorOwnedRelativePath(rel))
    if (before.isSymbolicLink()) continue

    if (!protectedPath && before.uid === operatorUid && (before.isDirectory() || before.isFile())) {
      const currentMode = before.mode & (before.isDirectory() ? 0o7777 : 0o0777)
      const desiredMode = desiredOperatorSharedMode(before)
      if (before.gid !== runtimeGid || currentMode !== desiredMode) {
        const flags = constants.O_RDONLY
          | (constants.O_NOFOLLOW ?? 0)
          | (before.isDirectory() ? (constants.O_DIRECTORY ?? 0) : 0)
        let fd: number | undefined
        try {
          fd = openSync(path, flags)
          const opened = fstatSync(fd)
          const openedDevice = deviceForPath?.(path, opened.dev) ?? opened.dev
          if (
            opened.dev !== before.dev
            || opened.ino !== before.ino
            || opened.uid !== operatorUid
            || opened.isDirectory() !== before.isDirectory()
            || opened.isFile() !== before.isFile()
          ) throw new Error('path changed while opening')
          if (openedDevice !== rootDevice) throw new Error('path crossed device boundary while opening')
          if (opened.isFile() && opened.nlink !== 1) {
            throw new Error('regular file became hard-linked while opening')
          }
          if (opened.isFile() && (opened.mode & 0o7000) !== 0) {
            throw new Error('regular file gained setuid, setgid, or sticky bits while opening')
          }
          const auditedMode = desiredOperatorSharedMode(opened)
          if (opened.gid !== runtimeGid) {
            fchownSync(fd, -1, runtimeGid)
            // chown may alter mode bits; reapply the sanitized audited mode.
            fchmodSync(fd, auditedMode)
          } else if (
            (opened.mode & (opened.isDirectory() ? 0o7777 : 0o0777)) !== auditedMode
          ) {
            fchmodSync(fd, auditedMode)
          }
        } catch (err) {
          throw new Error(
            `workspace reconciliation requires privileged prepare-workspace for ${path}: ${err}`,
          )
        } finally {
          if (fd !== undefined) closeSync(fd)
        }
      }
    }

    if (
      before.isDirectory()
      && rel !== '.git'
      && !isOpaqueOperatorSubtreeRoot(rel)
    ) {
      for (const child of readdirSync(path, { withFileTypes: true })) {
        pending.push(join(path, child.name))
      }
    }
  }
}

/** Prove existing and newly inherited workspace paths are shared-group writable. */
export function validateSharedWorkspaceBoundary(
  workspaceRoot: string,
  runtimeGid: number,
  operatorUid: number,
  maxEntries = 200_000,
  /** Deterministic ownership fault injection for boundary tests only. */
  ownerUidForPath: ((path: string, actualUid: number) => number) | undefined = undefined,
  /** Deterministic device fault injection for boundary tests only. */
  deviceForPath: WorkspaceDeviceForPath | undefined = undefined,
): void {
  const root = realpathSync(workspaceRoot)
  const provenDependencyHardlinks = preflightWorkspaceEntryIdentities(
    root,
    operatorUid,
    maxEntries,
    'workspace shared-group scan exceeds entry cap',
    deviceForPath,
    ownerUidForPath,
  )
  const rootStat = lstatSync(root)
  const rootDevice = deviceForPath?.(root, rootStat.dev) ?? rootStat.dev
  const seenRegularFiles = new Set<string>()
  const pending = [root]
  let entries = 0
  while (pending.length > 0) {
    const path = pending.pop()!
    const stat = lstatSync(path)
    const ownerUid = ownerUidForPath?.(path, stat.uid) ?? stat.uid
    const rel = path === root ? '' : path.slice(root.length + 1)
    entries++
    if (entries > maxEntries) throw new Error('workspace shared-group scan exceeds entry cap')
    const immutableDependencyHardlink = assertWorkspaceEntryIdentity(
      path,
      rel,
      stat,
      rootDevice,
      seenRegularFiles,
      provenDependencyHardlinks,
      operatorUid,
      deviceForPath,
      ownerUid,
    )
    const sensitive = rel !== '' && isSensitiveRelativePath(rel)
    const operatorOwned = rel !== '' && isOperatorOwnedRelativePath(rel)
    const gitMetadataRoot = rel === '.git'
    const opaqueOperatorSubtreeRoot = isOpaqueOperatorSubtreeRoot(rel)
    if (rel === '' && ownerUid !== operatorUid) {
      throw new Error(`workspace root must be owned by the attested operator: ${path}`)
    }
    if (opaqueOperatorSubtreeRoot) {
      if (
        stat.isSymbolicLink()
        || !stat.isDirectory()
        || realpathSync(path) !== path
      ) {
        throw new Error(`opaque operator subtree must be a real canonical directory: ${path}`)
      }
      if (ownerUid !== operatorUid) {
        throw new Error(`opaque operator subtree must be owned by the attested operator: ${path}`)
      }
      if ((stat.mode & 0o7777) !== 0o700) {
        throw new Error(`opaque operator subtree must have mode 0700: ${path}`)
      }
      assertNoExtendedAcl(path, 'opaque operator subtree')
      // Claude owns everything below this boundary, including ordinary
      // checkout modes and worktree-local `.git` pointer files. Codex must
      // neither inspect nor reconcile any descendant.
      continue
    }
    if (immutableDependencyHardlink) continue
    if (stat.isSymbolicLink()) {
      if (operatorOwned) throw new Error(`operator-owned workspace path cannot be a symlink: ${path}`)
      // macOS reports symlink mode 0777; replacement authority comes from the
      // already-validated shared parent and Seatbelt resolves the target.
      continue
    }
    if (sensitive) {
      if (ownerUid !== operatorUid) {
        throw new Error(`workspace secret path must be owned by the attested operator: ${path}`)
      }
      if ((stat.mode & 0o077) !== 0) {
        throw new Error(`workspace secret path must remain operator-only: ${path}`)
      }
      if (stat.isDirectory()) {
        for (const child of readdirSync(path, { withFileTypes: true })) {
          pending.push(join(path, child.name))
        }
      } else if (!stat.isFile()) {
        throw new Error(`workspace secret path is an unsupported special file: ${path}`)
      }
      continue
    }
    if (operatorOwned) {
      if (ownerUid !== operatorUid) {
        throw new Error(`operator-owned workspace path must be owned by the attested operator: ${path}`)
      }
      if ((stat.mode & 0o022) !== 0) {
        throw new Error(`operator-owned workspace path must not be group/world writable: ${path}`)
      }
      if (gitMetadataRoot && !stat.isDirectory()) {
        throw new Error(`workspace .git metadata root must be a real directory: ${path}`)
      }
      const runtimeBits = stat.gid === runtimeGid ? (stat.mode >> 3) & 0o7 : stat.mode & 0o7
      if (stat.isDirectory()) {
        if ((runtimeBits & 0o5) !== 0o5) {
          throw new Error(`operator-owned workspace directory is not runtime-readable/searchable: ${path}`)
        }
        if (!gitMetadataRoot) {
          for (const child of readdirSync(path, { withFileTypes: true })) {
            pending.push(join(path, child.name))
          }
        }
      } else if (!stat.isFile() || (runtimeBits & 0o4) === 0) {
        throw new Error(`operator-owned workspace file is not runtime-readable: ${path}`)
      }
      continue
    }
    if (stat.gid !== runtimeGid || (stat.mode & 0o002) !== 0) {
      throw new Error(`workspace path is outside the attested shared group; run prepare-workspace: ${path}`)
    }
    if (stat.isDirectory()) {
      if ((stat.mode & 0o2070) !== 0o2070) {
        throw new Error(`workspace directory must be setgid and group rwx; run prepare-workspace: ${path}`)
      }
      for (const child of readdirSync(path, { withFileTypes: true })) {
        pending.push(join(path, child.name))
      }
      continue
    }
    if (!stat.isFile()) throw new Error(`workspace contains unsupported special file: ${path}`)
    if ((stat.mode & 0o060) !== 0o060 || ((stat.mode & 0o100) !== 0 && (stat.mode & 0o010) === 0)) {
      throw new Error(`workspace file must be shared-group readable/writable; run prepare-workspace: ${path}`)
    }
  }
}

/** Parse the fixed root authority and build the only permitted execution route. */
export function validateDedicatedRuntimeBoundary(
  options: DedicatedRuntimeValidationOptions,
): DedicatedRuntimePlan {
  if (process.platform !== 'darwin' && options.attestationPath === undefined) {
    throw new Error('dedicated unattended runtime is currently supported only on macOS')
  }
  const attestationPath = options.attestationPath ?? DEDICATED_RUNTIME_ATTESTATION
  if (!isAbsolute(attestationPath) || realpathSync(attestationPath) !== attestationPath) {
    throw new Error('runtime attestation path must be fixed, absolute, and canonical')
  }
  const expectedAttestationUid = options.expectedAttestationUid ?? 0
  assertOwnerChain(dirname(attestationPath), expectedAttestationUid)

  const before = lstatSync(attestationPath)
  if (
    !before.isFile()
    || before.isSymbolicLink()
    || before.uid !== expectedAttestationUid
    || (before.mode & 0o022) !== 0
    || before.nlink !== 1
    || before.size < 2
    || before.size > 16 * 1024
  ) throw new Error('runtime attestation must be a bounded root-owned regular file')
  assertNoExtendedAcl(attestationPath, 'runtime attestation')
  const fd = openSync(attestationPath, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  let value: Record<string, unknown>
  try {
    const opened = fstatSync(fd)
    if (
      opened.dev !== before.dev
      || opened.ino !== before.ino
      || opened.size !== before.size
      || opened.mode !== before.mode
      || opened.uid !== before.uid
      || opened.gid !== before.gid
      || opened.nlink !== before.nlink
      || opened.mtimeMs !== before.mtimeMs
      || opened.ctimeMs !== before.ctimeMs
    ) throw new Error('runtime attestation changed while opening')
    const parsed: unknown = JSON.parse(readFileSync(fd, 'utf8'))
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('runtime attestation must contain an object')
    }
    value = parsed as Record<string, unknown>
  } finally {
    closeSync(fd)
  }
  if (JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(EXACT_ATTESTATION_KEYS)) {
    throw new Error('runtime attestation keys do not exactly match v2 schema')
  }
  if (value.schema !== DEDICATED_RUNTIME_SCHEMA) throw new Error('unsupported runtime attestation schema')

  const operatorUid = numericField(value.operator_uid, 'operator_uid')
  const currentUid = options.daemonUid
    ?? (typeof process.getuid === 'function' ? process.getuid() : operatorUid)
  if (operatorUid === 0 || currentUid === 0) {
    throw new Error('dedicated runtime operator_uid and daemon uid must be non-root')
  }
  if (operatorUid !== currentUid) throw new Error('runtime attestation operator_uid does not match daemon uid')
  const runtimeUid = numericField(value.runtime_uid, 'runtime_uid')
  if (runtimeUid === 0 || runtimeUid === operatorUid) {
    throw new Error('runtime uid must be a distinct non-root OS account')
  }
  if (typeof value.runtime_user !== 'string' || !/^[a-z_][a-z0-9_-]{0,31}$/.test(value.runtime_user)) {
    throw new Error('invalid attestation runtime_user')
  }
  const runtimeGid = numericField(value.runtime_gid, 'runtime_gid')
  if (runtimeGid === 0 || typeof value.runtime_group !== 'string'
    || !/^[a-z_][a-z0-9_-]{0,31}$/.test(value.runtime_group)) {
    throw new Error('invalid attestation runtime group/gid')
  }
  if (!options.skipAccountLookup) {
    const accountCommand = options.accountCommand ?? ((command, args) => spawnSync(command, [...args], {
      encoding: 'utf8', env: { PATH: '/usr/bin:/bin' }, timeout: 2000,
    }))
    const lookup = accountCommand('/usr/bin/id', ['-u', value.runtime_user])
    if (lookup.status !== 0 || Number(lookup.stdout.trim()) !== runtimeUid) {
      throw new Error('runtime user/uid does not resolve to the attested OS account')
    }
    const operatorLookup = accountCommand('/usr/bin/id', ['-nu', String(operatorUid)])
    const operatorUser = operatorLookup.stdout.trim()
    if (
      operatorLookup.status !== 0
      || !/^[A-Za-z_][A-Za-z0-9_.-]{0,63}$/.test(operatorUser)
    ) throw new Error('operator uid does not resolve to a trusted OS account name')
    const groupLookup = accountCommand(
      '/usr/bin/dscacheutil', ['-q', 'group', '-a', 'name', value.runtime_group],
    )
    const resolvedGid = Number(groupLookup.stdout.match(/^gid:\s*(\d+)$/m)?.[1])
    // Query directory membership for the named account. Bare `id -G` reports
    // the daemon's login-time kernel group cache and stays stale after setup.
    const operatorGroups = accountCommand('/usr/bin/id', ['-G', operatorUser])
    const runtimeGroups = accountCommand('/usr/bin/id', ['-G', value.runtime_user])
    const hasGroup = (output: string) => output.trim().split(/\s+/).map(Number).includes(runtimeGid)
    if (
      groupLookup.status !== 0
      || resolvedGid !== runtimeGid
      || operatorGroups.status !== 0
      || runtimeGroups.status !== 0
      || !hasGroup(operatorGroups.stdout)
      || !hasGroup(runtimeGroups.stdout)
    ) throw new Error('attested shared group must contain both operator and runtime users')
    let currentGroups = options.currentProcessGroups
    if (currentGroups === undefined) {
      // Node and Bun on macOS can omit a newly assigned supplemental group
      // from process.getgroups() even though a native getgroups(2) caller in a
      // child sees the inherited kernel credential. Prove the daemon's actual
      // credentials through fixed isolated system Python instead of weakening
      // this login-refresh boundary or trusting a Directory Services lookup.
      const credentialProof = accountCommand('/usr/bin/python3', [
        '-I', '-S', '-c',
        'import os;print(os.getuid(),os.geteuid(),os.getgid(),os.getegid(),",".join(map(str,os.getgroups())))',
      ])
      const match = credentialProof.stdout.trim().match(
        /^(\d+) (\d+) (\d+) (\d+) ((?:\d+,)*\d+)$/,
      )
      const currentGid = typeof process.getgid === 'function' ? process.getgid() : -1
      if (
        credentialProof.status !== 0
        || !match
        || Number(match[1]) !== currentUid
        || Number(match[2]) !== currentUid
        || Number(match[3]) !== currentGid
        || Number(match[4]) !== currentGid
      ) {
        throw new Error('could not prove the daemon process kernel credentials')
      }
      currentGroups = match[5].split(',').map(Number)
    }
    if (!currentGroups.includes(runtimeGid)) {
      throw new Error(
        'daemon process credentials do not include the attested shared group; log out/in and restart tmux before retrying',
      )
    }
  }
  const filesystemRuntimeUid = options.filesystemRuntimeUid ?? runtimeUid
  const attestedRuntimeHome = String(value.runtime_home)
  if (!isAbsolute(attestedRuntimeHome) || resolve(attestedRuntimeHome) !== attestedRuntimeHome) {
    throw new Error('runtime_home must be an absolute lexically canonical path')
  }
  assertOwnerChain(dirname(attestedRuntimeHome), options.expectedRuntimeParentUid ?? 0)
  const runtimeHome = assertRuntimeDirectory(attestedRuntimeHome, filesystemRuntimeUid, 0o700)
  const expectedCodexHome = join(runtimeHome, '.codex')
  if (value.codex_home !== expectedCodexHome) throw new Error('codex_home must be runtime_home/.codex')
  const codexHome = assertRuntimeDirectory(expectedCodexHome, filesystemRuntimeUid, 0o700)
  const runtimeTemp = assertRuntimeDirectory(join(runtimeHome, '.tmp'), filesystemRuntimeUid, 0o700)
  let auth: ReturnType<typeof lstatSync>
  try {
    auth = lstatSync(join(codexHome, 'auth.json'))
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      throw new Error(
        'dedicated ChatGPT auth is not initialized; run bin/swarm-codex-runtime.sh login, then retry',
      )
    }
    throw new Error(`could not inspect dedicated Codex auth.json: ${error}`)
  }
  if (
    !auth.isFile()
    || auth.isSymbolicLink()
    || auth.uid !== filesystemRuntimeUid
    || (auth.mode & 0o777) !== 0o600
    || auth.nlink !== 1
    || auth.size < 2
    || auth.size > 1024 * 1024
  ) throw new Error('dedicated Codex auth.json must be uid-owned regular mode 0600')

  const trustedNode = realpathSync(options.trustedNodePath)
  const trustedScript = realpathSync(options.trustedCodexScript)
  if (value.node_path !== trustedNode || value.codex_script !== trustedScript) {
    throw new Error('attested node/Codex script does not match independently trusted executable plan')
  }
  if (
    typeof value.node_sha256 !== 'string'
    || value.node_sha256 !== fileSha256(trustedNode, 512 * 1024 * 1024)
    || typeof value.codex_script_sha256 !== 'string'
    || value.codex_script_sha256 !== fileSha256(trustedScript, 16 * 1024 * 1024)
  ) throw new Error('attested node/Codex script hash changed')
  const expectedExecutableUid = options.expectedExecutableUid ?? 0
  for (const [path, executable] of [[trustedNode, true], [trustedScript, false]] as const) {
    assertOwnerChain(dirname(path), expectedExecutableUid)
    const stat = lstatSync(path)
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || stat.uid !== expectedExecutableUid
      || (stat.mode & 0o022) !== 0
      || (executable && (stat.mode & 0o111) === 0)
    ) throw new Error('attested Node/Codex script is not root-controlled')
  }

  const expectedRunner = options.runnerPathOverride ?? DEDICATED_RUNTIME_RUNNER
  if (value.runner_path !== expectedRunner || realpathSync(expectedRunner) !== expectedRunner) {
    throw new Error('attested runner path is not the fixed canonical runner')
  }
  const runner = lstatSync(expectedRunner)
  const expectedRunnerUid = options.expectedRunnerUid ?? 0
  assertOwnerChain(dirname(expectedRunner), expectedRunnerUid)
  if (
    !runner.isFile()
    || runner.isSymbolicLink()
    || runner.uid !== expectedRunnerUid
    || (runner.mode & 0o022) !== 0
    || (runner.mode & 0o111) === 0
    || typeof value.runner_sha256 !== 'string'
    || value.runner_sha256 !== fileSha256(expectedRunner, 4 * 1024 * 1024)
  ) throw new Error('root runner ownership/mode/hash is invalid')

  const fableAuthorities = [
    [value.fable_reviewer_path, value.fable_reviewer_sha256,
      options.fableReviewerPathOverride
        ?? (expectedExecutableUid === 0 ? DEDICATED_FABLE_REVIEWER : String(value.fable_reviewer_path)),
      true, 2 * 1024 * 1024],
    [value.fable_doctrine_path, value.fable_doctrine_sha256,
      options.fableDoctrinePathOverride
        ?? (expectedExecutableUid === 0 ? DEDICATED_FABLE_DOCTRINE : String(value.fable_doctrine_path)),
      false, 1024 * 1024],
    [value.fable_schema_path, value.fable_schema_sha256,
      options.fableSchemaPathOverride
        ?? (expectedExecutableUid === 0 ? DEDICATED_FABLE_SCHEMA : String(value.fable_schema_path)),
      false, 1024 * 1024],
  ] as const
  for (const [attestedPath, attestedHash, expectedPath, executable, maxBytes] of fableAuthorities) {
    if (attestedPath !== expectedPath || !isAbsolute(expectedPath)
      || realpathSync(expectedPath) !== expectedPath) {
      throw new Error('attested Fable reviewer path is not fixed and canonical')
    }
    assertOwnerChain(dirname(expectedPath), expectedExecutableUid)
    const info = lstatSync(expectedPath)
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== expectedExecutableUid
      || (info.mode & 0o022) !== 0 || info.nlink !== 1
      || (executable && (info.mode & 0o111) === 0)
      || typeof attestedHash !== 'string'
      || attestedHash !== fileSha256(expectedPath, maxBytes)) {
      throw new Error('attested Fable reviewer authority ownership/mode/hash is invalid')
    }
  }
  for (const [name, hash] of [
    ['fable_reviewer_config_sha256', value.fable_reviewer_config_sha256],
    ['codex_config_sha256', value.codex_config_sha256],
  ] as const) {
    if (typeof hash !== 'string' || !/^[0-9a-f]{64}$/.test(hash)) {
      throw new Error(`invalid attestation ${name}`)
    }
  }
  const codexConfigPath = join(codexHome, 'config.toml')
  const codexConfig = lstatSync(codexConfigPath)
  if (!codexConfig.isFile() || codexConfig.isSymbolicLink()
    || codexConfig.uid !== filesystemRuntimeUid || (codexConfig.mode & 0o777) !== 0o600
    || codexConfig.nlink !== 1) {
    throw new Error('dedicated Codex config differs from the installed root authority')
  }
  // The production daemon is intentionally unable to read hidden-UID 0600
  // config bytes. Their attested digest is descriptor-bound by the root runner
  // immediately before every launch. Test fixtures that share an uid prove the
  // same byte comparison here without weakening that account boundary.
  if (filesystemRuntimeUid === currentUid
    && value.codex_config_sha256 !== fileSha256(codexConfigPath, 1024 * 1024)) {
    throw new Error('dedicated Codex config differs from the installed root authority')
  }
  if (
    typeof value.launchd_canary_name !== 'string'
    || !/^QOFI_CODEX_RUNTIME_CANARY_[A-Z0-9_]{8,64}$/.test(value.launchd_canary_name)
    || typeof value.launchd_canary_sha256 !== 'string'
    || !/^[0-9a-f]{64}$/.test(value.launchd_canary_sha256)
  ) throw new Error('invalid dedicated launchd canary attestation')

  const workspace = realpathSync(options.workspaceRoot)
  const state = realpathSync(options.stateDir)
  for (const exposed of [workspace, state, ...(options.readableRoots ?? [])]) {
    const canonical = realpathSync(exposed)
    if (inside(canonical, runtimeHome) || inside(runtimeHome, canonical)) {
      throw new Error('dedicated runtime home overlaps workspace/state/tool read roots')
    }
  }
  if (!options.skipWorkspaceGroupValidation) {
    reconcileOperatorWorkspacePaths(workspace, runtimeGid, operatorUid)
    validateSharedWorkspaceBoundary(workspace, runtimeGid, operatorUid)
  }

  const sudoPath = '/usr/bin/sudo' as const
  const sudo = lstatSync(sudoPath)
  if (
    !sudo.isFile()
    || sudo.isSymbolicLink()
    || sudo.uid !== 0
    || sudo.gid !== 0
    || (sudo.mode & 0o7777) !== 0o4511
    || sudo.nlink !== 1
    || sudo.size <= 0
    || sudo.size > 16 * 1024 * 1024
  ) {
    throw new Error('/usr/bin/sudo is not a trusted root executable')
  }
  return {
    operatorUid,
    runtimeUid,
    runtimeUser: value.runtime_user,
    runtimeGid,
    runtimeGroup: value.runtime_group,
    runtimeHome,
    codexHome,
    runtimeTemp,
    nodePath: trustedNode,
    codexScript: trustedScript,
    runnerPath: expectedRunner,
    launchdCanaryName: value.launchd_canary_name,
    launchdCanarySha256: value.launchd_canary_sha256,
    sudoPath,
    sudoArgvPrefix: [
      '-n',
      '--', expectedRunner, '--parent-pid', String(process.pid), '--',
    ],
  }
}

export type DedicatedIsolationResult =
  | { ok: true }
  | { ok: false; detail: string }

export function isExactDedicatedPnpmVersionOutput(output: string): boolean {
  return output === DEDICATED_PNPM_VERSION || output === `${DEDICATED_PNPM_VERSION}\n`
}

export function isAttestedOperatorCanary(value: string | undefined, expectedSha256: string): boolean {
  return Boolean(
    value
    && /^[A-Za-z0-9_.:-]{16,256}$/.test(value)
    && createHash('sha256').update(value).digest('hex') === expectedSha256,
  )
}

/** Byte-for-byte pinned by qofi-codex-runner before /bin/sh may execute it. */
export const DEDICATED_TOOL_PROBE_SCRIPT = [
  'set -eu',
  'fail() { printf \'qofi-tool-probe: %s\\n\' "$1" >&2; exit 69; }',
  'while [ "$#" -gt 0 ]; do',
  '  name=$1',
  '  path=$2',
  '  shift 2',
  '  case "$name" in',
  '    xcrun) "$path" --find clang >/dev/null || fail "$name execution failed" ;;',
  '    xcodebuild) "$path" -version >/dev/null || fail "$name execution failed" ;;',
  '    go) "$path" version >/dev/null || fail "$name execution failed" ;;',
  '    pnpm) output=$("$path" --version && printf qofi-pnpm-end) || fail "$name execution failed"; expected=$(printf \'9.12.3\\nqofi-pnpm-end\'); { [ "$output" = "9.12.3qofi-pnpm-end" ] || [ "$output" = "$expected" ]; } || fail "pnpm must be exactly 9.12.3" ;;',
  '    *) "$path" --version >/dev/null || fail "$name execution failed" ;;',
  '  esac',
  'done',
].join('\n')

/** Prove the operator canary exists and is absent from the dedicated bootstrap/keychain. */
export function runDedicatedIsolationPreflight(
  plan: DedicatedRuntimePlan,
  workspaceRoot: string,
  readableRoots: readonly string[],
  deniedPaths: readonly string[],
  environment: NodeJS.ProcessEnv,
  toolExecutables: Readonly<Record<string, string>>,
  inheritedOperatorCanary?: string,
): DedicatedIsolationResult {
  const operatorCanary = spawnSync('/bin/launchctl', ['getenv', plan.launchdCanaryName], {
    encoding: 'utf8', env: sanitizedCodexEnv(environment), timeout: 3000,
  })
  const localOperatorCanary = operatorCanary.error || operatorCanary.status !== 0
    ? undefined
    : operatorCanary.stdout.trim()
  // A long-lived tmux server may retain an older macOS bootstrap/audit context
  // and therefore cannot query a canary installed in the current login
  // context. swarm-up may inherit the already root-attested witness from its
  // current terminal. Only its hash is trusted, and sanitized child/sandbox
  // environments never receive this parent-only value.
  if (
    !isAttestedOperatorCanary(localOperatorCanary, plan.launchdCanarySha256)
    && !isAttestedOperatorCanary(inheritedOperatorCanary, plan.launchdCanarySha256)
  ) {
    return { ok: false, detail: 'operator launchd isolation canary is absent or changed' }
  }

  const executionEnvironment = safeExecutionOverrides(environment)
  const shellEnvironmentToml = `{${Object.entries(executionEnvironment)
    .map(([key, value]) => `${JSON.stringify(key)}=${JSON.stringify(value)}`)
    .join(',')}}`

  const run = (command: string, args: string[]) => spawnSync(plan.sudoPath, [
    ...plan.sudoArgvPrefix,
    'sandbox', '-P', CODEX_PERMISSION_PROFILE, '-C', workspaceRoot,
    ...buildPermissionProfileArgs(readableRoots, false, workspaceRoot, deniedPaths, [plan.runtimeTemp]),
    '-c', 'shell_environment_policy.inherit="none"',
    '-c', `shell_environment_policy.set=${shellEnvironmentToml}`,
    '-c', 'shell_environment_policy.experimental_use_profile=false',
    '--', command, ...args,
  ], {
    encoding: 'utf8',
    cwd: workspaceRoot,
    env: { ...sanitizedCodexEnv(environment), HOME: plan.runtimeHome, CODEX_HOME: plan.codexHome },
    // A first macOS seatbelt launch can spend just over ten seconds bringing
    // up system preference infrastructure before the requested command execs.
    // Ten seconds races that handoff and can interrupt runner STOP->KILL
    // cleanup. Keep the probe bounded, but leave enough room for a cold start.
    timeout: 30_000,
  })

  const uid = run('/usr/bin/id', ['-u'])
  if (uid.error || uid.status !== 0 || Number(uid.stdout.trim()) !== plan.runtimeUid) {
    const diagnostic = `${uid.stderr ?? ''} ${uid.stdout ?? ''}`
      .trim().replace(/\s+/g, ' ').slice(0, 512)
    return {
      ok: false,
      detail: 'sudo/Codex sandbox did not execute as the attested runtime uid'
        + `${diagnostic ? `: ${diagnostic}` : ` (exit ${uid.status ?? 'spawn-error'})`}`,
    }
  }
  for (const required of ['git', 'python3', 'bun']) {
    if (!toolExecutables[required]) {
      return { ok: false, detail: `dedicated runtime is missing required tool ${required}` }
    }
  }
  const toolPairs = Object.entries(toolExecutables)
    .sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0)
  if (toolPairs.length > 16) {
    return { ok: false, detail: 'dedicated runtime detected more than 16 tools' }
  }
  const toolProbe = run('/bin/sh', [
    '-c', DEDICATED_TOOL_PROBE_SCRIPT, 'qofi-toolchain-probe',
    ...toolPairs.flatMap(([name, path]) => [name, path]),
  ])
  if (toolProbe.error || toolProbe.status !== 0) {
    const diagnostic = `${toolProbe.stderr ?? ''} ${toolProbe.stdout ?? ''}`
      .trim().replace(/\s+/g, ' ').slice(0, 512)
    return {
      ok: false,
      detail: 'dedicated runtime cannot execute detected toolchain'
        + `${diagnostic ? `: ${diagnostic}` : ` (exit ${toolProbe.status ?? 'spawn-error'})`}`,
    }
  }
  const gitRead = run('/bin/sh', [
    '-c', [
      'set -eu',
      'GIT_NO_LAZY_FETCH=1 "$1" --no-pager --no-optional-locks --no-replace-objects -c safe.directory="$2" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false -C "$2" rev-parse --verify "HEAD^{commit}" >/dev/null',
      'GIT_NO_LAZY_FETCH=1 "$1" --no-pager --no-optional-locks --no-replace-objects -c safe.directory="$2" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false -C "$2" cat-file -e "HEAD^{commit}"',
      'GIT_NO_LAZY_FETCH=1 "$1" --no-pager --no-optional-locks --no-replace-objects -c safe.directory="$2" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false -C "$2" ls-files --stage >/dev/null',
    ].join('\n'),
    'qofi-git-read-canary', toolExecutables.git, workspaceRoot,
  ])
  if (gitRead.error || gitRead.status !== 0) {
    const diagnostic = `${gitRead.stderr ?? ''} ${gitRead.stdout ?? ''}`
      .trim().replace(/\s+/g, ' ').slice(0, 512)
    return {
      ok: false,
      detail: 'dedicated runtime cannot safely read Git HEAD, objects, and index'
        + `${diagnostic ? `: ${diagnostic}` : ` (exit ${gitRead.status ?? 'spawn-error'})`}`,
    }
  }
  const buildCanary = (name: string, script: string, args: string[]): DedicatedIsolationResult | null => {
    const result = run('/bin/sh', ['-c', script, `qofi-${name}-build-canary`, ...args])
    return result.error || result.status !== 0
      ? { ok: false, detail: `dedicated runtime cannot complete ${name} build canary` }
      : null
  }
  let buildFailure = buildCanary('bun', [
    'd="$2/bun-build-$$"; trap \'rm -rf "$d"\' EXIT; mkdir -p "$d" || exit',
    'printf \'import {expect,test} from "bun:test"; test("smoke",()=>expect(2+2).toBe(4))\\n\' > "$d/smoke.test.ts" || exit',
    '"$1" test "$d/smoke.test.ts" >/dev/null 2>&1',
  ].join('; '), [toolExecutables.bun, plan.runtimeTemp])
  if (buildFailure) return buildFailure
  if (toolExecutables.go) {
    buildFailure = buildCanary('go', [
      'd="$2/go-build-$$"; trap \'rm -rf "$d"\' EXIT; mkdir -p "$d" || exit',
      'printf \'package smoke\\nimport "testing"\\nfunc TestSmoke(t *testing.T) {}\\n\' > "$d/smoke_test.go" || exit',
      'cd "$d" && "$1" test smoke_test.go >/dev/null 2>&1',
    ].join('; '), [toolExecutables.go, plan.runtimeTemp])
    if (buildFailure) return buildFailure
  }
  if (toolExecutables.rustc) {
    buildFailure = buildCanary('rustc', [
      'd="$2/rust-build-$$"; trap \'rm -rf "$d"\' EXIT; mkdir -p "$d" || exit',
      'printf \'fn main() { assert_eq!(2 + 2, 4); }\\n\' > "$d/main.rs" || exit',
      '"$1" "$d/main.rs" -o "$d/smoke" >/dev/null 2>&1 && "$d/smoke"',
    ].join('; '), [toolExecutables.rustc, plan.runtimeTemp])
    if (buildFailure) return buildFailure
  }
  if (toolExecutables.cargo) {
    if (!toolExecutables.rustc) {
      return { ok: false, detail: 'detected Cargo requires an independently validated rustc' }
    }
    buildFailure = buildCanary('cargo', [
      'd="$2/cargo-build-$$"; trap \'rm -rf "$d"\' EXIT; mkdir -p "$d/src" || exit',
      'printf \'[package]\\nname="qofi_smoke"\\nversion="0.1.0"\\nedition="2021"\\n\' > "$d/Cargo.toml" || exit',
      'printf \'fn main() { assert_eq!(2 + 2, 4); }\\n\' > "$d/src/main.rs" || exit',
      'RUSTC="$3" "$1" build --manifest-path "$d/Cargo.toml" --target-dir "$d/target" >/dev/null 2>&1',
    ].join('; '), [toolExecutables.cargo, plan.runtimeTemp, toolExecutables.rustc])
    if (buildFailure) return buildFailure
  }
  if (toolExecutables.swiftc || toolExecutables.xcrun) {
    const swiftTool = toolExecutables.xcrun ?? toolExecutables.swiftc
    const swiftPrefix = toolExecutables.xcrun ? '"$1" swiftc' : '"$1"'
    buildFailure = buildCanary('swift', [
      'd="$2/swift-build-$$"; trap \'rm -rf "$d"\' EXIT; mkdir -p "$d" || exit',
      'printf \'precondition(2 + 2 == 4)\\n\' > "$d/main.swift" || exit',
      `${swiftPrefix} "$d/main.swift" -o "$d/smoke" >/dev/null 2>&1 && "$d/smoke"`,
    ].join('; '), [swiftTool, plan.runtimeTemp])
    if (buildFailure) return buildFailure
  }
  if (toolExecutables.xcrun) {
    buildFailure = buildCanary('xcode', [
      'd="$2/xcode-build-$$"; trap \'rm -rf "$d"\' EXIT; mkdir -p "$d" || exit',
      'printf \'int main(void) { return 0; }\\n\' > "$d/main.c" || exit',
      '"$1" clang "$d/main.c" -o "$d/smoke" >/dev/null 2>&1 && "$d/smoke"',
    ].join('; '), [toolExecutables.xcrun, plan.runtimeTemp])
    if (buildFailure) return buildFailure
  }
  const workspaceMarker = join(workspaceRoot, `.qofi-runtime-write-canary-${process.pid}`)
  const deletedMarker = `${workspaceMarker}-deleted`
  try { rmSync(workspaceMarker, { force: true }) } catch {}
  try { rmSync(deletedMarker, { force: true }) } catch {}
  try {
    writeFileSync(workspaceMarker, 'operator', { mode: 0o644 })
    // Explicitly model an ordinary operator/editor file created under umask
    // 022 after privileged setup, then exercise the per-validation repair.
    chmodSync(workspaceMarker, 0o644)
    reconcileOperatorWorkspacePaths(workspaceRoot, plan.runtimeGid, plan.operatorUid)
  } catch (err) {
    try { rmSync(workspaceMarker, { force: true }) } catch {}
    return { ok: false, detail: `operator workspace reconciliation failed: ${err}` }
  }
  const workspaceWrite = run('/bin/sh', [
    '-c', 'umask 0002; printf runtime >> "$1" && printf delete > "$2" && rm -f "$2"',
    'qofi-runtime-write-canary', workspaceMarker, deletedMarker,
  ])
  let workspaceModeOk = false
  try {
    const markerStat = lstatSync(workspaceMarker)
    workspaceModeOk = markerStat.isFile()
      && markerStat.gid === plan.runtimeGid
      && (markerStat.mode & 0o060) === 0o060
      && readFileSync(workspaceMarker, 'utf8') === 'operatorruntime'
  } catch {}
  if (
    workspaceWrite.error
    || workspaceWrite.status !== 0
    || !workspaceModeOk
    || existsSync(deletedMarker)
  ) {
    try { rmSync(workspaceMarker, { force: true }) } catch {}
    try { rmSync(deletedMarker, { force: true }) } catch {}
    return { ok: false, detail: 'dedicated runtime cannot create/edit/delete a workspace file' }
  }
  try { rmSync(workspaceMarker, { force: true }) } catch {
    return { ok: false, detail: 'operator cannot remove a dedicated-runtime workspace file' }
  }
  const detachedMarker = join(workspaceRoot, `.qofi-runtime-detached-canary-${process.pid}`)
  try { rmSync(detachedMarker, { force: true }) } catch {}
  const detached = run('/bin/sh', [
    '-c', '(trap "" HUP; sleep 1; printf escaped > "$1") </dev/null >/dev/null 2>&1 &',
    'qofi-runtime-detached-canary', detachedMarker,
  ])
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500)
  if (detached.error || detached.status !== 0 || existsSync(detachedMarker)) {
    try { rmSync(detachedMarker, { force: true }) } catch {}
    return { ok: false, detail: 'root runner failed to reap a detached runtime process' }
  }
  const launchd = run('/bin/launchctl', ['getenv', plan.launchdCanaryName])
  if (launchd.error || launchd.status !== 0 || launchd.stdout.trim() !== '') {
    return { ok: false, detail: 'dedicated runtime can reach the operator launchd secret namespace' }
  }
  const keychains = run('/usr/bin/security', ['list-keychains', '-d', 'user'])
  if (keychains.error || keychains.status !== 0 || keychains.stdout.trim() !== '') {
    return { ok: false, detail: 'dedicated runtime user keychain search list is not empty' }
  }
  const label = `qofi.codex.sandbox-canary.${process.pid}.${Date.now()}`
  const marker = join(workspaceRoot, `.qofi-launchd-canary-${process.pid}-${Date.now()}`)
  try { rmSync(marker, { force: true }) } catch {}
  const submitted = run('/bin/launchctl', [
    'submit', '-l', label, '--', '/usr/bin/touch', marker,
  ])
  const printed = run('/bin/launchctl', ['print', `user/${plan.runtimeUid}/${label}`])
  const escaped = submitted.status === 0 || printed.status === 0 || existsSync(marker)
  try { rmSync(marker, { force: true }) } catch {}
  if (submitted.error || printed.error || escaped) {
    return { ok: false, detail: 'exact Codex permission profile permits persistent launchd job submission' }
  }
  return { ok: true }
}
