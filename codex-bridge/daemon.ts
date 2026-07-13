#!/usr/bin/env bun
/**
 * Discord ↔ Codex bridge daemon.
 *
 * The Claude Code bridge plugin (../bridge) rides Claude's channels capability:
 * an MCP server pushes inbound Discord messages into the live session. Codex
 * CLI has no channels concept, so this is a standalone daemon instead: it owns
 * the Discord gateway connection, applies the SAME access gate as the plugin
 * (pairing / allowlists / channel binding / bot-to-bot mention rules), and
 * drives Codex one turn per message via `codex exec --json` with per-chat
 * session resume. Codex's final agent message is posted back to the chat.
 *
 * Env:
 *   CODEX_BRIDGE_DISCORD_TOKEN_FILE required — exact <state>/discord-token
 *   DISCORD_BOUND_CHANNEL    optional — comma-separated channel ids the bot answers in
 *   DISCORD_STATE_DIR        default ~/.codex/channels/discord
 *   DISCORD_ACCESS_MODE      'static' pins access.json to its boot snapshot
 *   CODEX_BRIDGE_CWD         working dir codex runs in (the agent's repo); default $PWD
 *   CODEX_MODEL              optional model override
 *   CODEX_PROFILE            optional config profile
 *   CODEX_BRIDGE_APP_SERVER_MANAGER_SOCKET opt-in global manager Unix socket
 *   CODEX_TURN_TIMEOUT_MS    default 4500000 (75 min; includes reviewer queue)
 *   CODEX_BIN                default 'codex'
 *   CODEX_BRIDGE_INGRESS_LIMIT max ordered inbound jobs (default 100)
 *   CODEX_BRIDGE_QUEUE_LIMIT max serialized turns, active + waiting (default 25)
 *   SWARM_HARNESS_PARITY_RECEIPT owner-private atomic Claude+Codex receipt; default OFF
 */

import {
  Client,
  GatewayIntentBits,
  Partials,
  ChannelType,
  type Message,
} from 'discord.js'
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
} from 'fs'
import { userInfo } from 'os'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'path'
import { parseBoundChannels } from '../bridge/binding.ts'
import { forwardedContent, safeAttName } from '../bridge/normalize.ts'
import {
  AccessStore,
  gate,
  revalidateDeliveryAuthorization,
  SAFE_STATE_ID,
  type InboundMeta,
} from './gate.ts'
import { MAX_CHUNK_LIMIT } from './chunk.ts'
import {
  CODEX_PERMISSION_PROFILE,
  runCodexTurn,
  SessionStore,
  shouldRetryFresh,
} from './codex.ts'
import {
  AppServerManagerClient,
  AppServerManagerClientError,
  ManagerLivenessMonitor,
  managerClientErrorToCodexResult,
  type ManagerTurnExecution,
} from './app-server-manager-client.ts'
import {
  ATTENTION_RELAY_PREAMBLE,
  buildEnvelope,
  CPO_SILENCE_PREAMBLE,
  GIT_BROKER_PREAMBLE,
  PREAMBLE,
} from './prompt.ts'
import {
  cleanupTurnAttachmentScope,
  cleanupInbox,
  materializeTurnAttachments,
  MAX_ATTACHMENTS_PER_MESSAGE,
  MAX_MESSAGE_ATTACHMENT_BYTES,
  type DownloadableAttachment,
} from './attachments.ts'
import { BoundedSerialQueue } from './queue.ts'
import { RuntimeStateStore } from './runtime.ts'
import { BoundedEventLog } from './events.ts'
import {
  readFableReviewArtifacts,
  snapshotFableReviewArtifactBaseline,
  type FableReviewArtifactBaseline,
} from './review-artifacts.ts'
import { DaemonLock } from './lock.ts'
import { extractAttentionDirective, relaySwarmAttention } from './attention.ts'
import {
  checkWorkspaceSafety,
  DEDICATED_CODEX_PREFLIGHT_TIMEOUT_MS,
  recheckProjectConfig,
  runCodexPreflight,
} from './preflight.ts'
import {
  createToolShims,
  resolveToolchainPlan,
  safeTurnEnvironment,
  type ToolchainPlan,
} from './toolchain.ts'
import {
  assessInboundBudget,
  boundedOutboundChunks,
  buildOutboundPayload,
  buildPairingPayload,
  canAcceptGitControl,
  codexReplyText,
  gatewayRuntimePatch,
  parseTrustedBridgeIdentity,
  parseDaemonRuntimeConfig,
  shouldSuppressSilentFinal,
  trustedChannelRole,
  type TrustedChannelRole,
} from './policy.ts'
import { parseGitControlMessage, runGitBroker, type GitControlCommand } from './git-broker.ts'
import {
  captureWorkspaceSnapshot,
  diffWorkspaceSnapshots,
  type WorkspaceSnapshot,
} from './turn-changes.ts'
import {
  resolveTrustedCodexExecutable,
  resolveTrustedCodexScript,
  readPrivateDiscordTokenFile,
  validatePrivateStateBoundary,
} from './security.ts'
import {
  DEDICATED_RUNNER_KILL_GRACE_MS,
  runDedicatedIsolationPreflight,
  validateDedicatedRuntimeBoundary,
  type DedicatedRuntimePlan,
} from './dedicated-runtime.ts'
import {
  grantBaseRuntimeAccess,
  grantTurnRuntimeAccess,
  revokeBaseRuntimeAccess,
  revokeTurnRuntimeAccess,
  verifyBaseRuntimeAccess,
} from './runtime-acl.ts'
import {
  ParkedTurnStore,
  retryNoticeText,
  RetryNoticeStore,
  type ParkedTurn,
  type RetryNoticeKind,
} from './retry-notices.ts'
import { RepoLease } from './repo-lease.ts'
import {
  DaemonHarnessLifecycle,
  parseDaemonHarnessAdoption,
  type CompletionReviewMaterial,
  type DaemonHarnessAdoption,
} from './daemon-lifecycle.ts'
import { NormalizedEventStore } from '../swarm-harness/event-store.ts'
import { RoadmapStore } from '../swarm-harness/roadmap.ts'
import {
  completionReviewPolicySha256,
  parseCompletionReviewPolicy,
} from '../swarm-harness/completion-review-policy.ts'
import {
  StopDeliveryPipeline,
  StopStateStore,
  type MessageSender,
} from '../swarm-harness/stop-delivery.ts'
import type { FableReviewArtifact } from './review-artifacts.ts'
import {
  completeCodexTaskViaRootBroker,
  type CodexBrokerCompletionResult,
} from './harness-lifecycle-broker-client.ts'

const RAW_STATE_DIR = resolve(
  process.env.DISCORD_STATE_DIR ?? join(userInfo().homedir, '.codex', 'channels', 'discord'),
)
let STATE_DIR: string
try {
  STATE_DIR = validatePrivateStateBoundary(RAW_STATE_DIR)
} catch (err) {
  process.stderr.write(`codex-bridge: unsafe state boundary: ${err}\n`)
  process.exit(1)
}
process.umask(0o077)
const INBOX_DIR = join(STATE_DIR, 'inbox')
const TOOL_TMP_ROOT = join(STATE_DIR, 'tool-tmp')
const TOOL_SHIM_DIR = join(STATE_DIR, 'tool-shims')
const GIT_BROKER_STATE_DIR = join(STATE_DIR, 'git-broker')
const SWARM_NAME = process.env.CODEX_BRIDGE_SWARM_NAME ?? ''
if (
  !/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(SWARM_NAME)
  || STATE_DIR !== join(dirname(STATE_DIR), `discord-${SWARM_NAME}`)
) {
  process.stderr.write('codex-bridge: CODEX_BRIDGE_SWARM_NAME does not match the private state directory\n')
  process.exit(1)
}
const REPO_LEASE_ROOT = join(dirname(STATE_DIR), 'repo-locks')
const APP_SERVER_MANAGER_SOCKET = process.env.CODEX_BRIDGE_APP_SERVER_MANAGER_SOCKET || null
delete process.env.CODEX_BRIDGE_APP_SERVER_MANAGER_SOCKET

let TOKEN: string
try {
  TOKEN = readPrivateDiscordTokenFile(STATE_DIR, process.env.CODEX_BRIDGE_DISCORD_TOKEN_FILE)
  delete process.env.DISCORD_BOT_TOKEN
} catch (err) {
  process.stderr.write(`codex-bridge: private Discord token file required: ${err}\n`)
  process.exit(1)
}

const BOUND_CHANNELS = parseBoundChannels(process.env.DISCORD_BOUND_CHANNEL)
let BRIDGE_IDENTITY: ReturnType<typeof parseTrustedBridgeIdentity>
try {
  BRIDGE_IDENTITY = parseTrustedBridgeIdentity(process.env)
} catch (err) {
  process.stderr.write(`codex-bridge: invalid trusted channel-role binding: ${err}\n`)
  process.exit(1)
}
for (const channel of [BRIDGE_IDENTITY.operatorChannel, BRIDGE_IDENTITY.busChannel]) {
  if (channel && !BOUND_CHANNELS.includes(channel)) {
    process.stderr.write(`codex-bridge: trusted channel-role ${channel} is not in DISCORD_BOUND_CHANNEL\n`)
    process.exit(1)
  }
}
// Optional deployment-specific brief appended to the built-in preamble on the
// first turn of every chat's thread — e.g. swarm doctrine from swarm-up.sh.
const PREAMBLE_EXTRA = process.env.CODEX_BRIDGE_PREAMBLE_EXTRA
const FULL_PREAMBLE = `${PREAMBLE}${PREAMBLE_EXTRA ? `${PREAMBLE_EXTRA}\n\n` : ''}${ATTENTION_RELAY_PREAMBLE}${GIT_BROKER_PREAMBLE}${BRIDGE_IDENTITY.archetype === 'cpo' ? CPO_SILENCE_PREAMBLE : ''}`
const ATTENTION_BINDING = {
  channelId: process.env.CODEX_BRIDGE_ATTENTION_CHANNEL,
  swarmName: process.env.CODEX_BRIDGE_ATTENTION_SWARM,
  stateDir: process.env.CODEX_BRIDGE_ATTENTION_STATE_DIR,
}
const CANONICAL_ACCESS_FILE = process.env.CODEX_BRIDGE_CANONICAL_ACCESS_FILE
const daemonCfg = parseDaemonRuntimeConfig(process.env, process.cwd(), BRIDGE_IDENTITY.archetype)
const codexCfg = daemonCfg.codex
const RUNTIME_SOURCE_ROOT = realpathSync(resolve(import.meta.dir, '..'))
const HARNESS_COMPLETION_POLICY = parseCompletionReviewPolicy(JSON.parse(readFileSync(
  join(RUNTIME_SOURCE_ROOT, 'swarm-harness', 'completion-review-policy.json'),
  'utf8',
)))
let HARNESS_ADOPTION: DaemonHarnessAdoption
try {
  HARNESS_ADOPTION = parseDaemonHarnessAdoption(process.env, {
    expectedSwarm: SWARM_NAME,
    workspaceRoot: codexCfg.cwd,
    expectedCompletionPolicySha256: completionReviewPolicySha256(HARNESS_COMPLETION_POLICY),
  })
} catch (err) {
  process.stderr.write(`codex-bridge: invalid harness lifecycle adoption: ${err}\n`)
  process.exit(1)
}
for (const key of [
  'SWARM_HARNESS_PARITY_RECEIPT',
  'CODEX_BRIDGE_HARNESS_ADOPTION',
  'CODEX_BRIDGE_HARNESS_STATE_DIR',
  'CODEX_BRIDGE_HARNESS_ROADMAP_REPO_ROOT',
  'CODEX_BRIDGE_HARNESS_DR_REFS',
]) delete process.env[key]
// A different swarm may legitimately hold the one host-global App Server for
// its full turn timeout. Admission waiting is therefore independently bounded
// and abortable instead of consuming this turn's own execution budget.
const APP_SERVER_MANAGER_ADMISSION_TIMEOUT_MS = 86_400_000
const REQUESTED_CODEX_BIN = codexCfg.bin ?? 'codex'
const REQUESTED_CODEX_ARGV_PREFIX = codexCfg.binArgs?.[0]
let daemonLock: DaemonLock
try {
  daemonLock = DaemonLock.acquire(STATE_DIR)
} catch (err) {
  process.stderr.write(`codex-bridge: ${err}\n`)
  process.exit(1)
}
let baseRuntimeAclCleanup: (() => void) | null = null
let appServerManager: AppServerManagerClient | null = null
// Once runtime ACLs are live, retain singleton ownership until synchronous
// ACL cleanup has completed. This prevents a successor daemon from racing the
// old process's revocation window.
const releaseDaemonLock = () => {
  if (baseRuntimeAclCleanup === null) daemonLock.release()
}
process.once('exit', () => {
  appServerManager?.close()
  if (baseRuntimeAclCleanup !== null) {
    try { baseRuntimeAclCleanup() } finally { baseRuntimeAclCleanup = null }
  }
  daemonLock.release()
})

const protectedRuntimeRoots = [RUNTIME_SOURCE_ROOT, process.env.SWARM_HOME]
  .filter((value): value is string => Boolean(value))
const workspaceSafety = checkWorkspaceSafety(codexCfg.cwd, protectedRuntimeRoots)
if (!workspaceSafety.ok) {
  process.stderr.write(`codex-bridge: startup preflight failed (${workspaceSafety.errorKind}): ${workspaceSafety.detail}\n`)
  releaseDaemonLock()
  process.exit(1)
}
// Use one canonical identity for sandbox policy, scans, tool roots, and Git.
codexCfg.cwd = workspaceSafety.cwd
let toolchainPlan: ToolchainPlan
try {
  toolchainPlan = resolveToolchainPlan(
    codexCfg.cwd,
    process.env,
    ['git', 'python3', 'bun'],
    userInfo().homedir,
    true,
  )
} catch (err) {
  process.stderr.write(`codex-bridge: startup preflight failed (toolchain): ${err}\n`)
  releaseDaemonLock()
  process.exit(1)
}
let toolShimDir: string
try {
  toolShimDir = createToolShims(TOOL_SHIM_DIR, toolchainPlan)
} catch (err) {
  process.stderr.write(`codex-bridge: startup preflight failed (tool-shims): ${err}\n`)
  releaseDaemonLock()
  process.exit(1)
}
let startupRepoLease: RepoLease | null = null
try {
  startupRepoLease = await RepoLease.acquire({
    root: REPO_LEASE_ROOT,
    cwd: codexCfg.cwd,
    stateDir: STATE_DIR,
    swarmName: SWARM_NAME,
    operation: 'startup',
    waitMs: codexCfg.timeoutMs,
  })
} catch (err) {
  process.stderr.write(`codex-bridge: startup preflight failed (repo-lease): ${err}\n`)
  releaseDaemonLock()
  process.exit(1)
}
const releaseStartupRepoLease = (): boolean => {
  if (!startupRepoLease) return true
  const released = startupRepoLease.release()
  startupRepoLease = null
  return released
}
let dedicatedRuntime: DedicatedRuntimePlan
try {
  const trustedNode = resolveTrustedCodexExecutable(REQUESTED_CODEX_BIN, {
    workspaceRoot: codexCfg.cwd,
    stateDir: STATE_DIR,
    sourceEnv: process.env,
  })
  if (!REQUESTED_CODEX_ARGV_PREFIX) {
    throw new Error('dedicated runtime requires an exact CODEX_BRIDGE_CODEX_ARGV_PREFIX script')
  }
  const trustedScript = resolveTrustedCodexScript(REQUESTED_CODEX_ARGV_PREFIX, {
    workspaceRoot: codexCfg.cwd,
    stateDir: STATE_DIR,
    sourceEnv: process.env,
  })
  dedicatedRuntime = validateDedicatedRuntimeBoundary({
    workspaceRoot: codexCfg.cwd,
    stateDir: STATE_DIR,
    trustedNodePath: trustedNode,
    trustedCodexScript: trustedScript,
    readableRoots: toolchainPlan.readableRoots,
  })
  codexCfg.bin = dedicatedRuntime.sudoPath
  codexCfg.binArgs = dedicatedRuntime.sudoArgvPrefix
  codexCfg.killGraceMs = DEDICATED_RUNNER_KILL_GRACE_MS
} catch (err) {
  process.stderr.write(`codex-bridge: startup preflight failed (dedicated-runtime): ${err}\n`)
  releaseStartupRepoLease()
  releaseDaemonLock()
  process.exit(1)
}
const operatorCanaryWitness = process.env.CODEX_BRIDGE_OPERATOR_CANARY_VALUE
delete process.env.CODEX_BRIDGE_OPERATOR_CANARY_VALUE
const codexHostEnvironment = (): NodeJS.ProcessEnv => ({
  ...process.env,
  ...safeTurnEnvironment(dedicatedRuntime.runtimeTemp, toolchainPlan),
  HOME: dedicatedRuntime.runtimeHome,
  CODEX_HOME: dedicatedRuntime.codexHome,
})
const turnEnvironment = (tempDir: string): NodeJS.ProcessEnv => ({
  ...safeTurnEnvironment(tempDir, toolchainPlan, toolShimDir),
  HOME: dedicatedRuntime.runtimeHome,
  CODEX_HOME: dedicatedRuntime.codexHome,
})
// The attested runner starts a fresh hidden-user bootstrap context for each
// exact CLI proof. The shared bound covers both startup and per-turn auth.
if (APP_SERVER_MANAGER_SOCKET) {
  try {
    appServerManager = new AppServerManagerClient({ socketPath: APP_SERVER_MANAGER_SOCKET })
  } catch (err) {
    process.stderr.write(`codex-bridge: startup preflight failed (app-server-manager): ${err}\n`)
    appServerManager?.close()
    appServerManager = null
    releaseStartupRepoLease()
    releaseDaemonLock()
    process.exit(1)
  }
} else {
  const isolation = runDedicatedIsolationPreflight(
    dedicatedRuntime,
    codexCfg.cwd,
    toolchainPlan.readableRoots,
    workspaceSafety.deniedPaths,
    codexHostEnvironment(),
    toolchainPlan.executables,
    operatorCanaryWitness,
  )
  if (!isolation.ok) {
    process.stderr.write(`codex-bridge: startup preflight failed (dedicated-isolation): ${isolation.detail}\n`)
    releaseStartupRepoLease()
    releaseDaemonLock()
    process.exit(1)
  }
  const preflight = runCodexPreflight(
    codexCfg.bin!,
    codexHostEnvironment(),
    DEDICATED_CODEX_PREFLIGHT_TIMEOUT_MS,
    codexCfg.binArgs,
  )
  if (!preflight.ok) {
    process.stderr.write(`codex-bridge: startup preflight failed (${preflight.errorKind}): ${preflight.detail}\n`)
    releaseStartupRepoLease()
    releaseDaemonLock()
    process.exit(1)
  }
}
if (!releaseStartupRepoLease()) {
  process.stderr.write('codex-bridge: startup repository lease ownership changed before release\n')
  releaseDaemonLock()
  process.exit(1)
}

const store = new AccessStore(STATE_DIR, process.env.DISCORD_ACCESS_MODE === 'static')
const sessions = new SessionStore(STATE_DIR)
const retryNotices = new RetryNoticeStore(STATE_DIR)
const parkedTurns = new ParkedTurnStore(STATE_DIR)
try {
  retryNotices.list()
  parkedTurns.list()
} catch (err) {
  process.stderr.write(`codex-bridge: unsafe durable retry ledger: ${err}\n`)
  releaseDaemonLock()
  process.exit(1)
}
let shuttingDown = false
let runtimeWriteFailed = false
cleanupInbox(INBOX_DIR)
mkdirSync(INBOX_DIR, { recursive: true, mode: 0o700 })
try { chmodSync(INBOX_DIR, 0o700) } catch {}
try { rmSync(TOOL_TMP_ROOT, { recursive: true, force: true }) } catch {}
mkdirSync(TOOL_TMP_ROOT, { recursive: true, mode: 0o700 })
try { chmodSync(TOOL_TMP_ROOT, 0o700) } catch {}
try {
  grantBaseRuntimeAccess(
    dedicatedRuntime.runtimeUser,
    userInfo().homedir,
    STATE_DIR,
    INBOX_DIR,
    TOOL_TMP_ROOT,
    TOOL_SHIM_DIR,
  )
} catch (err) {
  process.stderr.write(`codex-bridge: startup preflight failed (runtime-acl): ${err}\n`)
  releaseDaemonLock()
  process.exit(1)
}
baseRuntimeAclCleanup = () => {
  try {
    revokeBaseRuntimeAccess(
      dedicatedRuntime.runtimeUser,
      userInfo().homedir,
      STATE_DIR,
      INBOX_DIR,
      TOOL_TMP_ROOT,
      TOOL_SHIM_DIR,
    )
  } catch (err) {
    process.stderr.write(`codex-bridge: dedicated runtime ACL cleanup incomplete: ${err}\n`)
  }
}
let runtime: RuntimeStateStore
let eventLog: BoundedEventLog
let managerActiveProfile: string | null = null
let managerPool = 'default'
let managerPoolParked = false
let managerParkedUntilMs: number | null = null
try {
  let managerFacadeEndpoint: string | null = null
  if (appServerManager) {
    const registration = await appServerManager.register({
      swarm: SWARM_NAME,
      repo: codexCfg.cwd,
      stateDir: STATE_DIR,
      model: codexCfg.model ?? null,
      reasoningEffort: codexCfg.reasoningEffort ?? null,
      profile: codexCfg.profile ?? null,
    }, {
      timeoutMs: APP_SERVER_MANAGER_ADMISSION_TIMEOUT_MS,
    })
    managerFacadeEndpoint = registration.facadeEndpoint
    managerActiveProfile = registration.activeProfile
    managerPool = registration.pool
    managerPoolParked = registration.activeProfile === null
    managerParkedUntilMs = managerPoolParked
      ? registration.parkedUntilMs ?? Date.now() + 5 * 60_000
      : null
  }
  runtime = managerFacadeEndpoint
    ? new RuntimeStateStore(STATE_DIR, { appServerEndpoint: managerFacadeEndpoint })
    : new RuntimeStateStore(STATE_DIR)
  eventLog = new BoundedEventLog(STATE_DIR)
} catch (err) {
  process.stderr.write(`codex-bridge: startup manager/runtime registration failed: ${err}\n`)
  if (appServerManager?.isRegistered) {
    try { await appServerManager.unregister() } catch {}
  }
  appServerManager?.close()
  appServerManager = null
  releaseDaemonLock()
  process.exit(1)
}
eventLog.emit('daemon.started', {
  pid: process.pid,
  backend: appServerManager ? 'app-server' : 'exec',
})

// ADR-0023 remains implemented/tested-not-live.  Enabling this only on Codex
// would create the silent parity split that the ADR forbids, so adoption must
// carry the exact shared Claude+Codex contract plus private state/repo paths.
let harnessLifecycle: DaemonHarnessLifecycle | null = null
let harnessStopState: StopStateStore | null = null
try {
  const adoption = HARNESS_ADOPTION
  if (adoption.enabled) {
    const state = lstatSync(adoption.stateRoot)
    const uid = process.getuid?.()
    if (!state.isDirectory() || state.isSymbolicLink() || realpathSync(adoption.stateRoot) !== adoption.stateRoot
      || uid === undefined || state.uid !== uid || (state.mode & 0o777) !== 0o700) {
      throw new Error('harness state root must be an owner-real mode 0700 directory')
    }
    const stateRelativeToWorkspace = relative(realpathSync(codexCfg.cwd), adoption.stateRoot)
    if (stateRelativeToWorkspace === '' || (
      stateRelativeToWorkspace !== '..'
      && !stateRelativeToWorkspace.startsWith(`..${sep}`)
      && !isAbsolute(stateRelativeToWorkspace)
    )) {
      throw new Error('harness state root must be outside the worker workspace')
    }
    const eventsDir = join(adoption.stateRoot, 'events')
    const roadmapStateDir = join(adoption.stateRoot, 'roadmap')
    for (const directory of [eventsDir, roadmapStateDir]) {
      try {
        mkdirSync(directory, { mode: 0o700 })
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      }
      const info = lstatSync(directory)
      if (!info.isDirectory() || info.isSymbolicLink() || realpathSync(directory) !== directory
        || info.uid !== uid || (info.mode & 0o777) !== 0o700) {
        throw new Error('harness child state must be an owner-real mode 0700 directory')
      }
    }
    const normalizedEvents = new NormalizedEventStore(eventsDir, {
      repoRoot: adoption.roadmapRepoRoot,
    })
    const roadmap = new RoadmapStore(
      adoption.roadmapRepoRoot,
      join(roadmapStateDir, 'authority.json'),
    )
    harnessStopState = new StopStateStore(join(adoption.stateRoot, 'stops'))
    harnessLifecycle = new DaemonHarnessLifecycle({
      eventStore: normalizedEvents,
      roadmapStore: roadmap,
      policy: HARNESS_COMPLETION_POLICY,
      repoRoot: codexCfg.cwd,
      swarm: SWARM_NAME,
      drRefs: adoption.drRefs,
    })
    eventLog.emit('harness.lifecycle', { status: 'adopted-parity-v1' })
  } else {
    eventLog.emit('harness.lifecycle', { status: 'draft-disabled' })
  }
} catch (err) {
  process.stderr.write(`codex-bridge: harness lifecycle adoption failed: ${err}\n`)
  eventLog.emit('daemon.error', { error_kind: 'harness-lifecycle-adoption' })
  if (appServerManager?.isRegistered) {
    try { await appServerManager.unregister() } catch {}
  }
  appServerManager?.close()
  appServerManager = null
  releaseDaemonLock()
  process.exit(1)
}

function updateRuntime(patch: Parameters<RuntimeStateStore['update']>[0]): void {
  try {
    runtime.update(patch)
  } catch (err) {
    process.stderr.write(`codex-bridge: runtime state write failed: ${err}\n`)
    eventLog.emit('daemon.error', { error_kind: 'runtime-state-write' })
    if (!runtimeWriteFailed) {
      runtimeWriteFailed = true
      setTimeout(() => { void shutdown(1) }, 0)
    }
  }
}

process.on('unhandledRejection', err => {
  process.stderr.write(`codex-bridge: unhandled rejection: ${err}\n`)
  updateRuntime({ last_error: 'process:unhandled-rejection' })
  eventLog.emit('daemon.error', { error_kind: 'unhandled-rejection' })
  void shutdown(1)
})
process.on('uncaughtException', err => {
  process.stderr.write(`codex-bridge: uncaught exception: ${err}\n`)
  updateRuntime({ last_error: 'process:uncaught-exception' })
  eventLog.emit('daemon.error', { error_kind: 'uncaught-exception' })
  void shutdown(1)
})

const client = new Client({
  intents: [
    GatewayIntentBits.DirectMessages,
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
  // DMs arrive as partial channels — messageCreate never fires without this.
  partials: [Partials.Channel],
})

// Track message IDs we recently sent, so reply-to-bot in guild channels
// counts as a mention without needing fetchReference().
const recentSentIds = new Set<string>()
const RECENT_SENT_CAP = 200
function noteSent(id: string): void {
  recentSentIds.add(id)
  if (recentSentIds.size > RECENT_SENT_CAP) {
    const first = recentSentIds.values().next().value
    if (first) recentSentIds.delete(first)
  }
}

/** Discord.js transport adapter used by the shared stop pipeline. */
function lifecycleSenderFor(msg: Message): MessageSender {
  return {
    async send(channelId: string, text: string) {
      const channel: any = channelId === msg.channelId
        ? msg.channel
        : await client.channels.fetch(channelId)
      if (!channel?.isTextBased?.() || typeof channel.send !== 'function') {
        throw new Error('lifecycle Discord channel is unavailable or not text based')
      }
      const sent = await channel.send(buildOutboundPayload(
        text,
        channelId === msg.channelId ? msg.id : undefined,
      ))
      if (!sent || typeof sent.id !== 'string' || !sent.id) {
        throw new Error('lifecycle Discord send returned no receipt')
      }
      noteSent(sent.id)
      return { messageId: sent.id }
    },
  }
}

/**
 * A non-terminal gate/failure notice is not a Stop event, but its transport
 * still cannot disappear silently.  Retry it and require a Discord receipt;
 * unlike an accepted Stop it never changes the task to stopped.
 */
async function sendVerifiedLifecycleNotice(
  msg: Message,
  text: string,
  reason: string,
): Promise<void> {
  const sender = lifecycleSenderFor(msg)
  let lastError: unknown = null
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const receipt = await sender.send(msg.channelId, text)
      eventLog.emit('harness.notice_delivered', {
        chat_id: msg.channelId,
        message_id: msg.id,
        reason,
        attempt,
        status: receipt.messageId ? 'delivered' : 'invalid-receipt',
      })
      return
    } catch (error) {
      lastError = error
      if (attempt < 3) await Bun.sleep(attempt === 1 ? 250 : 1_000)
    }
  }
  process.stderr.write(`codex-bridge: verified lifecycle notice failed (${reason}): ${lastError}\n`)
  eventLog.emit('harness.notice_error', {
    chat_id: msg.channelId,
    message_id: msg.id,
    reason,
    error_kind: 'discord-send',
  })
  throw lastError instanceof Error ? lastError : new Error(String(lastError))
}

type ShutdownDropKind = RetryNoticeKind

function gateChannelIdFor(msg: Message): string {
  return msg.channel.isThread() ? msg.channel.parentId ?? msg.channelId : msg.channelId
}

function retryAuthorizationMetadata(msg: Message) {
  return {
    senderId: msg.author.id,
    gateChannelId: gateChannelIdFor(msg),
    isDM: msg.channel.type === ChannelType.DM,
  }
}

async function notifyShutdownDrop(msg: Message, kind: ShutdownDropKind): Promise<void> {
  try { retryNotices.register(msg.channelId, msg.id, kind, retryAuthorizationMetadata(msg)) } catch (err) {
    process.stderr.write(`codex-bridge: could not persist shutdown retry notice: ${err}\n`)
  }
  eventLog.emit(`${kind}.dropped`, {
    chat_id: msg.channelId,
    message_id: msg.id,
    error_kind: 'shutdown',
  })
  try {
    const sent = await (msg.channel as any).send(buildOutboundPayload(
      retryNoticeText(kind),
      msg.id,
    ))
    if (typeof sent?.id === 'string') noteSent(sent.id)
    retryNotices.remove(msg.id)
  } catch (err) {
    process.stderr.write(`codex-bridge: failed to send shutdown retry notice: ${err}\n`)
    eventLog.emit(`${kind}.drop_notice_error`, {
      chat_id: msg.channelId,
      message_id: msg.id,
      error_kind: 'discord-send',
    })
  }
}

async function reauthorizeQueuedMessage(
  msg: Message,
  gateChannelId: string,
  kind: 'turn' | 'git',
  requireTopLevelOperator = false,
): Promise<boolean> {
  const authorization = await revalidateDeliveryAuthorization({
    senderId: msg.author.id,
    isDM: msg.channel.type === ChannelType.DM,
    gateChannelId,
    isMentioned: () => isMentioned(msg, store.load().mentionPatterns),
  }, {
    store,
    boundChannels: BOUND_CHANNELS,
    canonicalAccessFile: CANONICAL_ACCESS_FILE,
  })
  const operatorStillAuthorized = !requireTopLevelOperator || (
    authorization.ok
    && authorization.access.allowFrom.includes(msg.author.id)
    && (!CANONICAL_ACCESS_FILE || authorization.canonicalAccess?.allowFrom.includes(msg.author.id) === true)
  )
  if (authorization.ok && operatorStillAuthorized) return true

  eventLog.emit(`${kind}.revoked`, {
    chat_id: msg.channelId,
    message_id: msg.id,
    error_kind: 'authorization-revoked',
  })
  try {
    const sent = await (msg.channel as any).send(buildOutboundPayload(
      '⚠️ Authorization changed while this message was queued; it was not executed.',
      msg.id,
    ))
    if (typeof sent?.id === 'string') noteSent(sent.id)
  } catch {}
  try { retryNotices.remove(msg.id) } catch {}
  return false
}

async function replayRetryNotices(): Promise<void> {
  let entries
  try { entries = retryNotices.list() } catch (err) {
    process.stderr.write(`codex-bridge: could not replay retry notices: ${err}\n`)
    return
  }
  for (const entry of entries) {
    if (shuttingDown) return
    try {
      const authorization = await revalidateDeliveryAuthorization({
        senderId: entry.sender_id,
        isDM: entry.is_dm,
        gateChannelId: entry.gate_channel_id,
        // The original inbound mention was already authorized; replay is a
        // metadata-only failure notice, not a new workspace-writing turn.
        isMentioned: async () => true,
      }, {
        store,
        boundChannels: BOUND_CHANNELS,
        canonicalAccessFile: CANONICAL_ACCESS_FILE,
      })
      const operatorStillAuthorized = (entry.kind !== 'git' && entry.kind !== 'active-git') || (
        authorization.ok
        && authorization.access.allowFrom.includes(entry.sender_id)
        && (!CANONICAL_ACCESS_FILE
          || authorization.canonicalAccess?.allowFrom.includes(entry.sender_id) === true)
      )
      if (!authorization.ok || !operatorStillAuthorized) {
        retryNotices.remove(entry.message_id)
        eventLog.emit(`${entry.kind}.retry_revoked`, {
          chat_id: entry.channel_id,
          message_id: entry.message_id,
          error_kind: 'authorization-revoked',
        })
        continue
      }
      const channel = await client.channels.fetch(entry.channel_id)
      if (!channel?.isTextBased() || !('send' in channel)) throw new Error('retry channel unavailable')
      const sent = await channel.send(buildOutboundPayload(
        retryNoticeText(entry.kind),
        entry.message_id,
      ))
      if (typeof sent?.id === 'string') noteSent(sent.id)
      retryNotices.remove(entry.message_id)
      eventLog.emit(`${entry.kind}.retry_replayed`, {
        chat_id: entry.channel_id,
        message_id: entry.message_id,
        error_kind: 'prior-shutdown',
      })
    } catch (err) {
      process.stderr.write(`codex-bridge: retry notice remains pending: ${err}\n`)
      const timer = setTimeout(() => { void scheduleRetryReplay() }, 30_000)
      timer.unref?.()
      return // preserve FIFO and avoid hammering Discord during an outage
    }
  }
}

let retryReplayPromise: Promise<void> | null = null
function scheduleRetryReplay(): Promise<void> {
  if (!retryReplayPromise) {
    retryReplayPromise = replayRetryNotices().finally(() => { retryReplayPromise = null })
  }
  return retryReplayPromise
}

const parkedReplayTimers = new Map<string, ReturnType<typeof setTimeout>>()
const parkedReplayInFlight = new Set<string>()
const parkedReplayAccepted = new Set<string>()
let startupParkAnnouncementSent = false

function poolParkNotice(retryAtMs: number): string {
  return `⏸️ Codex profile pool ${managerPool} is exhausted; this swarm is parked until ${new Date(retryAtMs).toISOString()}.`
}

async function announcePoolParked(retryAtMs: number, msg?: Message): Promise<void> {
  const payload = buildOutboundPayload(poolParkNotice(retryAtMs), msg?.id)
  if (msg) {
    try {
      const sent = await (msg.channel as any).send(payload)
      if (typeof sent?.id === 'string') noteSent(sent.id)
    } catch {}
    return
  }
  if (startupParkAnnouncementSent) return
  startupParkAnnouncementSent = true
  for (const channelId of BOUND_CHANNELS) {
    try {
      const channel = await client.channels.fetch(channelId)
      if (!channel?.isTextBased() || !('send' in channel)) continue
      const sent = await channel.send(payload)
      if (typeof sent?.id === 'string') noteSent(sent.id)
    } catch {}
  }
}

function persistParkedTurn(msg: Message, retryAtMs: number, rotationAttempt: number): boolean {
  try {
    parkedTurns.register(
      msg.channelId,
      msg.id,
      retryAuthorizationMetadata(msg),
      retryAtMs,
      rotationAttempt,
    )
    // This task has a known replay boundary, not an uncertain shutdown
    // outcome. Avoid replaying a warning alongside the real task after boot.
    try { retryNotices.remove(msg.id) } catch {}
    return true
  } catch (err) {
    process.stderr.write(`codex-bridge: could not persist parked task: ${err}\n`)
    eventLog.emit('turn.error', {
      chat_id: msg.channelId,
      message_id: msg.id,
      error_kind: 'parked-retry-ledger',
    })
    return false
  }
}

function scheduleParkedTurn(entry: ParkedTurn): void {
  if (shuttingDown || parkedReplayTimers.has(entry.message_id)
    || parkedReplayInFlight.has(entry.message_id)) return
  const delay = Math.max(1_000, Math.min(entry.retry_at_ms - Date.now(), 2_147_000_000))
  const timer = setTimeout(() => {
    parkedReplayTimers.delete(entry.message_id)
    void replayParkedTurn(entry.message_id)
  }, delay)
  timer.unref?.()
  parkedReplayTimers.set(entry.message_id, timer)
}

function scheduleParkedTurnReplays(): void {
  let entries: ParkedTurn[]
  try { entries = parkedTurns.list() } catch (err) {
    process.stderr.write(`codex-bridge: could not schedule parked tasks: ${err}\n`)
    return
  }
  for (const entry of entries) scheduleParkedTurn(entry)
}

async function replayParkedTurn(messageId: string): Promise<void> {
  if (shuttingDown || parkedReplayInFlight.has(messageId)) return
  const entry = parkedTurns.list().find(candidate => candidate.message_id === messageId)
  if (!entry) return
  if (entry.retry_at_ms > Date.now()) {
    scheduleParkedTurn(entry)
    return
  }
  parkedReplayInFlight.add(messageId)
  try {
    const authorization = await revalidateDeliveryAuthorization({
      senderId: entry.sender_id,
      isDM: entry.is_dm,
      gateChannelId: entry.gate_channel_id,
      isMentioned: async () => true,
    }, {
      store,
      boundChannels: BOUND_CHANNELS,
      canonicalAccessFile: CANONICAL_ACCESS_FILE,
    })
    if (!authorization.ok) {
      parkedTurns.remove(messageId)
      eventLog.emit('turn.retry_revoked', {
        chat_id: entry.channel_id,
        message_id: messageId,
        error_kind: 'authorization-revoked',
      })
      return
    }
    const channel = await client.channels.fetch(entry.channel_id)
    if (!channel?.isTextBased() || !('messages' in channel)) throw new Error('retry channel unavailable')
    const msg = await (channel as any).messages.fetch(messageId) as Message
    if (msg.author.id !== entry.sender_id || msg.channelId !== entry.channel_id) {
      throw new Error('refetched parked task identity changed')
    }
    const accepted = inboundQueue.tryEnqueue(async () => {
      try {
        await handleInbound(msg, entry.rotation_attempt, true)
      } finally {
        const turnAccepted = parkedReplayAccepted.delete(messageId)
        parkedReplayInFlight.delete(messageId)
        if (!turnAccepted) {
          const current = parkedTurns.list().find(candidate => candidate.message_id === messageId)
          if (current) scheduleParkedTurn({ ...current, retry_at_ms: Date.now() + 30_000 })
        }
      }
    })
    if (!accepted) throw new Error('inbound retry queue is full')
    return
  } catch (err) {
    process.stderr.write(`codex-bridge: parked task remains pending: ${err}\n`)
  }
  parkedReplayInFlight.delete(messageId)
  const current = parkedTurns.list().find(candidate => candidate.message_id === messageId)
  if (current) scheduleParkedTurn({ ...current, retry_at_ms: Date.now() + 30_000 })
}

async function isMentioned(msg: Message, extraPatterns?: string[]): Promise<boolean> {
  if (client.user && msg.mentions.has(client.user)) return true
  const refId = msg.reference?.messageId
  if (refId) {
    if (recentSentIds.has(refId)) return true
    try {
      const ref = await msg.fetchReference()
      if (ref.author.id === client.user?.id) return true
    } catch {}
  }
  for (const pat of extraPatterns ?? []) {
    try {
      if (new RegExp(pat, 'i').test(msg.content)) return true
    } catch {}
  }
  return false
}

// The access CLI drops approved/<senderId> files when pairing someone —
// same protocol as the Claude bridge. Poll, confirm on Discord, clean up.
function checkApprovals(): void {
  let files: string[]
  try {
    files = readdirSync(store.approvedDir)
  } catch {
    return
  }
  for (const senderId of files) {
    const file = join(store.approvedDir, senderId)
    let dmChannelId = ''
    try {
      const stat = lstatSync(file)
      const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
      if (
        !SAFE_STATE_ID.test(senderId)
        || !stat.isFile()
        || stat.isSymbolicLink()
        || stat.uid !== uid
        || (stat.mode & 0o777) !== 0o600
        || stat.size < 1
        || stat.size > 256
      ) throw new Error('unsafe approval marker')
      dmChannelId = readFileSync(file, 'utf8').trim()
    } catch {}
    if (!SAFE_STATE_ID.test(dmChannelId)) {
      rmSync(file, { recursive: true, force: true })
      continue
    }
    void (async () => {
      try {
        const ch = await client.channels.fetch(dmChannelId)
        if (ch?.isTextBased() && 'send' in ch) {
          await ch.send(buildOutboundPayload('Paired! Say hi to Codex.'))
        }
      } catch (err) {
        process.stderr.write(`codex-bridge: failed to send approval confirm: ${err}\n`)
      } finally {
        rmSync(file, { force: true }) // don't loop on a broken send
      }
    })()
  }
}
if (process.env.DISCORD_ACCESS_MODE !== 'static') setInterval(checkApprovals, 5000).unref()

// Best-effort name of a forwarded message's source channel (see bridge/server.ts).
async function resolveForwardChannel(msg: Message): Promise<string | undefined> {
  const id = msg.reference?.channelId
  if (!id) return undefined
  const cached = client.channels.cache.get(id)
  if (cached && 'name' in cached && typeof cached.name === 'string') return cached.name
  try {
    const ch = await client.channels.fetch(id)
    if (ch && 'name' in ch && typeof ch.name === 'string') return ch.name
  } catch {}
  return undefined
}

function boundedRootLifecycleSummary(value: string): string {
  const clean = value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ' ')
  const bytes = Buffer.from(clean, 'utf8')
  if (bytes.byteLength <= 16 * 1024) return clean || 'Codex completed without a summary.'
  // Decode only a complete UTF-8 prefix. TextDecoder replaces at most the
  // truncated final code point; trim it so the broker sees stable bounded data.
  return bytes.subarray(0, 16 * 1024 - 64).toString('utf8').replace(/\uFFFD$/, '')
    + '\n\n[summary truncated by codex-bridge]'
}

// ---- turn queue -----------------------------------------------------------
// Codex turns run in the agent's repo with write access — never run two at
// once. Inbound preprocessing has its own FIFO so a later fast message cannot
// overtake an earlier message whose attachment/reference fetch is slower.
let activeTurnAbort: AbortController | null = null

type LatestTurnCapability = {
  chatId: string
  messageId: string
  changes: Readonly<Record<string, string | null>>
}
let latestTurnCapability: LatestTurnCapability | null = null

let inboundQueue: BoundedSerialQueue
let turnQueue: BoundedSerialQueue

function updateQueueState(): void {
  const inbound = inboundQueue.snapshot
  const turns = turnQueue.snapshot
  const waiting = inbound.waiting + turns.waiting
  updateRuntime({
    active: inbound.active || turns.active,
    queue_depth: waiting,
  })
  eventLog.emit('queue.changed', {
    waiting,
    active: inbound.active || turns.active,
  })
}

inboundQueue = new BoundedSerialQueue(
  daemonCfg.ingressLimit,
  updateQueueState,
  err => process.stderr.write(`codex-bridge: inbound job failed: ${err}\n`),
)
turnQueue = new BoundedSerialQueue(
  daemonCfg.turnLimit,
  updateQueueState,
  err => process.stderr.write(`codex-bridge: turn job failed: ${err}\n`),
)

async function runTurn(
  msg: Message,
  content: string,
  attachments: readonly DownloadableAttachment[],
  atts: string[],
  channelRole: TrustedChannelRole,
  rotationAttempt = 0,
) {
  const chatId = msg.channelId
  const abort = new AbortController()
  activeTurnAbort = abort
  let typing: ReturnType<typeof setInterval> | undefined
  const attachmentPaths: string[] = []
  let beforeSnapshot: WorkspaceSnapshot | null = null
  let turnSucceeded = false
  let turnAclActive = false
  let repoLease: RepoLease | null = null
  let managerExecution: ManagerTurnExecution | null = null
  let managerCleanupResult: Awaited<ReturnType<AppServerManagerClient['cleanupComplete']>> | null = null
  let managerReservationHeld = false
  let managerCleanupOk = true
  let managerTurnUncertain = false
  let retainRetryNotice = false
  let turnProfile = managerActiveProfile ?? 'default'
  let reviewArtifactBaseline: FableReviewArtifactBaseline | undefined
  let reviewArtifactBaselineRefused = false
  let harnessTaskStarted = false
  let harnessTaskFinished = false
  let harnessActivityFailure: unknown = null
  let completionReviewMaterial: CompletionReviewMaterial | null = null
  let completionReviewMaterialFailure: unknown = null
  let completionReviewToken: string | null = null
  let completionReviewVerdict: 'approve' | 'needs-changes' | 'block' | 'review-unavailable' | null = null
  let rootBrokerCompletion: CodexBrokerCompletionResult | null = null
  let terminalSummaryForBroker: string | null = null
  let currentReviewArtifacts: FableReviewArtifact[] = []
  latestTurnCapability = null
  const safeMessageId = msg.id.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64) || 'message'
  const turnInboxDir = join(INBOX_DIR, safeMessageId)
  const turnTempDir = join(TOOL_TMP_ROOT, safeMessageId)
  let finalizationPromise: Promise<void> | null = null

  const finalizeTurnBoundary = async (): Promise<void> => {
    if (!finalizationPromise) {
      finalizationPromise = (async () => {
        if (typing) {
          clearInterval(typing)
          typing = undefined
        }
        if (turnAclActive) {
          try {
            revokeTurnRuntimeAccess(
              dedicatedRuntime.runtimeUser,
              turnTempDir,
              attachmentPaths.length > 0 ? turnInboxDir : null,
              attachmentPaths,
            )
            turnAclActive = false
          } catch (err) {
            if (managerExecution || managerReservationHeld) managerCleanupOk = false
            process.stderr.write(`codex-bridge: active-turn ACL cleanup incomplete: ${err}\n`)
            updateRuntime({ last_error: 'runtime-acl:turn-cleanup' })
            eventLog.emit('daemon.error', { error_kind: 'runtime-acl-turn-cleanup' })
            if (!shuttingDown) void shutdown(1)
          }
        }
        try { cleanupTurnAttachmentScope(turnInboxDir, attachmentPaths) } catch {
          if (managerExecution || managerReservationHeld) managerCleanupOk = false
        }
        if (existsSync(turnInboxDir) || attachmentPaths.some(path => existsSync(path))) {
          if (managerExecution || managerReservationHeld) managerCleanupOk = false
          process.stderr.write('codex-bridge: active-turn attachment cleanup incomplete\n')
          eventLog.emit('daemon.error', { error_kind: 'attachment-cleanup' })
        }
        try { rmSync(turnTempDir, { recursive: true, force: true }) } catch {
          if (managerExecution || managerReservationHeld) managerCleanupOk = false
        }
        if (existsSync(turnTempDir)) {
          if (managerExecution || managerReservationHeld) managerCleanupOk = false
          process.stderr.write('codex-bridge: active-turn temp cleanup incomplete\n')
          eventLog.emit('daemon.error', { error_kind: 'turn-temp-cleanup' })
        }
        if ((turnSucceeded || managerExecution) && beforeSnapshot) {
          try {
            const afterSnapshot = captureWorkspaceSnapshot(codexCfg.cwd)
            if (turnSucceeded) {
              const changes = diffWorkspaceSnapshots(beforeSnapshot, afterSnapshot)
              latestTurnCapability = {
                chatId,
                messageId: msg.id,
                changes,
              }
              eventLog.emit('git.capability_ready', {
                chat_id: chatId,
                message_id: msg.id,
                path_count: Object.keys(latestTurnCapability.changes).length,
              })
              // Derive the exact Fable payload hash while the physical repo
              // lease is still held. A later task cannot race different file
              // bytes into completion-review provenance.
              if (harnessLifecycle) {
                try {
                  completionReviewMaterial = harnessLifecycle.deriveCompletionMaterial(changes)
                } catch (err) {
                  completionReviewMaterialFailure = err
                  process.stderr.write(`codex-bridge: completion review material refused: ${err}\n`)
                  eventLog.emit('review.artifact_refused', {
                    chat_id: chatId,
                    message_id: msg.id,
                    error_kind: 'review-material-invalid',
                    review_status: 'review-pending',
                  })
                }
              }
            } else {
              latestTurnCapability = null
            }
          } catch (err) {
            latestTurnCapability = null
            if (managerExecution || managerReservationHeld) managerCleanupOk = false
            process.stderr.write(`codex-bridge: turn change capability unavailable: ${err}\n`)
            eventLog.emit('git.capability_error', { error_kind: 'post-turn-snapshot' })
          }
        } else {
          latestTurnCapability = null
          if (managerExecution || managerReservationHeld) {
            try { captureWorkspaceSnapshot(codexCfg.cwd) } catch (err) {
              managerCleanupOk = false
              process.stderr.write(`codex-bridge: post-turn cleanup snapshot unavailable: ${err}\n`)
              eventLog.emit('git.capability_error', { error_kind: 'post-turn-snapshot' })
            }
          }
        }
        if (turnSucceeded && harnessLifecycle && managerExecution && appServerManager) {
          if (completionReviewMaterial === null || completionReviewMaterialFailure !== null) {
            managerCleanupOk = false
            managerTurnUncertain = true
            process.stderr.write('codex-bridge: host completion review lacks exact final material\n')
            eventLog.emit('daemon.error', { error_kind: 'host-completion-review-material' })
          } else {
            try {
              const admission = await appServerManager.beginCompletionReview(
                managerExecution.leaseId,
                completionReviewMaterial.hash,
                completionReviewMaterial.reviewInput,
              )
              completionReviewToken = admission.completionToken
              for (;;) {
                if (Date.now() >= admission.expiresAtMs) {
                  throw new Error('host completion review exceeded its manager deadline')
                }
                const status = await appServerManager.completionReviewStatus(
                  managerExecution.leaseId,
                  admission.completionToken,
                )
                if (status.status === 'complete') {
                  if (status.reviewedDiffSha256 !== completionReviewMaterial.hash) {
                    throw new Error('host completion review returned a different material hash')
                  }
                  completionReviewVerdict = status.verdict
                  break
                }
                await new Promise<void>(resolve => {
                  const timer = setTimeout(resolve, 100)
                  timer.unref?.()
                })
              }
            } catch (err) {
              managerCleanupOk = false
              managerTurnUncertain = true
              process.stderr.write(`codex-bridge: host completion review failed closed: ${err}\n`)
              eventLog.emit('daemon.error', { error_kind: 'host-completion-review' })
            }
          }
        }
        if (repoLease) {
          try {
            if (!repoLease.release()) {
              if (managerExecution || managerReservationHeld) managerCleanupOk = false
              process.stderr.write('codex-bridge: physical repository lease ownership changed before release\n')
              updateRuntime({ last_error: 'repo-lease:release' })
              eventLog.emit('daemon.error', { error_kind: 'repo-lease-release' })
              if (!shuttingDown) void shutdown(1)
            }
          } catch (err) {
            if (managerExecution || managerReservationHeld) managerCleanupOk = false
            process.stderr.write(`codex-bridge: physical repository lease release failed: ${err}\n`)
            if (!shuttingDown) void shutdown(1)
          }
          repoLease = null
        }
        if (turnSucceeded && harnessLifecycle && managerExecution && appServerManager
          && completionReviewToken && completionReviewVerdict && managerCleanupOk) {
          try {
            const prefix = completionReviewVerdict === 'block'
              ? `⛔ Advisory Fable review returned block for swarm ${SWARM_NAME} on profile ${turnProfile}. Ratification remains operator-owned.\n\n`
              : completionReviewVerdict === 'needs-changes'
                ? `⚠️ Advisory Fable review found required changes for swarm ${SWARM_NAME}; ratification remains operator-owned.\n\n`
                : completionReviewVerdict === 'review-unavailable'
                  ? `⚠️ Completion review is unavailable for swarm ${SWARM_NAME}; this result is review-pending, never silently approved.\n\n`
                  : ''
            rootBrokerCompletion = await completeCodexTaskViaRootBroker({
              swarm: SWARM_NAME,
              completionToken: completionReviewToken,
              taskId: msg.id,
              turnId: managerExecution.response.turnId,
              summary: boundedRootLifecycleSummary(
                prefix + (terminalSummaryForBroker ?? 'Codex completed without a bounded summary.'),
              ),
            })
            await appServerManager.endCompletionReview(
              managerExecution.leaseId,
              completionReviewToken,
            )
            // Root broker acceptance means result/delivery/task truth is now
            // durable. The operator-local compatibility lifecycle must not
            // emit a second stop or contradict that authority.
            harnessTaskFinished = true
          } catch (err) {
            managerCleanupOk = false
            managerTurnUncertain = true
            process.stderr.write(`codex-bridge: root completion broker failed closed: ${err}\n`)
            eventLog.emit('daemon.error', { error_kind: 'root-completion-broker' })
          }
        }
        if (runtimeWriteFailed && managerReservationHeld) managerCleanupOk = false
        if (managerReservationHeld && appServerManager) {
          if (managerCleanupOk) {
            try {
              const cancelled = await appServerManager.cancelTurnReservation()
              if (!cancelled) throw new Error('manager reservation capability disappeared before cancel')
              managerReservationHeld = false
            } catch (err) {
              managerCleanupOk = false
              managerTurnUncertain = true
              process.stderr.write(`codex-bridge: manager reservation cancellation failed: ${err}\n`)
              eventLog.emit('daemon.error', { error_kind: 'app-server-reservation-cancel' })
            }
          } else {
            // Only an exact post-revocation acknowledgement may reopen global
            // admission. Leave the reservation to fail closed into ambiguity.
            managerTurnUncertain = true
            process.stderr.write('codex-bridge: reservation cleanup was not proven; manager remains blocked\n')
            eventLog.emit('daemon.error', { error_kind: 'app-server-reservation-cleanup-unproven' })
          }
        }
        if (activeTurnAbort === abort) activeTurnAbort = null
        updateRuntime({
          child_pid: null,
          turn_started_at: null,
          last_completed_at: new Date().toISOString(),
        })
        if (runtimeWriteFailed && managerExecution) managerCleanupOk = false
        if (managerExecution && appServerManager) {
          try {
            await appServerManager.replaceSessions([
              ...new Set(sessions.list()
                .filter(entry => entry.profile_id === turnProfile)
                .map(entry => entry.thread_id)),
            ])
          } catch (err) {
            managerCleanupOk = false
            process.stderr.write(`codex-bridge: manager session sync failed before cleanup ack: ${err}\n`)
            eventLog.emit('daemon.error', { error_kind: 'app-server-session-sync' })
          }
          try {
            managerCleanupResult = await appServerManager.cleanupComplete(managerExecution.leaseId, managerCleanupOk)
            managerActiveProfile = managerCleanupResult.activeProfile
            managerPoolParked = managerCleanupResult.activeProfile === null
            managerParkedUntilMs = managerPoolParked
              ? managerCleanupResult.parkedUntilMs ?? Date.now() + 5 * 60_000
              : null
          } catch (err) {
            managerCleanupOk = false
            process.stderr.write(`codex-bridge: manager cleanup acknowledgement failed: ${err}\n`)
            eventLog.emit('daemon.error', { error_kind: 'app-server-cleanup-ack' })
          }
          if (!managerCleanupOk && !shuttingDown) {
            updateRuntime({ ready: false, last_error: 'app-server:cleanup-unproven' })
            void shutdown(1)
          }
        } else if (managerTurnUncertain && !shuttingDown) {
          updateRuntime({ ready: false, last_error: 'app-server:turn-uncertain' })
          void shutdown(1)
        }
      })().catch(err => {
        managerCleanupOk = false
        managerTurnUncertain = Boolean(appServerManager)
        process.stderr.write(`codex-bridge: turn boundary finalization failed closed: ${err}\n`)
        try { eventLog.emit('daemon.error', { error_kind: 'turn-finalization' }) } catch {}
        if (!shuttingDown) void shutdown(1)
      })
    }
    await finalizationPromise
  }

  try {
    retryNotices.register(msg.channelId, msg.id, 'active-turn', retryAuthorizationMetadata(msg))
    if (rotationAttempt > 0) {
      // Once replay execution actually begins it is an ordinary active turn:
      // a later crash is uncertain and must not be duplicated automatically.
      try { parkedTurns.remove(msg.id) } catch {}
    }
    updateRuntime({ turn_started_at: new Date().toISOString(), last_error: null })
    eventLog.emit('turn.started', {
      chat_id: chatId,
      message_id: msg.id,
      thread_id: sessions.get(chatId, turnProfile) ?? 'new',
    })

    const turnWorkspaceSafety = checkWorkspaceSafety(codexCfg.cwd, protectedRuntimeRoots)
    let boundaryDetail = ''
    try {
      validatePrivateStateBoundary(STATE_DIR, false)
      verifyBaseRuntimeAccess(
        dedicatedRuntime.runtimeUser,
        userInfo().homedir,
        STATE_DIR,
        INBOX_DIR,
        TOOL_TMP_ROOT,
        TOOL_SHIM_DIR,
      )
      const trustedNode = resolveTrustedCodexExecutable(REQUESTED_CODEX_BIN, {
        workspaceRoot: codexCfg.cwd,
        stateDir: STATE_DIR,
        sourceEnv: process.env,
      })
      if (!REQUESTED_CODEX_ARGV_PREFIX) throw new Error('missing attested Codex script')
      const trustedScript = resolveTrustedCodexScript(REQUESTED_CODEX_ARGV_PREFIX, {
        workspaceRoot: codexCfg.cwd,
        stateDir: STATE_DIR,
        sourceEnv: process.env,
      })
      const freshRuntime = validateDedicatedRuntimeBoundary({
        workspaceRoot: codexCfg.cwd,
        stateDir: STATE_DIR,
        trustedNodePath: trustedNode,
        trustedCodexScript: trustedScript,
        readableRoots: toolchainPlan.readableRoots,
      })
      if (
        freshRuntime.runtimeUid !== dedicatedRuntime.runtimeUid
        || freshRuntime.runtimeHome !== dedicatedRuntime.runtimeHome
        || JSON.stringify(freshRuntime.sudoArgvPrefix) !== JSON.stringify(dedicatedRuntime.sudoArgvPrefix)
      ) throw new Error('dedicated runtime plan changed after daemon startup')
      codexCfg.bin = dedicatedRuntime.sudoPath
      codexCfg.binArgs = dedicatedRuntime.sudoArgvPrefix
    } catch (err) {
      boundaryDetail = String(err).slice(0, 500)
    }
    let turnPreflight: { ok: true } | {
      ok: false
      errorKind: string
      detail: string
    }
    if (boundaryDetail) {
      turnPreflight = { ok: false, errorKind: 'host-boundary', detail: boundaryDetail }
    } else if (appServerManager) {
      try {
        const liveness = await appServerManager.liveness()
        managerRuntimeAvailable = managerLivenessMonitor.observe(liveness)
        updateRuntime({ ready: client.isReady() && managerRuntimeAvailable })
        turnPreflight = { ok: true }
      } catch (err) {
        turnPreflight = {
          ok: false,
          errorKind: 'app-server-manager',
          detail: String(err).slice(0, 500),
        }
      }
    } else {
      turnPreflight = runCodexPreflight(
        codexCfg.bin!,
        codexHostEnvironment(),
        DEDICATED_CODEX_PREFLIGHT_TIMEOUT_MS,
        codexCfg.binArgs,
      )
    }
    if (!turnWorkspaceSafety.ok || !turnPreflight.ok) {
      const kind = !turnWorkspaceSafety.ok
        ? turnWorkspaceSafety.errorKind
        : turnPreflight.ok ? 'unknown' : turnPreflight.errorKind
      const detail = !turnWorkspaceSafety.ok
        ? turnWorkspaceSafety.detail
        : turnPreflight.ok ? '' : turnPreflight.detail
      process.stderr.write(`codex-bridge: turn preflight failed (${kind}): ${detail}\n`)
      updateRuntime({ last_error: `preflight:${kind}` })
      eventLog.emit('turn.error', { chat_id: chatId, error_kind: `preflight-${kind}` })
      if (!shuttingDown) {
        await (msg.channel as any).send(buildOutboundPayload(
          `⚠️ codex runtime preflight failed (${kind}); operator action is required.`,
        ))
      }
      if (appServerManager && kind === 'app-server-manager' && !shuttingDown) void shutdown(1)
      return
    }

    // Typing indicator for the whole turn — Discord's lasts ~10s, so refresh.
    typing = setInterval(() => {
      if ('sendTyping' in msg.channel) void msg.channel.sendTyping().catch(() => {})
    }, 8000)
    if ('sendTyping' in msg.channel) void msg.channel.sendTyping().catch(() => {})

    try { rmSync(turnTempDir, { recursive: true, force: true }) } catch {}
    mkdirSync(turnTempDir, { recursive: true, mode: 0o700 })
    try { chmodSync(turnTempDir, 0o700) } catch {}

    // Own the physical checkout before preparing any turn input. Attachment
    // bytes are materialized operator-private; the hidden runtime UID receives
    // no turn-scoped ACL until the global App Server slot is also reserved.
    repoLease = await RepoLease.acquire({
      root: REPO_LEASE_ROOT,
      cwd: codexCfg.cwd,
      stateDir: STATE_DIR,
      swarmName: SWARM_NAME,
      operation: 'turn',
      signal: abort.signal,
      waitMs: codexCfg.timeoutMs,
    })
    const materialized = await materializeTurnAttachments(attachments, {
      inboxDir: turnInboxDir,
      signal: abort.signal,
      onError: err => process.stderr.write(`codex-bridge: attachment download failed: ${err}\n`),
    })
    attachmentPaths.push(...materialized.paths)
    const unavailable = materialized.failures > 0
      ? `[${materialized.failures} attachment(s) could not be downloaded]`
      : ''
    const turnContent = [content, unavailable].filter(Boolean).join('\n\n')
      || (atts.length > 0 ? '(attachment)' : '')

    const envelope = buildEnvelope(turnContent, {
      chatId,
      messageId: msg.id,
      user: msg.author.username,
      userId: msg.author.id,
      ts: msg.createdAt.toISOString(),
      archetype: BRIDGE_IDENTITY.archetype,
      channelRole,
      attachments: atts.length ? atts : undefined,
      attachmentPaths: attachmentPaths.length ? attachmentPaths : undefined,
    })

    let threadId = appServerManager ? null : sessions.get(chatId, turnProfile)
    let prompt = threadId ? envelope : FULL_PREAMBLE + envelope
    const runnerOptions = {
      signal: abort.signal,
      readableRoots: [
        ...toolchainPlan.readableRoots,
        toolShimDir,
        ...turnWorkspaceSafety.readableExamples,
        ...(attachmentPaths.length ? [turnInboxDir] : []),
      ],
      deniedPaths: turnWorkspaceSafety.deniedPaths,
      writableRoots: [turnTempDir],
      environment: turnEnvironment(turnTempDir),
      onChildPid: appServerManager
        ? undefined
        : (pid: number | null) => updateRuntime({ child_pid: pid }),
      onEvent: (event: { type: string; itemType?: string; status?: string }) => {
        eventLog.emit('codex.event', {
          event_type: event.type,
          item_type: event.itemType ?? null,
          status: event.status ?? null,
        })
        if (harnessLifecycle && harnessTaskStarted && harnessActivityFailure === null) {
          try {
            // Codex runner projections intentionally contain no command or
            // prose bytes. Every observed protocol event is therefore a
            // content-free runtime.activity fact; grounding classification
            // remains at raw rollout ingestion, not this lossy adapter.
            harnessLifecycle.recordRuntimeActivity(msg.id)
          } catch (error) {
            harnessActivityFailure = error
            process.stderr.write(`codex-bridge: normalized activity append failed: ${error}\n`)
            eventLog.emit('daemon.error', { error_kind: 'harness-activity-journal' })
          }
        }
      },
    }
    if (!recheckProjectConfig(turnWorkspaceSafety.cwd, turnWorkspaceSafety.projectConfig)) {
      process.stderr.write('codex-bridge: project .codex/config.toml changed after turn preflight\n')
      updateRuntime({ last_error: 'preflight:project-config-changed' })
      eventLog.emit('turn.error', { chat_id: chatId, error_kind: 'project-config-changed' })
      await finalizeTurnBoundary()
      if (!shuttingDown) {
        await (msg.channel as any).send(buildOutboundPayload(
          '⚠️ project Codex config changed during preflight; operator action is required.',
        ))
      }
      return
    }
    if (appServerManager) {
      try {
        const reservation = await appServerManager.reserveTurn({
          signal: abort.signal,
          timeoutMs: APP_SERVER_MANAGER_ADMISSION_TIMEOUT_MS,
        })
        managerPoolParked = false
        managerParkedUntilMs = null
        turnProfile = reservation.profile
        managerActiveProfile = reservation.profile
        threadId = sessions.get(chatId, turnProfile)
        prompt = threadId ? envelope : FULL_PREAMBLE + envelope
      } catch (err) {
        if (err instanceof AppServerManagerClientError && err.remotePoolExhausted) {
          const retryAt = err.remoteParkedUntilMs ?? Date.now() + 5 * 60_000
          managerPoolParked = true
          managerParkedUntilMs = retryAt
          await finalizeTurnBoundary()
          retainRetryNotice = persistParkedTurn(msg, retryAt, Math.max(1, rotationAttempt))
          if (retainRetryNotice) {
            const current = parkedTurns.list().find(entry => entry.message_id === msg.id)
            if (current) scheduleParkedTurn(current)
            await announcePoolParked(retryAt, msg)
          } else if (!shuttingDown) {
            try {
              await (msg.channel as any).send(buildOutboundPayload(
                '⚠️ Codex pool is parked, but the task could not be durably queued; operator repair is required.',
                msg.id,
              ))
            } catch {}
          }
          return
        }
        managerTurnUncertain = !(err instanceof AppServerManagerClientError)
          || err.ambiguous
          || ['boundary', 'protocol', 'transport', 'remote'].includes(err.kind)
        throw err
      }
      managerReservationHeld = true
      let postAdmissionFailure = ''
      try {
        if (shuttingDown) throw new Error('daemon is shutting down')
        const authorization = await revalidateDeliveryAuthorization({
          senderId: msg.author.id,
          isDM: msg.channel.type === ChannelType.DM,
          gateChannelId: gateChannelIdFor(msg),
          // The immutable inbound message already passed mention admission;
          // this second proof rechecks sender/channel authority without a
          // network fetch while the global reservation is held.
          isMentioned: async () => true,
        }, {
          store,
          boundChannels: BOUND_CHANNELS,
          canonicalAccessFile: CANONICAL_ACCESS_FILE,
        })
        if (!authorization.ok) throw new Error('sender or channel authorization changed')
        if (!repoLease?.verifyOwnership()) {
          throw new Error('physical repository lease ownership changed while waiting for global admission')
        }
        validatePrivateStateBoundary(STATE_DIR, false)
        verifyBaseRuntimeAccess(
          dedicatedRuntime.runtimeUser,
          userInfo().homedir,
          STATE_DIR,
          INBOX_DIR,
          TOOL_TMP_ROOT,
          TOOL_SHIM_DIR,
        )
        const freshWorkspaceSafety = checkWorkspaceSafety(codexCfg.cwd, protectedRuntimeRoots)
        if (!freshWorkspaceSafety.ok
          || JSON.stringify(freshWorkspaceSafety) !== JSON.stringify(turnWorkspaceSafety)) {
          throw new Error('workspace safety policy changed while waiting for global admission')
        }
        const freshToolchain = resolveToolchainPlan(
          codexCfg.cwd,
          process.env,
          ['git', 'python3', 'bun'],
          userInfo().homedir,
          true,
        )
        if (JSON.stringify(freshToolchain) !== JSON.stringify(toolchainPlan)) {
          throw new Error('dedicated toolchain plan changed while waiting for global admission')
        }
        const trustedNode = resolveTrustedCodexExecutable(REQUESTED_CODEX_BIN, {
          workspaceRoot: codexCfg.cwd,
          stateDir: STATE_DIR,
          sourceEnv: process.env,
        })
        if (!REQUESTED_CODEX_ARGV_PREFIX) throw new Error('missing attested Codex script')
        const trustedScript = resolveTrustedCodexScript(REQUESTED_CODEX_ARGV_PREFIX, {
          workspaceRoot: codexCfg.cwd,
          stateDir: STATE_DIR,
          sourceEnv: process.env,
        })
        const freshRuntime = validateDedicatedRuntimeBoundary({
          workspaceRoot: codexCfg.cwd,
          stateDir: STATE_DIR,
          trustedNodePath: trustedNode,
          trustedCodexScript: trustedScript,
          readableRoots: freshToolchain.readableRoots,
        })
        if (JSON.stringify(freshRuntime) !== JSON.stringify(dedicatedRuntime)) {
          throw new Error('dedicated runtime plan changed while waiting for global admission')
        }
      } catch (err) {
        postAdmissionFailure = String(err).slice(0, 500)
      }
      if (postAdmissionFailure) {
        process.stderr.write(`codex-bridge: post-admission authority check failed: ${postAdmissionFailure}\n`)
        updateRuntime({ last_error: 'preflight:post-admission-authority' })
        eventLog.emit('turn.error', { chat_id: chatId, error_kind: 'post-admission-authority' })
        await finalizeTurnBoundary()
        if (!shuttingDown) {
          await (msg.channel as any).send(buildOutboundPayload(
            '⚠️ authorization or runtime authority changed while waiting; the reserved turn was cancelled.',
          ))
        }
        return
      }
      // Reservation waits can span another swarm's complete turn. Reprove the
      // project policy after global admission and before exposing any path to
      // the hidden runtime UID.
      if (!recheckProjectConfig(turnWorkspaceSafety.cwd, turnWorkspaceSafety.projectConfig)) {
        process.stderr.write('codex-bridge: project .codex/config.toml changed while waiting for global admission\n')
        updateRuntime({ last_error: 'preflight:project-config-changed' })
        eventLog.emit('turn.error', { chat_id: chatId, error_kind: 'project-config-changed' })
        await finalizeTurnBoundary()
        if (!shuttingDown) {
          await (msg.channel as any).send(buildOutboundPayload(
            '⚠️ project Codex config changed during global admission; operator action is required.',
          ))
        }
        return
      }
    }
    try {
      // Capture the attribution baseline only after a potentially long global
      // admission wait, while the exact repository lease is still owned and
      // before the hidden UID receives access.
      beforeSnapshot = captureWorkspaceSnapshot(codexCfg.cwd)
    } catch (err) {
      process.stderr.write(`codex-bridge: turn change baseline unavailable: ${err}\n`)
      eventLog.emit('git.capability_error', { error_kind: 'baseline-snapshot' })
    }
    try {
      // Hard-limit replay keeps msg.id. Bind the result-set delta to the exact
      // reserved profile so a prior attempt cannot be replayed or poison this
      // attempt's intake.
      reviewArtifactBaseline = snapshotFableReviewArtifactBaseline(
        STATE_DIR, msg.id, SWARM_NAME, turnProfile,
      )
    } catch (err) {
      // The turn may continue, but post-turn intake must remain pending. An
      // absent baseline cannot safely distinguish this attempt from prior
      // same-profile records, so it is never treated as an empty baseline.
      reviewArtifactBaselineRefused = true
      process.stderr.write(`codex-bridge: Fable review artifact baseline unavailable: ${err}\n`)
      eventLog.emit('review.artifact_baseline_refused', {
        chat_id: chatId,
        message_id: msg.id,
        profile: turnProfile,
        error_kind: 'review-artifact-invalid',
        review_status: 'review-pending',
      })
    }
    if (harnessLifecycle) {
      // A hard-limit replay retains the original Discord task id and its
      // existing DRIVING event. Only the first attempt authors task.started.
      if (rotationAttempt === 0) harnessLifecycle.startTask(msg.id)
      harnessTaskStarted = true
    }
    // This exact reservation-to-start window is the only point at which
    // hidden-UID access exists. Cleanup revokes it before either reservation
    // cancellation or terminal manager acknowledgement.
    turnAclActive = true
    grantTurnRuntimeAccess(
      dedicatedRuntime.runtimeUser,
      turnTempDir,
      attachmentPaths.length > 0 ? turnInboxDir : null,
      attachmentPaths,
    )
    let result
    if (appServerManager) {
      try {
        managerExecution = await appServerManager.runTurn({
          taskId: msg.id,
          threadId,
          prompt,
          clientUserMessageId: msg.id,
          readableRoots: runnerOptions.readableRoots,
          deniedPaths: runnerOptions.deniedPaths,
          writableRoots: runnerOptions.writableRoots,
          environment: runnerOptions.environment,
        }, {
          signal: abort.signal,
          timeoutMs: codexCfg.timeoutMs,
          onEvent: runnerOptions.onEvent,
        })
        managerReservationHeld = false
        result = managerExecution.result
      } catch (err) {
        managerTurnUncertain = !(err instanceof AppServerManagerClientError) || err.ambiguous
        result = managerClientErrorToCodexResult(err, threadId)
      }
    } else {
      result = await runCodexTurn(threadId, prompt, codexCfg, runnerOptions)
    }

    // A vanished thread (rotated/deleted session files) shouldn't strand the
    // chat — drop the mapping and retry once as a fresh thread.
    if (!appServerManager && shouldRetryFresh(threadId, result)) {
      process.stderr.write(
        `codex-bridge: resume of ${threadId} failed (${result.error}); retrying fresh\n`,
      )
      eventLog.emit('turn.resume_missing', { chat_id: chatId, thread_id: threadId })
      sessions.delete(chatId)
      threadId = null
      if (!recheckProjectConfig(turnWorkspaceSafety.cwd, turnWorkspaceSafety.projectConfig)) {
        process.stderr.write('codex-bridge: project Codex config changed before fresh retry\n')
        return
      }
      result = await runCodexTurn(null, FULL_PREAMBLE + envelope, codexCfg, runnerOptions)
    }

    if (result.ok && result.threadId) {
      try {
        sessions.set(chatId, result.threadId, turnProfile)
      } catch (err) {
        if (appServerManager) managerCleanupOk = false
        throw err
      }
    }
    terminalSummaryForBroker = boundedRootLifecycleSummary(codexReplyText(result))
    turnSucceeded = result.ok

    // Revoke hidden-UID access and release/collapse the global manager slot
    // before any Discord send or attention relay can block on external I/O.
    await finalizeTurnBoundary()

    // The reviewer is terminal and writes only private artifacts. Intake
    // happens after every local execution/ACL/manager boundary has closed;
    // verdicts are provenance-bearing advisory inputs, never merge authority.
    let blockReviewPresent = false
    try {
      if (reviewArtifactBaselineRefused) {
        throw new Error('pre-execution review artifact baseline was refused')
      }
      const reviewArtifacts = readFableReviewArtifacts(
        STATE_DIR, msg.id, SWARM_NAME, turnProfile, reviewArtifactBaseline,
      )
      currentReviewArtifacts = reviewArtifacts
      for (const artifact of reviewArtifacts) {
        const reviewStatus = artifact.result.verdict === 'review-unavailable'
          ? 'review-pending'
          : 'advisory'
        // In adopted mode this is only a candidate until the host-derived
        // final-diff hash passes the shared completion gate below.
        if (!harnessLifecycle) {
          eventLog.emit('review.result_recorded', {
            chat_id: chatId,
            message_id: msg.id,
            profile: turnProfile,
            reviewer: 'claude-fable',
            verdict: artifact.result.verdict,
            review_status: reviewStatus,
            diff_hash: artifact.reviewed_diff_sha256,
          })
        }
        if (artifact.result.verdict === 'block'
          && (!harnessLifecycle || (
            // A valid two-artifact set may contain one earlier exception plus
            // the exact completion review. Announce either block verdict, but
            // only after the set proves a sole final-diff completion artifact.
            reviewArtifacts.length <= 2
            && completionReviewMaterial !== null
            && reviewArtifacts.filter(item => (
              item.reviewed_diff_sha256 === completionReviewMaterial!.hash
            )).length === 1
          ))) blockReviewPresent = true
      }
      if (!harnessLifecycle && reviewArtifacts.length > 0) {
        eventLog.emit('review.result_set', {
          chat_id: chatId,
          message_id: msg.id,
          profile: turnProfile,
          artifact_count: reviewArtifacts.length,
          review_status: reviewArtifacts.some(item => item.result.verdict === 'review-unavailable')
            ? 'review-pending'
            : 'advisory',
        })
      }
    } catch (err) {
      process.stderr.write(`codex-bridge: Fable review artifact intake refused: ${err}\n`)
      eventLog.emit('review.artifact_refused', {
        chat_id: chatId,
        message_id: msg.id,
        profile: turnProfile,
        error_kind: 'review-artifact-invalid',
        review_status: 'review-pending',
      })
    }
    if (!harnessLifecycle && blockReviewPresent && !shuttingDown) {
      try {
        await (msg.channel as any).send(buildOutboundPayload(
          `⛔ Advisory Fable review returned block for swarm ${SWARM_NAME} on profile ${turnProfile}. Ratification remains operator-owned.`,
          msg.id,
        ))
      } catch (err) {
        process.stderr.write(`codex-bridge: block review notice failed: ${err}\n`)
        eventLog.emit('review.notice_error', {
          chat_id: chatId,
          message_id: msg.id,
          error_kind: 'discord-send',
        })
      }
    }

    const rotation = managerExecution?.response.rotation ?? null
    if (rotation && managerCleanupResult) {
      const parked = rotation.activeProfile === null
      const resetText = rotation.parkedUntilMs
        ? ` until ${new Date(rotation.parkedUntilMs).toISOString()}`
        : ' with bounded backoff'
      const notice = parked
        ? `⏸️ Codex profile pool exhausted after ${rotation.previousProfile}; this swarm is parked${resetText}.`
        : rotation.reason === 'hard'
          ? `🔄 Codex usage limit on ${rotation.previousProfile}; rotated this swarm to ${rotation.activeProfile} and requeued the task.`
          : `🔄 Codex profile ${rotation.previousProfile} reached its pool threshold; this swarm will use ${rotation.activeProfile} at the next task boundary.`
      eventLog.emit(parked ? 'rotation.exhausted' : 'rotation.completed', {
        chat_id: chatId,
        message_id: msg.id,
        previous_profile: rotation.previousProfile,
        next_profile: rotation.activeProfile,
        reason: rotation.reason,
        parked_until_ms: rotation.parkedUntilMs,
        attempt: rotationAttempt,
      })
      const hardRetryBoundary = rotation.reason === 'hard' && rotationAttempt < 15
        ? (() => {
          const nextAttempt = rotationAttempt + 1
          const retryAt = rotation.activeProfile
            ? Date.now()
            : rotation.parkedUntilMs ?? Date.now() + 5 * 60_000
          return {
            nextAttempt,
            retryAt,
            persisted: persistParkedTurn(msg, retryAt, nextAttempt),
          }
        })()
        : null
      if (!shuttingDown) {
        if (harnessLifecycle) {
          await sendVerifiedLifecycleNotice(msg, notice, 'profile-rotation')
        } else {
          try {
            const sent = await (msg.channel as any).send(buildOutboundPayload(notice, msg.id))
            if (typeof sent?.id === 'string') noteSent(sent.id)
          } catch (err) {
            process.stderr.write(`codex-bridge: profile rotation notice failed: ${err}\n`)
            eventLog.emit('rotation.notice_error', {
              chat_id: chatId,
              message_id: msg.id,
              error_kind: 'discord-send',
            })
          }
        }
      }
      if (rotation.reason === 'hard') {
        if (rotationAttempt >= 15) {
          result = {
            ...result,
            error: 'Codex profile retry bound exhausted',
            errorKind: 'usage-limit' as const,
          }
        } else {
          const nextAttempt = hardRetryBoundary!.nextAttempt
          const retryAt = hardRetryBoundary!.retryAt
          if (!hardRetryBoundary!.persisted) {
            result = {
              ...result,
              error: 'Codex quota retry could not be durably queued',
              errorKind: 'usage-limit' as const,
            }
          } else if (shuttingDown) {
            retainRetryNotice = true
            return
          } else if (rotation.activeProfile) {
            // Keep the durable marker through the recursive attempt. Its
            // terminal boundary removes it; a daemon restart refetches the
            // same immutable Discord message instead of degrading to a warning.
            retainRetryNotice = true
            managerPoolParked = false
            managerParkedUntilMs = null
            eventLog.emit('turn.requeued', {
              chat_id: chatId,
              message_id: msg.id,
              profile: rotation.activeProfile,
              attempt: nextAttempt,
            })
            return await runTurn(msg, content, attachments, atts, channelRole, nextAttempt)
          } else {
            // Do not occupy the serial worker or repository lease for an
            // hours-long reset. The metadata-only ledger survives restarts;
            // the original Discord message is refetched after the boundary.
            retainRetryNotice = true
            managerPoolParked = true
            managerParkedUntilMs = retryAt
            const current = parkedTurns.list().find(entry => entry.message_id === msg.id)
            if (current) scheduleParkedTurn(current)
            return
          }
        }
      }
    }

    const access = store.load()
    const limit = Math.max(1, Math.min(access.textChunkLimit ?? MAX_CHUNK_LIMIT, MAX_CHUNK_LIMIT))
    const mode = access.chunkMode ?? 'length'
    const replyMode = access.replyToMode ?? 'first'

    if (!result.ok) {
      process.stderr.write(
        `codex-bridge: turn failed for chat ${chatId} (${result.errorKind ?? 'unknown'}): ${result.error}\n`,
      )
    }
    let text = codexReplyText(result)
    const suppressReply = result.ok
      && shouldSuppressSilentFinal(text, BRIDGE_IDENTITY, channelRole)
    if (result.ok && !suppressReply) {
      const extracted = extractAttentionDirective(text)
      if (extracted.directive) {
        text = extracted.visibleText || (extracted.directive.action === 'raise'
          ? `⚠️ BLOCKED: ${extracted.directive.reason}`
          : 'Swarm attention flag cleared.')
        const relay = await relaySwarmAttention(extracted.directive, ATTENTION_BINDING)
        if (relay.ok) {
          eventLog.emit('attention.updated', { status: extracted.directive.action })
        } else {
          process.stderr.write(
            `codex-bridge: attention relay failed (${relay.errorKind}): ${relay.detail}\n`,
          )
          updateRuntime({ last_error: `attention:${relay.errorKind}` })
          eventLog.emit('attention.error', { error_kind: relay.errorKind })
          text += '\n\n⚠️ codex-bridge could not update the swarm attention flag; operator action is still required.'
        }
      }
    }

    if (harnessLifecycle) {
      if (!result.ok) {
        harnessLifecycle.failTask(msg.id)
        harnessTaskFinished = true
        if (!shuttingDown) {
          await sendVerifiedLifecycleNotice(msg, text, 'codex-turn-failed')
        }
        updateRuntime({ last_error: `codex:${result.errorKind ?? 'unknown'}` })
        eventLog.emit('turn.error', {
          chat_id: chatId,
          error_kind: result.errorKind ?? 'unknown',
        })
        return
      }
      if (rootBrokerCompletion) {
        const exactArtifact = completionReviewMaterial
          ? currentReviewArtifacts.find(artifact => (
            artifact.reviewed_diff_sha256 === completionReviewMaterial!.hash
          ))
          : undefined
        if (exactArtifact) {
          eventLog.emit('review.result_recorded', {
            chat_id: chatId,
            message_id: msg.id,
            profile: turnProfile,
            reviewer: 'claude-fable',
            verdict: exactArtifact.result.verdict,
            review_status: exactArtifact.result.verdict === 'review-unavailable'
              ? 'review-pending' : 'advisory',
            diff_hash: exactArtifact.reviewed_diff_sha256,
          })
        }
        eventLog.emit('turn.completed', {
          chat_id: chatId,
          status: rootBrokerCompletion.stop_disposition === 'queued'
            ? 'silent-queued'
            : completionReviewVerdict === 'review-unavailable' ? 'review-pending' : 'ok',
          review_status: completionReviewVerdict === 'review-unavailable' ? 'pending' : 'complete',
        })
        return
      }
      if (harnessActivityFailure !== null) {
        throw new Error(`normalized activity evidence failed: ${harnessActivityFailure}`)
      }
      if (completionReviewMaterialFailure !== null || completionReviewMaterial === null) {
        throw new Error(`completion review material unavailable: ${completionReviewMaterialFailure ?? 'missing'}`)
      }

      const exactCandidates = currentReviewArtifacts.filter(artifact => (
        artifact.reviewed_diff_sha256 === completionReviewMaterial!.hash
      ))
      const exactArtifact = currentReviewArtifacts.length <= 2 && exactCandidates.length === 1
        ? exactCandidates[0]!
        : null
      if (blockReviewPresent) {
        text = `⛔ Advisory Fable review returned block for swarm ${SWARM_NAME} on profile ${turnProfile}. Ratification remains operator-owned.\n\n${text}`
      } else if (exactArtifact?.result.verdict === 'needs-changes') {
        text = `⚠️ Advisory Fable review found required changes for swarm ${SWARM_NAME}; ratification remains operator-owned.\n\n${text}`
      } else if (exactArtifact?.result.verdict === 'review-unavailable') {
        text = `⚠️ Completion review is unavailable for swarm ${SWARM_NAME}; this result is review-pending, never silently approved.\n\n${text}`
      }

      const sender = lifecycleSenderFor(msg)
      const fallbackChannel = BRIDGE_IDENTITY.operatorChannel
        && BRIDGE_IDENTITY.operatorChannel !== msg.channelId
        ? BRIDGE_IDENTITY.operatorChannel
        : null
      const pipeline = new StopDeliveryPipeline({
        sender,
        fallbackSender: sender,
        store: harnessStopState!,
      })
      const completion = await harnessLifecycle.completeTask({
        taskId: msg.id,
        turnId: result.threadId ?? msg.id,
        // A doctrine-suppressed CPO response cannot truthfully be delivered as
        // a stop message without creating a bot loop. Null primary transport
        // therefore dead-letters it; queued remains audited terminal evidence.
        channelId: suppressReply ? '' : msg.channelId,
        fallbackChannelId: suppressReply ? null : fallbackChannel,
        summary: suppressReply
          ? 'Codex task completed with a doctrine-suppressed channel response.'
          : text,
        material: completionReviewMaterial,
        artifacts: currentReviewArtifacts,
        pipeline,
      })
      harnessTaskFinished = true
      if (!completion.boundary.accepted) {
        updateRuntime({ last_error: `review-gate:${completion.reviewReason}` })
        eventLog.emit('turn.error', {
          chat_id: chatId,
          error_kind: 'completion-review-gate',
          review_status: 'review-pending',
        })
        if (!shuttingDown) {
          await sendVerifiedLifecycleNotice(
            msg,
            '⚠️ Completion review evidence did not match the final task diff. The task remains open and done was not accepted.',
            'completion-review-gate',
          )
        }
        return
      }
      if (exactArtifact) {
        eventLog.emit('review.result_recorded', {
          chat_id: chatId,
          message_id: msg.id,
          profile: turnProfile,
          reviewer: 'claude-fable',
          verdict: exactArtifact.result.verdict,
          review_status: completion.boundary.review_status === 'pending'
            ? 'review-pending'
            : 'advisory',
          diff_hash: exactArtifact.reviewed_diff_sha256,
        })
      }
      eventLog.emit('turn.completed', {
        chat_id: chatId,
        status: suppressReply
          ? 'silent-queued'
          : completion.boundary.review_status === 'pending' ? 'review-pending' : 'ok',
        review_status: completion.boundary.review_status,
      })
      return
    }

    const chunks = suppressReply ? [] : boundedOutboundChunks(text, limit, mode)
    if (!shuttingDown && !suppressReply) {
      for (let i = 0; i < chunks.length; i++) {
        const shouldReplyTo = replyMode !== 'off' && (replyMode === 'all' || i === 0)
        const sent = await (msg.channel as any).send(
          buildOutboundPayload(chunks[i], shouldReplyTo ? msg.id : undefined),
        )
        noteSent(sent.id)
      }
    }

    if (result.ok) {
      eventLog.emit('turn.completed', {
        chat_id: chatId,
        status: suppressReply ? 'silent' : 'ok',
      })
    } else {
      updateRuntime({ last_error: `codex:${result.errorKind ?? 'unknown'}` })
      eventLog.emit('turn.error', {
        chat_id: chatId,
        error_kind: result.errorKind ?? 'unknown',
      })
    }
  } catch (err) {
    process.stderr.write(`codex-bridge: turn failed for chat ${chatId}: ${err}\n`)
    updateRuntime({ last_error: 'bridge:internal' })
    eventLog.emit('turn.error', { chat_id: chatId, error_kind: 'bridge-internal' })
    await finalizeTurnBoundary()
    if (harnessLifecycle && harnessTaskStarted && !harnessTaskFinished && !retainRetryNotice) {
      try {
        harnessLifecycle.failTask(msg.id)
        harnessTaskFinished = true
      } catch (stateError) {
        process.stderr.write(`codex-bridge: harness task failure transition failed: ${stateError}\n`)
        eventLog.emit('daemon.error', { error_kind: 'harness-task-failure-transition' })
        if (!shuttingDown) void shutdown(1)
      }
    }
    if (!shuttingDown) {
      if (harnessLifecycle) {
        await sendVerifiedLifecycleNotice(
          msg,
          '⚠️ codex-bridge internal error; the harness did not accept this task as done.',
          'bridge-internal',
        )
      } else {
        try {
          const sent = await (msg.channel as any).send(buildOutboundPayload('⚠️ codex-bridge internal error'))
          if (typeof sent?.id === 'string') noteSent(sent.id)
        } catch (sendError) {
          process.stderr.write(`codex-bridge: internal error notice failed: ${sendError}\n`)
          eventLog.emit('turn.notice_error', {
            chat_id: chatId,
            message_id: msg.id,
            error_kind: 'discord-send',
          })
        }
      }
    }
  } finally {
    await finalizeTurnBoundary()
    if (harnessLifecycle && harnessTaskStarted && !harnessTaskFinished && !retainRetryNotice) {
      try {
        harnessLifecycle.failTask(msg.id)
        harnessTaskFinished = true
      } catch (stateError) {
        process.stderr.write(`codex-bridge: final harness task transition failed: ${stateError}\n`)
        eventLog.emit('daemon.error', { error_kind: 'harness-task-final-transition' })
        if (!shuttingDown) void shutdown(1)
      }
    }
    if (shuttingDown && !retainRetryNotice) await notifyShutdownDrop(msg, 'active-turn')
    else if (!retainRetryNotice) try { retryNotices.remove(msg.id) } catch {}
    if (!shuttingDown && rotationAttempt > 0 && !retainRetryNotice) {
      try { parkedTurns.remove(msg.id) } catch {}
    }
  }
}

async function runGitControl(
  msg: Message,
  command: GitControlCommand,
  allowedChanges?: Readonly<Record<string, string | null>>,
): Promise<void> {
  const abort = new AbortController()
  activeTurnAbort = abort
  const safeMessageId = msg.id.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64) || 'control'
  const tempDir = join(TOOL_TMP_ROOT, `git-${safeMessageId}`)
  let repoLease: RepoLease | null = null
  try {
    retryNotices.register(msg.channelId, msg.id, 'active-git', retryAuthorizationMetadata(msg))
    updateRuntime({ turn_started_at: new Date().toISOString(), last_error: null })
    eventLog.emit('git.started', {
      chat_id: msg.channelId,
      message_id: msg.id,
      action: command.action,
    })
    try { rmSync(tempDir, { recursive: true, force: true }) } catch {}
    mkdirSync(tempDir, { recursive: true, mode: 0o700 })
    try { chmodSync(tempDir, 0o700) } catch {}

    repoLease = await RepoLease.acquire({
      root: REPO_LEASE_ROOT,
      cwd: codexCfg.cwd,
      stateDir: STATE_DIR,
      swarmName: SWARM_NAME,
      operation: 'git',
      signal: abort.signal,
      waitMs: codexCfg.timeoutMs,
    })

    const result = await runGitBroker(command, {
      cwd: codexCfg.cwd,
      stateDir: GIT_BROKER_STATE_DIR,
      gitBin: toolchainPlan.executables.git,
      environment: safeTurnEnvironment(tempDir, toolchainPlan, toolShimDir),
      authorName: process.env.CODEX_BRIDGE_GIT_AUTHOR_NAME,
      authorEmail: process.env.CODEX_BRIDGE_GIT_AUTHOR_EMAIL,
      allowedChanges,
      signal: abort.signal,
      onChildPid: (pid: number | null) => updateRuntime({ child_pid: pid }),
    })

    if (!result.ok) {
      process.stderr.write(
        `codex-bridge: Git broker refused ${command.action} (${result.errorKind}): ${result.detail}\n`,
      )
      updateRuntime({ last_error: `git:${result.errorKind}` })
      eventLog.emit('git.error', { action: command.action, error_kind: result.errorKind })
      if (!shuttingDown) {
        const sent = await (msg.channel as any).send(buildOutboundPayload(
          `⚠️ Git broker refused (${result.errorKind}). Check the codex-bridge operator view.`,
          msg.id,
        ))
        noteSent(sent.id)
      }
      return
    }

    if (result.action === 'commit' && latestTurnCapability?.changes === allowedChanges) {
      // A latest-turn capability is single-use even when the operator chose a subset.
      latestTurnCapability = null
    }
    eventLog.emit('git.completed', {
      action: result.action,
      status: 'ok',
      ...(result.action === 'commit' ? { commit: result.commit } : { branch: result.branch }),
    })
    if (!shuttingDown) {
      const text = result.action === 'commit'
        ? `✅ Git broker advanced its side ref to ${result.commit}; canonical checkout unchanged.`
        : result.action === 'branch'
          ? `✅ Git broker created side ref \`${result.branch}\` without switching the canonical checkout.`
          : `✅ Git broker retired the integrated capability for \`${result.branch}\`; historical ref retained.`
      const sent = await (msg.channel as any).send(buildOutboundPayload(text, msg.id))
      noteSent(sent.id)
    }
  } catch (err) {
    process.stderr.write(`codex-bridge: Git broker internal error: ${err}\n`)
    updateRuntime({ last_error: 'git:internal' })
    eventLog.emit('git.error', { action: command.action, error_kind: 'internal' })
    if (!shuttingDown) try {
      const sent = await (msg.channel as any).send(
        buildOutboundPayload('⚠️ Git broker internal error. Check the operator view.', msg.id),
      )
      noteSent(sent.id)
    } catch {}
  } finally {
    if (repoLease && !repoLease.release()) {
      process.stderr.write('codex-bridge: physical repository Git lease ownership changed before release\n')
      updateRuntime({ last_error: 'repo-lease:release' })
      eventLog.emit('daemon.error', { error_kind: 'repo-lease-release' })
      if (!shuttingDown) void shutdown(1)
    }
    try { rmSync(tempDir, { recursive: true, force: true }) } catch {}
    if (activeTurnAbort === abort) activeTurnAbort = null
    updateRuntime({
      child_pid: null,
      turn_started_at: null,
      last_completed_at: new Date().toISOString(),
    })
    if (shuttingDown) await notifyShutdownDrop(msg, 'active-git')
    else try { retryNotices.remove(msg.id) } catch {}
  }
}

async function handleInbound(
  msg: Message,
  rotationAttempt = 0,
  durableParkedReplay = false,
): Promise<void> {
  try {
    validatePrivateStateBoundary(STATE_DIR, false)
    verifyBaseRuntimeAccess(
      dedicatedRuntime.runtimeUser,
      userInfo().homedir,
      STATE_DIR,
      INBOX_DIR,
      TOOL_TMP_ROOT,
      TOOL_SHIM_DIR,
    )
  } catch (err) {
    process.stderr.write(`codex-bridge: state boundary changed; refusing inbound message: ${err}\n`)
    updateRuntime({ last_error: 'state:unsafe-boundary' })
    eventLog.emit('daemon.error', { error_kind: 'unsafe-state-boundary' })
    void shutdown(1)
    return
  }
  const gateChannelId = gateChannelIdFor(msg)

  // For DMs, gateChannelId is the DM channel id (≠ user id) — the pairing
  // entry carries it so the approval confirmation can be delivered. Same
  // convention as the plugin.
  const meta: InboundMeta = {
    senderId: msg.author.id,
    isDM: msg.channel.type === ChannelType.DM,
    gateChannelId,
    isMentioned: () => isMentioned(msg, store.load().mentionPatterns),
  }
  const result = await gate(meta, {
    store,
    boundChannels: BOUND_CHANNELS,
    canonicalAccessFile: CANONICAL_ACCESS_FILE,
  })

  if (result.action === 'drop') {
    process.stderr.write(`codex-bridge: DROP ${result.reason} (sender ${msg.author.id})\n`)
    if (durableParkedReplay) try { parkedTurns.remove(msg.id) } catch {}
    return
  }

  if (result.action === 'pair') {
    if (durableParkedReplay) try { parkedTurns.remove(msg.id) } catch {}
    try {
      await msg.reply(buildPairingPayload(STATE_DIR, result.code, result.isResend))
    } catch (err) {
      process.stderr.write(`codex-bridge: failed to send pairing code: ${err}\n`)
    }
    return
  }

  const gitControl = parseGitControlMessage(msg.content, msg.attachments.size)
  if (gitControl.matched) {
    if (durableParkedReplay) try { parkedTurns.remove(msg.id) } catch {}
    const canonicalOperator = !CANONICAL_ACCESS_FILE
      || result.canonicalAccess?.allowFrom.includes(msg.author.id) === true
    const isTopLevelOperator = result.access.allowFrom.includes(msg.author.id) && canonicalOperator
    if (!isTopLevelOperator) {
      process.stderr.write(`codex-bridge: DROP Git control from non-operator ${msg.author.id}\n`)
      eventLog.emit('git.rejected', { error_kind: 'operator-authorization' })
      return
    }
    if (!gitControl.command) {
      process.stderr.write(`codex-bridge: DROP invalid Git control (${gitControl.error ?? 'invalid'})\n`)
      eventLog.emit('git.rejected', { error_kind: 'invalid-control' })
      try {
        await (msg.channel as any).send(buildOutboundPayload(
          '⚠️ Invalid Git control. Use the exact branch, commit, or retire form from the Codex preamble.',
          msg.id,
        ))
      } catch {}
      return
    }
    if (!canAcceptGitControl(turnQueue.snapshot.size)) {
      eventLog.emit('git.rejected', { error_kind: 'turn-queue-busy' })
      try {
        await (msg.channel as any).send(buildOutboundPayload(
          '⚠️ Git broker is available only while the Codex turn queue is completely idle.',
          msg.id,
        ))
      } catch {}
      return
    }
    if (shuttingDown) {
      await notifyShutdownDrop(msg, 'git')
      return
    }
    const allowedChanges = gitControl.command.action === 'commit'
      && latestTurnCapability?.chatId === msg.channelId
      ? latestTurnCapability.changes
      : undefined
    try { retryNotices.register(msg.channelId, msg.id, 'git', retryAuthorizationMetadata(msg)) } catch (err) {
      eventLog.emit('git.rejected', { error_kind: 'retry-ledger-unavailable' })
      try {
        await (msg.channel as any).send(buildOutboundPayload(
          '⚠️ Git control could not be durably accepted; retry after operator repair.',
          msg.id,
        ))
      } catch {}
      return
    }
    const accepted = turnQueue.tryEnqueue(
      async () => {
        if (!await reauthorizeQueuedMessage(msg, gateChannelId, 'git', true)) return
        if (shuttingDown) return notifyShutdownDrop(msg, 'git')
        return runGitControl(msg, gitControl.command!, allowedChanges)
      },
      () => notifyShutdownDrop(msg, 'git'),
    )
    if (!accepted) {
      try { retryNotices.remove(msg.id) } catch {}
      if (shuttingDown) await notifyShutdownDrop(msg, 'git')
      else {
        eventLog.emit('git.rejected', { error_kind: 'turn-queue-race' })
        try {
          await (msg.channel as any).send(buildOutboundPayload(
            '⚠️ Git broker became busy; retry only after the active turn completes.',
            msg.id,
          ))
        } catch {}
      }
      return
    }
    eventLog.emit('git.queued', {
      chat_id: msg.channelId,
      message_id: msg.id,
      action: gitControl.command.action,
    })
    return
  }

  if (appServerManager && managerPoolParked
    && managerParkedUntilMs !== null && Date.now() < managerParkedUntilMs) {
    const nextAttempt = Math.max(1, rotationAttempt)
    if (persistParkedTurn(msg, managerParkedUntilMs, nextAttempt)) {
      const current = parkedTurns.list().find(entry => entry.message_id === msg.id)
      if (current) scheduleParkedTurn(current)
      await announcePoolParked(managerParkedUntilMs, msg)
      eventLog.emit('rotation.exhausted', {
        chat_id: msg.channelId,
        message_id: msg.id,
        next_profile: null,
        reason: 'parked-admission',
        parked_until_ms: managerParkedUntilMs,
        attempt: nextAttempt,
      })
    } else if (!shuttingDown) {
      try {
        await (msg.channel as any).send(buildOutboundPayload(
          '⚠️ Codex pool is parked, but the task could not be durably queued; operator repair is required.',
          msg.id,
        ))
      } catch {}
    }
    return
  }

  // Ack reaction — "seen". Fire-and-forget.
  if (result.access.ackReaction) void msg.react(result.access.ackReaction).catch(() => {})

  // Record metadata now; bytes are downloaded only after this message owns the
  // serialized turn slot, immediately before Codex starts.
  const atts: string[] = []
  const attachments = [...msg.attachments.values()]
  // Reject before reserving a turn. The enqueue check below handles capacity
  // changes during reference/metadata preprocessing.
  const admission = assessInboundBudget(
    turnQueue.snapshot.size,
    turnQueue.capacity,
    attachments.map(att => att.size),
  )
  if (!admission.ok) {
    const queueFull = admission.reason === 'queue-full'
    process.stderr.write(
      `codex-bridge: DROP ${queueFull ? 'turn queue full' : 'attachment budget exceeded'} (sender ${msg.author.id})\n`,
    )
    try {
      await (msg.channel as any).send(buildOutboundPayload(queueFull
        ? '⚠️ codex-bridge queue is full; try again later'
        : `⚠️ attachment limit exceeded (max ${MAX_ATTACHMENTS_PER_MESSAGE} files / ${MAX_MESSAGE_ATTACHMENT_BYTES / 1024 / 1024}MB total)`))
    } catch {}
    return
  }

  for (const att of attachments) {
    const kb = (att.size / 1024).toFixed(0)
    atts.push(`${safeAttName(att)} (${att.contentType ?? 'unknown'}, ${kb}KB)`)
  }

  if (shuttingDown) {
    await notifyShutdownDrop(msg, 'turn')
    return
  }

  const forwarded = forwardedContent(msg, await resolveForwardChannel(msg))
  const content = [msg.content, forwarded].filter(Boolean).join('\n\n')

  if (turnQueue.snapshot.size > 0 && 'react' in msg) void msg.react('⏳').catch(() => {})
  try { retryNotices.register(msg.channelId, msg.id, 'turn', retryAuthorizationMetadata(msg)) } catch (err) {
    eventLog.emit('turn.error', { chat_id: msg.channelId, error_kind: 'retry-ledger-unavailable' })
    try {
      await (msg.channel as any).send(buildOutboundPayload(
        '⚠️ codex-bridge could not durably accept this turn; retry after operator repair.',
        msg.id,
      ))
    } catch {}
    return
  }
  const accepted = turnQueue.tryEnqueue(
    async () => {
      if (!await reauthorizeQueuedMessage(msg, gateChannelId, 'turn')) return
      if (shuttingDown) return notifyShutdownDrop(msg, 'turn')
      return runTurn(
        msg,
        content,
        attachments,
        atts,
        trustedChannelRole(BRIDGE_IDENTITY, gateChannelId),
        rotationAttempt,
      )
    },
    () => notifyShutdownDrop(msg, 'turn'),
  )
  if (!accepted) {
    try { retryNotices.remove(msg.id) } catch {}
    process.stderr.write(`codex-bridge: DROP turn queue full (sender ${msg.author.id})\n`)
    if (shuttingDown) await notifyShutdownDrop(msg, 'turn')
    else try {
      await (msg.channel as any).send(
        buildOutboundPayload('⚠️ codex-bridge queue is full; try again later'),
      )
    } catch {}
    return
  }
  eventLog.emit('turn.queued', {
    chat_id: msg.channelId,
    message_id: msg.id,
  })
  if (durableParkedReplay) parkedReplayAccepted.add(msg.id)
}

client.on('messageCreate', msg => {
  if (msg.author.bot && msg.author.id === msg.client.user?.id) return // ignore own messages
  if (msg.author.bot && !msg.mentions.has(msg.client.user!)) return // ignore bot msgs that don't @mention us
  if (shuttingDown) return
  try { retryNotices.register(msg.channelId, msg.id, 'inbound', retryAuthorizationMetadata(msg)) } catch (err) {
    process.stderr.write(`codex-bridge: DROP retry ledger unavailable (sender ${msg.author.id}): ${err}\n`)
    void msg.reply(buildOutboundPayload(
      '⚠️ codex-bridge cannot durably accept messages; retry after operator repair.',
    )).catch(() => {})
    return
  }
  if (!inboundQueue.tryEnqueue(
    async () => {
      try { await handleInbound(msg) } finally {
        try { retryNotices.removeIfKind(msg.id, 'inbound') } catch {}
      }
    },
    () => notifyShutdownDrop(msg, 'inbound'),
  )) {
    try { retryNotices.remove(msg.id) } catch {}
    process.stderr.write(`codex-bridge: DROP inbound queue full (sender ${msg.author.id})\n`)
    void msg.reply(buildOutboundPayload('⚠️ codex-bridge is overloaded; try again later'))
      .catch(() => {})
  }
})

client.on('error', err => {
  process.stderr.write(`codex-bridge: client error: ${err}\n`)
  updateRuntime({ last_error: 'discord:client' })
  eventLog.emit('daemon.error', { error_kind: 'discord-client' })
})

const managerLivenessMonitor = new ManagerLivenessMonitor()
let managerRuntimeAvailable = true

function recordGatewayLifecycle(
  kind: Parameters<typeof gatewayRuntimePatch>[0],
): void {
  if (shuttingDown) {
    updateRuntime({ ready: false })
    return
  }
  const gatewayPatch = gatewayRuntimePatch(kind, client.isReady())
  const patch = gatewayPatch.ready && !managerRuntimeAvailable
    ? { ...gatewayPatch, ready: false }
    : gatewayPatch
  updateRuntime(patch)
  eventLog.emit(`discord.${kind}`, {
    status: patch.ready ? 'ready' : 'not-ready',
    error_kind: patch.last_error ?? null,
  })
}

client.on('shardDisconnect', () => recordGatewayLifecycle('shard-disconnect'))
client.on('invalidated', () => recordGatewayLifecycle('invalidated'))
client.on('shardReady', () => {
  recordGatewayLifecycle('shard-ready')
  void scheduleRetryReplay()
  scheduleParkedTurnReplays()
})
client.on('shardResume', () => {
  recordGatewayLifecycle('shard-resume')
  void scheduleRetryReplay()
  scheduleParkedTurnReplays()
})

client.once('clientReady', c => {
  recordGatewayLifecycle('ready')
  eventLog.emit('daemon.ready', { pid: process.pid })
  process.stderr.write(
    `codex-bridge: gateway connected as ${c.user.tag} (cwd ${codexCfg.cwd}, permissions ${CODEX_PERMISSION_PROFILE}${BOUND_CHANNELS.length ? `, bound [${BOUND_CHANNELS.join(', ')}]` : ''})\n`,
  )
  void scheduleRetryReplay()
  scheduleParkedTurnReplays()
  if (managerPoolParked && managerParkedUntilMs !== null) {
    void announcePoolParked(managerParkedUntilMs)
  }
})

let managerHeartbeatInFlight = false
const heartbeat = setInterval(() => {
  // Event notifications are primary; deriving readiness here prevents a
  // missed/changed gateway event from leaving a stale healthy heartbeat.
  updateRuntime({ ready: client.isReady() && managerRuntimeAvailable })
  if (appServerManager && !appServerManager.hasActiveLease && !managerHeartbeatInFlight && !shuttingDown) {
    managerHeartbeatInFlight = true
    void appServerManager.liveness().then(liveness => {
      if (shuttingDown) return
      // Another registered swarm may own the global serialized turn/cleanup
      // slot for arbitrarily longer than one heartbeat. That is healthy. A
      // drain/resume transition is also nonfatal, but readiness remains false
      // and one continuous fixed deadline covers both maintenance phases.
      managerRuntimeAvailable = managerLivenessMonitor.observe(liveness)
      updateRuntime({ ready: client.isReady() && managerRuntimeAvailable })
    }).catch(err => {
      if (shuttingDown) return
      process.stderr.write(`codex-bridge: manager heartbeat failed: ${err}\n`)
      managerRuntimeAvailable = false
      updateRuntime({ ready: false, last_error: 'app-server:health' })
      eventLog.emit('daemon.error', { error_kind: 'app-server-health' })
      if (!shuttingDown) void shutdown(1)
    }).finally(() => { managerHeartbeatInFlight = false })
  }
}, 5000)
heartbeat.unref()

async function shutdown(exitCode = 0): Promise<void> {
  if (shuttingDown) return
  shuttingDown = true
  process.stderr.write('codex-bridge: shutting down\n')
  clearInterval(heartbeat)
  eventLog.emit('daemon.shutdown')
  updateRuntime({ ready: false })
  inboundQueue.close()
  turnQueue.close()
  activeTurnAbort?.abort()

  const forcedExit = setTimeout(() => {
    try {
      updateRuntime({
        ready: false,
        active: false,
        queue_depth: 0,
        child_pid: null,
        turn_started_at: null,
        last_error: 'shutdown:forced',
      })
    } finally {
      releaseDaemonLock()
      process.exit(1)
    }
  }, 10_000)
  forcedExit.unref?.()

  try {
    // Retry notices are persisted at admission. Keep the client alive while
    // best-effort immediate sends drain; a forced exit leaves durable replay.
    await inboundQueue.drain()
    await turnQueue.drain()
    let finalExitCode = exitCode
    if (appServerManager) {
      try {
        await appServerManager.unregister()
      } catch (err) {
        finalExitCode = 1
        process.stderr.write(`codex-bridge: manager unregister failed: ${err}\n`)
        updateRuntime({ last_error: 'app-server:unregister' })
        eventLog.emit('daemon.error', { error_kind: 'app-server-unregister' })
      } finally {
        appServerManager.close()
        appServerManager = null
      }
    }
    client.destroy()
    updateRuntime({
      ready: false,
      active: false,
      queue_depth: 0,
      child_pid: null,
      turn_started_at: null,
    })
    clearTimeout(forcedExit)
    releaseDaemonLock()
    process.exit(finalExitCode)
  } catch (err) {
    process.stderr.write(`codex-bridge: shutdown failed: ${err}\n`)
    updateRuntime({ last_error: 'shutdown:error' })
    clearTimeout(forcedExit)
    releaseDaemonLock()
    process.exit(1)
  }
}
process.on('SIGTERM', () => { void shutdown() })
process.on('SIGINT', () => { void shutdown() })
process.on('SIGHUP', () => { void shutdown() })

client.login(TOKEN).catch(err => {
  process.stderr.write(`codex-bridge: login failed: ${err}\n`)
  updateRuntime({ ready: false, last_error: 'discord:login' })
  eventLog.emit('daemon.error', { error_kind: 'discord-login' })
  void shutdown(1)
})
