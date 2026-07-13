import { spawnSync } from 'child_process'
import { createHash } from 'crypto'
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
} from 'fs'
import { isAbsolute, join, resolve, sep } from 'path'
import { MIN_CODEX_CLI_VERSION, sanitizedCodexEnv } from './codex.ts'
import { containsHighConfidenceSecret, discoverWorkspacePolicy } from './workspace.ts'
import { validateProjectConfigToml } from './project-config.ts'

export const MAX_CODEX_CLI_VERSION_EXCLUSIVE = '0.145.0'
/** Covers a cold hidden-user macOS bootstrap while remaining fail-fast. */
export const DEDICATED_CODEX_PREFLIGHT_TIMEOUT_MS = 30_000

export type CodexPreflightResult =
  | { ok: true; version: string }
  | { ok: false; errorKind: 'version-command' | 'unsupported-version' | 'login-command' | 'auth-mode'; detail: string }

export type WorkspaceSafetyResult =
  | {
      ok: true
      cwd: string
      deniedPaths: string[]
      readableExamples: string[]
      projectConfig: ProjectConfigIdentity | null
    }
  | { ok: false; errorKind: 'workspace-vault' | 'workspace-scan'; detail: string }

export type ProjectConfigIdentity = {
  path: string
  identity: string
}

export function inspectProjectConfig(
  root: string,
  /** Deterministic race seam for tests; production callers always omit it. */
  beforeOpen?: () => void,
): ProjectConfigIdentity | null {
  const path = join(root, '.codex', 'config.toml')
  let before
  try { before = lstatSync(path) } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw err
  }
  const uid = typeof process.getuid === 'function' ? process.getuid() : before.uid
  if (
    !before.isFile()
    || before.isSymbolicLink()
    || before.uid !== uid
    || (before.mode & 0o022) !== 0
    || before.size > 64 * 1024
    || realpathSync(path) !== path
  ) throw new Error('project .codex/config.toml must be canonical owner-controlled regular <=64KiB')
  const noFollow = typeof constants.O_NOFOLLOW === 'number' ? constants.O_NOFOLLOW : 0
  beforeOpen?.()
  const fd = openSync(path, constants.O_RDONLY | noFollow)
  try {
    const opened = fstatSync(fd)
    if (
      !opened.isFile()
      || opened.dev !== before.dev
      || opened.ino !== before.ino
      || opened.size !== before.size
      || opened.mode !== before.mode
    ) throw new Error('project .codex/config.toml changed while opening')
    const content = readFileSync(fd)
    if (containsHighConfidenceSecret(content)) {
      throw new Error('project .codex/config.toml contains a high-confidence secret')
    }
    validateProjectConfigToml(content.toString('utf8'))
    const hash = createHash('sha256').update(content).digest('hex')
    return {
      path,
      identity: `${opened.dev}:${opened.ino}:${opened.mode}:${opened.size}:${opened.mtimeMs}:${hash}`,
    }
  } finally {
    closeSync(fd)
  }
}

export function recheckProjectConfig(
  cwd: string,
  expected: ProjectConfigIdentity | null,
): boolean {
  try {
    const current = inspectProjectConfig(realpathSync(resolve(cwd)))
    return current?.path === expected?.path && current?.identity === expected?.identity
  } catch {
    return false
  }
}

/** A swarm vault must never itself become a model-readable workspace. */
export function checkWorkspaceSafety(
  cwd: string,
  protectedRuntimeRoots: readonly string[] = [],
): WorkspaceSafetyResult {
  let normalized: string
  try {
    const lexical = resolve(cwd)
    const rootStat = lstatSync(lexical)
    if (!rootStat.isDirectory()) {
      return { ok: false, errorKind: 'workspace-scan', detail: 'workspace root is not a directory' }
    }
    normalized = realpathSync(lexical)
  } catch (err) {
    return {
      ok: false,
      errorKind: 'workspace-scan',
      detail: `could not canonicalize workspace root: ${err}`.slice(0, 500),
    }
  }
  for (const rawRoot of protectedRuntimeRoots) {
    try {
      if (!isAbsolute(rawRoot)) throw new Error('protected runtime root is not absolute')
      const protectedRoot = realpathSync(resolve(rawRoot))
      const workspaceContainsRuntime = protectedRoot === normalized
        || protectedRoot.startsWith(normalized + sep)
      const runtimeContainsWorkspace = normalized.startsWith(protectedRoot + sep)
      if (workspaceContainsRuntime || runtimeContainsWorkspace) {
        return {
          ok: false,
          errorKind: 'workspace-vault',
          detail: 'workspace overlaps the bridge runtime/SWARM_HOME source boundary',
        }
      }
    } catch (err) {
      return {
        ok: false,
        errorKind: 'workspace-scan',
        detail: `could not validate protected runtime root: ${err}`.slice(0, 500),
      }
    }
  }
  const gitEntry = join(normalized, '.git')
  try {
    const gitStat = lstatSync(gitEntry)
    if (!gitStat.isDirectory() || gitStat.isSymbolicLink() || realpathSync(gitEntry) !== gitEntry) {
      return {
        ok: false,
        errorKind: 'workspace-vault',
        detail: 'linked/symlinked Git worktrees are unsupported; use a canonical in-repo .git directory',
      }
    }
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      return { ok: false, errorKind: 'workspace-vault', detail: `could not validate .git boundary: ${err}`.slice(0, 500) }
    }
  }
  const vault = join(normalized, 'tokens.env')
  try {
    lstatSync(vault)
    return {
      ok: false,
      errorKind: 'workspace-vault',
      detail: `refusing workspace containing vault file ${vault}`,
    }
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      return {
        ok: false,
        errorKind: 'workspace-vault',
        detail: `could not verify workspace vault boundary: ${err}`.slice(0, 500),
      }
    }
  }
  const gitConfig = join(normalized, '.git', 'config')
  try {
    const configStat = lstatSync(gitConfig)
    const uid = typeof process.getuid === 'function' ? process.getuid() : configStat.uid
    if (
      !configStat.isFile()
      || configStat.isSymbolicLink()
      || configStat.uid !== uid
      || (configStat.mode & 0o022) !== 0
      || realpathSync(gitConfig) !== gitConfig
    ) {
      return { ok: false, errorKind: 'workspace-vault', detail: 'git config is not a regular file' }
    }
    if (configStat.size > 64 * 1024) {
      return { ok: false, errorKind: 'workspace-vault', detail: 'git config exceeds safety bound' }
    }
    const config = readFileSync(gitConfig, 'utf8')
    if (
      /[a-z][a-z0-9+.-]*:\/\/[^/\s@]+@/i.test(config)
      || /[?&](?:access_?token|api_?key|private_?token|password|passwd|signature|sig|auth)=/i.test(config)
      || containsHighConfidenceSecret(config)
      || /^\s*extraheader\s*=/im.test(config)
      || /^\s*\[credential\b/im.test(config)
      || /^\s*(?:credential\.[^=]+|cookiefile|sslkey|askpass)\s*=/im.test(config)
      || /^\s*\[include(?:If)?\b/im.test(config)
      || /^\s*(?:fsmonitor|sshCommand|askPass|pager|editor)\s*=/im.test(config)
      || /^\s*[^=]+\s*=\s*!/m.test(config)
    ) {
      return { ok: false, errorKind: 'workspace-vault', detail: 'git config contains unsafe credential/include/hook settings' }
    }
    const safeHooks = join(normalized, '.git', 'hooks')
    for (const match of config.matchAll(/^\s*hooksPath\s*=\s*(.+?)\s*$/gim)) {
      const raw = match[1].replace(/^(?:"|')|(?:"|')$/g, '')
      const resolvedHooks = resolve(normalized, raw)
      let canonicalHooks = resolvedHooks
      try { canonicalHooks = realpathSync(resolvedHooks) } catch {}
      if (canonicalHooks !== safeHooks) {
        return { ok: false, errorKind: 'workspace-vault', detail: 'git hooksPath escapes the immutable .git/hooks directory' }
      }
      try {
        const hookStat = lstatSync(safeHooks)
        if (!hookStat.isDirectory() || hookStat.isSymbolicLink() || realpathSync(safeHooks) !== safeHooks) {
          return { ok: false, errorKind: 'workspace-vault', detail: 'git hooks directory is unsafe' }
        }
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
      }
    }
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      return {
        ok: false,
        errorKind: 'workspace-vault',
        detail: `could not verify git config safety: ${err}`.slice(0, 500),
      }
    }
  }
  try {
    const projectConfig = inspectProjectConfig(normalized)
    const policy = discoverWorkspacePolicy(normalized)
    return {
      ok: true,
      cwd: normalized,
      deniedPaths: policy.deniedPaths,
      readableExamples: policy.readableExamples,
      projectConfig,
    }
  } catch (err) {
    return {
      ok: false,
      errorKind: 'workspace-scan',
      detail: String((err as Error).message ?? err).slice(0, 500),
    }
  }
}

export function isSupportedCodexVersion(version: string): boolean {
  const match = version.match(/^(\d+)\.(\d+)\.(\d+)$/)
  if (!match) return false
  const [, major, minor, patch] = match.map(Number)
  return major === 0 && minor === 144 && patch >= 1
}

export function parseCodexVersion(output: string): string | null {
  return output.match(/(?:^|\s)codex-cli\s+(\d+\.\d+\.\d+)(?:\s|$)/)?.[1] ?? null
}

/** Verify the exact CLI semantics and subscription auth required by the daemon. */
export function runCodexPreflight(
  bin: string,
  sourceEnv: NodeJS.ProcessEnv = process.env,
  timeoutMs = 5000,
  argvPrefix: readonly string[] = [],
): CodexPreflightResult {
  const env = sanitizedCodexEnv(sourceEnv)
  const common = { env, encoding: 'utf8' as const, timeout: timeoutMs }
  const versionRun = spawnSync(bin, [...argvPrefix, '--version'], common)
  const versionOutput = `${versionRun.stdout ?? ''}\n${versionRun.stderr ?? ''}`
  if (versionRun.error || versionRun.status !== 0) {
    return {
      ok: false,
      errorKind: 'version-command',
      detail: `could not execute Codex version check: ${versionRun.error?.message ?? `exit ${versionRun.status}`}`.slice(0, 500),
    }
  }
  const version = parseCodexVersion(versionOutput)
  if (!version || !isSupportedCodexVersion(version)) {
    return {
      ok: false,
      errorKind: 'unsupported-version',
      detail: `requires codex-cli >=${MIN_CODEX_CLI_VERSION}, <${MAX_CODEX_CLI_VERSION_EXCLUSIVE}; found ${version ?? 'unknown'}`,
    }
  }

  const loginRun = spawnSync(bin, [
    ...argvPrefix,
    'login',
    '-c', 'forced_login_method="chatgpt"',
    '-c', 'cli_auth_credentials_store="file"',
    'status',
  ], common)
  const loginOutput = `${loginRun.stdout ?? ''}\n${loginRun.stderr ?? ''}`
  if (loginRun.error || loginRun.status !== 0) {
    return {
      ok: false,
      errorKind: 'login-command',
      detail: `could not query Codex login status: ${loginRun.error?.message ?? `exit ${loginRun.status}`}`.slice(0, 500),
    }
  }
  if (!/(?:^|\r?\n)Logged in using ChatGPT(?:\r?\n|$)/.test(loginOutput)) {
    return {
      ok: false,
      errorKind: 'auth-mode',
      detail: 'Codex must be logged in using ChatGPT subscription auth',
    }
  }
  return { ok: true, version }
}
