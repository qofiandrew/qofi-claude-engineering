/**
 * Codex CLI runner. One Codex thread per Discord chat, persisted in
 * sessions.json so conversation context survives daemon restarts.
 *
 * First message in a chat:   codex exec --json ... -   (prompt on stdin)
 * Every later message:       codex exec resume <threadId> --json ... -
 *
 * `--json` emits JSONL events on stdout. Observed stream (codex-cli 0.142.3):
 *   {"type":"thread.started","thread_id":"<uuid>"}
 *   {"type":"turn.started"}
 *   {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"..."}}
 *   {"type":"turn.completed","usage":{...}}
 * Failures surface as {"type":"turn.failed",...} or {"type":"error","message":...}.
 *
 * NOTE: `exec resume` does not accept `-m`; model and the custom permission
 * profile are passed uniformly as `-c key=value` overrides on both forms.
 */

import { spawn } from 'child_process'
import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { isAbsolute, join, parse as parsePath, resolve } from 'path'
import { StringDecoder } from 'string_decoder'
import {
  DEFAULT_CODEX_MODEL,
  DEFAULT_CODEX_REASONING_EFFORT,
  type ManagedCodexReasoningEffort,
} from './model.ts'

export type CodexFailureKind =
  | 'missing-thread'
  | 'usage-limit'
  | 'turn-failed'
  | 'protocol'
  | 'spawn'
  | 'exit'
  | 'timeout'
  | 'aborted'
  | 'output-limit'

export type CodexTurnResult = {
  ok: boolean
  threadId: string | null
  /** All agent_message texts in the turn, in order. The last one is the reply. */
  messages: string[]
  error?: string
  errorKind?: CodexFailureKind
}

type JsonObject = Record<string, any>

function isObjectEvent(value: unknown): value is JsonObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function errorText(ev: JsonObject, fallback: string): string {
  const candidate = ev.error?.message ?? ev.message
  return typeof candidate === 'string' && candidate ? candidate.slice(0, 4096) : fallback
}

type ParsedState = {
  threadId: string | null
  messages: string[]
  completed: boolean
  error?: string
  errorKind?: CodexFailureKind
}

export type CodexEventSummary = {
  type: string
  threadId?: string
  itemId?: string
  itemType?: string
  status?: string
}

/** A deliberately content-free event projection suitable for operator logs. */
export function summarizeCodexEvent(ev: JsonObject): CodexEventSummary | null {
  if (typeof ev.type !== 'string' || ev.type.length > 80) return null
  const summary: CodexEventSummary = { type: ev.type }
  if (ev.type === 'thread.started' && typeof ev.thread_id === 'string') {
    summary.threadId = ev.thread_id.slice(0, 128)
  }
  if ((ev.type === 'item.started' || ev.type === 'item.completed') && isObjectEvent(ev.item)) {
    if (typeof ev.item.id === 'string') summary.itemId = ev.item.id.slice(0, 128)
    if (typeof ev.item.type === 'string') summary.itemType = ev.item.type.slice(0, 80)
    if (typeof ev.item.status === 'string') summary.status = ev.item.status.slice(0, 80)
  }
  if (ev.type === 'turn.completed') summary.status = 'completed'
  if (ev.type === 'turn.failed') summary.status = 'failed'
  return summary
}

function consumeEvent(state: ParsedState, value: unknown): CodexEventSummary | null {
  // JSONL producers occasionally print JSON scalars as diagnostics. They are
  // valid JSON but not protocol events, so treat them like other stdout noise.
  if (!isObjectEvent(value)) return null
  const ev = value
  switch (ev.type) {
    case 'thread.started':
      state.threadId = typeof ev.thread_id === 'string' ? ev.thread_id : state.threadId
      break
    case 'item.completed':
      if (ev.item?.type === 'agent_message' && typeof ev.item.text === 'string') {
        state.messages.push(ev.item.text)
      }
      break
    case 'turn.completed':
      state.completed = true
      break
    case 'turn.failed':
      state.error = errorText(ev, 'turn failed')
      state.errorKind = isMissingThreadError(state.error) ? 'missing-thread' : 'turn-failed'
      break
    case 'error':
      state.error = errorText(ev, 'error')
      state.errorKind = isMissingThreadError(state.error) ? 'missing-thread' : 'turn-failed'
      break
  }
  return summarizeCodexEvent(ev)
}

function resultFromState(state: ParsedState): CodexTurnResult {
  if (state.error) {
    return {
      ok: false,
      threadId: state.threadId,
      messages: state.messages,
      error: state.error,
      errorKind: state.errorKind,
    }
  }
  if (!state.completed) {
    return {
      ok: false,
      threadId: state.threadId,
      messages: state.messages,
      error: 'stream ended without turn.completed',
      errorKind: 'protocol',
    }
  }
  return { ok: true, threadId: state.threadId, messages: state.messages }
}

/** Parse a `codex exec --json` stdout stream. Pure — unit-tested on fixtures. */
export function parseCodexEvents(jsonl: string): CodexTurnResult {
  const state: ParsedState = { threadId: null, messages: [], completed: false }
  for (const line of jsonl.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    let ev: unknown
    try {
      ev = JSON.parse(trimmed)
    } catch {
      continue // non-JSON noise on stdout — ignore
    }
    consumeEvent(state, ev)
  }
  return resultFromState(state)
}

export type CodexConfig = {
  cwd: string
  model?: string
  reasoningEffort?: ManagedCodexReasoningEffort
  profile?: string
  timeoutMs: number
  bin?: string
  /** Canonical argv fields inserted before Codex CLI flags (for example codex.js after absolute node). */
  binArgs?: string[]
  maxStdoutBytes?: number
  maxStderrBytes?: number
  killGraceMs?: number
  disabledFeatures?: string[]
}

export const DEFAULT_DISABLED_FEATURES = [
  'plugins',
  'plugin_sharing',
  'remote_plugin',
  'apps',
  'browser_use',
  'browser_use_external',
  'browser_use_full_cdp_access',
  'in_app_browser',
  'computer_use',
  'image_generation',
  'skill_mcp_dependency_install',
  'tool_call_mcp_elicitation',
  'auth_elicitation',
  'tool_suggest',
  'code_mode_host',
  // Discord turns are scoped to sessions.json; block host-global persistence
  // and autonomous continuation outside the supervised child process.
  'goals',
  'memories',
  'chronicle',
  'workspace_dependencies',
  'shell_snapshot',
  // Command hooks run outside the tool filesystem/network sandbox in 0.144.1.
  // Unattended Discord turns must never execute them, even when stamped.
  'hooks',
] as const

/** First CLI version verified against the hardening flags above. */
export const MIN_CODEX_CLI_VERSION = '0.144.1'
export const CODEX_PERMISSION_PROFILE = 'qofi-workspace-only'
export const PROTECTED_ROOT_DOCTRINE = [
  'AGENTS.md', 'CLAUDE.md', 'TEAM_LEAD.md', 'ESCALATION.md',
  'CONVERSATION.md', 'EVALUATION.md', 'SURFACING.md', 'MEMORY.md',
  'READINESS_BAR.md', 'CPO_BUS_PROTOCOL.md',
] as const

export function workspaceProtectedReadPaths(workspaceRoot: string): string[] {
  const root = resolve(workspaceRoot)
  return [
    join(root, '.codex'),
    join(root, '.agents'),
    join(root, '.claude'),
    join(root, '.gitleaks.toml'),
    ...PROTECTED_ROOT_DOCTRINE.map(name => join(root, name)),
  ]
}

export function workspaceSecretDenyPaths(workspaceRoot: string): string[] {
  const root = resolve(workspaceRoot)
  const envSuffixes = ['local', 'production', 'development', 'test', 'staging', 'secret', 'private']
  return [
    join(root, '.git', 'credentials'),
    join(root, '.git', 'config.worktree'),
    join(root, '.git', 'FETCH_HEAD'),
    join(root, '.git', 'objects', 'info', 'http-alternates'),
    join(root, '.git', 'hooks'),
    `${root}/.git/hooks/**`,
    `${root}/.git/modules/**/credentials`,
    `${root}/.git/modules/**/config`,
    `${root}/.git/modules/**/config.worktree`,
    `${root}/.git/modules/**/FETCH_HEAD`,
    `${root}/.git/modules/**/objects/info/http-alternates`,
    `${root}/.git/modules/**/hooks/**`,
    join(root, '.claude', 'worktrees'),
    `${root}/.claude/worktrees/**`,
    join(root, '.env'),
    `${root}/*.env`,
    `${root}/**/.env`,
    `${root}/**/*.env`,
    ...envSuffixes.flatMap(suffix => [
      `${root}/.env.${suffix}`,
      `${root}/**/.env.${suffix}`,
    ]),
    join(root, 'tokens.env'),
    `${root}/**/tokens.env`,
    join(root, '.npmrc'),
    `${root}/**/.npmrc`,
    join(root, '.pypirc'),
    `${root}/**/.pypirc`,
    join(root, '.netrc'),
    `${root}/**/.netrc`,
    `${root}/**/*.pem`,
    `${root}/**/*.key`,
    `${root}/**/.aws/**`,
    `${root}/**/.ssh/**`,
    `${root}/**/.gnupg/**`,
  ]
}

export function buildPermissionFilesystem(
  readableRoots: readonly string[] = [],
  deniedPaths: readonly string[] = [],
  writableRoots: readonly string[] = [],
): string {
  const entries = buildPermissionFilesystemConfig(readableRoots, deniedPaths, writableRoots)
  return `{${Object.entries(entries)
    .map(([path, access]) => `${JSON.stringify(path)}=${JSON.stringify(access)}`)
    .join(',')}}`
}

export type PermissionFilesystemConfig = Record<string, 'read' | 'write' | 'deny'>

/** Nested equivalent of the exact TOML override used by `codex exec`. */
export function buildPermissionFilesystemConfig(
  readableRoots: readonly string[] = [],
  deniedPaths: readonly string[] = [],
  writableRoots: readonly string[] = [],
): PermissionFilesystemConfig {
  const entries = new Map<string, 'read' | 'write' | 'deny'>([
    [':root', 'deny'],
    [':minimal', 'read'],
    // App Server otherwise reports (and applies) its process TMPDIR as an
    // implicit workspace-write root. Per-turn tool temp is granted back by
    // its exact absolute path through writableRoots; no generation-global
    // temp capability may leak across swarms or turns.
    [':tmpdir', 'deny'],
    [':slash_tmp', 'deny'],
  ])
  for (const path of deniedPaths) {
    if (!isAbsolute(path) || path === parsePath(path).root) continue
    entries.set(path, 'deny')
  }
  for (const root of readableRoots) {
    // Exact read exceptions (for example .env.example) intentionally follow
    // broad deny globs; dynamic discovery never places a secret in both sets.
    if (!isAbsolute(root) || root === parsePath(root).root) continue
    entries.set(root, 'read')
  }
  for (const root of writableRoots) {
    if (!isAbsolute(root) || root === parsePath(root).root) continue
    entries.set(root, 'write')
  }
  return Object.fromEntries(entries)
}

/** Shared by exec turns and the standalone sandbox contract test. */
export function buildPermissionProfileArgs(
  readableRoots: readonly string[] = [],
  selectAsDefault = true,
  workspaceRoot?: string,
  additionalDeniedPaths: readonly string[] = [],
  writableRoots: readonly string[] = [],
): string[] {
  const protectedProjectState = workspaceRoot
    ? workspaceProtectedReadPaths(workspaceRoot)
    : []
  const deniedProjectSecrets = [
    ...(workspaceRoot ? workspaceSecretDenyPaths(workspaceRoot) : []),
    ...(workspaceRoot ? [`${resolve(workspaceRoot)}/.swarm-*`] : []),
    ...additionalDeniedPaths,
  ]
  return [
    ...(selectAsDefault
      ? ['-c', `default_permissions="${CODEX_PERMISSION_PROFILE}"`]
      : []),
    '-c', `permissions.${CODEX_PERMISSION_PROFILE}.extends=":workspace"`,
    '-c', `permissions.${CODEX_PERMISSION_PROFILE}.filesystem=${buildPermissionFilesystem([
      ...protectedProjectState,
      ...readableRoots,
    ], deniedProjectSecrets, writableRoots)}`,
    '-c', `permissions.${CODEX_PERMISSION_PROFILE}.network.enabled=false`,
  ]
}

const EXECUTION_ENV_KEYS = new Set([
  'HOME', 'CODEX_HOME', 'PATH', 'TMPDIR', 'TMP', 'TEMP', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME',
  'XDG_DATA_HOME', 'XDG_STATE_HOME',
  'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_TERMINAL_PROMPT', 'GIT_ASKPASS',
  'NPM_CONFIG_USERCONFIG', 'NPM_CONFIG_CACHE', 'NPM_CONFIG_UPDATE_NOTIFIER',
  'NPM_CONFIG_AUDIT', 'NPM_CONFIG_FUND', 'NPM_CONFIG_STORE_DIR',
  'NPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS', 'NPM_CONFIG_PACKAGE_MANAGER_STRICT',
  'NPM_CONFIG_PACKAGE_MANAGER_STRICT_VERSION', 'PNPM_HOME',
  'COREPACK_ENABLE_PROJECT_SPEC', 'COREPACK_ENABLE_DOWNLOAD_PROMPT',
  'COREPACK_ENABLE_NETWORK', 'BUN_INSTALL_CACHE_DIR', 'UV_CACHE_DIR',
  'PIP_CONFIG_FILE', 'PIP_CACHE_DIR', 'PYTHONNOUSERSITE',
  'GOCACHE', 'GOPATH', 'GOMODCACHE',
  'CARGO_HOME', 'CARGO_TARGET_DIR', 'RUSTUP_HOME',
  'CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULE_CACHE_PATH',
  'SWIFTPM_CACHE_PATH', 'SWIFTPM_CONFIG_PATH', 'SWIFTPM_SECURITY_PATH',
  'OBJROOT', 'SYMROOT', 'SHARED_PRECOMPS_DIR', 'DERIVED_DATA_DIR',
])

export function safeExecutionOverrides(source: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  const clean: NodeJS.ProcessEnv = {}
  for (const [key, value] of Object.entries(source)) {
    if (!EXECUTION_ENV_KEYS.has(key) || value === undefined || value.includes('\0')) continue
    clean[key] = value.slice(0, 8192)
  }
  return clean
}

function tomlStringMap(source: NodeJS.ProcessEnv): string {
  return `{${Object.entries(safeExecutionOverrides(source))
    .map(([key, value]) => `${JSON.stringify(key)}=${JSON.stringify(value)}`)
    .join(',')}}`
}

export type AppServerThreadConfig = {
  model_reasoning_effort: ManagedCodexReasoningEffort
  default_permissions: typeof CODEX_PERMISSION_PROFILE
  permissions: Record<typeof CODEX_PERMISSION_PROFILE, {
    extends: ':workspace'
    filesystem: PermissionFilesystemConfig
    network: { enabled: false }
  }>
  approval_policy: 'never'
  forced_login_method: 'chatgpt'
  cli_auth_credentials_store: 'file'
  allow_login_shell: false
  web_search: 'disabled'
  shell_environment_policy: {
    inherit: 'none'
    set: NodeJS.ProcessEnv
    experimental_use_profile: false
    ignore_default_excludes: false
  }
}

/**
 * Exact nested config for a manager-owned App Server thread. The persistent
 * server has a scrubbed environment, and each turn receives only this fixed
 * allowlisted tool environment rather than inheriting manager state.
 */
export function buildAppServerThreadConfig(
  workspaceRoot: string,
  readableRoots: readonly string[] = [],
  deniedPaths: readonly string[] = [],
  writableRoots: readonly string[] = [],
  environment: NodeJS.ProcessEnv = {},
  reasoningEffort: ManagedCodexReasoningEffort = DEFAULT_CODEX_REASONING_EFFORT,
): AppServerThreadConfig {
  const root = resolve(workspaceRoot)
  const protectedProjectState = workspaceProtectedReadPaths(root)
  const deniedProjectSecrets = [
    ...workspaceSecretDenyPaths(root),
    `${root}/.swarm-*`,
    ...deniedPaths,
  ]
  return {
    model_reasoning_effort: reasoningEffort,
    default_permissions: CODEX_PERMISSION_PROFILE,
    permissions: {
      [CODEX_PERMISSION_PROFILE]: {
        extends: ':workspace',
        filesystem: buildPermissionFilesystemConfig([
          ...protectedProjectState,
          ...readableRoots,
        ], deniedProjectSecrets, writableRoots),
        network: { enabled: false },
      },
    },
    approval_policy: 'never',
    forced_login_method: 'chatgpt',
    cli_auth_credentials_store: 'file',
    allow_login_shell: false,
    web_search: 'disabled',
    shell_environment_policy: {
      inherit: 'none',
      set: safeExecutionOverrides(environment),
      experimental_use_profile: false,
      ignore_default_excludes: false,
    },
  }
}

export function buildCodexArgs(
  threadId: string | null,
  cfg: CodexConfig,
  readableRoots: readonly string[] = [],
  deniedPaths: readonly string[] = [],
  writableRoots: readonly string[] = [],
  environment: NodeJS.ProcessEnv = {},
): string[] {
  const command = [
    'exec',
    ...(threadId ? ['resume', threadId] : []),
    '--json',
    '--ignore-user-config',
    // Project/user execpolicy allow rules can authorize commands beyond the
    // unattended boundary. The OS permission profile is the only authority.
    '--ignore-rules',
    // Retained intentionally for bounded, in-turn delegation. All delegates
    // remain descendants of this supervised process group; the preamble
    // forbids overlapping edits to the same worktree.
    '--enable', 'multi_agent',
    ...(cfg.disabledFeatures ?? [...DEFAULT_DISABLED_FEATURES])
      .flatMap(feature => ['--disable', feature]),
    '--skip-git-repo-check',
    // Classic workspace-write can still read host credentials. This managed
    // profile denies the host root, restores only the minimal runtime plus the
    // workspace inherited from :workspace, and adds active-turn attachments.
    ...buildPermissionProfileArgs(readableRoots, true, cfg.cwd, deniedPaths, writableRoots),
    '-c', 'approval_policy="never"',
    // Pin the subscription route at the invocation boundary. A prior login
    // status check alone has a status-to-exec race and stored API auth must
    // never become an unapproved metered money path.
    '-c', 'forced_login_method="chatgpt"',
    // Keep subscription tokens in the separately hardened auth.json. macOS
    // may create inert Security.framework backing state even with an empty
    // keychain search list; it is never an authentication fallback.
    '-c', 'cli_auth_credentials_store="file"',
    '-c', 'allow_login_shell=false',
    '-c', 'web_search="disabled"',
    '-c', 'shell_environment_policy.inherit="all"',
    '-c', `shell_environment_policy.set=${tomlStringMap(environment)}`,
    '-c', 'shell_environment_policy.experimental_use_profile=false',
    '-c', 'shell_environment_policy.ignore_default_excludes=false',
    // Classic exec is only an emergency compatibility path. It deliberately
    // cannot call Fable; reviewer-unavailable is safer than bypassing the
    // manager-scoped budget/artifact contract or permitting reviewer recursion.
    '-c', 'mcp_servers={}',
    '-c', `model_reasoning_effort="${cfg.reasoningEffort ?? DEFAULT_CODEX_REASONING_EFFORT}"`,
    '-c', `model="${cfg.model ?? DEFAULT_CODEX_MODEL}"`,
    '-', // prompt on stdin — immune to argv length limits and leading-dash text
  ]
  // `-p` is a root/global flag. `codex exec resume` does not accept it after
  // the subcommand, while `codex -p <name> exec resume ...` works uniformly.
  return [...(cfg.profile ? ['-p', cfg.profile] : []), ...command]
}

const BASE_ENV_ALLOWLIST = new Set([
  'HOME', 'CODEX_HOME', 'PATH', 'TMPDIR', 'TMP', 'TEMP', 'USER', 'LOGNAME',
  'SHELL', 'TERM', 'COLORTERM', 'LANG', 'TZ', 'NO_COLOR', 'SSL_CERT_FILE',
  'SSL_CERT_DIR',
])
const SENSITIVE_ENV_NAME = /(?:^|_)(?:API_?KEY|ACCESS_?KEY(?:_ID)?|PRIVATE_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?|AUTH(?:ORIZATION)?|COOKIE|SESSION|DATABASE_URL|DSN|SSH_AUTH_SOCK)(?:_|$)/i
const PROVIDER_ENV_NAME = /^(?:AWS|AZURE|GCP|GOOGLE|OPENAI|ANTHROPIC|DISCORD|STRIPE|DATABASE|REDIS|POSTGRES|MYSQL|MONGODB|GITHUB|GH)_/i
const DANGEROUS_ENV_NAME = /^(?:BASH_ENV|ENV|ZDOTDIR|SHELLOPTS|PROMPT_COMMAND|LD_PRELOAD|DYLD_INSERT_LIBRARIES|NODE_OPTIONS|PYTHONSTARTUP|RUBYOPT|PERL5OPT|GIT_ASKPASS|SSH_ASKPASS)$/i

/** Remove credentials that an untrusted Discord prompt never needs to see. */
export function sanitizedCodexEnv(
  source: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const clean: NodeJS.ProcessEnv = {}
  const extra = new Set(
    (source.CODEX_BRIDGE_ENV_ALLOWLIST ?? '')
      .split(',')
      .map(name => name.trim())
      .filter(name => /^[A-Za-z_][A-Za-z0-9_]*$/.test(name)),
  )
  for (const [key, value] of Object.entries(source)) {
    if (
      value === undefined
      || key === 'CODEX_BRIDGE_OPERATOR_CANARY_VALUE'
      || SENSITIVE_ENV_NAME.test(key)
      || PROVIDER_ENV_NAME.test(key)
      || DANGEROUS_ENV_NAME.test(key)
    ) continue
    if (!BASE_ENV_ALLOWLIST.has(key) && !key.startsWith('LC_') && !extra.has(key)) continue
    clean[key] = value
  }
  return clean
}

export function isMissingThreadError(error: string | undefined): boolean {
  if (!error) return false
  return (
    /no rollout found for thread id/i.test(error) ||
    /(?:thread|session)(?:\/resume)?.{0,80}(?:not found|does not exist|unknown|invalid)/i.test(error)
  )
}

export function shouldRetryFresh(threadId: string | null, result: CodexTurnResult): boolean {
  return Boolean(threadId && !result.ok && result.errorKind === 'missing-thread')
}

export type RunCodexTurnOptions = {
  signal?: AbortSignal
  /** Absolute, active-turn-only attachment directories exposed read-only. */
  readableRoots?: string[]
  /** Absolute/glob workspace paths denied after all read/write grants. */
  deniedPaths?: string[]
  /** Absolute private per-turn writable directories. */
  writableRoots?: string[]
  /** Fixed non-secret tool environment, also pinned into shell policy. */
  environment?: NodeJS.ProcessEnv
  onChildPid?: (pid: number | null) => void
  onEvent?: (event: CodexEventSummary) => void
}

function positiveLimit(value: number | undefined, fallback: number): number {
  return Number.isFinite(value) && value! > 0 ? Math.floor(value!) : fallback
}

/** Run one Codex turn. Never rejects — errors come back in the result. */
export function runCodexTurn(
  threadId: string | null,
  prompt: string,
  cfg: CodexConfig,
  options: RunCodexTurnOptions = {},
): Promise<CodexTurnResult> {
  return new Promise(resolve => {
    if (!Number.isFinite(cfg.timeoutMs) || cfg.timeoutMs <= 0) {
      resolve({
        ok: false,
        threadId,
        messages: [],
        error: 'invalid codex turn timeout',
        errorKind: 'spawn',
      })
      return
    }
    if (options.signal?.aborted) {
      resolve({ ok: false, threadId, messages: [], error: 'codex turn aborted', errorKind: 'aborted' })
      return
    }

    const args = buildCodexArgs(
      threadId,
      cfg,
      options.readableRoots,
      options.deniedPaths,
      options.writableRoots,
      options.environment,
    )
    let child
    try {
      child = spawn(cfg.bin ?? 'codex', [...(cfg.binArgs ?? []), ...args], {
        cwd: cfg.cwd,
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...sanitizedCodexEnv(), ...safeExecutionOverrides(options.environment) },
        // A dedicated process group lets timeout/shutdown terminate Codex and
        // every shell/tool descendant before the FIFO advances.
        detached: process.platform !== 'win32',
      })
    } catch (err) {
      resolve({ ok: false, threadId, messages: [], error: `spawn failed: ${err}`, errorKind: 'spawn' })
      return
    }

    const maxStdout = positiveLimit(cfg.maxStdoutBytes, 8 * 1024 * 1024)
    const maxStderr = positiveLimit(cfg.maxStderrBytes, 256 * 1024)
    const killGraceMs = positiveLimit(cfg.killGraceMs, 1500)
    const state: ParsedState = { threadId: null, messages: [], completed: false }
    let stdoutPending = ''
    const stdoutDecoder = new StringDecoder('utf8')
    let stdoutBytes = 0
    let stderr = ''
    let stderrBytes = 0
    let settled = false
    let terminalError: { message: string; kind: CodexFailureKind } | null = null
    let forceTimer: ReturnType<typeof setTimeout> | undefined

    const notifyPid = (pid: number | null) => {
      try { options.onChildPid?.(pid) } catch {}
    }

    const signalGroup = (signal: NodeJS.Signals): void => {
      const pid = child.pid
      if (!pid) return
      try {
        if (process.platform !== 'win32') process.kill(-pid, signal)
        else child.kill(signal)
      } catch {
        try { child.kill(signal) } catch {}
      }
    }

    const cancel = (message: string, kind: CodexFailureKind): void => {
      if (!terminalError) terminalError = { message, kind }
      signalGroup('SIGTERM')
      if (!forceTimer) {
        forceTimer = setTimeout(() => signalGroup('SIGKILL'), killGraceMs)
        forceTimer.unref?.()
      }
    }

    const consumeLine = (line: string): void => {
      const trimmed = line.trim()
      if (!trimmed) return
      let ev: unknown
      try { ev = JSON.parse(trimmed) } catch { return }
      const summary = consumeEvent(state, ev)
      if (summary) {
        try { options.onEvent?.(summary) } catch {}
      }
    }

    const consumeChunk = (d: Buffer): void => {
      stdoutBytes += d.byteLength
      if (stdoutBytes > maxStdout) {
        cancel(`codex stdout exceeded ${maxStdout} bytes`, 'output-limit')
        return
      }
      stdoutPending += stdoutDecoder.write(d)
      let newline = stdoutPending.indexOf('\n')
      while (newline >= 0) {
        consumeLine(stdoutPending.slice(0, newline))
        stdoutPending = stdoutPending.slice(newline + 1)
        newline = stdoutPending.indexOf('\n')
      }
      if (Buffer.byteLength(stdoutPending) > maxStdout) {
        cancel(`codex JSON event exceeded ${maxStdout} bytes`, 'output-limit')
      }
    }

    const onAbort = () => cancel('codex turn aborted', 'aborted')
    options.signal?.addEventListener('abort', onAbort, { once: true })
    notifyPid(child.pid ?? null)

    const timer = setTimeout(() => {
      if (settled) return
      cancel(`codex turn timed out after ${Math.round(cfg.timeoutMs / 1000)}s`, 'timeout')
    }, cfg.timeoutMs)
    timer.unref?.()

    child.stdout.on('data', consumeChunk)
    child.stderr.on('data', (d: Buffer) => {
      stderrBytes += d.byteLength
      if (stderrBytes > maxStderr) {
        cancel(`codex stderr exceeded ${maxStderr} bytes`, 'output-limit')
        return
      }
      stderr += d.toString()
      if (stderr.length > 16 * 1024) stderr = stderr.slice(-16 * 1024)
    })
    child.stdin.on('error', err => {
      if (!settled) cancel(`codex stdin error: ${err.message}`, 'spawn')
    })
    child.on('error', err => {
      if (settled) return
      terminalError = { message: `codex spawn error: ${err.message}`, kind: 'spawn' }
    })
    child.on('close', code => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (forceTimer) clearTimeout(forceTimer)
      // Reap any backgrounded tool descendants that outlived the Codex group
      // leader. This also closes the SIGTERM race where Codex exits before an
      // ignoring grandchild and would otherwise cancel the scheduled SIGKILL.
      signalGroup('SIGKILL')
      options.signal?.removeEventListener('abort', onAbort)
      notifyPid(null)
      stdoutPending += stdoutDecoder.end()
      if (stdoutPending) consumeLine(stdoutPending)

      if (terminalError) {
        resolve({
          ok: false,
          threadId: state.threadId ?? threadId,
          messages: state.messages,
          error: terminalError.message,
          errorKind: terminalError.kind,
        })
        return
      }

      const parsed = resultFromState(state)
      if (code !== 0) {
        const tail = stderr.trim().split('\n').slice(-3).join(' | ')
        const prior = parsed.error
        parsed.ok = false
        parsed.error = `codex exited ${code ?? 'without an exit code'}${tail ? `: ${tail}` : ''}${prior ? ` (${prior})` : ''}`
        parsed.errorKind = isMissingThreadError(parsed.error) ? 'missing-thread' : 'exit'
      }
      resolve(parsed)
    })

    try {
      child.stdin.end(prompt)
    } catch (err) {
      cancel(`codex stdin error: ${err instanceof Error ? err.message : err}`, 'spawn')
    }
  })
}

export const MAX_SESSION_ENTRIES = 256
export const MAX_SESSION_FILE_BYTES = 128 * 1024

const SESSION_SCHEMA = 'codex-bridge-sessions/v2'
const LEGACY_SESSION_SCHEMA = 'codex-bridge-sessions/v1'
const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/
export const DEFAULT_SESSION_PROFILE = 'default' as const

export type SessionEntry = { chat_id: string; profile_id: string; thread_id: string }
type SessionFileIdentity = {
  dev: number
  ino: number
  size: number
  mtimeMs: number
  ctimeMs: number
}

export class SessionStoreError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SessionStoreError'
  }
}

function validateSessionId(value: string, field: 'chat_id' | 'profile_id' | 'thread_id'): void {
  if (!SESSION_ID.test(value)) throw new SessionStoreError(`invalid session ${field}`)
}

function sessionIdentity(stat: ReturnType<typeof fstatSync>): SessionFileIdentity {
  return {
    dev: stat.dev,
    ino: stat.ino,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
    ctimeMs: stat.ctimeMs,
  }
}

function sameSessionIdentity(a: SessionFileIdentity | null, b: SessionFileIdentity | null): boolean {
  return a === null
    ? b === null
    : b !== null
      && a.dev === b.dev
      && a.ino === b.ino
      && a.size === b.size
      && a.mtimeMs === b.mtimeMs
      && a.ctimeMs === b.ctimeMs
}

/**
 * (chat_id, profile_id) → Codex thread_id LRU, persisted atomically in the
 * state dir. Omitted profile arguments select the explicit `default` profile.
 *
 * The ordered file is oldest-first. A successful turn calls `set`, moving its
 * chat/profile pair to the newest position; once the hard cap is reached the
 * least recently successful pair is evicted. Unsafe or malformed existing
 * state is refused, never silently replaced.
 */
export class SessionStore {
  private readonly file: string
  private readonly dir: string
  private entries: SessionEntry[] = []
  private identity: SessionFileIdentity | null | undefined
  private tempSerial = 0

  constructor(stateDir: string) {
    this.dir = stateDir
    this.file = join(stateDir, 'sessions.json')
  }

  private currentIdentity(): SessionFileIdentity | null {
    try {
      const stat = lstatSync(this.file)
      const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
      if (
        !stat.isFile()
        || stat.isSymbolicLink()
        || stat.uid !== uid
        || (stat.mode & 0o777) !== 0o600
        || stat.size > MAX_SESSION_FILE_BYTES
      ) throw new SessionStoreError('sessions.json is not a private bounded regular file')
      return sessionIdentity(stat)
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
      if (err instanceof SessionStoreError) throw err
      throw new SessionStoreError(`could not inspect sessions.json: ${err}`)
    }
  }

  private parse(value: unknown): SessionEntry[] {
    let rawEntries: unknown[]
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      const record = value as Record<string, unknown>
      if (record.schema === SESSION_SCHEMA || record.schema === LEGACY_SESSION_SCHEMA) {
        if (!Array.isArray(record.entries)) throw new SessionStoreError('invalid sessions.json entries')
        rawEntries = record.schema === LEGACY_SESSION_SCHEMA
          ? record.entries.map(entry => entry !== null && typeof entry === 'object' && !Array.isArray(entry)
            ? { ...(entry as Record<string, unknown>), profile_id: DEFAULT_SESSION_PROFILE }
            : entry)
          : record.entries
      } else if (!Object.prototype.hasOwnProperty.call(record, 'schema')) {
        // Read the historical object map once so upgrades preserve sessions.
        rawEntries = Object.entries(record).map(([chat_id, thread_id]) => ({
          chat_id, profile_id: DEFAULT_SESSION_PROFILE, thread_id,
        }))
      } else {
        throw new SessionStoreError('unsupported sessions.json schema')
      }
    } else {
      throw new SessionStoreError('invalid sessions.json shape')
    }
    if (rawEntries.length > MAX_SESSION_ENTRIES) {
      throw new SessionStoreError('sessions.json exceeds the entry cap')
    }
    const seen = new Set<string>()
    return rawEntries.map(raw => {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        throw new SessionStoreError('invalid sessions.json entry')
      }
      const record = raw as Record<string, unknown>
      if (typeof record.chat_id !== 'string' || typeof record.profile_id !== 'string'
        || typeof record.thread_id !== 'string') {
        throw new SessionStoreError('invalid sessions.json entry fields')
      }
      validateSessionId(record.chat_id, 'chat_id')
      validateSessionId(record.profile_id, 'profile_id')
      validateSessionId(record.thread_id, 'thread_id')
      const key = `${record.chat_id}\0${record.profile_id}`
      if (seen.has(key)) throw new SessionStoreError('duplicate sessions.json chat/profile pair')
      seen.add(key)
      return {
        chat_id: record.chat_id,
        profile_id: record.profile_id,
        thread_id: record.thread_id,
      }
    })
  }

  private read(): SessionEntry[] {
    const observed = this.currentIdentity()
    if (this.identity !== undefined && sameSessionIdentity(this.identity, observed)) return this.entries
    if (observed === null) {
      this.entries = []
      this.identity = null
      return this.entries
    }

    let fd: number | null = null
    try {
      fd = openSync(this.file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
      const before = fstatSync(fd)
      const uid = typeof process.getuid === 'function' ? process.getuid() : before.uid
      if (
        !before.isFile()
        || before.uid !== uid
        || (before.mode & 0o777) !== 0o600
        || before.size > MAX_SESSION_FILE_BYTES
      ) throw new SessionStoreError('sessions.json changed during validation')
      const bytes = readFileSync(fd)
      const after = fstatSync(fd)
      if (bytes.byteLength > MAX_SESSION_FILE_BYTES || !sameSessionIdentity(sessionIdentity(before), sessionIdentity(after))) {
        throw new SessionStoreError('sessions.json changed while being read')
      }
      let value: unknown
      try { value = JSON.parse(bytes.toString('utf8')) } catch {
        throw new SessionStoreError('sessions.json is malformed JSON')
      }
      const parsed = this.parse(value)
      this.entries = parsed
      this.identity = sessionIdentity(after)
      return this.entries
    } catch (err) {
      if (err instanceof SessionStoreError) throw err
      throw new SessionStoreError(`could not read sessions.json: ${err}`)
    } finally {
      if (fd !== null) try { closeSync(fd) } catch {}
    }
  }

  get(chatId: string, profileId = DEFAULT_SESSION_PROFILE): string | null {
    validateSessionId(chatId, 'chat_id')
    validateSessionId(profileId, 'profile_id')
    return this.read().find(entry => entry.chat_id === chatId && entry.profile_id === profileId)?.thread_id ?? null
  }

  /** Return a bounded defensive copy for manager/facade registration. */
  list(): SessionEntry[] {
    return this.read().map(entry => ({ ...entry }))
  }

  set(chatId: string, threadId: string, profileId = DEFAULT_SESSION_PROFILE): void {
    validateSessionId(chatId, 'chat_id')
    validateSessionId(threadId, 'thread_id')
    validateSessionId(profileId, 'profile_id')
    const entries = this.read().filter(entry => entry.chat_id !== chatId || entry.profile_id !== profileId)
    entries.push({ chat_id: chatId, profile_id: profileId, thread_id: threadId })
    while (entries.length > MAX_SESSION_ENTRIES) entries.shift()
    this.write(entries)
  }

  private write(entries: SessionEntry[]): void {
    const serialized = JSON.stringify({ schema: SESSION_SCHEMA, entries }, null, 2) + '\n'
    if (Buffer.byteLength(serialized) > MAX_SESSION_FILE_BYTES) {
      throw new SessionStoreError('serialized sessions.json exceeds the byte cap')
    }
    mkdirSync(this.dir, { recursive: true, mode: 0o700 })
    const tmp = `${this.file}.tmp-${process.pid}-${this.tempSerial++}`
    try {
      writeFileSync(tmp, serialized, { mode: 0o600, flag: 'wx' })
      chmodSync(tmp, 0o600)
      renameSync(tmp, this.file)
      const identity = this.currentIdentity()
      if (identity === null) throw new SessionStoreError('sessions.json disappeared after write')
      this.entries = entries
      this.identity = identity
    } catch (err) {
      try { rmSync(tmp, { force: true }) } catch {}
      if (err instanceof SessionStoreError) throw err
      throw new SessionStoreError(`could not persist sessions.json: ${err}`)
    }
  }

  /** Drop a mapping — used when a resume fails because the thread is gone. */
  delete(chatId: string, profileId = DEFAULT_SESSION_PROFILE): void {
    validateSessionId(chatId, 'chat_id')
    validateSessionId(profileId, 'profile_id')
    const current = this.read()
    const entries = current.filter(entry => entry.chat_id !== chatId || entry.profile_id !== profileId)
    if (entries.length === current.length) return
    this.write(entries)
  }
}
