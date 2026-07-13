import { chmodSync, mkdirSync, renameSync, writeFileSync } from 'fs'
import { isAbsolute, join, normalize, relative, sep } from 'path'

type RuntimeStateBase = {
  schema: 'codex-bridge-runtime/v1'
  pid: number
  started_at: string
  updated_at: string
  ready: boolean
  active: boolean
  /** Accepted jobs waiting to start; excludes active preprocessing/turn work. */
  queue_depth: number
  child_pid: number | null
  turn_started_at: string | null
  last_completed_at: string | null
  last_error: string | null
}

export type RuntimeState = RuntimeStateBase & (
  | { backend: 'exec'; app_server_endpoint: null }
  | { backend: 'app-server'; app_server_endpoint: string }
)

export type RuntimeStateStoreOptions = Readonly<{
  /** Per-swarm, operator-owned filtering facade published to native viewers. */
  appServerEndpoint: string
}>

function validatedAppServerEndpoint(value: string, stateDir: string): string {
  if (
    typeof value !== 'string'
    || !value.startsWith('unix://')
    || value.includes('|')
    || [...value].some(char => {
      const code = char.charCodeAt(0)
      return code < 32 || code === 127
    })
  ) throw new TypeError('appServerEndpoint must be a safe absolute unix:// endpoint')
  const socketPath = value.slice('unix://'.length)
  const relativeSocket = relative(stateDir, socketPath)
  if (
    !isAbsolute(stateDir)
    || normalize(stateDir) !== stateDir
    || !isAbsolute(socketPath)
    || normalize(socketPath) !== socketPath
    || !relativeSocket
    || relativeSocket === '..'
    || relativeSocket.startsWith(`..${sep}`)
    || isAbsolute(relativeSocket)
  ) {
    throw new TypeError('appServerEndpoint must be a safe absolute unix:// endpoint')
  }
  return value
}

export class RuntimeStateStore {
  readonly file: string
  readonly stateDir: string
  private state: RuntimeState

  constructor(stateDir: string, options?: RuntimeStateStoreOptions)
  constructor(stateDir: string, now?: Date, options?: RuntimeStateStoreOptions)
  constructor(
    stateDir: string,
    nowOrOptions: Date | RuntimeStateStoreOptions = new Date(),
    explicitOptions?: RuntimeStateStoreOptions,
  ) {
    const now = nowOrOptions instanceof Date ? nowOrOptions : new Date()
    const options = nowOrOptions instanceof Date ? explicitOptions : nowOrOptions
    this.stateDir = stateDir
    this.file = join(stateDir, 'runtime.json')
    const iso = now.toISOString()
    const backend = options
      ? {
          backend: 'app-server' as const,
          app_server_endpoint: validatedAppServerEndpoint(options.appServerEndpoint, stateDir),
        }
      : { backend: 'exec' as const, app_server_endpoint: null }
    this.state = {
      schema: 'codex-bridge-runtime/v1',
      pid: process.pid,
      started_at: iso,
      updated_at: iso,
      ready: false,
      active: false,
      queue_depth: 0,
      child_pid: null,
      turn_started_at: null,
      last_completed_at: null,
      last_error: null,
      ...backend,
    }
    this.write(now)
  }

  snapshot(): RuntimeState {
    return { ...this.state }
  }

  update(patch: Partial<Omit<RuntimeState, 'schema' | 'pid' | 'started_at' | 'updated_at' | 'backend' | 'app_server_endpoint'>>, now = new Date()): void {
    this.state = { ...this.state, ...patch }
    // The App Server child belongs to the global manager, never this daemon.
    // Keep the field null even while daemon-local Git plumbing is active.
    if (this.state.backend === 'app-server') this.state.child_pid = null
    if (typeof this.state.last_error === 'string') this.state.last_error = this.state.last_error.slice(0, 500)
    this.write(now)
  }

  heartbeat(now = new Date()): void {
    this.write(now)
  }

  private write(now: Date): void {
    this.state.updated_at = now.toISOString()
    mkdirSync(this.stateDir, { recursive: true, mode: 0o700 })
    try { chmodSync(this.stateDir, 0o700) } catch {}
    const tmp = `${this.file}.tmp-${process.pid}`
    writeFileSync(tmp, JSON.stringify(this.state, null, 2) + '\n', { mode: 0o600 })
    try { chmodSync(tmp, 0o600) } catch {}
    renameSync(tmp, this.file)
  }
}
