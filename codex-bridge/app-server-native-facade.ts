/** Read-only, per-swarm Codex 0.144.1 native-TUI facade over a private Unix WS. */

import { createServer, type IncomingMessage, type Server as HttpServer } from 'http'
import type { Socket } from 'net'
import WebSocket, { WebSocketServer, type RawData } from 'ws'
import {
  closeOwnedUnixServer,
  listenOwnerUnixSocket,
  type UnixSocketIdentity,
} from './app-server-unix-socket.ts'
import {
  CODEX_APP_SERVER_PROTOCOL_VERSION,
  type AppServerNotification,
} from './app-server-client.ts'
import {
  CODEX_REASONING_EFFORT_OPTIONS,
  DEFAULT_CODEX_MODEL,
  DEFAULT_CODEX_MODEL_DISPLAY_NAME,
  DEFAULT_CODEX_REASONING_EFFORT,
  isManagedCodexReasoningEffort,
  type ManagedCodexReasoningEffort,
} from './model.ts'

type JsonObject = Record<string, unknown>
type RequestId = string | number

export type NativeFacadeOptions = {
  socketPath: string
  swarmName: string
  repo: string
  stateDir: string
  model?: string
  reasoningEffort?: ManagedCodexReasoningEffort
  maxFrameBytes?: number
  maxClients?: number
}

type ClientState = {
  initialized: boolean
  announced: boolean
  requestCount: number
  subscriptions: Set<string>
}

const SAFE_READ_METHODS = new Set([
  'account/read',
  'account/rateLimits/read',
  'collaborationMode/list',
  'config/read',
  'configRequirements/read',
  'hooks/list',
  'model/list',
  'permissionProfile/list',
  'plugin/list',
  'skills/list',
  'thread/goal/get',
  'thread/items/list',
  'thread/list',
  'thread/loaded/list',
  'thread/read',
  'thread/resume',
  'thread/turns/list',
  'thread/unsubscribe',
])

const encoder = new TextEncoder()
const decoder = new TextDecoder('utf-8', { fatal: true })

function object(value: unknown): value is JsonObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function requestId(value: unknown): value is RequestId {
  return (typeof value === 'string' && value.length > 0 && value.length <= 128)
    || (typeof value === 'number' && Number.isSafeInteger(value))
}

function safeThreadId(value: unknown): value is string {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= 256
    && !value.includes('\0')
}

function bounded(value: number | undefined, fallback: number, min: number, max: number, name: string): number {
  const selected = value ?? fallback
  if (!Number.isSafeInteger(selected) || selected < min || selected > max) {
    throw new TypeError(`${name} must be an integer from ${min} to ${max}`)
  }
  return selected
}

function cloneBounded(value: unknown, maxBytes: number): unknown {
  const text = JSON.stringify(value)
  if (encoder.encode(text).byteLength > maxBytes) throw new Error('facade cache value exceeds its byte bound')
  return JSON.parse(text)
}

export function appServerNotificationThreadId(notification: unknown): string | null {
  if (!object(notification) || !object(notification.params)) return null
  const params = notification.params
  if (safeThreadId(params.threadId)) return params.threadId
  if (object(params.thread) && safeThreadId(params.thread.id)) return params.thread.id
  return null
}

/**
 * The facade intentionally does not implement AppServerTransport: nothing a
 * native viewer sends is ever eligible to reach the hidden-UID upstream.
 */
export class CodexNativeReadOnlyFacade {
  readonly endpoint: string
  private model: string
  private reasoningEffort: ManagedCodexReasoningEffort
  private readonly maxFrameBytes: number
  private readonly maxClients: number
  private readonly allowedThreads = new Set<string>()
  private readonly threadCache = new Map<string, JsonObject>()
  private readonly threadTurns = new Map<string, unknown[]>()
  private readonly clients = new Map<WebSocket, ClientState>()
  private readonly http: HttpServer
  private readonly websocket: WebSocketServer
  private socketIdentity: UnixSocketIdentity | null = null

  constructor(readonly options: NativeFacadeOptions) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(options.swarmName)) {
      throw new TypeError('invalid facade swarm name')
    }
    this.model = options.model ?? DEFAULT_CODEX_MODEL
    if (!/^[A-Za-z0-9_.:-]{1,128}$/.test(this.model)) throw new TypeError('invalid facade model')
    this.reasoningEffort = options.reasoningEffort ?? DEFAULT_CODEX_REASONING_EFFORT
    if (!isManagedCodexReasoningEffort(this.reasoningEffort)) throw new TypeError('invalid facade reasoning effort')
    this.maxFrameBytes = bounded(options.maxFrameBytes, 2 * 1024 * 1024, 1024, 16 * 1024 * 1024, 'maxFrameBytes')
    this.maxClients = bounded(options.maxClients, 4, 1, 32, 'maxClients')
    this.endpoint = `unix://${options.socketPath}`
    this.http = createServer((_request, response) => {
      response.writeHead(404, { 'content-type': 'text/plain', 'content-length': '0' })
      response.end()
    })
    this.http.headersTimeout = 5_000
    this.http.requestTimeout = 5_000
    this.http.keepAliveTimeout = 5_000
    this.http.maxHeadersCount = 32
    this.websocket = new WebSocketServer({ noServer: true, maxPayload: this.maxFrameBytes })
    this.http.on('upgrade', (request, socket, head) => this.upgrade(request, socket, head))
    this.websocket.on('connection', client => this.accept(client))
  }

  async start(): Promise<void> {
    if (this.socketIdentity) throw new Error('native facade is already listening')
    this.socketIdentity = await listenOwnerUnixSocket(this.http, this.options.socketPath)
  }

  setModel(model: string): void {
    if (!/^[A-Za-z0-9_.:-]{1,128}$/.test(model)) throw new TypeError('invalid facade model')
    this.model = model
  }

  setReasoningEffort(reasoningEffort: ManagedCodexReasoningEffort): void {
    if (!isManagedCodexReasoningEffort(reasoningEffort)) throw new TypeError('invalid facade reasoning effort')
    this.reasoningEffort = reasoningEffort
  }

  replaceThreadIds(ids: readonly string[]): void {
    if (ids.length > 256 || new Set(ids).size !== ids.length || ids.some(id => !safeThreadId(id))) {
      throw new Error('facade thread set must contain at most 256 unique bounded ids')
    }
    const replacement = new Set(ids)
    this.allowedThreads.clear()
    for (const id of replacement) this.allowedThreads.add(id)
    for (const id of this.threadCache.keys()) {
      if (!replacement.has(id)) {
        this.threadCache.delete(id)
        this.threadTurns.delete(id)
      }
    }
    for (const state of this.clients.values()) {
      for (const id of state.subscriptions) if (!replacement.has(id)) state.subscriptions.delete(id)
    }
  }

  cacheThread(threadId: string, thread: JsonObject): void {
    if (!this.allowedThreads.has(threadId) || thread.id !== threadId) {
      throw new Error('cannot cache an unbound facade thread')
    }
    this.threadCache.set(threadId, this.sanitizeThread(threadId, thread))
    this.threadTurns.set(threadId, this.sanitizeTurns(Array.isArray(thread.turns) ? thread.turns : []))
  }

  publish(notification: AppServerNotification | JsonObject): boolean {
    if (!object(notification) || typeof notification.method !== 'string' || 'id' in notification
      || 'result' in notification || 'error' in notification) return false
    const threadId = appServerNotificationThreadId(notification)
    if (!threadId || !this.allowedThreads.has(threadId)) return false
    if (notification.method === 'thread/started' && object(notification.params)
      && object(notification.params.thread) && notification.params.thread.id === threadId) {
      this.cacheThread(threadId, notification.params.thread)
    }
    const text = JSON.stringify(notification)
    if (encoder.encode(text).byteLength > this.maxFrameBytes) return false
    let sent = false
    for (const [client, state] of this.clients) {
      if (client.readyState !== WebSocket.OPEN || !state.announced || !state.subscriptions.has(threadId)) continue
      if (client.bufferedAmount > this.maxFrameBytes * 2) {
        client.close(1013, 'viewer backpressure limit')
        continue
      }
      client.send(text)
      sent = true
    }
    return sent
  }

  async close(): Promise<void> {
    for (const client of this.clients.keys()) {
      try { client.terminate() } catch {}
    }
    this.clients.clear()
    // noServer WebSocketServer owns no listener; terminating its clients is
    // sufficient, while the HTTP Unix listener below has bounded close/attest.
    try { this.websocket.close() } catch {}
    const identity = this.socketIdentity
    this.socketIdentity = null
    await closeOwnedUnixServer(this.http, identity)
  }

  private upgrade(request: IncomingMessage, socket: Socket, head: Buffer): void {
    if (request.url !== '/rpc' || this.clients.size >= this.maxClients) {
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n')
      socket.destroy()
      return
    }
    this.websocket.handleUpgrade(request, socket, head, client => {
      this.websocket.emit('connection', client, request)
    })
  }

  private accept(client: WebSocket): void {
    const state: ClientState = {
      initialized: false,
      announced: false,
      requestCount: 0,
      subscriptions: new Set(),
    }
    this.clients.set(client, state)
    client.on('message', (data, isBinary) => this.receive(client, state, data, isBinary))
    client.on('close', () => this.clients.delete(client))
    client.on('error', () => {})
  }

  private receive(client: WebSocket, state: ClientState, raw: RawData, isBinary: boolean): void {
    if (isBinary) {
      client.close(1003, 'text frames required')
      return
    }
    let message: unknown
    try {
      const bytes = Buffer.isBuffer(raw) ? raw : Buffer.from(raw as ArrayBuffer)
      if (bytes.byteLength > this.maxFrameBytes) throw new Error('oversized')
      message = JSON.parse(decoder.decode(bytes))
    } catch {
      client.close(1007, 'invalid JSON')
      return
    }
    if (!object(message)) {
      client.close(1008, 'invalid envelope')
      return
    }
    // The facade never issues a request to viewers. A result/error is thus a
    // response to an unissued id and is closed rather than relayed upstream.
    if ('result' in message || 'error' in message || (('id' in message) && !('method' in message))) {
      client.close(1008, 'unissued response envelope')
      return
    }
    if (typeof message.method !== 'string' || message.method.length > 128) {
      client.close(1008, 'invalid method')
      return
    }
    if (message.method === 'initialized' && !('id' in message)) {
      if (!state.initialized) client.close(1008, 'initialize first')
      else state.announced = true
      return
    }
    if (!requestId(message.id)) {
      // Unknown client notifications are dropped. They are never upstream.
      return
    }
    state.requestCount += 1
    if (state.requestCount > 1_000_000) {
      client.close(1008, 'request lifetime bound reached')
      return
    }
    if (message.method === 'initialize') {
      if (state.initialized) {
        this.sendError(client, message.id, -32600, 'already initialized')
        return
      }
      state.initialized = true
      this.sendResult(client, message.id, {
        userAgent: `qofi-codex-native-facade/${CODEX_APP_SERVER_PROTOCOL_VERSION}`,
        codexHome: `${this.options.stateDir}/native-view`,
        platformFamily: 'unix',
        platformOs: 'macos',
      })
      return
    }
    if (!state.initialized) {
      this.sendError(client, message.id, -32000, 'initialize required')
      return
    }
    if (!SAFE_READ_METHODS.has(message.method)) {
      this.sendError(client, message.id, -32601, 'read-only native facade')
      return
    }
    try {
      const result = this.readResult(message.method, object(message.params) ? message.params : {}, state)
      this.sendResult(client, message.id, result)
    } catch (error) {
      this.sendError(client, message.id, -32602, error instanceof Error ? error.message : 'invalid params')
    }
  }

  private readResult(method: string, params: JsonObject, state: ClientState): unknown {
    switch (method) {
      case 'account/read':
        return { account: { type: 'chatgpt', email: null, planType: 'unknown' }, requiresOpenaiAuth: true }
      case 'account/rateLimits/read':
        return { rateLimits: {}, rateLimitsByLimitId: null, rateLimitResetCredits: null }
      case 'hooks/list':
        // The pinned TUI reports its launcher cwd here even when -C selects
        // the registered repo. Hooks are disabled globally, so an empty
        // synthetic response is safe for every cwd and is never forwarded.
        return { data: [] }
      case 'configRequirements/read': return { requirements: null }
      case 'skills/list': return { data: [] }
      case 'plugin/list': return { marketplaces: [], featuredPluginIds: [], marketplaceLoadErrors: [] }
      case 'collaborationMode/list': return { data: [] }
      case 'permissionProfile/list':
        return {
          data: [{
            id: 'qofi-workspace-only', allowed: true,
            description: 'Managed workspace-only profile (viewer cannot mutate)',
          }],
          nextCursor: null,
        }
      case 'model/list':
        return {
          data: [{
            id: this.model, model: this.model,
            displayName: this.model === DEFAULT_CODEX_MODEL
              ? DEFAULT_CODEX_MODEL_DISPLAY_NAME : this.model,
            description: 'Manager-selected Codex model', hidden: false, isDefault: true,
            defaultReasoningEffort: this.reasoningEffort,
            supportedReasoningEfforts: CODEX_REASONING_EFFORT_OPTIONS,
            inputModalities: ['text', 'image'], serviceTiers: [], supportsPersonality: false,
          }],
          nextCursor: null,
        }
      case 'config/read':
        this.assertOptionalCwd(params)
        return {
          config: {
            model: this.model,
            model_reasoning_effort: this.reasoningEffort,
            model_provider: 'openai',
            approval_policy: 'never',
            sandbox_mode: 'workspace-write',
            default_permissions: 'qofi-workspace-only',
            web_search: 'disabled',
            analytics: { enabled: false },
          },
          origins: {},
          layers: null,
        }
      case 'thread/list':
        return { data: [...this.allowedThreads].map(id => this.thread(id, false)), nextCursor: null, backwardsCursor: null }
      case 'thread/loaded/list':
        return { data: [...this.allowedThreads], nextCursor: null }
      case 'thread/read': {
        const id = this.boundId(params)
        return { thread: this.thread(id, params.includeTurns !== false) }
      }
      case 'thread/resume': {
        const id = this.boundId(params)
        state.subscriptions.add(id)
        const pagedTurns = object(params.initialTurnsPage)
        return {
          // Codex TUI 0.144.1 omits initialTurnsPage and restores history from
          // Thread.turns. Paged clients independently select excludeTurns,
          // matching the upstream thread/resume contract exactly.
          thread: this.thread(id, params.excludeTurns !== true),
          model: this.model,
          modelProvider: 'openai',
          cwd: this.options.repo,
          approvalPolicy: 'never',
          approvalsReviewer: 'user',
          sandbox: {
            type: 'workspaceWrite', networkAccess: false,
            writableRoots: [], excludeTmpdirEnvVar: true, excludeSlashTmp: true,
          },
          activePermissionProfile: { id: 'qofi-workspace-only', extends: ':workspace' },
          runtimeWorkspaceRoots: [this.options.repo],
          instructionSources: [],
          reasoningEffort: this.reasoningEffort,
          multiAgentMode: 'explicitRequestOnly',
          serviceTier: null,
          initialTurnsPage: pagedTurns ? this.turnsPage(id, params.initialTurnsPage as JsonObject) : null,
        }
      }
      case 'thread/turns/list': {
        const id = this.boundId(params)
        return this.turnsPage(id, params)
      }
      case 'thread/items/list':
        this.boundId(params)
        return { data: [], nextCursor: null, backwardsCursor: null }
      case 'thread/goal/get':
        this.boundId(params)
        return { goal: null }
      case 'thread/unsubscribe': {
        const id = this.boundId(params)
        const present = state.subscriptions.delete(id)
        return { status: present ? 'unsubscribed' : 'notSubscribed' }
      }
      default: throw new Error('unsupported read method')
    }
  }

  private boundId(params: JsonObject): string {
    if (!safeThreadId(params.threadId) || !this.allowedThreads.has(params.threadId)) {
      throw new Error('thread is not bound to this facade')
    }
    return params.threadId
  }

  private assertOptionalCwd(params: JsonObject): void {
    if (params.cwd !== undefined && params.cwd !== null && params.cwd !== this.options.repo) {
      throw new Error('cwd is outside the bound repository')
    }
  }

  private thread(id: string, includeTurns = true): JsonObject {
    const cached = this.threadCache.get(id) ?? this.sanitizeThread(id, { id })
    return { ...cloneBounded(cached, this.maxFrameBytes) as JsonObject,
      // Thread.turns is chronological. The paginated API defaults to newest
      // first, so reverse its bounded newest window for native TUI replay.
      turns: includeTurns ? this.turnsPage(id, {}).data.reverse() : [] }
  }

  private sanitizeThread(id: string, raw: JsonObject): JsonObject {
    const now = Math.floor(Date.now() / 1000)
    return {
      id,
      sessionId: safeThreadId(raw.sessionId) ? raw.sessionId : id,
      cliVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
      createdAt: Number.isSafeInteger(raw.createdAt) ? raw.createdAt : now,
      updatedAt: Number.isSafeInteger(raw.updatedAt) ? raw.updatedAt : now,
      cwd: this.options.repo,
      ephemeral: raw.ephemeral === true,
      modelProvider: 'openai',
      preview: typeof raw.preview === 'string' ? raw.preview.slice(0, 4096) : '',
      source: safeThreadId(raw.parentThreadId) && this.allowedThreads.has(raw.parentThreadId)
        ? {
          subAgent: {
            thread_spawn: {
              depth: 1,
              parent_thread_id: raw.parentThreadId,
              agent_nickname: typeof raw.agentNickname === 'string' ? raw.agentNickname.slice(0, 128) : null,
              agent_role: typeof raw.agentRole === 'string' ? raw.agentRole.slice(0, 128) : null,
              agent_path: null,
            },
          },
        }
        : (['cli', 'vscode', 'exec', 'appServer', 'unknown'].includes(String(raw.source))
          ? raw.source : 'appServer'),
      status: object(raw.status) ? cloneBounded(raw.status, 4096) : { type: 'idle' },
      turns: [],
      name: typeof raw.name === 'string' ? raw.name.slice(0, 256) : null,
      parentThreadId: safeThreadId(raw.parentThreadId) && this.allowedThreads.has(raw.parentThreadId)
        ? raw.parentThreadId : null,
      agentRole: typeof raw.agentRole === 'string' ? raw.agentRole.slice(0, 128) : null,
      agentNickname: typeof raw.agentNickname === 'string' ? raw.agentNickname.slice(0, 128) : null,
      extra: object(raw.extra) ? cloneBounded(raw.extra, 16 * 1024) : null,
      forkedFromId: safeThreadId(raw.forkedFromId) && this.allowedThreads.has(raw.forkedFromId)
        ? raw.forkedFromId : null,
      gitInfo: object(raw.gitInfo) ? {
        sha: typeof raw.gitInfo.sha === 'string' ? raw.gitInfo.sha.slice(0, 128) : null,
        branch: typeof raw.gitInfo.branch === 'string' ? raw.gitInfo.branch.slice(0, 256) : null,
        originUrl: null,
      } : null,
      historyMode: raw.historyMode === 'legacy' ? 'legacy' : 'paginated',
      path: null,
      recencyAt: Number.isSafeInteger(raw.recencyAt) ? raw.recencyAt : null,
      threadSource: typeof raw.threadSource === 'string' ? raw.threadSource.slice(0, 128) : null,
    }
  }

  private sanitizeTurns(turns: unknown[]): unknown[] {
    const selected: unknown[] = []
    let bytes = 2
    // Preserve the newest bounded history deterministically; pagination then
    // exposes it in chronological order.
    for (let index = turns.length - 1; index >= 0 && selected.length < 512; index -= 1) {
      let cloned: unknown
      let size: number
      try {
        cloned = cloneBounded(turns[index], this.maxFrameBytes)
        size = encoder.encode(JSON.stringify(cloned)).byteLength + 1
      } catch {
        continue
      }
      if (bytes + size > 8 * 1024 * 1024) break
      selected.unshift(cloned)
      bytes += size
    }
    return selected
  }

  private turnsPage(
    id: string,
    params: JsonObject,
  ): { data: unknown[]; nextCursor: string | null; backwardsCursor: string | null } {
    const turns = this.threadTurns.get(id) ?? []
    const direction = params.sortDirection === undefined || params.sortDirection === null
      ? 'desc' : params.sortDirection
    if (direction !== 'asc' && direction !== 'desc') throw new Error('invalid history sort direction')
    let position = direction === 'desc' ? turns.length : 0
    if (typeof params.cursor === 'string') {
      const match = params.cursor.match(/^qofi:(asc|desc):(\d{1,6})$/)
      if (!match || match[1] !== direction) throw new Error('invalid history cursor')
      position = Math.min(Number(match[2]), turns.length)
    }
    const requested = params.limit === null || params.limit === undefined ? 64 : Number(params.limit)
    if (!Number.isSafeInteger(requested) || requested < 1 || requested > 256) throw new Error('invalid history limit')
    const origin = position
    const data: unknown[] = []
    let bytes = 2
    while (data.length < requested) {
      const index = direction === 'desc' ? position - 1 : position
      if (index < 0 || index >= turns.length) break
      const item = turns[index]
      const itemBytes = encoder.encode(JSON.stringify(item)).byteLength + 1
      if (data.length > 0 && bytes + itemBytes > Math.floor(this.maxFrameBytes / 2)) break
      data.push(item)
      bytes += itemBytes
      position += direction === 'desc' ? -1 : 1
    }
    const hasMore = direction === 'desc' ? position > 0 : position < turns.length
    return {
      data,
      nextCursor: hasMore ? `qofi:${direction}:${position}` : null,
      backwardsCursor: data.length > 0
        ? `qofi:${direction === 'desc' ? 'asc' : 'desc'}:${origin}`
        : null,
    }
  }

  private sendResult(client: WebSocket, id: RequestId, result: unknown): void {
    this.send(client, { id, result })
  }

  private sendError(client: WebSocket, id: RequestId, code: number, message: string): void {
    this.send(client, { id, error: { code, message: message.slice(0, 512) } })
  }

  private send(client: WebSocket, envelope: JsonObject): void {
    const text = JSON.stringify(envelope)
    if (encoder.encode(text).byteLength > this.maxFrameBytes) {
      client.close(1009, 'response oversized')
      return
    }
    if (client.bufferedAmount > this.maxFrameBytes * 2) {
      client.close(1013, 'viewer backpressure limit')
      return
    }
    client.send(text)
  }
}
