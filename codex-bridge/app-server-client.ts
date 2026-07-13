/**
 * Minimal, fail-closed client for the Codex 0.144.1 App Server protocol.
 *
 * App Server uses JSON-RPC-shaped messages without a `jsonrpc` member.  This
 * module deliberately owns only protocol state.  Socket ownership, daemon
 * lifecycle, ACLs, authentication, and reconnect policy remain host concerns.
 */

import { isAbsolute } from 'path'

export const CODEX_APP_SERVER_PROTOCOL_VERSION = '0.144.1'

const KNOWN_SERVER_REQUEST_METHODS = [
  'item/commandExecution/requestApproval',
  'item/fileChange/requestApproval',
  'item/tool/requestUserInput',
  'mcpServer/elicitation/request',
  'item/permissions/requestApproval',
  'item/tool/call',
  'account/chatgptAuthTokens/refresh',
  'attestation/generate',
  'currentTime/read',
  'applyPatchApproval',
  'execCommandApproval',
] as const

const MAX_INITIALIZATION_BUFFERED_MESSAGES = 64
const MAX_INITIALIZATION_BUFFERED_BYTES = 8 * 1024 * 1024

export type AppServerRequestId = string | number
export type KnownServerRequestMethod = typeof KNOWN_SERVER_REQUEST_METHODS[number]

/**
 * Return this from a server-request handler when another subscribed connection
 * owns the request.  App Server 0.144.1 consumes the shared callback on either
 * a result or an error, so a non-owner must send no response at all.
 */
export const APP_SERVER_DEFER_REQUEST = Symbol('qofi.app-server.defer-request')

export type AppServerTransportClose = {
  code?: number
  reason?: string
}

export type AppServerTransportHandlers = {
  message: (message: string | Uint8Array) => void
  close: (details?: AppServerTransportClose) => void
}

/** A connected, message-oriented WebSocket transport. */
export interface AppServerTransport {
  send(message: string): void | Promise<void>
  close(code?: number, reason?: string): void | Promise<void>
  setHandlers(handlers: AppServerTransportHandlers): () => void
}

/**
 * Host-provided connector for a WebSocket carried over an absolute Unix socket.
 * Keeping this injected lets the host attest the socket and choose its WebSocket
 * implementation without giving the protocol client network or process powers.
 */
export type UnixWebSocketTransportFactory = (
  absoluteSocketPath: string,
) => AppServerTransport | Promise<AppServerTransport>

type JsonScalar = string | number | boolean | null
export type JsonValue = JsonScalar | JsonValue[] | { [key: string]: JsonValue }

type AppServerThreadConfigurationParams = {
  model?: string | null
  modelProvider?: string | null
  serviceTier?: string | null
  cwd?: string | null
  approvalPolicy?: 'untrusted' | 'on-request' | 'never' | JsonValue
  approvalsReviewer?: JsonValue
  sandbox?: 'read-only' | 'workspace-write' | 'danger-full-access' | null
  config?: Record<string, JsonValue> | null
  baseInstructions?: string | null
  developerInstructions?: string | null
  personality?: JsonValue
  /** Named permission profile selected from the supplied config layer. */
  permissions?: string | null
  runtimeWorkspaceRoots?: string[] | null
}

export type AppServerThreadStartParams = AppServerThreadConfigurationParams & {
  serviceName?: string | null
  ephemeral?: boolean | null
  sessionStartSource?: JsonValue
  threadSource?: JsonValue
}

export type AppServerThreadResumeParams = AppServerThreadConfigurationParams & {
  threadId: string
}

export type AppServerUserInput =
  | { type: 'text'; text: string; text_elements: JsonValue[] }
  | { type: 'image'; url: string; detail?: JsonValue }
  | { type: 'localImage'; path: string; detail?: JsonValue }
  | { type: 'skill' | 'mention'; name: string; path: string }

export type AppServerTurnStartParams = {
  threadId: string
  clientUserMessageId?: string | null
  input: AppServerUserInput[]
  cwd?: string | null
  approvalPolicy?: 'untrusted' | 'on-request' | 'never' | JsonValue
  approvalsReviewer?: JsonValue
  sandboxPolicy?: JsonValue
  model?: string | null
  serviceTier?: string | null
  effort?: JsonValue
  summary?: JsonValue
  personality?: JsonValue
  outputSchema?: JsonValue
}

export type AppServerThread = {
  id: string
  [key: string]: unknown
}

/** Security-relevant effective configuration returned by start/resume. */
export type AppServerEffectiveThread = {
  thread: AppServerThread
  model: string
  modelProvider: string
  cwd: string
  approvalPolicy: unknown
  approvalsReviewer: unknown
  sandbox: unknown
  reasoningEffort: string | null
  activePermissionProfile: { id: string; extends?: string | null } | null
  runtimeWorkspaceRoots: string[]
}

export type AppServerTurnTerminalStatus =
  | 'completed'
  | 'interrupted'
  | 'failed'
  | 'protocol'
  | 'disconnected'

export type AppServerTurnResult = {
  ok: boolean
  threadId: string
  turnId: string
  status: AppServerTurnTerminalStatus
  messages: string[]
  error?: string
  /** Structured upstream evidence only; never inferred from arbitrary prose. */
  quotaLimited?: true
  /** True when the server may still be running or may have accepted a request. */
  ambiguous: boolean
}

function quotaLimitErrorInfo(value: unknown): boolean {
  if (value === 'usageLimitExceeded') return true
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const record = value as Record<string, unknown>
  for (const key of [
    'httpConnectionFailed', 'responseStreamConnectionFailed',
    'responseStreamDisconnected', 'responseTooManyFailedAttempts',
  ]) {
    const detail = record[key]
    if (detail !== null && typeof detail === 'object' && !Array.isArray(detail)
      && (detail as Record<string, unknown>).httpStatusCode === 429) return true
  }
  return false
}

export type AppServerTurnHandle = {
  threadId: string
  turnId: string
  completion: Promise<AppServerTurnResult>
}

export type AppServerNotification = {
  method: string
  params?: unknown
}

export type ServerRequestHandler = (
  params: Record<string, unknown>,
  request: { id: AppServerRequestId; method: KnownServerRequestMethod },
) => JsonValue | typeof APP_SERVER_DEFER_REQUEST | Promise<JsonValue | typeof APP_SERVER_DEFER_REQUEST>

export type AppServerClientOptions = {
  clientInfo?: {
    name: string
    title?: string | null
    version: string
  }
  /** Opt into protocol fields that this client explicitly sends and validates. */
  experimentalApi?: boolean
  requestTimeoutMs?: number
  serverRequestTimeoutMs?: number
  maxInboundMessageBytes?: number
  maxOutboundMessageBytes?: number
  maxPendingRequests?: number
  maxServerRequests?: number
  maxTrackedTurns?: number
  maxAgentMessagesPerTurn?: number
  maxAgentMessageBytesPerTurn?: number
  serverRequestHandlers?: Partial<Record<KnownServerRequestMethod, ServerRequestHandler>>
  onNotification?: (notification: AppServerNotification) => void | Promise<void>
  onProtocolError?: (error: AppServerProtocolError) => void
}

type NormalizedOptions = {
  clientInfo: { name: string; title: string | null; version: string }
  experimentalApi: boolean
  requestTimeoutMs: number
  serverRequestTimeoutMs: number
  maxInboundMessageBytes: number
  maxOutboundMessageBytes: number
  maxPendingRequests: number
  maxServerRequests: number
  maxTrackedTurns: number
  maxAgentMessagesPerTurn: number
  maxAgentMessageBytesPerTurn: number
  serverRequestHandlers: Partial<Record<KnownServerRequestMethod, ServerRequestHandler>>
  onNotification?: (notification: AppServerNotification) => void | Promise<void>
  onProtocolError?: (error: AppServerProtocolError) => void
}

type ClientState = 'connecting' | 'initializing' | 'ready' | 'disconnected' | 'faulted' | 'closed'

type BufferedInitializationMessage = {
  message: Record<string, unknown>
  bytes: number
}

type PendingRequest = {
  method: string
  ambiguousOnLoss: boolean
  timer: ReturnType<typeof setTimeout>
  resolve: (result: unknown) => void
  reject: (error: Error) => void
}

type Deferred<T> = {
  promise: Promise<T>
  resolve: (value: T) => void
  reject: (error: Error) => void
}

type TurnAccumulator = {
  threadId: string
  turnId: string
  messages: string[]
  messageIds: Map<string, string>
  messageBytes: number
  terminal: boolean
  deferred: Deferred<AppServerTurnResult>
}

type ProvisionalTurn = {
  threadId: string
  failure?: AppServerRequestError
}

const encoder = new TextEncoder()
const decoder = new TextDecoder('utf-8', { fatal: true })
const knownServerRequests = new Set<string>(KNOWN_SERVER_REQUEST_METHODS)

export class AppServerProtocolError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AppServerProtocolError'
  }
}

export class AppServerRemoteError extends Error {
  readonly code: number
  readonly data: unknown

  constructor(code: number, message: string, data?: unknown) {
    super(message)
    this.name = 'AppServerRemoteError'
    this.code = code
    this.data = data
  }
}

export class AppServerRequestError extends Error {
  readonly method: string
  readonly kind: 'timeout' | 'disconnected' | 'closed'
  readonly ambiguous: boolean

  constructor(
    method: string,
    kind: 'timeout' | 'disconnected' | 'closed',
    ambiguous: boolean,
    message: string,
  ) {
    super(message)
    this.name = 'AppServerRequestError'
    this.method = method
    this.kind = kind
    this.ambiguous = ambiguous
  }
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function hasOwn(value: object, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key)
}

function isRequestId(value: unknown): value is AppServerRequestId {
  if (typeof value === 'number') return Number.isSafeInteger(value)
  return typeof value === 'string' && value.length > 0 && value.length <= 128
}

function requestKey(id: AppServerRequestId): string {
  return `${typeof id === 'number' ? 'n' : 's'}:${id}`
}

function turnKey(threadId: string, turnId: string): string {
  return `${threadId}\u0000${turnId}`
}

function assertIdentifier(value: unknown, label: string): asserts value is string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 256 || value.includes('\0')) {
    throw new AppServerProtocolError(`invalid ${label}`)
  }
}

function boundedInteger(value: number | undefined, fallback: number, min: number, max: number, name: string): number {
  const selected = value ?? fallback
  if (!Number.isSafeInteger(selected) || selected < min || selected > max) {
    throw new TypeError(`${name} must be an integer from ${min} to ${max}`)
  }
  return selected
}

function normalizeOptions(options: AppServerClientOptions): NormalizedOptions {
  const clientInfo = options.clientInfo ?? {
    name: 'qofi-codex-bridge',
    title: 'Qofi Codex Bridge',
    version: '0.1.0',
  }
  if (!/^[A-Za-z0-9._-]{1,80}$/.test(clientInfo.name)
    || !clientInfo.version
    || clientInfo.version.length > 80) {
    throw new TypeError('clientInfo name must be a safe token and version must be 1 to 80 characters')
  }
  if (options.experimentalApi !== undefined && typeof options.experimentalApi !== 'boolean') {
    throw new TypeError('experimentalApi must be boolean')
  }

  const handlers = { ...(options.serverRequestHandlers ?? {}) }
  for (const method of Object.keys(handlers)) {
    if (!knownServerRequests.has(method)) {
      throw new TypeError(`unsupported server request handler: ${method}`)
    }
  }

  return {
    clientInfo: {
      name: clientInfo.name,
      title: clientInfo.title ?? null,
      version: clientInfo.version,
    },
    experimentalApi: options.experimentalApi ?? false,
    requestTimeoutMs: boundedInteger(options.requestTimeoutMs, 30_000, 10, 300_000, 'requestTimeoutMs'),
    serverRequestTimeoutMs: boundedInteger(
      options.serverRequestTimeoutMs,
      30_000,
      10,
      300_000,
      'serverRequestTimeoutMs',
    ),
    maxInboundMessageBytes: boundedInteger(
      options.maxInboundMessageBytes,
      2 * 1024 * 1024,
      256,
      80 * 1024 * 1024,
      'maxInboundMessageBytes',
    ),
    maxOutboundMessageBytes: boundedInteger(
      options.maxOutboundMessageBytes,
      2 * 1024 * 1024,
      256,
      80 * 1024 * 1024,
      'maxOutboundMessageBytes',
    ),
    maxPendingRequests: boundedInteger(options.maxPendingRequests, 32, 1, 1024, 'maxPendingRequests'),
    maxServerRequests: boundedInteger(options.maxServerRequests, 16, 1, 1024, 'maxServerRequests'),
    maxTrackedTurns: boundedInteger(options.maxTrackedTurns, 32, 1, 1024, 'maxTrackedTurns'),
    maxAgentMessagesPerTurn: boundedInteger(
      options.maxAgentMessagesPerTurn,
      64,
      1,
      4096,
      'maxAgentMessagesPerTurn',
    ),
    maxAgentMessageBytesPerTurn: boundedInteger(
      options.maxAgentMessageBytesPerTurn,
      1024 * 1024,
      64,
      8 * 1024 * 1024,
      'maxAgentMessageBytesPerTurn',
    ),
    serverRequestHandlers: handlers,
    onNotification: options.onNotification,
    onProtocolError: options.onProtocolError,
  }
}

function extractServerVersion(userAgent: string): string | null {
  return userAgent.match(/\/(\d{1,10}\.\d{1,10}\.\d{1,10})(?:[ (]|$)/)?.[1] ?? null
}

function safeMessage(value: unknown, fallback: string): string {
  return typeof value === 'string' && value.length > 0 ? value.slice(0, 4096) : fallback
}

export class CodexAppServerClient {
  private transport: AppServerTransport
  private readonly options: NormalizedOptions
  private state: ClientState = 'connecting'
  private requestSequence = 0
  private generation = 0
  private cleanupTransport: (() => void) | null = null
  private initializationFailure: Error | null = null
  private initializationBufferedBytes = 0
  private readonly initializationMessages: BufferedInitializationMessage[] = []
  private readonly pending = new Map<string, PendingRequest>()
  private readonly activeServerRequests = new Set<string>()
  private readonly provisionalTurns = new Map<string, ProvisionalTurn>()
  private readonly earlyTurns = new Map<string, TurnAccumulator>()
  private readonly activeTurns = new Map<string, TurnAccumulator>()
  private readonly activeThreadTurns = new Map<string, TurnAccumulator>()

  private constructor(transport: AppServerTransport, options: AppServerClientOptions) {
    this.transport = transport
    this.options = normalizeOptions(options)
    this.bindTransport(transport)
  }

  static async connect(
    transport: AppServerTransport,
    options: AppServerClientOptions = {},
  ): Promise<CodexAppServerClient> {
    const client = new CodexAppServerClient(transport, options)
    try {
      await client.initializeConnection()
      return client
    } catch (error) {
      if (client.state === 'connecting' || client.state === 'initializing') client.state = 'faulted'
      client.discardInitializationMessages()
      client.closeTransport(1002, 'initialization failed')
      throw error
    }
  }

  get connectionState(): ClientState {
    return this.state
  }

  /**
   * Explicitly attach a fresh transport after loss.  Only initialize is sent;
   * pending thread/turn operations are never replayed.
   */
  async reconnect(transport: AppServerTransport): Promise<void> {
    if (this.state !== 'disconnected' && this.state !== 'faulted') {
      throw new AppServerRequestError('initialize', 'closed', false, `cannot reconnect while ${this.state}`)
    }
    this.cleanupTransport?.()
    this.cleanupTransport = null
    this.transport = transport
    this.state = 'connecting'
    this.resetInitializationBoundary()
    this.bindTransport(transport)
    try {
      await this.initializeConnection()
    } catch (error) {
      if (this.state === 'connecting' || this.state === 'initializing') this.state = 'faulted'
      this.discardInitializationMessages()
      this.closeTransport(1002, 'reinitialization failed')
      throw error
    }
  }

  async startThread(params: AppServerThreadStartParams): Promise<AppServerThread> {
    const result = await this.request('thread/start', params, true)
    return this.threadFromResponse(result, 'thread/start')
  }

  async startThreadEffective(params: AppServerThreadStartParams): Promise<AppServerEffectiveThread> {
    const result = await this.request('thread/start', params, true)
    return this.effectiveThreadFromResponse(result, 'thread/start')
  }

  async resumeThread(params: AppServerThreadResumeParams): Promise<AppServerThread> {
    assertIdentifier(params.threadId, 'threadId')
    const result = await this.request('thread/resume', params, true)
    return this.threadFromResponse(result, 'thread/resume')
  }

  async resumeThreadEffective(params: AppServerThreadResumeParams): Promise<AppServerEffectiveThread> {
    assertIdentifier(params.threadId, 'threadId')
    const result = await this.request('thread/resume', params, true)
    return this.effectiveThreadFromResponse(result, 'thread/resume')
  }

  /** Read persisted history without loading or subscribing to the thread. */
  async readThread(threadId: string, includeTurns = true): Promise<AppServerThread> {
    assertIdentifier(threadId, 'threadId')
    const result = await this.request('thread/read', { threadId, includeTurns }, false)
    return this.threadFromResponse(result, 'thread/read')
  }

  async startTurn(params: AppServerTurnStartParams): Promise<AppServerTurnHandle> {
    assertIdentifier(params.threadId, 'threadId')
    if (!Array.isArray(params.input) || params.input.length === 0) {
      throw new AppServerProtocolError('turn/start input must be a non-empty array')
    }
    if (this.activeThreadTurns.has(params.threadId) || this.provisionalTurns.has(params.threadId)) {
      throw new AppServerProtocolError(`a turn is already tracked for thread ${params.threadId}`)
    }
    if (this.activeTurns.size + this.earlyTurns.size >= this.options.maxTrackedTurns) {
      throw new AppServerProtocolError('tracked turn limit reached')
    }

    const provisional: ProvisionalTurn = { threadId: params.threadId }
    this.provisionalTurns.set(params.threadId, provisional)
    let result: unknown
    try {
      result = await this.request('turn/start', params, true)
    } catch (error) {
      this.discardProvisional(params.threadId)
      throw error
    }

    if (provisional.failure || this.state !== 'ready') {
      this.discardProvisional(params.threadId)
      throw provisional.failure ?? new AppServerRequestError(
        'turn/start',
        'disconnected',
        true,
        'connection was lost while accepting turn/start',
      )
    }

    const turn = this.turnFromStartResponse(result)
    const key = turnKey(params.threadId, turn.id)
    const accumulator = this.earlyTurns.get(key) ?? this.newAccumulator(params.threadId, turn.id)
    this.earlyTurns.delete(key)
    for (const [earlyKey, early] of this.earlyTurns) {
      if (early.threadId === params.threadId) this.earlyTurns.delete(earlyKey)
    }
    this.provisionalTurns.delete(params.threadId)

    const handle: AppServerTurnHandle = {
      threadId: params.threadId,
      turnId: turn.id,
      completion: accumulator.deferred.promise,
    }

    if (accumulator.terminal) return handle

    if (turn.status !== 'inProgress') {
      this.completeAccumulator(accumulator, turn)
      return handle
    }

    this.activeTurns.set(key, accumulator)
    this.activeThreadTurns.set(params.threadId, accumulator)
    return handle
  }

  async interrupt(threadId: string, turnId: string): Promise<void> {
    assertIdentifier(threadId, 'threadId')
    assertIdentifier(turnId, 'turnId')
    const result = await this.request('turn/interrupt', { threadId, turnId }, true)
    if (!isObject(result)) this.protocolFault('turn/interrupt returned a malformed result')
  }

  close(): void {
    if (this.state === 'closed') return
    if (this.state === 'initializing' && !this.initializationFailure) {
      this.initializationFailure = new AppServerRequestError(
        'initialize', 'closed', false, 'client closed during initialization',
      )
    }
    this.state = 'closed'
    this.discardInitializationMessages()
    this.rejectPending('closed', 'client closed')
    this.failTrackedTurns('disconnected', 'client closed', true)
    this.cleanupTransport?.()
    this.cleanupTransport = null
    this.closeTransport(1000, 'client closed')
  }

  private async initializeConnection(): Promise<void> {
    await this.issueRequest(
      'initialize',
      {
        clientInfo: this.options.clientInfo,
        capabilities: {
          experimentalApi: this.options.experimentalApi,
          requestAttestation: false,
        },
      },
      false,
      true,
    )
    // dispatchResponse validates the result and opens only the bounded inbound
    // handshake buffer in the same stack frame. Codex may place an initialize
    // response and its first notification in one JSONL chunk, but neither
    // observers, server-request handlers, nor public mutations are released
    // until our initialized notification has been handed off successfully.
    if (this.state !== 'initializing') throw this.initializationError()
    try {
      await this.sendEnvelope({ method: 'initialized' })
    } catch (error) {
      if (this.state === 'initializing') this.connectionLost('failed to send initialized notification')
      this.discardInitializationMessages()
      throw error
    }
    if (this.state !== 'initializing') throw this.initializationError()

    // Keep public calls denied while draining the bounded FIFO. Reentrant
    // inbound frames append to the same array and are consumed in wire order;
    // only a completely drained, still-live boundary becomes publicly ready.
    let index = 0
    while (index < this.initializationMessages.length) {
      if (this.state !== 'initializing') throw this.initializationError()
      const { message } = this.initializationMessages[index++]
      this.dispatchMethodMessage(message)
    }
    if (this.state !== 'initializing') throw this.initializationError()
    this.discardInitializationMessages()
    this.state = 'ready'
    this.initializationFailure = null
  }

  private bindTransport(transport: AppServerTransport): void {
    const generation = ++this.generation
    this.cleanupTransport = transport.setHandlers({
      message: message => {
        if (generation !== this.generation) return
        try {
          this.receive(message)
        } catch (error) {
          if (!(error instanceof AppServerProtocolError)) {
            try {
              this.protocolFault('unexpected message-dispatch failure')
            } catch {
              // The protocol transition is the desired outcome.
            }
          }
        }
      },
      close: details => {
        if (generation !== this.generation) return
        this.connectionLost(details?.reason || 'transport closed')
      },
    })
  }

  private async request(method: string, params: unknown, ambiguousOnLoss: boolean): Promise<unknown> {
    if (this.state !== 'ready') {
      throw new AppServerRequestError(
        method,
        this.state === 'closed' ? 'closed' : 'disconnected',
        false,
        `Codex App Server client is ${this.state}`,
      )
    }
    return this.issueRequest(method, params, ambiguousOnLoss, false)
  }

  private async issueRequest(
    method: string,
    params: unknown,
    ambiguousOnLoss: boolean,
    allowConnecting: boolean,
  ): Promise<unknown> {
    if ((!allowConnecting && this.state !== 'ready') || (allowConnecting && this.state !== 'connecting')) {
      throw new AppServerRequestError(method, 'disconnected', false, `cannot send ${method} while ${this.state}`)
    }
    if (this.pending.size >= this.options.maxPendingRequests) {
      throw new AppServerProtocolError('pending request limit reached')
    }
    if (this.requestSequence >= Number.MAX_SAFE_INTEGER) {
      throw new AppServerProtocolError('request id space exhausted')
    }

    const id = `qofi-${++this.requestSequence}`
    const key = requestKey(id)
    const wait = deferred<unknown>()
    const timer = setTimeout(() => {
      const pending = this.pending.get(key)
      if (!pending) return
      this.pending.delete(key)
      pending.reject(new AppServerRequestError(
        method,
        'timeout',
        pending.ambiguousOnLoss,
        `${method} timed out`,
      ))
      // The server may still complete a timed-out mutation.  Retire this
      // connection so no later request can be issued on an unresolved stream,
      // and so a late response cannot be mistaken for a fresh correlation.
      this.connectionLost(`${method} timed out`)
      this.closeTransport(1011, 'request timeout')
    }, this.options.requestTimeoutMs)
    this.pending.set(key, {
      method,
      ambiguousOnLoss,
      timer,
      resolve: wait.resolve,
      reject: wait.reject,
    })

    try {
      await this.sendEnvelope({ method, id, params })
    } catch (error) {
      if (error instanceof AppServerProtocolError) {
        const pending = this.pending.get(key)
        if (pending) {
          clearTimeout(pending.timer)
          this.pending.delete(key)
          pending.reject(error)
        }
      } else {
        // Once transport.send has been invoked, delivery cannot be disproved.
        // Reject through connectionLost so mutating requests retain their
        // ambiguity bit instead of surfacing an unclassified transport error.
        this.connectionLost('transport send failed')
        this.closeTransport(1011, 'transport send failed')
      }
    }
    return wait.promise
  }

  private async sendEnvelope(envelope: Record<string, unknown>): Promise<void> {
    let message: string
    try {
      message = JSON.stringify(envelope)
    } catch {
      throw new AppServerProtocolError('outbound message is not JSON serializable')
    }
    if (encoder.encode(message).byteLength > this.options.maxOutboundMessageBytes) {
      throw new AppServerProtocolError('outbound message exceeds configured byte limit')
    }
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      await Promise.race([
        Promise.resolve(this.transport.send(message)),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('transport send timed out')), this.options.requestTimeoutMs)
        }),
      ])
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  private receive(raw: string | Uint8Array): void {
    if (this.state === 'closed' || this.state === 'disconnected' || this.state === 'faulted') return
    let text: string
    let bytes: number
    try {
      bytes = typeof raw === 'string' ? encoder.encode(raw).byteLength : raw.byteLength
      if (bytes > this.options.maxInboundMessageBytes) {
        this.protocolFault('inbound message exceeds configured byte limit')
      }
      text = typeof raw === 'string' ? raw : decoder.decode(raw)
    } catch (error) {
      if (error instanceof AppServerProtocolError) return
      this.protocolFault('inbound message is not valid UTF-8')
      return
    }

    let message: unknown
    try {
      message = JSON.parse(text)
    } catch {
      this.protocolFault('inbound message is not valid JSON')
      return
    }
    if (!isObject(message)) {
      this.protocolFault('inbound message is not an object')
      return
    }

    if (hasOwn(message, 'method')) {
      if (this.state === 'connecting') {
        this.protocolFault('server sent a request or notification before initialized')
      }
      if (this.state === 'initializing') {
        this.bufferInitializationMessage(message, bytes)
        return
      }
      if (this.state !== 'ready') this.protocolFault('server message arrived outside an active connection')
      this.dispatchMethodMessage(message)
      return
    }

    this.dispatchResponse(message)
  }

  private dispatchResponse(message: Record<string, unknown>): void {
    if (!isRequestId(message.id)
      || hasOwn(message, 'params')
      || hasOwn(message, 'result') === hasOwn(message, 'error')) {
      this.protocolFault('malformed response envelope')
      return
    }
    const key = requestKey(message.id)
    const pending = this.pending.get(key)
    if (!pending) {
      this.protocolFault('response has an unknown or duplicate request id')
      return
    }
    clearTimeout(pending.timer)
    this.pending.delete(key)

    if (hasOwn(message, 'error')) {
      const error = message.error
      if (!isObject(error) || !Number.isSafeInteger(error.code) || typeof error.message !== 'string') {
        pending.reject(new AppServerProtocolError('malformed JSON-RPC error response'))
        this.protocolFault('malformed JSON-RPC error response')
        return
      }
      pending.reject(new AppServerRemoteError(error.code as number, safeMessage(error.message, 'remote error'), error.data))
      return
    }
    if (pending.method === 'initialize') {
      try {
        this.validateInitializeResult(message.result)
      } catch (error) {
        pending.reject(error instanceof Error ? error : new AppServerProtocolError('initialize validation failed'))
        throw error
      }
      // Open the inbound gate in the same stack frame that consumes the valid
      // response. A following JSONL line can otherwise beat the Promise
      // continuation in initializeConnection. This state is deliberately not
      // public readiness: method-bearing frames are only buffered here.
      this.state = 'initializing'
    }
    pending.resolve(message.result)
  }

  private dispatchMethodMessage(message: Record<string, unknown>): void {
    if (typeof message.method !== 'string' || message.method.length === 0 || message.method.length > 256
      || hasOwn(message, 'result') || hasOwn(message, 'error')) {
      this.rejectMalformedServerMessage(message)
      return
    }
    const method = message.method
    if (hasOwn(message, 'id')) {
      void this.dispatchServerRequest(message, this.generation).catch(error => {
        if (error instanceof AppServerProtocolError) return
        try {
          this.protocolFault('unexpected server-request dispatch failure')
        } catch {
          // The protocol transition is the desired outcome.
        }
      })
    } else {
      this.dispatchNotification(method, message.params)
    }
  }

  private bufferInitializationMessage(message: Record<string, unknown>, bytes: number): void {
    const byteLimit = Math.min(this.options.maxInboundMessageBytes, MAX_INITIALIZATION_BUFFERED_BYTES)
    if (this.initializationMessages.length >= MAX_INITIALIZATION_BUFFERED_MESSAGES
      || this.initializationBufferedBytes + bytes > byteLimit) {
      this.protocolFault('initialization message buffer limit exceeded')
    }
    this.initializationMessages.push({ message, bytes })
    this.initializationBufferedBytes += bytes
  }

  private discardInitializationMessages(): void {
    this.initializationMessages.length = 0
    this.initializationBufferedBytes = 0
  }

  private resetInitializationBoundary(): void {
    this.initializationFailure = null
    this.discardInitializationMessages()
  }

  private initializationError(): Error {
    return this.initializationFailure ?? new AppServerRequestError(
      'initialize', 'disconnected', false, 'connection lost during initialization',
    )
  }

  private validateInitializeResult(result: unknown): void {
    if (!isObject(result)
      || typeof result.userAgent !== 'string'
      || !/^[\x20-\x7e]{1,1024}$/.test(result.userAgent)
      || typeof result.codexHome !== 'string'
      || result.codexHome.length === 0
      || result.codexHome.length > 4096
      || result.codexHome.includes('\0')
      || !isAbsolute(result.codexHome)
      || typeof result.platformFamily !== 'string'
      || !/^[A-Za-z0-9._-]{1,64}$/.test(result.platformFamily)
      || typeof result.platformOs !== 'string'
      || !/^[A-Za-z0-9._-]{1,64}$/.test(result.platformOs)) {
      this.protocolFault('initialize returned a malformed result')
    }
    const serverVersion = extractServerVersion(result.userAgent)
    if (serverVersion !== CODEX_APP_SERVER_PROTOCOL_VERSION) {
      this.protocolFault(
        `unsupported Codex App Server version ${serverVersion ?? 'unknown'}; expected ${CODEX_APP_SERVER_PROTOCOL_VERSION}`,
      )
    }
  }

  private dispatchNotification(method: string, params: unknown): void {
    if (method === 'item/completed') {
      this.consumeItemCompleted(params)
    } else if (method === 'turn/completed') {
      this.consumeTurnCompleted(params)
    }
    if (this.state === 'faulted') return
    try {
      const outcome = this.options.onNotification?.({ method, params })
      if (outcome && typeof (outcome as Promise<void>).catch === 'function') {
        void (outcome as Promise<void>).catch(() => {})
      }
    } catch {
      // Observer failures must not alter protocol state.
    }
  }

  private consumeItemCompleted(params: unknown): void {
    if (!isObject(params)) {
      this.protocolFault('item/completed has malformed params')
      return
    }
    try {
      assertIdentifier(params.threadId, 'item/completed threadId')
      assertIdentifier(params.turnId, 'item/completed turnId')
    } catch (error) {
      this.protocolFault((error as Error).message)
      return
    }
    if (!isObject(params.item) || typeof params.item.type !== 'string' || typeof params.item.id !== 'string') {
      this.protocolFault('item/completed has a malformed item')
      return
    }
    if (params.item.type !== 'agentMessage') return
    if (typeof params.item.text !== 'string') {
      this.protocolFault('completed agentMessage has no text')
      return
    }
    const accumulator = this.accumulatorForEvent(params.threadId, params.turnId)
    if (!accumulator) return
    this.appendAgentMessage(accumulator, params.item.id, params.item.text)
  }

  private consumeTurnCompleted(params: unknown): void {
    if (!isObject(params) || !isObject(params.turn)) {
      this.protocolFault('turn/completed has malformed params')
      return
    }
    try {
      assertIdentifier(params.threadId, 'turn/completed threadId')
      assertIdentifier(params.turn.id, 'turn/completed turnId')
    } catch (error) {
      this.protocolFault((error as Error).message)
      return
    }
    const accumulator = this.accumulatorForEvent(params.threadId, params.turn.id)
    if (!accumulator) return
    this.completeAccumulator(accumulator, params.turn)
  }

  private accumulatorForEvent(threadId: string, turnId: string): TurnAccumulator | null {
    const key = turnKey(threadId, turnId)
    const active = this.activeTurns.get(key)
    if (active) return active
    const provisional = this.provisionalTurns.get(threadId)
    if (!provisional || provisional.failure) return null
    const existing = this.earlyTurns.get(key)
    if (existing) return existing
    if (this.activeTurns.size + this.earlyTurns.size >= this.options.maxTrackedTurns) {
      this.protocolFault('tracked turn limit reached while buffering early events')
      return null
    }
    const accumulator = this.newAccumulator(threadId, turnId)
    this.earlyTurns.set(key, accumulator)
    return accumulator
  }

  private newAccumulator(threadId: string, turnId: string): TurnAccumulator {
    return {
      threadId,
      turnId,
      messages: [],
      messageIds: new Map(),
      messageBytes: 0,
      terminal: false,
      deferred: deferred<AppServerTurnResult>(),
    }
  }

  private appendAgentMessage(accumulator: TurnAccumulator, itemId: string, text: string): void {
    if (accumulator.terminal) {
      this.protocolFault('agentMessage arrived after the terminal turn notification')
      return
    }
    if (!itemId || itemId.length > 256) {
      this.protocolFault('completed agentMessage has an invalid id')
      return
    }
    const prior = accumulator.messageIds.get(itemId)
    if (prior !== undefined) {
      if (prior !== text) this.protocolFault('completed agentMessage id was reused with different text')
      return
    }
    const bytes = encoder.encode(text).byteLength
    if (accumulator.messages.length >= this.options.maxAgentMessagesPerTurn
      || accumulator.messageBytes + bytes > this.options.maxAgentMessageBytesPerTurn) {
      this.protocolFault('completed agentMessage accumulation limit exceeded')
      return
    }
    accumulator.messageIds.set(itemId, text)
    accumulator.messages.push(text)
    accumulator.messageBytes += bytes
  }

  private completeAccumulator(accumulator: TurnAccumulator, turn: Record<string, unknown>): void {
    if (accumulator.terminal) {
      this.protocolFault('duplicate terminal notification for a turn')
      return
    }
    if (turn.id !== accumulator.turnId) {
      this.protocolFault('terminal turn id does not match its envelope')
      return
    }
    if (!Array.isArray(turn.items)) {
      this.protocolFault('terminal turn has malformed items')
    }
    for (const item of turn.items) {
      if (isObject(item) && item.type === 'agentMessage' && typeof item.id === 'string' && typeof item.text === 'string') {
        this.appendAgentMessage(accumulator, item.id, item.text)
        if (this.state === 'faulted') return
      }
    }

    const status = turn.status
    if (status !== 'completed' && status !== 'interrupted' && status !== 'failed') {
      this.protocolFault('turn/completed contains a non-terminal status')
      return
    }
    accumulator.terminal = true
    const key = turnKey(accumulator.threadId, accumulator.turnId)
    this.activeTurns.delete(key)
    if (this.activeThreadTurns.get(accumulator.threadId) === accumulator) {
      this.activeThreadTurns.delete(accumulator.threadId)
    }
    // A completion can beat the turn/start response. Keep that bounded early
    // accumulator until the correlated response supplies the authoritative ID.
    if (!this.provisionalTurns.has(accumulator.threadId)) this.earlyTurns.delete(key)

    const errorObject = isObject(turn.error) ? turn.error : null
    const quotaLimited = status === 'failed' && quotaLimitErrorInfo(errorObject?.codexErrorInfo)
    const error = status === 'failed'
      ? safeMessage(errorObject?.message, 'turn failed')
      : status === 'interrupted' ? 'turn interrupted' : undefined
    accumulator.deferred.resolve({
      ok: status === 'completed',
      threadId: accumulator.threadId,
      turnId: accumulator.turnId,
      status,
      messages: [...accumulator.messages],
      ...(error ? { error } : {}),
      ...(quotaLimited ? { quotaLimited: true as const } : {}),
      ambiguous: false,
    })
  }

  private turnFromStartResponse(result: unknown): { id: string; status: string; items?: unknown[]; error?: unknown } {
    if (!isObject(result) || !isObject(result.turn)) {
      this.protocolFault('turn/start returned a malformed result')
    }
    const turn = result.turn
    assertIdentifier(turn.id, 'turn/start turn id')
    if (!Array.isArray(turn.items)) this.protocolFault('turn/start returned malformed turn items')
    if (turn.status !== 'inProgress'
      && turn.status !== 'completed'
      && turn.status !== 'interrupted'
      && turn.status !== 'failed') {
      this.protocolFault('turn/start returned an invalid turn status')
    }
    return turn as { id: string; status: string; items?: unknown[]; error?: unknown }
  }

  private threadFromResponse(result: unknown, method: string): AppServerThread {
    if (!isObject(result) || !isObject(result.thread)) {
      this.protocolFault(`${method} returned a malformed result`)
    }
    assertIdentifier(result.thread.id, `${method} thread id`)
    return result.thread as AppServerThread
  }

  private effectiveThreadFromResponse(result: unknown, method: string): AppServerEffectiveThread {
    const thread = this.threadFromResponse(result, method)
    if (!isObject(result)
      || typeof result.model !== 'string' || result.model.length === 0 || result.model.length > 128
      || typeof result.modelProvider !== 'string' || result.modelProvider.length === 0 || result.modelProvider.length > 128
      || typeof result.cwd !== 'string' || !isAbsolute(result.cwd)
      || !hasOwn(result, 'approvalPolicy')
      || !hasOwn(result, 'approvalsReviewer')
      || !hasOwn(result, 'sandbox')
      || !hasOwn(result, 'reasoningEffort')
      || (result.reasoningEffort !== null
        && (typeof result.reasoningEffort !== 'string'
          || result.reasoningEffort.length === 0
          || result.reasoningEffort.length > 64))) {
      this.protocolFault(`${method} returned malformed effective configuration`)
    }
    let activePermissionProfile: AppServerEffectiveThread['activePermissionProfile'] = null
    if (result.activePermissionProfile !== undefined && result.activePermissionProfile !== null) {
      if (!isObject(result.activePermissionProfile)
        || typeof result.activePermissionProfile.id !== 'string'
        || result.activePermissionProfile.id.length === 0
        || result.activePermissionProfile.id.length > 128
        || (result.activePermissionProfile.extends !== undefined
          && result.activePermissionProfile.extends !== null
          && typeof result.activePermissionProfile.extends !== 'string')) {
        this.protocolFault(`${method} returned malformed active permission profile`)
      }
      activePermissionProfile = {
        id: result.activePermissionProfile.id,
        extends: result.activePermissionProfile.extends as string | null | undefined,
      }
    }
    const runtimeWorkspaceRoots = result.runtimeWorkspaceRoots ?? []
    if (!Array.isArray(runtimeWorkspaceRoots)
      || runtimeWorkspaceRoots.length > 64
      || runtimeWorkspaceRoots.some(root => typeof root !== 'string' || !isAbsolute(root))) {
      this.protocolFault(`${method} returned malformed runtime workspace roots`)
    }
    return {
      thread,
      model: result.model,
      modelProvider: result.modelProvider,
      cwd: result.cwd,
      approvalPolicy: result.approvalPolicy,
      approvalsReviewer: result.approvalsReviewer,
      sandbox: result.sandbox,
      reasoningEffort: result.reasoningEffort as string | null,
      activePermissionProfile,
      runtimeWorkspaceRoots: [...runtimeWorkspaceRoots] as string[],
    }
  }

  private async dispatchServerRequest(message: Record<string, unknown>, generation: number): Promise<void> {
    const id = message.id
    const method = message.method as string
    if (!isRequestId(id)) {
      this.protocolFault('server request has an invalid id')
      return
    }
    const key = `${generation}:${requestKey(id)}`
    if (this.activeServerRequests.has(key)) {
      this.protocolFault('server reused an active request id')
      return
    }
    if (!isObject(message.params)) {
      await this.sendServerError(id, -32602, 'invalid server request params', generation)
      return
    }
    if (!knownServerRequests.has(method)) {
      await this.sendServerError(id, -32601, 'unsupported server request method', generation)
      return
    }
    if (this.activeServerRequests.size >= this.options.maxServerRequests) {
      await this.sendServerError(id, -32000, 'server request limit reached', generation)
      return
    }
    const handler = this.options.serverRequestHandlers[method as KnownServerRequestMethod]
    if (!handler) {
      await this.sendServerError(id, -32001, 'server request refused by client policy', generation)
      return
    }

    this.activeServerRequests.add(key)
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('server request handler timed out')), this.options.serverRequestTimeoutMs)
      })
      const result = await Promise.race([
        Promise.resolve(handler(message.params, { id, method: method as KnownServerRequestMethod })),
        timeout,
      ])
      if (generation !== this.generation || this.state !== 'ready') return
      if (result === APP_SERVER_DEFER_REQUEST) return
      if (result === undefined) throw new Error('server request handler returned undefined')
      try {
        await this.sendEnvelope({ id, result })
      } catch (error) {
        if (error instanceof AppServerProtocolError) {
          await this.sendServerError(id, -32002, safeMessage(error.message, 'invalid handler result'), generation)
        } else {
          this.connectionLost('transport send failed')
        }
      }
    } catch (error) {
      await this.sendServerError(
        id,
        -32002,
        safeMessage((error as Error)?.message, 'server request handler failed'),
        generation,
      )
    } finally {
      if (timer) clearTimeout(timer)
      this.activeServerRequests.delete(key)
    }
  }

  private async sendServerError(
    id: AppServerRequestId,
    code: number,
    message: string,
    generation = this.generation,
  ): Promise<void> {
    if (generation !== this.generation) return
    try {
      await this.sendEnvelope({ id, error: { code, message: message.slice(0, 512) } })
    } catch {
      this.connectionLost('failed to reject server request')
    }
  }

  private rejectMalformedServerMessage(message: Record<string, unknown>): void {
    if (isRequestId(message.id)) {
      void this.sendServerError(message.id, -32600, 'malformed server request', this.generation)
      return
    }
    this.protocolFault('malformed server message')
  }

  private discardProvisional(threadId: string): void {
    this.provisionalTurns.delete(threadId)
    for (const [key, early] of this.earlyTurns) {
      if (early.threadId === threadId) this.earlyTurns.delete(key)
    }
  }

  private connectionLost(reason: string): void {
    if (this.state === 'closed' || this.state === 'disconnected' || this.state === 'faulted') return
    if (this.state === 'initializing' && !this.initializationFailure) {
      this.initializationFailure = new AppServerRequestError(
        'initialize', 'disconnected', false, reason,
      )
    }
    this.state = 'disconnected'
    this.discardInitializationMessages()
    this.rejectPending('disconnected', reason)
    const failure = new AppServerRequestError('turn/start', 'disconnected', true, reason)
    for (const provisional of this.provisionalTurns.values()) provisional.failure = failure
    this.failTrackedTurns('disconnected', reason, true)
    this.earlyTurns.clear()
    this.activeServerRequests.clear()
  }

  private rejectPending(kind: 'disconnected' | 'closed', reason: string): void {
    for (const [key, pending] of this.pending) {
      clearTimeout(pending.timer)
      this.pending.delete(key)
      pending.reject(new AppServerRequestError(
        pending.method,
        kind,
        pending.ambiguousOnLoss,
        `${pending.method}: ${reason}`,
      ))
    }
  }

  private failTrackedTurns(
    status: 'protocol' | 'disconnected',
    error: string,
    ambiguous: boolean,
  ): void {
    for (const accumulator of this.activeTurns.values()) {
      if (accumulator.terminal) continue
      accumulator.terminal = true
      accumulator.deferred.resolve({
        ok: false,
        threadId: accumulator.threadId,
        turnId: accumulator.turnId,
        status,
        messages: [...accumulator.messages],
        error,
        ambiguous,
      })
    }
    this.activeTurns.clear()
    this.activeThreadTurns.clear()
  }

  private protocolFault(message: string): never {
    const error = new AppServerProtocolError(message)
    if (this.state !== 'faulted' && this.state !== 'closed') {
      if (this.state === 'initializing' && !this.initializationFailure) {
        this.initializationFailure = error
      }
      this.state = 'faulted'
      this.discardInitializationMessages()
      this.rejectPending('disconnected', message)
      const failure = new AppServerRequestError('turn/start', 'disconnected', true, message)
      for (const provisional of this.provisionalTurns.values()) provisional.failure = failure
      this.failTrackedTurns('protocol', message, true)
      this.earlyTurns.clear()
      this.activeServerRequests.clear()
      try {
        this.options.onProtocolError?.(error)
      } catch {
        // Diagnostics must not prevent the fail-closed transition.
      }
      this.closeTransport(1002, 'protocol error')
    }
    throw error
  }

  private closeTransport(code: number, reason: string): void {
    try {
      const closed = this.transport.close(code, reason)
      if (closed && typeof (closed as Promise<void>).catch === 'function') {
        void (closed as Promise<void>).catch(() => {})
      }
    } catch {
      // State has already transitioned; transport close is best effort.
    }
  }
}

export async function connectCodexAppServerOverUnixWebSocket(
  absoluteSocketPath: string,
  transportFactory: UnixWebSocketTransportFactory,
  options: AppServerClientOptions = {},
): Promise<CodexAppServerClient> {
  if (!isAbsolute(absoluteSocketPath) || absoluteSocketPath.includes('\0')) {
    throw new TypeError('Codex App Server Unix socket path must be absolute')
  }
  const transport = await transportFactory(absoluteSocketPath)
  return CodexAppServerClient.connect(transport, options)
}
