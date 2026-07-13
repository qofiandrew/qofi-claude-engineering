import { afterEach, describe, expect, test } from 'bun:test'
import { createHash } from 'crypto'
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { request as httpRequest } from 'http'
import { EventEmitter } from 'events'
import type { Socket } from 'net'
import { join } from 'path'
import { PassThrough } from 'stream'
import type { ChildProcessWithoutNullStreams } from 'child_process'
import WebSocket, { type RawData } from 'ws'
import type {
  AppServerEffectiveThread,
  AppServerThreadResumeParams,
  AppServerThreadStartParams,
  AppServerTurnHandle,
  AppServerTurnResult,
  AppServerTurnStartParams,
} from './app-server-client.ts'
import { AppServerProtocolError, AppServerRemoteError } from './app-server-client.ts'
import {
  APP_SERVER_MANAGER_SCHEMA,
  AppServerManager,
  FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA,
  FABLE_REVIEWER_SCOPE_SCHEMA,
  MANAGER_MAX_TURN_BODY_BYTES,
  MANAGER_MAX_TURN_PROMPT_BYTES,
  managerInitializationFailure,
  type ManagerClient,
  type ManagerGeneration,
  type ManagerGenerationExit,
  type ManagerGenerationFactory,
} from './app-server-manager.ts'
import {
  QOFI_CODEX_REVIEW_DISABLED_FEATURES,
  QOFI_CODEX_REVIEW_MODEL,
  QOFI_CODEX_REVIEW_REASONING_EFFORT,
  QOFI_CODEX_RUNNER,
  qofiCodexReviewArgs,
  spawnFixedReviewRunner,
  type AppServerRunnerSpawn,
  type FixedReviewRunnerResult,
} from './app-server-stdio-transport.ts'

const roots: string[] = []
const managers: AppServerManager[] = []

afterEach(async () => {
  for (const manager of managers.splice(0)) {
    try {
      if (manager.health().phase === 'idle') await manager.drain()
      if (manager.health().phase === 'drained') await manager.shutdown()
    } catch {}
  }
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('AppServerManager per-swarm profile rotation', () => {
  test('releases only persisted leases whose swarm row was permanently removed', async () => {
    const f = fixture()
    f.writeProfileCatalog({
      schema: 'qofi-codex-profiles/v1',
      profiles: [
        { label: 'default', shared: false },
        { label: 'max_b', shared: false },
      ],
      pools: {
        default: { profiles: ['default'] },
        rotating: { profiles: ['default', 'max_b'] },
      },
    })
    f.writeConfig('codex', 'rotating')
    const rotationPath = join(f.managerState, 'profile-rotation-state.json')
    writeFileSync(rotationPath, JSON.stringify({
      schema: 'qofi-codex-profile-rotation/v1',
      swarms: {
        removed: { activeProfile: 'default', cooldowns: {}, telemetry: {} },
        alpha: { activeProfile: 'max_b', cooldowns: {}, telemetry: {} },
      },
    }) + '\n', { mode: 0o600 })
    chmodSync(rotationPath, 0o600)

    const manager = await AppServerManager.start({
      stateDir: f.managerState,
      swarmHome: f.swarmHome,
      operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    expect(registered.activeProfile).toBe('max_b')
    expect(registered.thresholdPercent).toBe(95)
    const persisted = JSON.parse(readFileSync(rotationPath, 'utf8'))
    expect(Object.keys(persisted.swarms)).toEqual(['alpha'])
  })

  test('reconciles a dormant unregistered lease before allocation without manager restart', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    f.writeProfileCatalog({
      schema: 'qofi-codex-profiles/v1',
      profiles: [{ label: 'default', shared: false }],
      pools: { default: { profiles: ['default'] } },
    })
    const manager = await AppServerManager.start({
      stateDir: f.managerState,
      swarmHome: f.swarmHome,
      operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)

    const alpha = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    expect(alpha.activeProfile).toBe('default')
    await manager.unregister({ registrationToken: alpha.registrationToken })

    const registeredBeta = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })
    expect(registeredBeta.activeProfile).toBeNull()

    // The daemon is already normally unregistered; removing its row must make
    // the dormant exclusive lease disappear at Beta's next allocation boundary.
    writeFileSync(join(f.swarmHome, 'swarm.conf'),
      `${beta.swarm} | ${beta.repo} | BOT_BETA | 3 | 4 | | codex\n`, { mode: 0o600 })
    chmodSync(join(f.swarmHome, 'swarm.conf'), 0o600)
    const reservation = await manager.reserveTurn({
      registrationToken: registeredBeta.registrationToken,
      requestId: 'beta-after-alpha-removal',
    })
    expect(reservation.profile).toBe('default')
    const persisted = JSON.parse(readFileSync(
      join(f.managerState, 'profile-rotation-state.json'),
      'utf8',
    ))
    expect(Object.keys(persisted.swarms)).toEqual(['beta'])
    expect(persisted.swarms.beta.activeProfile).toBe('default')
    await manager.cancelTurnReservation({
      registrationToken: registeredBeta.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
    })
  })

  test('reports an already exhausted pool as a structured parked admission boundary', async () => {
    const f = fixture()
    const parkedUntilMs = Date.now() + 60_000
    const rotationPath = join(f.managerState, 'profile-rotation-state.json')
    writeFileSync(rotationPath, JSON.stringify({
      schema: 'qofi-codex-profile-rotation/v1',
      swarms: {
        alpha: {
          activeProfile: null,
          cooldowns: { default: parkedUntilMs },
          telemetry: {},
        },
      },
    }) + '\n', { mode: 0o600 })
    chmodSync(rotationPath, 0o600)
    const manager = await AppServerManager.start({
      stateDir: f.managerState,
      swarmHome: f.swarmHome,
      operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    expect(registered).toMatchObject({ activeProfile: null, parkedUntilMs })
    const response = await postJson(f.controlSocketPath, '/v1/turn/reserve', {
      registrationToken: registered.registrationToken,
      requestId: 'parked-admission',
    })
    expect(response).toEqual({
      status: 409,
      body: {
        error: 'Codex auth pool exhausted',
        phase: 'idle',
        retryable: true,
        parkedUntilMs,
      },
    })
  })

  test('applies a fresh soft breach only after cleanup and respawns on the selected home', async () => {
    const f = fixture()
    f.writeProfileCatalog({
      schema: 'qofi-codex-profiles/v1',
      profiles: [
        { label: 'default', shared: false },
        { label: 'max_b', shared: false },
      ],
      pools: {
        default: { profiles: ['default'], thresholdPercent: 85 },
        rotating: { profiles: ['default', 'max_b'], thresholdPercent: 85 },
      },
    })
    f.writeConfig('codex', 'rotating')
    const now = Date.now()
    const manager = await AppServerManager.start({
      stateDir: f.managerState,
      swarmHome: f.swarmHome,
      operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath,
      generationFactory: f.generationFactory,
      profileTelemetryReader: async profile => profile === 'default' ? {
        status: 'fresh', observedAtMs: now, physicalLine: 1,
        fiveHour: { windowMinutes: 300, usedPercent: 86, resetsAtMs: now + 60_000 },
        weekly: { windowMinutes: 10_080, usedPercent: 20, resetsAtMs: now + 600_000 },
      } : { status: 'unknown', reason: 'no_token_count', observedAtMs: null, physicalLine: null },
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    expect(registered).toMatchObject({ activeProfile: 'default', pool: 'rotating', thresholdPercent: 85 })
    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'soft-rotate',
    })
    expect(reservation.profile).toBe('default')
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'rotate at boundary',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    f.clients.at(-1)!.turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(terminal.rotation).toEqual({
      reason: 'soft', previousProfile: 'default', activeProfile: 'max_b', parkedUntilMs: null,
    })
    // The active registration is still bound to the completed generation until
    // the daemon proves its own ACL/session cleanup.
    expect(f.generationProfiles.at(-1)).toBe('default')
    const cleanup = await manager.cleanupComplete({
      registrationToken: registered.registrationToken, leaseId: terminal.leaseId, ok: true,
    })
    expect(cleanup).toMatchObject({ activeProfile: 'max_b', parkedUntilMs: null })
    expect(f.generationProfiles.at(-1)).toBe('max_b')
    const state = JSON.parse(readFileSync(join(f.stateDir, 'rotation-state.json'), 'utf8'))
    expect(state.active_profile).toBe('max_b')
    expect(state.profiles.find((profile: any) => profile.label === 'default').cooldown_until_ms)
      .toBeGreaterThan(now)
  })

  test('turn/start HTTP 429 is a definitive hard trigger with cleanup-bound rotation', async () => {
    const f = fixture()
    f.writeProfileCatalog({
      schema: 'qofi-codex-profiles/v1',
      profiles: [{ label: 'default' }, { label: 'max_b' }],
      pools: {
        default: { profiles: ['default'] },
        rotating: { profiles: ['default', 'max_b'], thresholdPercent: 85 },
      },
    })
    f.writeConfig('codex', 'rotating')
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome,
      operatorHome: f.operatorHome, controlSocketPath: f.controlSocketPath,
      generationFactory: f.generationFactory,
      profileTelemetryReader: async () => ({
        status: 'unknown', reason: 'rate_limits_null', observedAtMs: Date.now(), physicalLine: 1,
      }),
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'hard-429',
    })
    f.clients.at(-1)!.nextTurnStartError = new AppServerRemoteError(429, 'provider rejected', {
      codexErrorInfo: { httpConnectionFailed: { httpStatusCode: 429 } },
    })
    const terminal = await manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'hard retry',
    })
    expect(terminal.result).toMatchObject({ ok: false, quotaLimited: true, ambiguous: false })
    expect(terminal.rotation).toMatchObject({
      reason: 'hard', previousProfile: 'default', activeProfile: 'max_b',
    })
    expect(manager.health().phase).toBe('terminal-cleanup-pending')
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken, leaseId: terminal.leaseId, ok: true,
    })).toMatchObject({ activeProfile: 'max_b' })
  })
})

type Deferred<T> = { promise: Promise<T>; resolve: (value: T) => void; reject: (error: unknown) => void }
function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail })
  return { promise, resolve, reject }
}

function reviewResult(overrides: Partial<FixedReviewRunnerResult> = {}): FixedReviewRunnerResult {
  return {
    code: 0, signal: null, stdout: 'reviewed\n', stderr: '',
    timedOut: false, outputExceeded: false, inputFailed: false,
    ...overrides,
  }
}

function fakeReviewChild() {
  const child = new EventEmitter() as ChildProcessWithoutNullStreams & {
    kills: NodeJS.Signals[]
    input: string
  }
  child.stdin = new PassThrough()
  child.stdout = new PassThrough()
  child.stderr = new PassThrough()
  child.kills = []
  child.input = ''
  child.stdin.on('data', chunk => { child.input += chunk.toString('utf8') })
  child.kill = ((signal?: NodeJS.Signals) => {
    child.kills.push(signal ?? 'SIGTERM')
    return true
  }) as typeof child.kill
  return child
}

class FakeManagerClient implements ManagerClient {
  readonly turns: Array<{
    params: AppServerTurnStartParams
    completion: Deferred<AppServerTurnResult>
    handle: AppServerTurnHandle
  }> = []
  readonly interrupts: Array<{ threadId: string; turnId: string }> = []
  readonly effectiveParams: Array<AppServerThreadStartParams | AppServerThreadResumeParams> = []
  readonly reads: Array<{ threadId: string; includeTurns: boolean }> = []
  readonly turnStarted = deferred<void>()
  nextThread = 1
  nextStartError: Error | null = null
  nextTurnStartError: Error | null = null
  nextResumeError: Error | null = null
  nextReadError: Error | null = null
  readCwdOverride: string | null = null
  effectiveReasoningEffortOverride: string | null | undefined = undefined
  closed = false

  constructor(
    readonly readCwd = '/private/runtime',
    readonly threadCwds = new Map<string, string>(),
  ) {}

  async startThreadEffective(params: AppServerThreadStartParams): Promise<AppServerEffectiveThread> {
    this.effectiveParams.push(params)
    if (this.nextStartError) {
      const error = this.nextStartError
      this.nextStartError = null
      throw error
    }
    const threadId = `thread-${this.nextThread++}`
    if (typeof params.cwd === 'string') this.threadCwds.set(threadId, params.cwd)
    return this.effective(threadId, params)
  }

  async resumeThreadEffective(params: AppServerThreadResumeParams): Promise<AppServerEffectiveThread> {
    this.effectiveParams.push(params)
    if (this.nextResumeError) {
      const error = this.nextResumeError
      this.nextResumeError = null
      throw error
    }
    if (typeof params.cwd === 'string') this.threadCwds.set(params.threadId, params.cwd)
    return this.effective(params.threadId, params)
  }

  async readThread(threadId: string, includeTurns = true) {
    this.reads.push({ threadId, includeTurns })
    if (this.nextReadError) {
      const error = this.nextReadError
      this.nextReadError = null
      throw error
    }
    return {
      id: threadId, cwd: this.readCwdOverride ?? this.threadCwds.get(threadId) ?? this.readCwd,
      turns: [], preview: `history:${threadId}`,
    }
  }

  async startTurn(params: AppServerTurnStartParams): Promise<AppServerTurnHandle> {
    if (this.nextTurnStartError) {
      const error = this.nextTurnStartError
      this.nextTurnStartError = null
      throw error
    }
    const completion = deferred<AppServerTurnResult>()
    const handle = {
      threadId: params.threadId,
      turnId: `turn-${this.turns.length + 1}`,
      completion: completion.promise,
    }
    this.turns.push({ params, completion, handle })
    this.turnStarted.resolve(undefined)
    return handle
  }

  async interrupt(threadId: string, turnId: string): Promise<void> {
    this.interrupts.push({ threadId, turnId })
  }

  close(): void {
    this.closed = true
    for (const turn of this.turns) {
      turn.completion.resolve({
        ok: false,
        threadId: turn.handle.threadId,
        turnId: turn.handle.turnId,
        status: 'disconnected',
        messages: [],
        error: 'upstream stopped',
        ambiguous: true,
      })
    }
  }

  private effective(
    id: string,
    params: AppServerThreadStartParams | AppServerThreadResumeParams,
  ): AppServerEffectiveThread {
    const review = params.permissions === 'qofi-review-readonly'
    const cwd = params.cwd ?? '/private/runtime'
    const filesystem = (params.config as any)?.permissions?.['qofi-workspace-only']?.filesystem
    const configuredEffort = (params.config as any)?.model_reasoning_effort
    const writableRoots = filesystem && typeof filesystem === 'object'
      ? Object.entries(filesystem)
        .filter(([, access]) => access === 'write')
        .map(([path]) => path)
      : []
    return {
      thread: {
        id, cwd, turns: [], preview: '', parentThreadId: null,
      },
      model: params.model ?? 'gpt-test',
      modelProvider: 'openai',
      cwd,
      approvalPolicy: 'never',
      approvalsReviewer: 'user',
      reasoningEffort: this.effectiveReasoningEffortOverride !== undefined
        ? this.effectiveReasoningEffortOverride
        : (typeof configuredEffort === 'string' ? configuredEffort : null),
      sandbox: review
        ? { type: 'readOnly', networkAccess: false }
        : {
          type: 'workspaceWrite', networkAccess: false,
          writableRoots, excludeTmpdirEnvVar: true, excludeSlashTmp: true,
        },
      activePermissionProfile: {
        id: review ? 'qofi-review-readonly' : 'qofi-workspace-only',
        extends: review ? ':read-only' : ':workspace',
      },
      runtimeWorkspaceRoots: review ? [] : [cwd],
    }
  }
}

function fixture() {
  const root = realpathSync(mkdtempSync(join(process.env.HOME!, '.qm-')))
  roots.push(root)
  chmodSync(root, 0o700)
  const operatorHome = join(root, 'home')
  const channels = join(operatorHome, '.codex', 'channels')
  const stateDir = join(channels, 'discord-alpha')
  const managerState = join(channels, 'app-server-manager')
  const swarmHome = join(root, 'swarm')
  const repo = join(root, 'repos', 'alpha')
  for (const path of [operatorHome, join(operatorHome, '.codex'), channels, stateDir, managerState, swarmHome, dirname(repo), repo]) {
    mkdirSync(path, { recursive: true, mode: 0o700 })
    chmodSync(path, 0o700)
  }
  const writeSessions = (threadIds: string[]) => {
    writeFileSync(join(stateDir, 'sessions.json'), JSON.stringify({
      schema: 'codex-bridge-sessions/v1',
      entries: threadIds.map((thread_id, index) => ({ chat_id: `chat-${index}`, thread_id })),
    }) + '\n', { mode: 0o600 })
    chmodSync(join(stateDir, 'sessions.json'), 0o600)
  }
  writeSessions([])
  const writeConfig = (engine = 'codex', pool = '') => {
    writeFileSync(join(swarmHome, 'swarm.conf'), `alpha | ${repo} | BOT_ALPHA | 1 | 2 | | ${engine} | ${pool}\n`, { mode: 0o600 })
    chmodSync(join(swarmHome, 'swarm.conf'), 0o600)
  }
  const writeProfileCatalog = (value: unknown) => {
    writeFileSync(join(swarmHome, 'codex-profiles.json'), JSON.stringify(value) + '\n', { mode: 0o600 })
    chmodSync(join(swarmHome, 'codex-profiles.json'), 0o600)
  }
  const writeReviewerConfig = (value: unknown = {
    schema: 'qofi-fable-reviewer/v1',
    defaults: {
      authLane: 'device', maxCallsPerTask: 1, maxCallsPerWindow: 12,
      windowSeconds: 3600, timeoutSeconds: 180, failurePolicy: 'review-pending',
    },
    swarms: {},
  }) => {
    writeFileSync(join(swarmHome, 'fable-reviewer.json'), JSON.stringify(value) + '\n', { mode: 0o600 })
    chmodSync(join(swarmHome, 'fable-reviewer.json'), 0o600)
  }
  writeConfig()
  writeReviewerConfig()
  const clients: FakeManagerClient[] = []
  const threadCwds = new Map<string, string>()
  const stops: number[] = []
  const exits: Array<Deferred<ManagerGenerationExit>> = []
  const factoryErrors: Error[] = []
  const immediateExits: ManagerGenerationExit[] = []
  const delayedStopExits = new Set<number>()
  const factoryGates: Array<{ entered: Deferred<void>; release: Deferred<void> }> = []
  const reviewExecutions: Array<{
    prompt: string
    completion: Deferred<FixedReviewRunnerResult>
    stopCalls: number
  }> = []
  const reviewLaunchErrors: Error[] = []
  const completionReviewExecutions: Array<{
    request: Readonly<Record<string, unknown>>
    completion: Deferred<unknown>
    stopCalls: number
  }> = []
  const completionReviewLaunchErrors: Error[] = []
  let handlers: Parameters<ManagerGenerationFactory>[0] | null = null
  const handlerGenerations: Parameters<ManagerGenerationFactory>[0][] = []
  const generationProfiles: string[] = []
  const generationFactory: ManagerGenerationFactory = async (currentHandlers, profile) => {
    generationProfiles.push(profile ?? 'default')
    handlers = currentHandlers
    handlerGenerations.push(currentHandlers)
    const factoryGate = factoryGates.shift()
    if (factoryGate) {
      factoryGate.entered.resolve(undefined)
      await factoryGate.release.promise
    }
    const factoryError = factoryErrors.shift()
    if (factoryError) throw factoryError
    const generationIndex = clients.length
    const client = new FakeManagerClient(repo, threadCwds)
    clients.push(client)
    const exit = deferred<ManagerGenerationExit>()
    exits.push(exit)
    const generation: ManagerGeneration = {
      client,
      stop: async () => {
        stops.push(clients.length)
        client.close()
        if (!delayedStopExits.has(generationIndex)) exit.resolve({ code: 0, signal: null })
      },
      exited: exit.promise,
    }
    const immediateExit = immediateExits.shift()
    if (immediateExit) {
      const status = immediateExit
      queueMicrotask(() => exit.resolve(status))
    }
    return generation
  }
  const reviewRunner = (prompt: string) => {
    const launchError = reviewLaunchErrors.shift()
    if (launchError) throw launchError
    const completion = deferred<FixedReviewRunnerResult>()
    const record = { prompt, completion, stopCalls: 0 }
    reviewExecutions.push(record)
    return {
      completed: completion.promise,
      stopAndWait: async () => {
        record.stopCalls += 1
        completion.resolve(reviewResult({ code: null, signal: 'SIGTERM' }))
        await completion.promise
      },
    }
  }
  const completionReviewRunner = (request: Readonly<Record<string, unknown>>) => {
    const launchError = completionReviewLaunchErrors.shift()
    if (launchError) throw launchError
    const completion = deferred<unknown>()
    const record = { request, completion, stopCalls: 0 }
    completionReviewExecutions.push(record)
    return {
      completed: completion.promise,
      stopAndWait: async () => {
        record.stopCalls += 1
        completion.reject(new Error('completion review stopped'))
        await completion.promise.catch(() => undefined)
      },
    }
  }
  return {
    root, operatorHome, stateDir, managerState, swarmHome, repo,
    controlSocketPath: join(managerState, 'control.sock'),
    writeSessions, writeConfig, writeProfileCatalog, writeReviewerConfig,
    clients, stops, exits, generationFactory,
    generationProfiles,
    reviewRunner, reviewExecutions, completionReviewRunner, completionReviewExecutions,
    failNextCompletionReviewLaunch: (error: Error) => { completionReviewLaunchErrors.push(error) },
    failNextReviewLaunch: (error: Error) => { reviewLaunchErrors.push(error) },
    failNextGeneration: (error: Error) => { factoryErrors.push(error) },
    exitNextGenerationImmediately: (status: ManagerGenerationExit) => { immediateExits.push(status) },
    delayStopExit: (index: number) => { delayedStopExits.add(index) },
    blockNextGeneration: () => {
      const gate = { entered: deferred<void>(), release: deferred<void>() }
      factoryGates.push(gate)
      return gate
    },
    exitGeneration: (index: number, status: ManagerGenerationExit) => exits[index].resolve(status),
    notification: (value: any) => handlers?.onNotification(value),
    protocolErrorGeneration: (index: number, error: Error) => handlerGenerations[index]?.onProtocolError(error),
  }
}

function addSecondSwarm(f: ReturnType<typeof fixture>) {
  const swarm = 'beta'
  const stateDir = join(f.operatorHome, '.codex', 'channels', `discord-${swarm}`)
  const repo = join(f.root, 'repos', swarm)
  for (const path of [stateDir, repo]) {
    mkdirSync(path, { recursive: true, mode: 0o700 })
    chmodSync(path, 0o700)
  }
  writeFileSync(join(stateDir, 'sessions.json'), JSON.stringify({
    schema: 'codex-bridge-sessions/v1', entries: [],
  }) + '\n', { mode: 0o600 })
  chmodSync(join(stateDir, 'sessions.json'), 0o600)
  writeFileSync(join(f.swarmHome, 'swarm.conf'), [
    `alpha | ${f.repo} | BOT_ALPHA | 1 | 2 | | codex`,
    `${swarm} | ${repo} | BOT_BETA | 3 | 4 | | codex`,
  ].join('\n') + '\n', { mode: 0o600 })
  chmodSync(join(f.swarmHome, 'swarm.conf'), 0o600)
  return { swarm, stateDir, repo }
}

function dirname(path: string): string {
  return path.slice(0, path.lastIndexOf('/'))
}

async function getJson(socketPath: string, path: string): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const request = httpRequest({ socketPath, path, method: 'GET' }, response => {
      const chunks: Buffer[] = []
      response.on('data', chunk => chunks.push(Buffer.from(chunk)))
      response.on('end', () => resolve({
        status: response.statusCode ?? 0,
        body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
      }))
    })
    request.on('error', reject)
    request.end()
  })
}

async function postJson(socketPath: string, path: string, value: unknown): Promise<{ status: number; body: any }> {
  const body = JSON.stringify(value)
  return new Promise((resolve, reject) => {
    const request = httpRequest({
      socketPath, path, method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': String(Buffer.byteLength(body)) },
    }, response => {
      const chunks: Buffer[] = []
      response.on('data', chunk => chunks.push(Buffer.from(chunk)))
      response.on('end', () => resolve({
        status: response.statusCode ?? 0,
        body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
      }))
    })
    request.on('error', reject)
    request.end(body)
  })
}

async function readFacadeConfig(facadeEndpoint: string, cwd: string): Promise<Record<string, unknown>> {
  const socketPath = facadeEndpoint.slice('unix://'.length)
  const socket = new WebSocket(`ws+unix://${socketPath}:/rpc`)
  await new Promise<void>((resolve, reject) => {
    socket.once('open', () => resolve())
    socket.once('error', reject)
  })
  const rpc = (id: string, method: string, params: Record<string, unknown> = {}) => {
    const response = new Promise<Record<string, any>>((resolve, reject) => {
      const onError = (error: Error) => {
        socket.off('message', onMessage)
        reject(error)
      }
      const onMessage = (data: RawData) => {
        socket.off('error', onError)
        try { resolve(JSON.parse(data.toString())) } catch (error) { reject(error) }
      }
      socket.once('message', onMessage)
      socket.once('error', onError)
    })
    socket.send(JSON.stringify({ id, method, params }))
    return response
  }
  try {
    await rpc('initialize', 'initialize')
    socket.send(JSON.stringify({ method: 'initialized' }))
    return (await rpc('config', 'config/read', { cwd })).result.config
  } finally {
    socket.terminate()
  }
}

async function reserveTurn(manager: AppServerManager, registrationToken: string, requestId: string) {
  return manager.reserveTurn({ registrationToken, requestId })
}

describe('AppServerManager lifecycle', () => {
  test('fixed review spawn uses only the exact tool-less root-runner capability', async () => {
    const child = fakeReviewChild()
    let observed: Parameters<AppServerRunnerSpawn> | null = null
    const execution = spawnFixedReviewRunner({
      parentPid: 4242,
      cwd: '/private/tmp',
      spawnProcess: ((...args) => { observed = args; return child }) as AppServerRunnerSpawn,
    }, 'bounded prompt')

    expect(observed?.[0]).toBe('/usr/bin/sudo')
    expect(observed?.[1]).toEqual([
      '-n', '--', QOFI_CODEX_RUNNER,
      '--mode', 'review', '--parent-pid', '4242', '--',
      ...qofiCodexReviewArgs('/private/tmp'),
    ])
    expect(observed?.[2].stdio).toEqual(['pipe', 'pipe', 'pipe'])
    expect(Object.keys(observed?.[2].env ?? {}).sort()).toEqual([
      'HOME', 'LANG', 'LC_ALL', 'LOGNAME', 'PATH', 'USER',
    ])
    expect(child.input).toBe('bounded prompt')
    const args = qofiCodexReviewArgs('/private/tmp')
    expect(args).not.toContain('--enable')
    for (const feature of QOFI_CODEX_REVIEW_DISABLED_FEATURES) {
      expect(args.join('\0')).toContain(`--disable\0${feature}`)
    }
    expect(args).toContain(`model="${QOFI_CODEX_REVIEW_MODEL}"`)
    expect(args).toContain(`model_reasoning_effort="${QOFI_CODEX_REVIEW_REASONING_EFFORT}"`)

    child.stdout.write('reviewed\n')
    child.emit('close', 0, null)
    expect(await execution.completed).toEqual(reviewResult())
  })

  test('fixed review process errors terminate and do not complete before supervisor reap', async () => {
    const child = fakeReviewChild()
    const execution = spawnFixedReviewRunner({
      parentPid: 4242, cwd: '/private/tmp', killGraceMs: 50, stopTimeoutMs: 100,
      spawnProcess: (() => child) as AppServerRunnerSpawn,
    }, 'prompt')
    let stopped = false
    child.emit('error', new Error('spawn failed after child creation'))
    const stopping = execution.stopAndWait().then(() => { stopped = true })
    await Promise.resolve()
    expect(stopped).toBe(false)
    expect(child.kills).toContain('SIGTERM')
    child.emit('close', null, null)
    await stopping
    expect(await execution.completed).toMatchObject({
      code: null, signal: null, inputFailed: true,
      stderr: 'spawn failed after child creation',
    })
  })

  test('fixed review timeout and output overflow terminate with bounded results', async () => {
    const timedChild = fakeReviewChild()
    const timed = spawnFixedReviewRunner({
      parentPid: 4242, cwd: '/private/tmp', timeoutMs: 10, killGraceMs: 50,
      spawnProcess: (() => timedChild) as AppServerRunnerSpawn,
    }, 'prompt')
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(timedChild.kills).toContain('SIGTERM')
    timedChild.emit('close', null, 'SIGTERM')
    expect(await timed.completed).toMatchObject({ timedOut: true, outputExceeded: false })

    const outputChild = fakeReviewChild()
    const output = spawnFixedReviewRunner({
      parentPid: 4242, cwd: '/private/tmp', maxOutputBytes: 1024, killGraceMs: 50,
      spawnProcess: (() => outputChild) as AppServerRunnerSpawn,
    }, 'prompt')
    outputChild.stdout.write('x'.repeat(1025))
    expect(outputChild.kills).toContain('SIGTERM')
    outputChild.emit('close', null, 'SIGTERM')
    const result = await output.completed
    expect(result).toMatchObject({ timedOut: false, outputExceeded: true })
    expect(Buffer.byteLength(result.stdout)).toBe(1024)
  })

  test('preserves bounded initialization causes across clean and failed runner reap', () => {
    const protocol = managerInitializationFailure(
      new Error('later request rejection'),
      `pre-response protocol; forged=field\n\x1b]8;;link\x07${'x'.repeat(10_000)}`,
      'fixed App Server runner exited (0)',
      true,
    )
    expect(protocol.message).toStartWith('App Server protocol error during initialization: ')
    expect(protocol.message).not.toContain('\n')
    expect(protocol.message).not.toContain('\x1b')
    expect(protocol.message.length).toBeLessThan(600)

    const initializedSend = managerInitializationFailure(
      new Error('initialized transport send failed'), null,
      'fixed App Server runner exited (0)', true,
    )
    expect(initializedSend.message).toContain('initialized transport send failed')
    expect(initializedSend.message).not.toContain('runner exited (0)')

    const typedProtocol = managerInitializationFailure(
      new AppServerProtocolError('malformed initialize result'), null,
      'fixed App Server runner exited (0)', true,
    )
    expect(typedProtocol.message).toContain('malformed initialize result')

    const reap = managerInitializationFailure(
      new Error('remote initialize rejected'), null,
      'fixed App Server runner did not exit', false,
    )
    expect(reap.message).toContain('could not be reaped')
    expect(reap.message).toContain('remote initialize rejected')
    expect(reap.message).toContain('fixed App Server runner did not exit')

    const reapException = managerInitializationFailure(
      new Error('remote initialize rejected'), null,
      'JSONL transport is closed', false, new Error('termination wait timed out'),
    )
    expect(reapException.message).toContain('remote initialize rejected')
    expect(reapException.message).toContain('termination wait timed out')

    const runner = managerInitializationFailure(
      new Error('stdout ended'), null,
      'fixed App Server runner exited (69): attestation failed; phase=ready\n\x1b[31mforged', true,
    )
    expect(runner.message).toBe(
      'App Server initialization failed: '
      + 'runner="fixed App Server runner exited (69): attestation failed; phase=ready [31mforged"; '
      + 'initialization="stdout ended"',
    )
    expect(runner.message).not.toContain('\n')
    expect(runner.message).not.toContain('\x1b')
  })

  test('refuses active worker scope and owns one terminal review through consume/end', async () => {
    const f = fixture()
    f.writeReviewerConfig({
      schema: 'qofi-fable-reviewer/v1',
      defaults: {
        authLane: 'device', maxCallsPerTask: 1, maxCallsPerWindow: 12,
        windowSeconds: 3600, timeoutSeconds: 180, failurePolicy: 'review-pending',
      },
      swarms: {
        alpha: { authLane: 'anthropic-api-key', timeoutSeconds: 90 },
      },
    })
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
      completionReviewRunner: f.completionReviewRunner,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await reserveTurn(manager, registered.registrationToken, 'scope-request')
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      taskId: '123456789012345678',
      threadId: null,
      prompt: 'invoke the bounded reviewer',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    await expect(manager.reviewerScope({ schema: FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA }))
      .rejects.toThrow('worker-initiated reviewer scope is disabled')
    await expect(manager.reviewerScope({
      schema: FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA,
      phase: 'early',
    } as any)).rejects.toThrow('invalid reviewer scope request')
    await expect(manager.reviewerScope(
      { schema: FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA },
      { _handle: { getPeerCredentials: () => ({ uid: 4_294_967_000 }) } } as unknown as Socket,
    )).rejects.toThrow('reviewer scope peer is not the operator')
    await expect(manager.reviewerScope(
      { schema: FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA },
      { _handle: {} } as unknown as Socket,
    )).rejects.toThrow('reviewer scope peer is not the operator')
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    await expect(manager.reviewerScope({ schema: FABLE_REVIEWER_SCOPE_REQUEST_SCHEMA }))
      .rejects.toThrow('worker-initiated reviewer scope is disabled')
    const sentinel = 'qofi completion review: no workspace file changes'
    const reviewedHash = createHash('sha256').update(sentinel).digest('hex')
    const beginRequest = {
      schema: 'qofi-codex-completion-review-begin/v1' as const,
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      reviewedDiffSha256: reviewedHash,
      arguments: { diff_or_files: sentinel, context_refs: [] as const, mode: 'code' as const },
    }
    const admitted = await manager.beginCompletionReview(beginRequest)
    expect(manager.health()).toMatchObject({
      status: 'review-pending', phase: 'completion-review-pending',
      upstreamReady: false, upstreamState: 'cleanup-pending',
    })
    expect(await manager.beginCompletionReview(beginRequest)).toEqual(admitted)
    expect(f.completionReviewExecutions).toHaveLength(1)
    expect(f.completionReviewExecutions[0]!.request).toMatchObject({
      schema: 'qofi-fable-reviewer-one-shot-request/v1',
      expected_reviewed_diff_sha256: reviewedHash,
      scope: {
        swarm: 'alpha', profile: 'default', task_id: '123456789012345678',
        state_dir: f.stateDir,
        policy: {
          auth_lane: 'anthropic-api-key', max_calls_per_task: 1,
          max_calls_per_window: 12, window_seconds: 3600,
          timeout_seconds: 90, failure_policy: 'review-pending',
        },
      },
    })
    expect(manager.completionReviewStatus({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      completionToken: admitted.completionToken,
    })).toEqual({ status: 'pending' })
    f.completionReviewExecutions[0]!.completion.resolve({
      schema: 'qofi-fable-reviewer-one-shot-result/v1',
      reviewed_diff_sha256: reviewedHash,
      artifact: {
        name: 'fable-review-20260713T101112123456Z-0123456789abcdef.json',
        sha256: 'a'.repeat(64),
      },
      result: {
        schema: 'qofi-adversarial-review-output/v2', verdict: 'approve',
        summary: 'bounded terminal review', checked: ['final named files'],
        not_checked: ['runtime execution'], findings: [], next_steps: [],
      },
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(manager.health().phase).toBe('completion-review-complete')
    const complete = manager.completionReviewStatus({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      completionToken: admitted.completionToken,
    })
    expect(complete).toMatchObject({
      status: 'complete', reviewedDiffSha256: reviewedHash, verdict: 'approve',
      artifactSha256: 'a'.repeat(64),
    })
    expect(() => manager.endCompletionReview({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      completionToken: admitted.completionToken,
    })).toThrow('not complete and consumed')
    expect(manager.consumeCompletionReview({
      schema: 'qofi-codex-completion-review-consume-request/v1',
      completionToken: admitted.completionToken,
      repoRoot: f.repo,
      taskId: '123456789012345678',
    })).toEqual({
      schema: 'qofi-codex-completion-review-receipt/v1',
      swarm: 'alpha', profile: 'default', taskId: '123456789012345678',
      repoRoot: f.repo, reviewedDiffSha256: reviewedHash, verdict: 'approve',
      artifactName: 'fable-review-20260713T101112123456Z-0123456789abcdef.json',
      artifactSha256: 'a'.repeat(64),
    })
    expect(manager.consumeCompletionReview({
      schema: 'qofi-codex-completion-review-consume-request/v1',
      completionToken: admitted.completionToken,
      repoRoot: f.repo,
      taskId: '123456789012345678',
    })).toMatchObject({
      schema: 'qofi-codex-completion-review-receipt/v1',
      reviewedDiffSha256: reviewedHash,
      artifactSha256: 'a'.repeat(64),
    })
    expect(manager.endCompletionReview({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      completionToken: admitted.completionToken,
    })).toEqual({ ended: true, leaseId: terminal.leaseId })
    expect(manager.health().phase).toBe('terminal-cleanup-pending')
    await manager.cleanupComplete({
      registrationToken: registered.registrationToken, leaseId: terminal.leaseId, ok: true,
    })
  })

  test('blocks on a missing host reviewer and expires a stuck one without reopening admission', async () => {
    for (const failure of ['launch', 'timeout'] as const) {
      const f = fixture()
      const manager = await AppServerManager.start({
        stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
        controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
        completionReviewRunner: f.completionReviewRunner,
        completionReviewTtlMs: 20,
      })
      managers.push(manager)
      const registered = await manager.register({
        swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
      })
      const reservation = await reserveTurn(manager, registered.registrationToken, `completion-${failure}`)
      const pending = manager.startTurn({
        registrationToken: registered.registrationToken,
        reservationToken: reservation.reservationToken,
        requestId: reservation.requestId,
        taskId: `terminal-${failure}`,
        threadId: null,
        prompt: 'terminal review failure proof',
      })
      await new Promise(resolve => setTimeout(resolve, 0))
      f.clients[0]!.turns[0]!.completion.resolve({
        ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
        messages: ['done'], ambiguous: false,
      })
      const terminal = await pending
      if (failure === 'launch') f.failNextCompletionReviewLaunch(new Error('shim missing'))
      const begin = manager.beginCompletionReview({
        schema: 'qofi-codex-completion-review-begin/v1',
        registrationToken: registered.registrationToken,
        leaseId: terminal.leaseId,
        reviewedDiffSha256: createHash('sha256')
          .update('qofi completion review: no workspace file changes').digest('hex'),
        arguments: {
          diff_or_files: 'qofi completion review: no workspace file changes',
          context_refs: [], mode: 'code',
        },
      })
      if (failure === 'launch') {
        await expect(begin).rejects.toThrow('fixed host Fable reviewer is unavailable')
      } else {
        await begin
        await new Promise(resolve => setTimeout(resolve, 50))
        expect(f.completionReviewExecutions[0]!.stopCalls).toBe(1)
      }
      expect(manager.health()).toMatchObject({
        status: 'ambiguous', phase: 'ambiguous', upstreamReady: false,
      })
      await expect(manager.cleanupComplete({
        registrationToken: registered.registrationToken,
        leaseId: terminal.leaseId,
        ok: true,
      })).rejects.toThrow('no matching cleanup-pending lease')
    }
  })

  test('requires a strict repo-controlled Fable reviewer config at manager startup', async () => {
    const f = fixture()
    rmSync(join(f.swarmHome, 'fable-reviewer.json'))
    await expect(AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })).rejects.toThrow()
    f.writeReviewerConfig({ schema: 'qofi-fable-reviewer/v1', defaults: {}, swarms: {} })
    await expect(AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })).rejects.toThrow('policy has missing or unknown keys')
    f.writeReviewerConfig({
      schema: 'qofi-fable-reviewer/v1',
      defaults: {
        authLane: 'device', maxCallsPerTask: 2, maxCallsPerWindow: 12,
        windowSeconds: 3600, timeoutSeconds: 180, failurePolicy: 'review-pending',
      },
      swarms: {},
    })
    await expect(AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })).rejects.toThrow('maxCallsPerTask must be an integer from 1 through 1')
    f.writeReviewerConfig({
      schema: 'qofi-fable-reviewer/v1',
      defaults: {
        authLane: 'device', maxCallsPerTask: 1, maxCallsPerWindow: 12,
        windowSeconds: 3_601, timeoutSeconds: 180, failurePolicy: 'review-pending',
      },
      swarms: {},
    })
    await expect(AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })).rejects.toThrow('windowSeconds must be an integer from 60 through 3600')
  })

  test('binds reviewer policy bytes to the secure installed runtime attestation on restart', async () => {
    const f = fixture()
    const attestationPath = join(f.root, 'runtime-attestation.json')
    const policyPath = join(f.swarmHome, 'fable-reviewer.json')
    const policyHash = createHash('sha256').update(readFileSync(policyPath)).digest('hex')
    const value = {
      schema: 'qofi-codex-runtime/v2', operator_uid: process.getuid?.() ?? 501,
      runtime_uid: 65001, runtime_user: '_qofi_codex', runtime_home: '/Users/_qofi_codex',
      runtime_gid: 65002, runtime_group: '_qofi_codex_shared',
      codex_home: '/Users/_qofi_codex/.codex', runner_path: '/usr/local/libexec/qofi-codex-runner',
      runner_sha256: '1'.repeat(64), node_path: '/fixed/node', node_sha256: '2'.repeat(64),
      codex_script: '/fixed/codex.js', codex_script_sha256: '3'.repeat(64),
      launchd_canary_name: 'QOFI_CODEX_RUNTIME_CANARY_FIXTURE123',
      launchd_canary_sha256: '4'.repeat(64),
      fable_reviewer_path: '/usr/local/libexec/qofi-fable-reviewer-mcp.py',
      fable_reviewer_sha256: '5'.repeat(64),
      fable_doctrine_path: '/usr/local/libexec/qofi-fable-reviewer-doctrine.md',
      fable_doctrine_sha256: '6'.repeat(64),
      fable_schema_path: '/usr/local/libexec/qofi-adversarial-review-output.schema.json',
      fable_schema_sha256: '7'.repeat(64),
      fable_reviewer_config_sha256: policyHash, codex_config_sha256: '8'.repeat(64),
    }
    writeFileSync(attestationPath, JSON.stringify(value), { mode: 0o600 })
    chmodSync(attestationPath, 0o600)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, runtimeAttestationPath: realpathSync(attestationPath),
      expectedRuntimeAttestationUid: process.getuid?.() ?? 501,
    })
    await manager.shutdown()
    f.writeReviewerConfig({
      schema: 'qofi-fable-reviewer/v1',
      defaults: {
        authLane: 'anthropic-api-key', maxCallsPerTask: 1, maxCallsPerWindow: 12,
        windowSeconds: 3600, timeoutSeconds: 180, failurePolicy: 'review-pending',
      },
      swarms: {},
    })
    await expect(AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, runtimeAttestationPath: realpathSync(attestationPath),
      expectedRuntimeAttestationUid: process.getuid?.() ?? 501,
    })).rejects.toThrow('differs from the installed root authority')
  })

  test('serializes a turn, reaps upstream before cleanup, then restarts with cold history', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState,
      swarmHome: f.swarmHome,
      operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath,
      model: 'gpt-test',
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    expect(lstatSync(f.controlSocketPath).mode & 0o777).toBe(0o600)
    const health = await getJson(f.controlSocketPath, '/v1/health')
    expect(health.status).toBe(200)
    expect(health.body).toMatchObject({
      schema: APP_SERVER_MANAGER_SCHEMA,
      status: 'ready', upstreamState: 'ready', cliVersion: '0.144.1',
    })

    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
      model: 'gpt-test', reasoningEffort: 'medium',
    })
    expect(registered.registrationToken).toMatch(/^[0-9a-f]{64}$/)
    expect(registered.reasoningEffort).toBe('medium')
    const turnTemp = join(f.stateDir, 'tool-tmp', 'request-one')
    mkdirSync(turnTemp, { recursive: true, mode: 0o700 })
    chmodSync(turnTemp, 0o700)
    const reservation = await reserveTurn(manager, registered.registrationToken, 'request-one')
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'request-one',
      threadId: null,
      prompt: 'hello',
      writableRoots: [turnTemp],
      environment: { PATH: '/fixed/bin', TMPDIR: turnTemp },
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(manager.health().phase).toBe('active')
    expect(f.clients[0].effectiveParams[0]).toMatchObject({
      cwd: f.repo, model: 'gpt-test', permissions: 'qofi-workspace-only',
      runtimeWorkspaceRoots: [f.repo], approvalPolicy: 'never',
    })
    expect((f.clients[0].effectiveParams[0].config as any)
      .permissions['qofi-workspace-only'].filesystem[turnTemp]).toBe('write')
    expect((f.clients[0].effectiveParams[0].config as any).model_reasoning_effort).toBe('medium')
    expect(f.clients[0].turns[0].params).toMatchObject({
      threadId: 'thread-1', cwd: f.repo, approvalPolicy: 'never',
      model: 'gpt-test', effort: 'medium',
    })
    expect(f.clients[0].turns[0].params).not.toHaveProperty('sandboxPolicy')
    const interrupted = manager.interruptTurn({
      registrationToken: registered.registrationToken,
      requestId: 'request-one',
    })
    expect(await interrupted).toEqual({ accepted: true, threadId: 'thread-1', turnId: 'turn-1' })
    expect(f.clients[0].interrupts).toEqual([{ threadId: 'thread-1', turnId: 'turn-1' }])

    f.notification({
      method: 'thread/started',
      params: {
        thread: {
          id: 'thread-child', parentThreadId: 'thread-1', cwd: f.repo,
          turns: [], preview: 'subagent', agentRole: 'worker', agentNickname: 'Scout',
        },
      },
    })

    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(terminal.cleanupRequired).toBe(true)
    expect(manager.health()).toMatchObject({
      phase: 'terminal-cleanup-pending', upstreamReady: false, upstreamState: 'cleanup-pending',
    })
    expect(f.stops).toHaveLength(1)
    await expect(manager.reserveTurn({
      registrationToken: registered.registrationToken,
      requestId: 'overlap',
    })).rejects.toThrow('terminal-cleanup-pending')

    f.writeSessions(['thread-1'])
    expect(await manager.replaceSessions({
      registrationToken: registered.registrationToken, sessions: ['thread-1'],
    })).toMatchObject({ sessionCount: 1 })
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      ok: true,
    })).toEqual({ generation: 2, ready: true, activeProfile: 'default', parkedUntilMs: null })
    expect(manager.health()).toMatchObject({ phase: 'idle', upstreamReady: true })
    expect(f.clients).toHaveLength(2)
    expect(f.clients[1].effectiveParams).toHaveLength(0)
    expect(f.clients[1].reads.sort((a, b) => a.threadId.localeCompare(b.threadId))).toEqual([
      { threadId: 'thread-1', includeTurns: true },
      { threadId: 'thread-child', includeTurns: true },
    ])

    const adopted = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir,
      sessions: ['thread-1'], model: 'gpt-test',
    })
    expect(adopted.registrationToken).not.toBe(registered.registrationToken)
    await expect(manager.unregister({ registrationToken: registered.registrationToken })).rejects.toThrow(
      'unknown registration capability',
    )
    expect(await manager.unregister({ registrationToken: adopted.registrationToken })).toEqual({ removed: true })
    expect(await postJson(f.controlSocketPath, '/v1/drain', {})).toMatchObject({
      status: 200, body: { drained: true },
    })
    expect(await postJson(f.controlSocketPath, '/v1/resume', {})).toMatchObject({
      status: 200, body: { ready: true },
    })
  }, 15_000)

  test('keeps persisted threads cold until the exact per-turn profile is applied', async () => {
    const f = fixture()
    f.writeSessions(['thread-existing'])
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir,
      sessions: ['thread-existing'], model: 'gpt-test',
    })
    expect(f.clients[0].reads).toEqual([{ threadId: 'thread-existing', includeTurns: true }])
    expect(f.clients[0].effectiveParams).toHaveLength(0)

    const turnTemp = join(f.stateDir, 'tool-tmp', 'persisted-turn')
    mkdirSync(turnTemp, { recursive: true, mode: 0o700 })
    chmodSync(turnTemp, 0o700)
    const reservation = await reserveTurn(manager, registered.registrationToken, 'persisted-turn')
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'persisted-turn',
      threadId: 'thread-existing',
      prompt: 'continue',
      writableRoots: [turnTemp],
      environment: { TMPDIR: turnTemp },
    })
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(f.clients[0].effectiveParams).toHaveLength(1)
    expect(f.clients[0].effectiveParams[0]).toMatchObject({
      threadId: 'thread-existing', cwd: f.repo, permissions: 'qofi-workspace-only',
      runtimeWorkspaceRoots: [f.repo], approvalPolicy: 'never',
    })
    expect((f.clients[0].effectiveParams[0].config as any)
      .permissions['qofi-workspace-only'].filesystem[turnTemp]).toBe('write')
    expect((f.clients[0].effectiveParams[0].config as any).model_reasoning_effort).toBe('ultra')
    expect(f.clients[0].turns[0].params).toMatchObject({ model: 'gpt-test', effort: 'ultra' })
    expect(f.clients[0].turns[0].params).not.toHaveProperty('sandboxPolicy')

    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-existing', turnId: 'turn-1', status: 'completed',
      messages: ['continued'], ambiguous: false,
    })
    const terminal = await pending
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      ok: true,
    })).toMatchObject({ ready: true })
    expect(f.clients[1].effectiveParams).toHaveLength(0)
    expect(f.clients[1].reads).toEqual([{ threadId: 'thread-existing', includeTurns: true }])
  }, 15_000)

  test('registration accepts only the managed medium/Ultra effort pair', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    await expect(manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
      reasoningEffort: 'high' as any,
    })).rejects.toThrow('invalid reasoning effort')
    expect(manager.health()).toMatchObject({ phase: 'idle', registeredSwarmCount: 0 })
  })

  test('fails closed when App Server changes the managed CPO medium effort', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
      reasoningEffort: 'medium',
    })
    f.clients[0].effectiveReasoningEffortOverride = 'ultra'
    const reservation = await reserveTurn(manager, registered.registrationToken, 'effort-downgrade')
    await expect(manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'effort-downgrade',
      threadId: null,
      prompt: 'must remain medium',
    })).rejects.toThrow('effective thread authority differs')
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(f.clients[0].turns).toHaveLength(0)
  }, 15_000)

  test('serializes registration, turn admission, and lifecycle restore before their first await', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)

    const firstRegistration = manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    await expect(manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })).rejects.toThrow('another manager operation is already in progress')
    const registered = await firstRegistration

    const reservation = await reserveTurn(manager, registered.registrationToken, 'serialized-first')
    const firstTurn = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'serialized-first', threadId: null, prompt: 'first',
    })
    await expect(manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'serialized-second', threadId: null, prompt: 'second',
    })).rejects.toThrow('another manager operation is already in progress')
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(f.clients[0].turns).toHaveLength(1)
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await firstTurn
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      ok: true,
    })).toMatchObject({ ready: true })

    await manager.drain()
    const firstResume = manager.resume()
    await expect(manager.resume()).rejects.toThrow('another manager operation is already in progress')
    expect(await firstResume).toMatchObject({ ready: true })
    expect(manager.health()).toMatchObject({ phase: 'idle', upstreamReady: true })
  })

  test('revalidates swarm.conf at turn admission and revokes stale authority', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    f.writeConfig('claude')
    await expect(manager.reserveTurn({
      registrationToken: registered.registrationToken,
      requestId: 'revoked',
    })).rejects.toThrow('registration was revoked')
    expect(manager.health().registeredSwarmCount).toBe(0)
    expect(f.clients[0].turns).toHaveLength(0)
    const rotation = JSON.parse(readFileSync(
      join(f.managerState, 'profile-rotation-state.json'),
      'utf8',
    ))
    expect(rotation.swarms).toEqual({})
  })

  test('failed existing registration refresh preserves its old token, model, effort, and live facade', async () => {
    const f = fixture()
    f.writeSessions(['thread-existing'])
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const original = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir,
      sessions: ['thread-existing'], model: 'gpt-old', reasoningEffort: 'medium',
    })
    const facadePath = original.facadeEndpoint.slice('unix://'.length)
    expect(lstatSync(facadePath).isSocket()).toBe(true)
    f.clients[0].nextReadError = new Error('injected history refresh failure')

    await expect(manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir,
      sessions: ['thread-existing'], model: 'gpt-new', reasoningEffort: 'ultra',
    })).rejects.toThrow('injected history refresh failure')
    expect(lstatSync(facadePath).isSocket()).toBe(true)
    expect(await manager.replaceSessions({
      registrationToken: original.registrationToken,
      sessions: ['thread-existing'],
    })).toMatchObject({ sessionCount: 1, facadeEndpoint: original.facadeEndpoint })
    expect(await readFacadeConfig(original.facadeEndpoint, f.repo)).toMatchObject({
      model: 'gpt-old', model_reasoning_effort: 'medium',
    })

    const retried = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir,
      sessions: ['thread-existing'], model: 'gpt-new', reasoningEffort: 'ultra',
    })
    expect(retried.registrationToken).not.toBe(original.registrationToken)
    await expect(manager.unregister({
      registrationToken: original.registrationToken,
    })).rejects.toThrow('unknown registration capability')
    expect(await manager.unregister({
      registrationToken: retried.registrationToken,
    })).toEqual({ removed: true })
  })

  test('history refresh tolerates stale rollouts but rejects cross-repo thread metadata', async () => {
    const f = fixture()
    f.writeSessions(['thread-existing'])
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    f.clients[0].nextReadError = new AppServerRemoteError(
      -32602, 'thread not loaded: thread-existing',
    )
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: ['thread-existing'],
    })
    expect(registered.registrationToken).toMatch(/^[0-9a-f]{64}$/)

    f.clients[0].readCwdOverride = join(f.root, 'repos', 'other')
    await expect(manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: ['thread-existing'],
    })).rejects.toThrow('cwd outside the registered repo')
    expect(await manager.unregister({
      registrationToken: registered.registrationToken,
    })).toEqual({ removed: true })
  })

  test('an unexpected no-lease idle exit is drain-recoverable and drain is idempotent', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
    })
    managers.push(manager)

    f.exitGeneration(0, { code: 70, signal: null })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    f.protocolErrorGeneration(0, new Error('late callback from exited transport'))
    await new Promise(resolve => setTimeout(resolve, 0))

    const recovered = await postJson(f.controlSocketPath, '/v1/drain', {})
    expect(recovered).toEqual({
      status: 200,
      body: { drained: true, generation: 1 },
    })
    expect(manager.health()).toMatchObject({
      phase: 'drained', upstreamReady: false, upstreamState: 'stopped',
    })
    expect(await manager.drain()).toEqual({ drained: true, generation: 1 })
    expect(f.stops).toHaveLength(0)

    expect(await manager.resume()).toEqual({ ready: true, generation: 2 })
    expect(manager.health()).toMatchObject({ phase: 'idle', upstreamReady: true })
  })

  test('startup retries one immediate pre-lease generation exit before publishing ready', async () => {
    const f = fixture()
    f.exitNextGenerationImmediately({ code: 75, signal: null })
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
    })
    managers.push(manager)

    expect(manager.health()).toMatchObject({
      generation: 2, phase: 'idle', upstreamReady: true, upstreamState: 'ready',
    })
    expect(f.clients).toHaveLength(2)
    // The first fake generation has already exited, so there is no live
    // handle left for the manager to stop before its bounded retry.
    expect(f.stops).toHaveLength(0)
  })

  test('startup retries one pre-lease connection factory failure', async () => {
    const f = fixture()
    f.failNextGeneration(new Error('injected initialize transport close'))
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
    })
    managers.push(manager)

    expect(manager.health()).toMatchObject({
      generation: 1, phase: 'idle', upstreamReady: true, upstreamState: 'ready',
    })
    expect(f.clients).toHaveLength(1)
    expect(f.stops).toHaveLength(0)
  })

  test('resume retries one immediate pre-lease generation exit and becomes ready', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    expect(await manager.drain()).toEqual({ drained: true, generation: 1 })
    f.exitNextGenerationImmediately({ code: 75, signal: null })

    expect(await manager.resume()).toEqual({ ready: true, generation: 3 })
    expect(manager.health()).toMatchObject({
      phase: 'idle', upstreamReady: true, upstreamState: 'ready',
    })
    expect(f.clients).toHaveLength(3)
    expect(f.stops).toHaveLength(1)
  })

  test('ignores a retained protocol callback from an older stopped generation', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    await manager.drain()
    await manager.resume()
    expect(manager.health()).toMatchObject({ generation: 2, phase: 'idle', upstreamReady: true })
    expect(f.stops).toHaveLength(1)

    f.protocolErrorGeneration(0, new Error('stale transport callback'))
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(manager.health()).toMatchObject({ generation: 2, phase: 'idle', upstreamReady: true })
    expect(f.stops).toHaveLength(1)
  })

  test('ignores a delayed exit from a stopped generation while its replacement starts', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    f.delayStopExit(0)
    expect(await manager.drain()).toEqual({ drained: true, generation: 1 })

    const gate = f.blockNextGeneration()
    const resuming = manager.resume()
    await gate.entered.promise
    let stateAfterOldExit: ReturnType<AppServerManager['health']>
    try {
      f.exitGeneration(0, { code: 0, signal: null })
      await new Promise(resolve => setTimeout(resolve, 0))
      stateAfterOldExit = manager.health()
    } finally {
      // Never strand the replacement factory if a future assertion changes.
      gate.release.resolve(undefined)
    }
    const resumed = await resuming

    expect(stateAfterOldExit).toMatchObject({ generation: 1, phase: 'starting', upstreamReady: false })
    expect(resumed).toEqual({ ready: true, generation: 2 })
    expect(manager.health()).toMatchObject({ generation: 2, phase: 'idle', upstreamReady: true })
  })

  test('bounded pre-lease restore failure remains explicitly drain-recoverable', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    await manager.drain()
    f.exitNextGenerationImmediately({ code: 75, signal: null })
    f.exitNextGenerationImmediately({ code: 75, signal: null })

    await expect(manager.resume()).rejects.toThrow('restoring readiness')
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(await manager.drain()).toEqual({ drained: true, generation: 3 })
    expect(await manager.drain()).toEqual({ drained: true, generation: 3 })
  })

  test('reclaims only a non-listening owner-private facade socket after manager crash', async () => {
    const f = fixture()
    const nativeView = join(f.stateDir, 'native-view')
    mkdirSync(nativeView, { mode: 0o700 })
    chmodSync(nativeView, 0o700)
    const stale = join(nativeView, 'app-server.sock')
    const child = Bun.spawn([
      '/usr/bin/python3', '-c',
      'import os,socket,sys\np=sys.argv[1]\ns=socket.socket(socket.AF_UNIX)\ns.bind(p)\nos.chmod(p,0o600)\nprint("ready",flush=True)\nos.pause()',
      stale,
    ], { stdout: 'pipe', stderr: 'pipe' })
    const reader = child.stdout.getReader()
    const ready = await reader.read()
    expect(new TextDecoder().decode(ready.value)).toContain('ready')
    child.kill('SIGKILL')
    await child.exited
    expect(lstatSync(stale).isSocket()).toBe(true)

    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    expect(lstatSync(stale).isSocket()).toBe(true)
    expect(lstatSync(stale).mode & 0o777).toBe(0o600)
    await manager.unregister({ registrationToken: registered.registrationToken })
  })

  test('stops upstream and remains ambiguous when the active turn connection disconnects', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const owner = new EventEmitter() as Socket
    const reservation = await reserveTurn(manager, registered.registrationToken, 'disconnect')
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'disconnect', threadId: null, prompt: 'work',
    }, owner)
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(manager.health().phase).toBe('active')
    owner.emit('close')
    await expect(pending).rejects.toThrow('ambiguous')
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(f.stops).toHaveLength(1)
    await expect(manager.drain()).rejects.toThrow('not safely drain-recoverable')
    expect(await postJson(f.controlSocketPath, '/v1/drain', {})).toMatchObject({
      status: 409,
      body: { phase: 'ambiguous' },
    })
    expect(manager.health().phase).toBe('ambiguous')
    ;(manager as any).phase = 'drained'
    await manager.shutdown()
    managers.splice(managers.indexOf(manager), 1)
  })

  test('reaps the fixed review child and remains ambiguous when its owner disconnects', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, reviewRunner: f.reviewRunner,
    })
    managers.push(manager)
    const owner = new EventEmitter() as Socket
    const pending = manager.startReview({ requestId: 'review-disconnect', prompt: 'review' }, owner)
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(f.stops).toHaveLength(1)
    expect(f.reviewExecutions).toHaveLength(1)
    expect(manager.health()).toMatchObject({ phase: 'active', upstreamReady: false })

    owner.emit('close')
    await expect(pending).rejects.toThrow('ambiguous')
    expect(f.reviewExecutions[0].stopCalls).toBe(1)
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(f.clients).toHaveLength(1)
    await expect(manager.drain()).rejects.toThrow('not safely drain-recoverable')

    ;(manager as any).phase = 'drained'
    await manager.shutdown()
    managers.splice(managers.indexOf(manager), 1)
  })

  test('exports attachment-parity bounds and isolates the 5MiB review lane from the shared App Server', async () => {
    expect(MANAGER_MAX_TURN_PROMPT_BYTES).toBeGreaterThanOrEqual(64 * 1024 * 1024)
    expect(MANAGER_MAX_TURN_BODY_BYTES).toBeGreaterThan(MANAGER_MAX_TURN_PROMPT_BYTES)
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, reviewRunner: f.reviewRunner,
    })
    managers.push(manager)
    const pending = manager.startReview({ requestId: 'review-large', prompt: 'r'.repeat(5 * 1024 * 1024) })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(f.stops).toHaveLength(1)
    expect(manager.health()).toMatchObject({ phase: 'active', upstreamReady: false, upstreamState: 'stopped' })
    expect(f.clients[0].effectiveParams).toEqual([])
    expect(f.clients[0].turns).toEqual([])
    expect(f.reviewExecutions).toHaveLength(1)
    expect(Buffer.byteLength(f.reviewExecutions[0].prompt)).toBe(5 * 1024 * 1024)
    f.reviewExecutions[0].completion.resolve(reviewResult())
    const result = await pending
    expect(result.result).toMatchObject({ ok: true, status: 'completed', messages: ['reviewed'], ambiguous: false })
    expect(result.threadId).toStartWith('review-')
    expect(result.turnId).toStartWith('review-')
    expect(result.cleanupRequired).toBe(true)
    expect(f.stops).toHaveLength(1)
    expect(await manager.cleanupComplete({
      cleanupToken: result.cleanupToken, leaseId: result.leaseId, ok: true,
    })).toEqual({ generation: 2, ready: true, activeProfile: null, parkedUntilMs: null })
  }, 15_000)

  test('definitive fixed-review launch rejections restore only a fresh ready generation', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, reviewRunner: f.reviewRunner,
    })
    managers.push(manager)
    f.failNextReviewLaunch(new Error('fixed review spawn rejected'))

    await expect(manager.startReview({ requestId: 'rejected-review', prompt: 'review' })).rejects.toThrow(
      'fixed review spawn rejected',
    )
    expect(manager.health()).toMatchObject({
      generation: 2, phase: 'idle', upstreamReady: true, upstreamState: 'ready',
    })
    expect(f.stops).toHaveLength(1)

    f.failNextReviewLaunch(new Error('second fixed review spawn rejected'))
    await expect(manager.startReview({ requestId: 'rejected-turn', prompt: 'review' })).rejects.toThrow(
      'second fixed review spawn rejected',
    )
    expect(manager.health()).toMatchObject({
      generation: 3, phase: 'idle', upstreamReady: true, upstreamState: 'ready',
    })
    expect(f.stops).toHaveLength(2)

    const retry = manager.startReview({ requestId: 'retry-review', prompt: 'review again' })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(f.clients[2].effectiveParams).toEqual([])
    f.reviewExecutions[0].completion.resolve(reviewResult())
    const result = await retry
    expect(await manager.cleanupComplete({
      cleanupToken: result.cleanupToken, leaseId: result.leaseId, ok: true,
    })).toEqual({ generation: 4, ready: true, activeProfile: null, parkedUntilMs: null })
  })

  test('failed restore after a definitive fixed-review launch rejection remains drain-recoverable ambiguous', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, reviewRunner: f.reviewRunner,
    })
    managers.push(manager)
    f.failNextReviewLaunch(new Error('review launch rejected'))
    f.failNextGeneration(new Error('first restore failed'))
    f.failNextGeneration(new Error('second restore failed'))

    await expect(manager.startReview({ requestId: 'rejected-review', prompt: 'review' })).rejects.toThrow(
      'review launch recovery failed',
    )
    expect(manager.health()).toMatchObject({
      generation: 1, phase: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(f.stops).toHaveLength(1)
    expect(await manager.drain()).toEqual({ drained: true, generation: 1 })
    expect(await manager.resume()).toEqual({ ready: true, generation: 2 })
  })

  test('a registered pre-turn remote rejection retains its unacknowledged cleanup boundary', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await reserveTurn(manager, registered.registrationToken, 'rejected-turn')
    f.clients[0].nextStartError = new AppServerRemoteError(-32602, 'workspace thread rejected')

    await expect(manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'rejected-turn', threadId: null, prompt: 'work',
    })).rejects.toThrow('workspace thread rejected')
    expect(manager.health()).toMatchObject({
      generation: 1, phase: 'ambiguous', upstreamReady: false,
      upstreamState: 'ambiguous', registeredSwarmCount: 1,
    })
    expect(f.stops).toHaveLength(1)
    await expect(manager.drain()).rejects.toThrow('not safely drain-recoverable')

    // The production recovery boundary deliberately needs external operator
    // reconciliation. This test owns no real ACLs, so tear down its fixture.
    ;(manager as any).phase = 'drained'
    await manager.shutdown()
    managers.splice(managers.indexOf(manager), 1)
  })

  test('turn HTTP results preserve bounded output beyond the control-route cap', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await postJson(f.controlSocketPath, '/v1/turn/reserve', {
      registrationToken: registered.registrationToken,
      requestId: 'large-result',
    })
    expect(reservation.status).toBe(200)
    const pending = postJson(f.controlSocketPath, '/v1/turn/start', {
      registrationToken: registered.registrationToken,
      reservationToken: reservation.body.reservationToken,
      requestId: 'large-result', threadId: null, prompt: 'work',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    const output = 'escaped line\n'.repeat(12_000)
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: [output], ambiguous: false,
    })
    const response = await pending
    expect(response.status).toBe(200)
    expect(response.body.result.messages).toEqual([output])
    expect(Buffer.byteLength(JSON.stringify(response.body))).toBeGreaterThan(64 * 1024)
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken,
      leaseId: response.body.leaseId,
      ok: true,
    })).toMatchObject({ ready: true })
  })
})

describe('AppServerManager turn reservations', () => {
  test('holds one global registration-bound reservation and fails other mutations closed', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const alphaRegistration = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const betaRegistration = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })

    const reservation = await manager.reserveTurn({
      registrationToken: alphaRegistration.registrationToken,
      requestId: 'alpha-reserved',
    })
    expect(await manager.reserveTurn({
      registrationToken: alphaRegistration.registrationToken,
      requestId: 'alpha-reserved',
    })).toEqual(reservation)
    expect(reservation.reservationToken).toMatch(/^[0-9a-f]{64}$/)
    expect(reservation.requestId).toBe('alpha-reserved')
    expect(manager.health()).toMatchObject({
      phase: 'reserved', status: 'busy', upstreamReady: true, upstreamState: 'ready',
    })
    await expect(manager.reserveTurn({
      registrationToken: betaRegistration.registrationToken,
      requestId: 'beta-overlap',
    })).rejects.toThrow('manager is reserved')
    await expect(manager.startTurn({
      registrationToken: betaRegistration.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'must not cross registrations',
    })).rejects.toThrow('turn reservation capability mismatch')
    await expect(manager.startTurn({
      registrationToken: alphaRegistration.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: 'wrong-request',
      threadId: null,
      prompt: 'must not cross requests',
    })).rejects.toThrow('turn reservation capability mismatch')
    await expect(manager.replaceSessions({
      registrationToken: betaRegistration.registrationToken,
      sessions: [],
    })).rejects.toThrow('manager is reserved')
    await expect(manager.drain()).rejects.toThrow('manager is reserved')
    expect(await manager.cancelTurnReservation({
      registrationToken: alphaRegistration.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
    })).toEqual({ cancelled: true })
    expect(manager.health()).toMatchObject({ phase: 'idle', status: 'ready', upstreamReady: true })
  })

  test('requires the exact cancellation capability and releases duplicate-request bookkeeping', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const betaRegistration = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'cancel-exact',
    })
    await expect(manager.cancelTurnReservation({
      registrationToken: registered.registrationToken,
      reservationToken: '0'.repeat(64),
      requestId: reservation.requestId,
    })).rejects.toThrow('turn reservation capability mismatch')
    expect(manager.health().phase).toBe('reserved')

    const cancelRequest = {
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
    }
    expect(await postJson(f.controlSocketPath, '/v1/turn/reservation-cancel', cancelRequest)).toEqual({
      status: 200, body: { cancelled: true },
    })
    expect(await postJson(f.controlSocketPath, '/v1/turn/reservation-cancel', cancelRequest)).toEqual({
      status: 200, body: { cancelled: true },
    })
    const betaReservation = await manager.reserveTurn({
      registrationToken: betaRegistration.registrationToken, requestId: 'beta-active',
    })
    const betaPending = manager.startTurn({
      registrationToken: betaRegistration.registrationToken,
      reservationToken: betaReservation.reservationToken,
      requestId: betaReservation.requestId,
      threadId: null,
      prompt: 'hold beta active',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(manager.health().phase).toBe('active')
    expect(await postJson(f.controlSocketPath, '/v1/turn/reservation-cancel', cancelRequest)).toEqual({
      status: 200, body: { cancelled: true },
    })
    expect(manager.health().phase).toBe('active')
    expect(f.clients[0].turns).toHaveLength(1)
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const betaTerminal = await betaPending
    expect(await manager.cleanupComplete({
      registrationToken: betaRegistration.registrationToken,
      leaseId: betaTerminal.leaseId,
      ok: true,
    })).toMatchObject({ ready: true })

    const repeated = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'cancel-exact',
    })
    expect(await manager.cancelTurnReservation({
      registrationToken: registered.registrationToken,
      reservationToken: repeated.reservationToken,
      requestId: repeated.requestId,
    })).toEqual({ cancelled: true })
  })

  test('marks only genuine pre-admission contention retryable in HTTP errors', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })

    const semanticIdleConflict = await postJson(f.controlSocketPath, '/v1/turn/start', {
      registrationToken: registered.registrationToken,
      reservationToken: '0'.repeat(64),
      requestId: 'no-reservation',
      threadId: null,
      prompt: 'must not retry',
    })
    expect(semanticIdleConflict).toMatchObject({
      status: 409,
      body: {
        error: 'manager has no matching turn reservation',
        phase: 'idle',
        retryable: false,
      },
    })

    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken,
      requestId: 'busy-owner',
    })
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'hold operation open',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    const busyConflict = await postJson(f.controlSocketPath, '/v1/turn/reserve', {
      registrationToken: registered.registrationToken,
      requestId: 'contending-request',
    })
    expect(busyConflict).toMatchObject({
      status: 409,
      body: {
        error: 'another manager operation is already in progress',
        phase: 'active',
        retryable: true,
      },
    })
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      ok: true,
    })).toMatchObject({ ready: true })
  })

  test('expires into a stopped ambiguous boundary and never silently reopens admission', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, reservationTtlMs: 20,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'will-expire',
    })
    await new Promise(resolve => setTimeout(resolve, 50))
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', status: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(f.stops).toHaveLength(1)
    await expect(manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'must-not-admit',
    })).rejects.toThrow('manager is ambiguous')
    await expect(manager.drain()).rejects.toThrow('not safely drain-recoverable')

    ;(manager as any).phase = 'drained'
    await manager.shutdown()
    managers.splice(managers.indexOf(manager), 1)
  })

  test('fresh authority drift after reserve blocks and reaps without consuming the cleanup capability', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'authority-drift',
    })
    f.writeConfig('claude')
    await expect(manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'must not run after authority drift',
    })).rejects.toThrow('registration authority changed after reservation')
    expect(f.clients[0].turns).toHaveLength(0)
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', status: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(f.stops).toHaveLength(1)
    expect(await manager.cancelTurnReservation({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
    })).toEqual({ cancelled: true })
    expect(manager.health().phase).toBe('ambiguous')

    ;(manager as any).phase = 'drained'
    await manager.shutdown()
    managers.splice(managers.indexOf(manager), 1)
  })

  test('consumes once into an active lease and clears the expiry timer before awaiting upstream', async () => {
    const f = fixture()
    const reservationTtlMs = 1_000
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, reservationTtlMs,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'consume-once',
    })
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'remain active beyond reservation ttl',
    })
    const outcome = pending.then(
      terminal => ({ kind: 'terminal' as const, terminal }),
      error => ({ kind: 'error' as const, error }),
    )
    const admission = await Promise.race([
      f.clients[0].turnStarted.promise.then(() => ({ kind: 'active' as const })),
      outcome,
    ])
    if (admission.kind === 'error') throw admission.error
    expect(admission.kind).toBe('active')
    await new Promise(resolve => setTimeout(
      resolve,
      Math.max(0, reservation.expiresAtMs - Date.now()) + 25,
    ))
    expect(manager.health()).toMatchObject({ phase: 'active', status: 'busy', upstreamReady: true })
    expect(f.stops).toHaveLength(0)
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const completed = await outcome
    if (completed.kind === 'error') throw completed.error
    const terminal = completed.terminal
    await expect(manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'cannot reuse consumed capability',
    })).rejects.toThrow('manager has no matching turn reservation')
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken,
      leaseId: terminal.leaseId,
      ok: true,
    })).toMatchObject({ ready: true })
    const repeated = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: reservation.requestId,
    })
    await manager.cancelTurnReservation({
      registrationToken: registered.registrationToken,
      reservationToken: repeated.reservationToken,
      requestId: repeated.requestId,
    })
  })

  test('leaves invalid or admission-disconnected owner reservations safely cancelable', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })

    const invalidReservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'invalid-owner',
    })
    const invalidOwner = Object.assign(new EventEmitter(), { destroyed: true }) as unknown as Socket
    await expect(manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: invalidReservation.reservationToken,
      requestId: invalidReservation.requestId,
      threadId: null,
      prompt: 'invalid owner',
    }, invalidOwner)).rejects.toThrow('disconnected before lease admission')
    expect(manager.health().phase).toBe('reserved')
    expect(await manager.cancelTurnReservation({
      registrationToken: registered.registrationToken,
      reservationToken: invalidReservation.reservationToken,
      requestId: invalidReservation.requestId,
    })).toEqual({ cancelled: true })

    const disconnectedReservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'disconnect-admission',
    })
    const disconnectedOwner = Object.assign(new EventEmitter(), { destroyed: false }) as unknown as Socket
    const installListener = disconnectedOwner.once.bind(disconnectedOwner)
    disconnectedOwner.once = ((event: string, listener: (...args: any[]) => void) => {
      const result = installListener(event, listener)
      ;(disconnectedOwner as any).destroyed = true
      return result
    }) as typeof disconnectedOwner.once
    await expect(manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: disconnectedReservation.reservationToken,
      requestId: disconnectedReservation.requestId,
      threadId: null,
      prompt: 'disconnect during owner admission',
    }, disconnectedOwner)).rejects.toThrow('disconnected during lease admission')
    expect(disconnectedOwner.listenerCount('close')).toBe(0)
    expect(manager.health().phase).toBe('reserved')
    expect(await manager.cancelTurnReservation({
      registrationToken: registered.registrationToken,
      reservationToken: disconnectedReservation.reservationToken,
      requestId: disconnectedReservation.requestId,
    })).toEqual({ cancelled: true })
  })

  test('removes the close listener after every successful turn on a reused owner socket', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const owner = new EventEmitter() as Socket

    for (let index = 0; index < 2; index += 1) {
      const requestId = `reused-owner-${index}`
      const reservation = await manager.reserveTurn({
        registrationToken: registered.registrationToken, requestId,
      })
      const pending = manager.startTurn({
        registrationToken: registered.registrationToken,
        reservationToken: reservation.reservationToken,
        requestId,
        threadId: null,
        prompt: `turn ${index}`,
      }, owner)
      await new Promise(resolve => setTimeout(resolve, 0))
      expect(owner.listenerCount('close')).toBe(1)
      const turn = f.clients[index].turns[0]
      turn.completion.resolve({
        ok: true, threadId: turn.handle.threadId, turnId: turn.handle.turnId,
        status: 'completed', messages: ['done'], ambiguous: false,
      })
      const terminal = await pending
      expect(owner.listenerCount('close')).toBe(0)
      expect(await manager.cleanupComplete({
        registrationToken: registered.registrationToken,
        leaseId: terminal.leaseId,
        ok: true,
      })).toMatchObject({ ready: true })
      expect(owner.listenerCount('close')).toBe(0)
    }
  })
})

describe('AppServerManager shared registration removal', () => {
  test('removes only a non-owner registration while another swarm is reserved', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const alpha = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const betaRegistration = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: alpha.registrationToken, requestId: 'alpha-reserved-owner',
    })

    await expect(manager.unregister({ registrationToken: alpha.registrationToken })).rejects.toThrow(
      'registration owns the current manager boundary',
    )
    expect(await manager.unregister({ registrationToken: betaRegistration.registrationToken })).toEqual({ removed: true })
    expect(manager.health()).toMatchObject({ phase: 'reserved', registeredSwarmCount: 1 })

    const pending = manager.startTurn({
      registrationToken: alpha.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'reservation remains usable',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(await manager.cleanupComplete({
      registrationToken: alpha.registrationToken, leaseId: terminal.leaseId, ok: true,
    })).toMatchObject({ ready: true })
  })

  test('bypasses an active turn only for a non-owner registration', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const alpha = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const betaRegistration = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: alpha.registrationToken, requestId: 'alpha-active-owner',
    })
    const pending = manager.startTurn({
      registrationToken: alpha.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'hold alpha active',
    })
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(await manager.unregister({ registrationToken: betaRegistration.registrationToken })).toEqual({ removed: true })
    expect(manager.health()).toMatchObject({ phase: 'active', registeredSwarmCount: 1 })
    await expect(manager.unregister({ registrationToken: betaRegistration.registrationToken })).rejects.toThrow(
      'unknown registration capability',
    )
    await expect(manager.unregister({ registrationToken: alpha.registrationToken })).rejects.toThrow(
      'registration owns the current manager boundary',
    )

    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(await manager.cleanupComplete({
      registrationToken: alpha.registrationToken, leaseId: terminal.leaseId, ok: true,
    })).toMatchObject({ ready: true })
  })

  test('allows registration removal during an active registration-free review lease', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, reviewRunner: f.reviewRunner,
    })
    managers.push(manager)
    const alpha = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const betaRegistration = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })
    const pending = manager.startReview({ requestId: 'active-review-removal', prompt: 'review' })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(manager.health().phase).toBe('active')

    expect(await manager.unregister({ registrationToken: alpha.registrationToken })).toEqual({ removed: true })
    expect(await manager.unregister({ registrationToken: betaRegistration.registrationToken })).toEqual({ removed: true })
    expect(manager.health()).toMatchObject({ phase: 'active', registeredSwarmCount: 0 })

    f.reviewExecutions[0].completion.resolve(reviewResult())
    const terminal = await pending
    expect(await manager.cleanupComplete({
      cleanupToken: terminal.cleanupToken, leaseId: terminal.leaseId, ok: true,
    })).toMatchObject({ ready: true })
  })

  test('rejects the cleanup owner but removes another registration at a stable terminal boundary', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const alpha = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const betaRegistration = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: alpha.registrationToken, requestId: 'terminal-owner',
    })
    const pending = manager.startTurn({
      registrationToken: alpha.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'reach terminal cleanup',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(manager.health().phase).toBe('terminal-cleanup-pending')

    await expect(manager.unregister({ registrationToken: alpha.registrationToken })).rejects.toThrow(
      'registration owns the current manager boundary',
    )
    expect(await manager.unregister({ registrationToken: betaRegistration.registrationToken })).toEqual({ removed: true })
    expect(manager.health()).toMatchObject({ phase: 'terminal-cleanup-pending', registeredSwarmCount: 1 })
    expect(await manager.cleanupComplete({
      registrationToken: alpha.registrationToken, leaseId: terminal.leaseId, ok: true,
    })).toMatchObject({ ready: true })
  })

  test('keeps unregister serialized and retryable while cleanup restores the manager', async () => {
    const f = fixture()
    const beta = addSecondSwarm(f)
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      controlSocketPath: f.controlSocketPath, generationFactory: f.generationFactory,
    })
    managers.push(manager)
    const alpha = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const betaRegistration = await manager.register({
      swarm: beta.swarm, repo: beta.repo, stateDir: beta.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: alpha.registrationToken, requestId: 'cleanup-race',
    })
    const pending = manager.startTurn({
      registrationToken: alpha.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'reach cleanup restore',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    const cleanup = manager.cleanupComplete({
      registrationToken: alpha.registrationToken, leaseId: terminal.leaseId, ok: true,
    })
    const raced = await postJson(f.controlSocketPath, '/v1/unregister', {
      registrationToken: betaRegistration.registrationToken,
    })
    expect(raced).toMatchObject({
      status: 409,
      body: {
        error: 'another manager operation is already in progress', retryable: true,
      },
    })
    expect(manager.health().registeredSwarmCount).toBe(2)
    expect(await cleanup).toMatchObject({ ready: true })
    expect(await manager.unregister({ registrationToken: betaRegistration.registrationToken })).toEqual({ removed: true })
  })
})

describe('AppServerManager cleanup acknowledgement deadline', () => {
  test('blocks with the upstream stopped when terminal cleanup is never acknowledged', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, cleanupPendingTtlMs: 20,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'cleanup-expiry',
    })
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'finish without cleanup acknowledgement',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(manager.health()).toMatchObject({
      phase: 'terminal-cleanup-pending', upstreamReady: false, upstreamState: 'cleanup-pending',
    })
    await new Promise(resolve => setTimeout(resolve, 50))
    expect(manager.health()).toMatchObject({
      phase: 'ambiguous', status: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous',
    })
    expect(f.stops).toHaveLength(1)
    await expect(manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'must-not-reopen',
    })).rejects.toThrow('manager is ambiguous')
    await expect(manager.cleanupComplete({
      registrationToken: registered.registrationToken, leaseId: terminal.leaseId, ok: true,
    })).rejects.toThrow('no matching cleanup-pending lease')
    await expect(manager.unregister({ registrationToken: registered.registrationToken })).rejects.toThrow(
      'registration owns the current manager boundary',
    )

    ;(manager as any).phase = 'drained'
    await manager.shutdown()
    managers.splice(managers.indexOf(manager), 1)
  })

  test('clears the terminal timer before restore and stays ready beyond the old deadline', async () => {
    const f = fixture()
    const manager = await AppServerManager.start({
      stateDir: f.managerState, swarmHome: f.swarmHome, operatorHome: f.operatorHome,
      generationFactory: f.generationFactory, cleanupPendingTtlMs: 20,
    })
    managers.push(manager)
    const registered = await manager.register({
      swarm: 'alpha', repo: f.repo, stateDir: f.stateDir, sessions: [],
    })
    const reservation = await manager.reserveTurn({
      registrationToken: registered.registrationToken, requestId: 'cleanup-timely',
    })
    const pending = manager.startTurn({
      registrationToken: registered.registrationToken,
      reservationToken: reservation.reservationToken,
      requestId: reservation.requestId,
      threadId: null,
      prompt: 'cleanup promptly',
    })
    await new Promise(resolve => setTimeout(resolve, 0))
    f.clients[0].turns[0].completion.resolve({
      ok: true, threadId: 'thread-1', turnId: 'turn-1', status: 'completed',
      messages: ['done'], ambiguous: false,
    })
    const terminal = await pending
    expect(await manager.cleanupComplete({
      registrationToken: registered.registrationToken, leaseId: terminal.leaseId, ok: true,
    })).toEqual({ generation: 2, ready: true, activeProfile: 'default', parkedUntilMs: null })
    await new Promise(resolve => setTimeout(resolve, 50))
    expect(manager.health()).toMatchObject({
      phase: 'idle', status: 'ready', generation: 2, upstreamReady: true, upstreamState: 'ready',
    })
    expect(f.stops).toHaveLength(1)
  })
})
