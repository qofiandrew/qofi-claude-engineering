import { describe, expect, test } from 'bun:test'
import {
  APP_SERVER_DEFER_REQUEST,
  AppServerProtocolError,
  AppServerRemoteError,
  AppServerRequestError,
  CODEX_APP_SERVER_PROTOCOL_VERSION,
  CodexAppServerClient,
  connectCodexAppServerOverUnixWebSocket,
  type AppServerTransport,
  type AppServerTransportClose,
  type AppServerTransportHandlers,
  type AppServerTurnHandle,
} from './app-server-client.ts'

class FakeTransport implements AppServerTransport {
  sent: Array<Record<string, unknown>> = []
  closes: Array<{ code?: number; reason?: string }> = []
  onSend?: (message: Record<string, unknown>) => void
  sendGate?: Promise<void>
  gateOnMethod?: string
  methodGate?: Promise<void>
  failOnMethod?: string
  private handlers: AppServerTransportHandlers | null = null

  send(text: string): void | Promise<void> {
    const message = JSON.parse(text) as Record<string, unknown>
    this.sent.push(message)
    this.onSend?.(message)
    if (this.failOnMethod !== undefined && message.method === this.failOnMethod) {
      return Promise.reject(new Error(`failed to send ${this.failOnMethod}`))
    }
    if (this.gateOnMethod !== undefined && message.method === this.gateOnMethod) {
      return this.methodGate
    }
    return this.sendGate
  }

  close(code?: number, reason?: string): void {
    this.closes.push({ code, reason })
  }

  setHandlers(handlers: AppServerTransportHandlers): () => void {
    this.handlers = handlers
    return () => {
      if (this.handlers === handlers) this.handlers = null
    }
  }

  emit(message: unknown): void {
    this.handlers?.message(JSON.stringify(message))
  }

  emitRaw(message: string | Uint8Array): void {
    this.handlers?.message(message)
  }

  emitClose(details: AppServerTransportClose = {}): void {
    this.handlers?.close(details)
  }

  request(method: string, occurrence = 0): Record<string, unknown> {
    const messages = this.sent.filter(message => message.method === method && 'id' in message)
    const message = messages[occurrence]
    if (!message) throw new Error(`missing ${method} request ${occurrence}`)
    return message
  }
}

function withAutomaticInitialize(
  userAgent = `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
): FakeTransport {
  const transport = new FakeTransport()
  transport.onSend = message => {
    if (message.method !== 'initialize') return
    transport.emit({
      id: message.id,
      result: {
        userAgent,
        codexHome: '/private/var/qofi-codex/.codex',
        platformFamily: 'unix',
        platformOs: 'macos',
      },
    })
  }
  return transport
}

async function connected(
  options: Parameters<typeof CodexAppServerClient.connect>[1] = {},
): Promise<{ client: CodexAppServerClient; transport: FakeTransport }> {
  const transport = withAutomaticInitialize()
  const client = await CodexAppServerClient.connect(transport, options)
  return { client, transport }
}

function response(transport: FakeTransport, request: Record<string, unknown>, result: unknown): void {
  transport.emit({ id: request.id, result })
}

function responseTurn(
  transport: FakeTransport,
  request: Record<string, unknown>,
  turnId: string,
  status = 'inProgress',
): void {
  response(transport, request, {
    turn: {
      id: turnId,
      status,
      items: [],
      itemsView: { type: 'full' },
      error: null,
    },
  })
}

async function beginTurn(
  client: CodexAppServerClient,
  transport: FakeTransport,
  threadId: string,
  turnId: string,
): Promise<AppServerTurnHandle> {
  const pending = client.startTurn({
    threadId,
    input: [{ type: 'text', text: 'hello', text_elements: [] }],
  })
  const turnRequests = transport.sent.filter(message => message.method === 'turn/start' && 'id' in message)
  const request = turnRequests.at(-1)
  if (!request) throw new Error('missing turn/start request')
  responseTurn(transport, request, turnId)
  return pending
}

function terminalTurn(
  threadId: string,
  turnId: string,
  status: 'completed' | 'interrupted' | 'failed',
  options: { message?: string; items?: unknown[]; errorInfo?: unknown } = {},
): Record<string, unknown> {
  return {
    method: 'turn/completed',
    params: {
      threadId,
      turn: {
        id: turnId,
        status,
        items: options.items ?? [],
        itemsView: { type: 'full' },
        error: status === 'failed' ? {
          message: options.message ?? 'failed',
          ...(('errorInfo' in options) ? { codexErrorInfo: options.errorInfo } : {}),
        } : null,
      },
    },
  }
}

async function flush(): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('CodexAppServerClient initialization', () => {
  test('requires initialize response before sending initialized', async () => {
    const transport = new FakeTransport()
    const pending = CodexAppServerClient.connect(transport, {
      clientInfo: { name: 'qofi-test', title: 'Qofi Test', version: '9.8.7' },
    })

    expect(transport.sent.map(message => message.method)).toEqual(['initialize'])
    const initialize = transport.request('initialize')
    expect(initialize.params).toEqual({
      clientInfo: { name: 'qofi-test', title: 'Qofi Test', version: '9.8.7' },
      capabilities: { experimentalApi: false, requestAttestation: false },
    })

    response(transport, initialize, {
      userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
      codexHome: '/runtime/.codex',
      platformFamily: 'unix',
      platformOs: 'macos',
    })
    const client = await pending
    expect(transport.sent.map(message => message.method)).toEqual(['initialize', 'initialized'])
    expect(transport.sent[1]).toEqual({ method: 'initialized' })
    expect(client.connectionState).toBe('ready')
  })

  test('advertises experimental protocol fields only on explicit boolean opt-in', async () => {
    const transport = withAutomaticInitialize()
    const client = await CodexAppServerClient.connect(transport, { experimentalApi: true })
    expect(transport.request('initialize').params).toEqual({
      clientInfo: { name: 'qofi-codex-bridge', title: 'Qofi Codex Bridge', version: '0.1.0' },
      capabilities: { experimentalApi: true, requestAttestation: false },
    })
    expect(client.connectionState).toBe('ready')

    await expect(CodexAppServerClient.connect(
      new FakeTransport(),
      { experimentalApi: 'true' } as unknown as Parameters<typeof CodexAppServerClient.connect>[1],
    )).rejects.toThrow('experimentalApi must be boolean')
  })

  test('rejects any server protocol version other than the pinned CLI', async () => {
    const transport = withAutomaticInitialize('qofi-test/0.145.0 (Mac OS; arm64)')
    await expect(CodexAppServerClient.connect(transport)).rejects.toThrow(
      `expected ${CODEX_APP_SERVER_PROTOCOL_VERSION}`,
    )
    expect(transport.closes.some(close => close.code === 1002)).toBe(true)
  })

  test('bounds hostile initialize identity fields before version parsing or diagnostics', async () => {
    const versionPrefix = 'qofi-test/9999999999.1.1 '
    const exactBound = versionPrefix + 'x'.repeat(1024 - versionPrefix.length)
    const bounded = withAutomaticInitialize(exactBound)
    const versionError = await CodexAppServerClient.connect(bounded).catch(value => value)
    expect(versionError).toBeInstanceOf(AppServerProtocolError)
    expect(versionError.message).toContain('unsupported Codex App Server version')
    expect(versionError.message.length).toBeLessThan(256)

    const oversized = withAutomaticInitialize(exactBound + 'x')
    const error = await CodexAppServerClient.connect(oversized).catch(value => value)
    expect(error).toBeInstanceOf(AppServerProtocolError)
    expect(error.message).toBe('initialize returned a malformed result')
  })

  test('rejects malformed initialize results', async () => {
    const transport = new FakeTransport()
    transport.onSend = message => {
      if (message.method === 'initialize') transport.emit({ id: message.id, result: { userAgent: 'bad' } })
    }
    await expect(CodexAppServerClient.connect(transport)).rejects.toBeInstanceOf(AppServerProtocolError)
  })

  test('accepts a notification coalesced immediately after the initialize response', async () => {
    const notifications: string[] = []
    const transport = new FakeTransport()
    transport.onSend = message => {
      if (message.method !== 'initialize') return
      transport.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      // Codex can write this as the next JSONL line in the same stdout chunk,
      // before the initialize Promise continuation gets a microtask turn.
      transport.emit({
        method: 'remoteControl/status/changed',
        params: { status: 'disabled' },
      })
    }

    const client = await CodexAppServerClient.connect(transport, {
      onNotification: notification => notifications.push(notification.method),
    })
    expect(client.connectionState).toBe('ready')
    expect(notifications).toEqual(['remoteControl/status/changed'])
    expect(transport.sent.map(message => message.method)).toEqual(['initialize', 'initialized'])
  })

  test('does not release coalesced notifications or server requests before initialized settles', async () => {
    const notifications: string[] = []
    const requests: unknown[] = []
    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    const transport = new FakeTransport()
    transport.gateOnMethod = 'initialized'
    transport.methodGate = gate
    transport.onSend = message => {
      if (message.method !== 'initialize') return
      transport.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      transport.emit({ method: 'remoteControl/status/changed', params: { status: 'disabled' } })
      transport.emit({ id: 'time-during-init', method: 'currentTime/read', params: {} })
    }

    const pending = CodexAppServerClient.connect(transport, {
      onNotification: notification => notifications.push(notification.method),
      serverRequestHandlers: {
        'currentTime/read': params => {
          requests.push(params)
          return { currentTimeAt: 1 }
        },
      },
    })
    await flush()
    expect(notifications).toEqual([])
    expect(requests).toEqual([])
    expect(transport.sent.map(message => message.method)).toEqual(['initialize', 'initialized'])

    release()
    const client = await pending
    await flush()
    expect(client.connectionState).toBe('ready')
    expect(notifications).toEqual(['remoteControl/status/changed'])
    expect(requests).toEqual([{}])
    expect(transport.sent.find(message => message.id === 'time-during-init')).toEqual({
      id: 'time-during-init', result: { currentTimeAt: 1 },
    })
    expect(transport.sent.findIndex(message => message.method === 'initialized'))
      .toBeLessThan(transport.sent.findIndex(message => message.id === 'time-during-init'))
  })

  test('discards coalesced callbacks when initialized fails', async () => {
    const notifications: string[] = []
    const handled: unknown[] = []
    const transport = new FakeTransport()
    transport.failOnMethod = 'initialized'
    transport.onSend = message => {
      if (message.method !== 'initialize') return
      transport.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      transport.emit({ method: 'remoteControl/status/changed', params: { status: 'disabled' } })
      transport.emit({ id: 'must-not-run', method: 'currentTime/read', params: {} })
    }

    await expect(CodexAppServerClient.connect(transport, {
      onNotification: notification => notifications.push(notification.method),
      serverRequestHandlers: {
        'currentTime/read': params => { handled.push(params); return { currentTimeAt: 1 } },
      },
    })).rejects.toThrow('failed to send initialized')
    expect(notifications).toEqual([])
    expect(handled).toEqual([])
    expect(transport.sent.some(message => message.id === 'must-not-run')).toBe(false)
  })

  test('does not send initialized after a same-chunk post-response protocol fault', async () => {
    const transport = new FakeTransport()
    transport.onSend = message => {
      if (message.method !== 'initialize') return
      transport.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      transport.emitRaw('{not-json')
    }

    await expect(CodexAppServerClient.connect(transport)).rejects.toThrow(
      'inbound message is not valid JSON',
    )
    expect(transport.sent.map(message => message.method)).toEqual(['initialize'])
  })

  test('buffers malformed method envelopes without any pre-ack response', async () => {
    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    const transport = new FakeTransport()
    transport.gateOnMethod = 'initialized'
    transport.methodGate = gate
    transport.onSend = message => {
      if (message.method !== 'initialize') return
      transport.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      transport.emit({ id: 'malformed', method: 'currentTime/read', params: {}, result: {} })
    }

    const pending = CodexAppServerClient.connect(transport)
    await flush()
    expect(transport.sent.map(message => message.method)).toEqual(['initialize', 'initialized'])
    expect(transport.sent.some(message => message.id === 'malformed')).toBe(false)
    release()
    await pending
    await flush()
    expect((transport.sent.find(message => message.id === 'malformed')?.error as any).code).toBe(-32600)
  })

  test('bounds coalesced initialization messages before releasing any callback', async () => {
    const notifications: string[] = []
    const transport = new FakeTransport()
    transport.onSend = message => {
      if (message.method !== 'initialize') return
      transport.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      for (let index = 0; index < 65; index += 1) {
        transport.emit({ method: 'queued/status', params: { index } })
      }
    }
    await expect(CodexAppServerClient.connect(transport, {
      onNotification: notification => notifications.push(notification.method),
    })).rejects.toThrow('initialization message buffer limit exceeded')
    expect(notifications).toEqual([])
    expect(transport.sent.map(message => message.method)).toEqual(['initialize'])
  })

  test('still faults on a server message before a valid initialize response', async () => {
    const protocolErrors: string[] = []
    const transport = new FakeTransport()
    transport.onSend = message => {
      if (message.method === 'initialize') {
        transport.emit({ method: 'remoteControl/status/changed', params: { status: 'disabled' } })
      }
    }

    await expect(CodexAppServerClient.connect(transport, {
      onProtocolError: error => protocolErrors.push(error.message),
    })).rejects.toThrow('server sent a request or notification before initialized')
    expect(protocolErrors).toEqual(['server sent a request or notification before initialized'])
    expect(transport.sent.map(message => message.method)).toEqual(['initialize'])
    expect(transport.closes.some(close => close.code === 1002)).toBe(true)
  })

  test('fails closed when the initialized notification cannot be sent', async () => {
    const transport = withAutomaticInitialize()
    transport.failOnMethod = 'initialized'

    await expect(CodexAppServerClient.connect(transport)).rejects.toThrow('failed to send initialized')
    expect(transport.sent.map(message => message.method)).toEqual(['initialize', 'initialized'])
    expect(transport.closes.some(close => close.code === 1002)).toBe(true)
  })

  test('accepts notifications emitted as soon as initialized is handed to the transport', async () => {
    const notifications: string[] = []
    const transport = new FakeTransport()
    transport.onSend = message => {
      if (message.method === 'initialize') {
        transport.emit({
          id: message.id,
          result: {
            userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
            codexHome: '/runtime/.codex',
            platformFamily: 'unix',
            platformOs: 'macos',
          },
        })
      } else if (message.method === 'initialized') {
        transport.emit({
          method: 'thread/status/changed',
          params: { threadId: 'thread-1', status: { type: 'idle' } },
        })
      }
    }

    const client = await CodexAppServerClient.connect(transport, {
      onNotification: notification => notifications.push(notification.method),
    })
    expect(client.connectionState).toBe('ready')
    expect(notifications).toEqual(['thread/status/changed'])
  })
})

describe('request correlation and bounds', () => {
  test('returns the effective thread configuration for manager-side authority checks', async () => {
    const { client, transport } = await connected()
    const pending = client.resumeThreadEffective({ threadId: 'thread-one', cwd: '/repo' })
    const request = transport.request('thread/resume')
    response(transport, request, {
      thread: { id: 'thread-one' },
      model: 'gpt-test',
      modelProvider: 'openai',
      cwd: '/repo',
      approvalPolicy: 'never',
      approvalsReviewer: 'user',
      sandbox: { type: 'workspaceWrite', networkAccess: false },
      reasoningEffort: 'ultra',
      activePermissionProfile: { id: 'qofi-workspace-only', extends: ':workspace' },
      runtimeWorkspaceRoots: ['/repo'],
    })
    expect(await pending).toMatchObject({
      thread: { id: 'thread-one' }, cwd: '/repo', approvalPolicy: 'never',
      reasoningEffort: 'ultra',
      activePermissionProfile: { id: 'qofi-workspace-only' },
      runtimeWorkspaceRoots: ['/repo'],
    })
  })

  test('reads persisted history without using a mutating or ambiguous request boundary', async () => {
    const { client, transport } = await connected()
    const pending = client.readThread('thread-one', true)
    const request = transport.request('thread/read')
    expect(request.params).toEqual({ threadId: 'thread-one', includeTurns: true })
    response(transport, request, {
      thread: { id: 'thread-one', status: { type: 'notLoaded' }, turns: [{ id: 'turn-one' }] },
    })
    expect(await pending).toEqual({
      id: 'thread-one', status: { type: 'notLoaded' }, turns: [{ id: 'turn-one' }],
    })
  })

  test('correlates out-of-order responses without trusting response order', async () => {
    const { client, transport } = await connected()
    const first = client.startThread({ cwd: '/repo/one' })
    const second = client.startThread({ cwd: '/repo/two' })
    const firstRequest = transport.request('thread/start', 0)
    const secondRequest = transport.request('thread/start', 1)

    response(transport, secondRequest, { thread: { id: 'thread-two' } })
    response(transport, firstRequest, { thread: { id: 'thread-one' } })

    expect((await first).id).toBe('thread-one')
    expect((await second).id).toBe('thread-two')
  })

  test('preserves a correlated remote rejection when the transport closes immediately after it', async () => {
    const { client, transport } = await connected()
    const pending = client.startThread({ cwd: '/repo' })
    const request = transport.request('thread/start')
    transport.emit({ id: request.id, error: { code: -32602, message: 'rejected' } })
    transport.emitClose({ code: 1006, reason: 'closed after rejection' })

    const error = await pending.catch(value => value)
    expect(error).toBeInstanceOf(AppServerRemoteError)
    expect(error.message).toBe('rejected')
    expect(client.connectionState).toBe('disconnected')
  })

  test('bounds pending requests', async () => {
    const { client, transport } = await connected({ maxPendingRequests: 1 })
    const first = client.startThread({ cwd: '/repo/one' })
    await expect(client.startThread({ cwd: '/repo/two' })).rejects.toThrow('pending request limit')
    response(transport, transport.request('thread/start'), { thread: { id: 'thread-one' } })
    expect((await first).id).toBe('thread-one')
  })

  test('times out a sent mutating request and marks it ambiguous', async () => {
    const { client, transport } = await connected({ requestTimeoutMs: 10 })
    const error = await client.startThread({ cwd: '/repo' }).catch(value => value)
    expect(error).toBeInstanceOf(AppServerRequestError)
    expect(error.kind).toBe('timeout')
    expect(error.ambiguous).toBe(true)
    expect(client.connectionState).toBe('disconnected')
    expect(transport.closes.at(-1)?.code).toBe(1011)
  })

  test('classifies a transport send failure as an ambiguous disconnect', async () => {
    const { client, transport } = await connected()
    transport.sendGate = Promise.reject(new Error('write failed after handoff'))
    const error = await client.startThread({ cwd: '/repo' }).catch(value => value)
    expect(error).toBeInstanceOf(AppServerRequestError)
    expect(error.kind).toBe('disconnected')
    expect(error.ambiguous).toBe(true)
    expect(client.connectionState).toBe('disconnected')
    expect(transport.closes.at(-1)?.code).toBe(1011)
  })

  test('request timeout remains effective when an async transport send never settles', async () => {
    const { client, transport } = await connected({ requestTimeoutMs: 10 })
    transport.sendGate = new Promise(() => {})
    const error = await client.startThread({ cwd: '/repo' }).catch(value => value)
    expect(error).toBeInstanceOf(AppServerRequestError)
    expect(error.kind).toBe('timeout')
    expect(error.ambiguous).toBe(true)
    expect(client.connectionState).toBe('disconnected')
  })

  test('fails the connection on oversized or malformed inbound frames', async () => {
    const protocolErrors: string[] = []
    const { client, transport } = await connected({
      maxInboundMessageBytes: 256,
      onProtocolError: error => protocolErrors.push(error.message),
    })
    transport.emitRaw('x'.repeat(257))
    expect(client.connectionState).toBe('faulted')
    expect(protocolErrors).toEqual(['inbound message exceeds configured byte limit'])
    expect(transport.closes.at(-1)?.code).toBe(1002)
  })

  test('unknown or duplicate response ids are protocol faults', async () => {
    const { client, transport } = await connected()
    transport.emit({ id: 'not-issued', result: {} })
    expect(client.connectionState).toBe('faulted')
  })
})

describe('notifications and server requests', () => {
  test('dispatches notifications and explicit allowlisted server handlers', async () => {
    const notifications: string[] = []
    const handled: unknown[] = []
    const { transport } = await connected({
      onNotification: notification => notifications.push(notification.method),
      serverRequestHandlers: {
        'item/commandExecution/requestApproval': params => {
          handled.push(params)
          return { decision: 'decline' }
        },
      },
    })

    transport.emit({ method: 'thread/status/changed', params: { threadId: 't1', status: { type: 'idle' } } })
    transport.emit({
      id: 'server-1',
      method: 'item/commandExecution/requestApproval',
      params: { threadId: 't1', turnId: 'turn-1', itemId: 'item-1' },
    })
    await flush()

    expect(notifications).toEqual(['thread/status/changed'])
    expect(handled).toHaveLength(1)
    expect(transport.sent.find(message => message.id === 'server-1')).toEqual({
      id: 'server-1',
      result: { decision: 'decline' },
    })
  })

  test('supports the bounded host current-time request without delegating authority', async () => {
    const { transport } = await connected({
      serverRequestHandlers: {
        'currentTime/read': params => ({
          currentTimeAt: params.threadId === 'thread-1' ? 1_752_192_000 : 0,
        }),
      },
    })
    transport.emit({ id: 'time', method: 'currentTime/read', params: { threadId: 'thread-1' } })
    await flush()
    expect(transport.sent.find(message => message.id === 'time')).toEqual({
      id: 'time', result: { currentTimeAt: 1_752_192_000 },
    })
  })

  test('unknown, unhandled, and malformed server requests are denied without execution', async () => {
    const { client, transport } = await connected()
    transport.emit({ id: 'unknown', method: 'future/dangerousAction', params: {} })
    transport.emit({ id: 'unhandled', method: 'item/fileChange/requestApproval', params: {} })
    transport.emit({ id: 'bad-params', method: 'item/fileChange/requestApproval', params: 'nope' })
    await flush()

    expect((transport.sent.find(message => message.id === 'unknown')?.error as any).code).toBe(-32601)
    expect((transport.sent.find(message => message.id === 'unhandled')?.error as any).code).toBe(-32001)
    expect((transport.sent.find(message => message.id === 'bad-params')?.error as any).code).toBe(-32602)
    expect(client.connectionState).toBe('ready')
  })

  test('lets a non-owning subscriber defer without consuming the shared callback', async () => {
    const { client, transport } = await connected({
      serverRequestHandlers: {
        'item/commandExecution/requestApproval': () => APP_SERVER_DEFER_REQUEST,
      },
    })
    transport.emit({
      id: 'owned-elsewhere',
      method: 'item/commandExecution/requestApproval',
      params: { threadId: 'thread-1', turnId: 'turn-1', itemId: 'item-1' },
    })
    await flush()
    expect(transport.sent.some(message => message.id === 'owned-elsewhere')).toBe(false)
    expect(client.connectionState).toBe('ready')
  })

  test('invalid server request ids fail the connection closed', async () => {
    const { client, transport } = await connected()
    transport.emit({ id: null, method: 'item/fileChange/requestApproval', params: {} })
    expect(client.connectionState).toBe('faulted')
  })

  test('bounds concurrent server requests and handler duration', async () => {
    let release!: () => void
    const blocked = new Promise<void>(resolve => { release = resolve })
    const { transport } = await connected({
      maxServerRequests: 1,
      serverRequestTimeoutMs: 10,
      serverRequestHandlers: {
        'item/fileChange/requestApproval': async () => {
          await blocked
          return { decision: 'decline' }
        },
      },
    })
    transport.emit({ id: 'one', method: 'item/fileChange/requestApproval', params: {} })
    transport.emit({ id: 'two', method: 'item/fileChange/requestApproval', params: {} })
    await flush()
    expect((transport.sent.find(message => message.id === 'two')?.error as any).code).toBe(-32000)
    await new Promise(resolve => setTimeout(resolve, 15))
    expect((transport.sent.find(message => message.id === 'one')?.error as any).code).toBe(-32002)
    release()
  })

  test('fails closed when the server reuses an active request id', async () => {
    let release!: () => void
    const blocked = new Promise<void>(resolve => { release = resolve })
    const { client, transport } = await connected({
      serverRequestHandlers: {
        'item/fileChange/requestApproval': async () => {
          await blocked
          return { decision: 'decline' }
        },
      },
    })
    transport.emit({ id: 'duplicate', method: 'item/fileChange/requestApproval', params: {} })
    transport.emit({ id: 'duplicate', method: 'item/fileChange/requestApproval', params: {} })
    expect(client.connectionState).toBe('faulted')
    expect(transport.closes.at(-1)?.code).toBe(1002)
    release()
    await flush()
  })
})

describe('turn lifecycle', () => {
  test('accumulates completed agent messages and maps a successful terminal turn', async () => {
    const { client, transport } = await connected()
    const handle = await beginTurn(client, transport, 'thread-1', 'turn-1')
    transport.emit({
      method: 'item/completed',
      params: {
        threadId: 'thread-1',
        turnId: 'turn-1',
        completedAtMs: 1,
        item: { type: 'agentMessage', id: 'message-1', text: 'working' },
      },
    })
    transport.emit({
      method: 'item/completed',
      params: {
        threadId: 'thread-1',
        turnId: 'turn-1',
        completedAtMs: 2,
        item: { type: 'commandExecution', id: 'command-1' },
      },
    })
    transport.emit(terminalTurn('thread-1', 'turn-1', 'completed', {
      items: [
        { type: 'agentMessage', id: 'message-1', text: 'working' },
        { type: 'agentMessage', id: 'message-2', text: 'done' },
      ],
    }))

    expect(await handle.completion).toEqual({
      ok: true,
      threadId: 'thread-1',
      turnId: 'turn-1',
      status: 'completed',
      messages: ['working', 'done'],
      ambiguous: false,
    })
  })

  test('maps interrupted and failed terminal turns', async () => {
    const { client, transport } = await connected()
    const interrupted = await beginTurn(client, transport, 'thread-i', 'turn-i')
    transport.emit(terminalTurn('thread-i', 'turn-i', 'interrupted'))
    expect(await interrupted.completion).toMatchObject({
      ok: false,
      status: 'interrupted',
      error: 'turn interrupted',
      ambiguous: false,
    })

    const failed = await beginTurn(client, transport, 'thread-f', 'turn-f')
    transport.emit(terminalTurn('thread-f', 'turn-f', 'failed', { message: 'model overloaded' }))
    expect(await failed.completion).toMatchObject({
      ok: false,
      status: 'failed',
      error: 'model overloaded',
      ambiguous: false,
    })
  })

  test('preserves only structured usage-limit or HTTP-429 evidence', async () => {
    const { client, transport } = await connected()
    const usage = await beginTurn(client, transport, 'thread-u', 'turn-u')
    transport.emit(terminalTurn('thread-u', 'turn-u', 'failed', {
      message: 'bounded provider diagnostic',
      errorInfo: 'usageLimitExceeded',
    }))
    expect(await usage.completion).toMatchObject({ quotaLimited: true })

    const http = await beginTurn(client, transport, 'thread-h', 'turn-h')
    transport.emit(terminalTurn('thread-h', 'turn-h', 'failed', {
      message: 'bounded provider diagnostic',
      errorInfo: { httpConnectionFailed: { httpStatusCode: 429 } },
    }))
    expect(await http.completion).toMatchObject({ quotaLimited: true })

    const prose = await beginTurn(client, transport, 'thread-p', 'turn-p')
    transport.emit(terminalTurn('thread-p', 'turn-p', 'failed', {
      message: 'someone wrote 429 usage limit in prose',
    }))
    expect((await prose.completion).quotaLimited).toBeUndefined()
  })

  test('buffers bounded turn events that beat the correlated turn/start response', async () => {
    const { client, transport } = await connected()
    const pending = client.startTurn({
      threadId: 'thread-fast',
      input: [{ type: 'text', text: 'fast', text_elements: [] }],
    })
    const request = transport.request('turn/start')
    transport.emit({
      method: 'item/completed',
      params: {
        threadId: 'thread-fast',
        turnId: 'turn-fast',
        completedAtMs: 1,
        item: { type: 'agentMessage', id: 'fast-message', text: 'already done' },
      },
    })
    transport.emit(terminalTurn('thread-fast', 'turn-fast', 'completed'))
    responseTurn(transport, request, 'turn-fast')

    const handle = await pending
    expect(await handle.completion).toMatchObject({
      ok: true,
      messages: ['already done'],
      status: 'completed',
    })
  })

  test('fails closed when completed message accumulation exceeds its byte bound', async () => {
    const { client, transport } = await connected({ maxAgentMessageBytesPerTurn: 64 })
    const handle = await beginTurn(client, transport, 'thread-big', 'turn-big')
    transport.emit({
      method: 'item/completed',
      params: {
        threadId: 'thread-big',
        turnId: 'turn-big',
        completedAtMs: 1,
        item: { type: 'agentMessage', id: 'message-big', text: 'x'.repeat(65) },
      },
    })
    expect(client.connectionState).toBe('faulted')
    expect(await handle.completion).toMatchObject({
      ok: false,
      status: 'protocol',
      ambiguous: true,
    })
  })

  test('interrupt sends the exact thread and turn ids and awaits correlation', async () => {
    const { client, transport } = await connected()
    const pending = client.interrupt('thread-1', 'turn-1')
    const request = transport.request('turn/interrupt')
    expect(request.params).toEqual({ threadId: 'thread-1', turnId: 'turn-1' })
    response(transport, request, {})
    await pending
  })
})

describe('disconnect and Unix WebSocket seam', () => {
  test('reconnect initializes only and never resubmits an ambiguous active turn', async () => {
    const { client, transport } = await connected()
    const handle = await beginTurn(client, transport, 'thread-1', 'turn-1')
    transport.emitClose({ code: 1006, reason: 'socket lost' })
    expect(await handle.completion).toMatchObject({
      status: 'disconnected',
      ambiguous: true,
    })

    const replacement = withAutomaticInitialize()
    await client.reconnect(replacement)
    expect(replacement.sent.map(message => message.method)).toEqual(['initialize', 'initialized'])
    expect(replacement.sent.some(message => message.method === 'turn/start')).toBe(false)
    expect(client.connectionState).toBe('ready')
  })

  test('a disconnect before turn/start correlation rejects as ambiguous and is not replayed', async () => {
    const { client, transport } = await connected()
    const pending = client.startTurn({
      threadId: 'thread-1',
      input: [{ type: 'text', text: 'hello', text_elements: [] }],
    })
    transport.emitClose({ reason: 'lost after send' })
    const error = await pending.catch(value => value)
    expect(error).toBeInstanceOf(AppServerRequestError)
    expect(error.ambiguous).toBe(true)

    const replacement = withAutomaticInitialize()
    await client.reconnect(replacement)
    expect(replacement.sent.map(message => message.method)).toEqual(['initialize', 'initialized'])
  })

  test('reconnect denies public calls and drains reentrant notifications in order before ready', async () => {
    const observed: string[] = []
    let client!: CodexAppServerClient
    let replacement!: FakeTransport
    let reentrant: Promise<unknown> | null = null
    const initial = await connected({
      onNotification: notification => {
        observed.push(notification.method)
        if (notification.method === 'queued/first') {
          reentrant = client.startThread({ cwd: '/must-not-send' }).catch(error => error)
          replacement.emit({ method: 'queued/nested', params: {} })
        }
      },
    })
    client = initial.client
    initial.transport.emitClose({ reason: 'replace transport' })

    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    replacement = new FakeTransport()
    replacement.gateOnMethod = 'initialized'
    replacement.methodGate = gate
    replacement.onSend = message => {
      if (message.method !== 'initialize') return
      replacement.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      replacement.emit({ method: 'queued/first', params: {} })
      replacement.emit({ method: 'queued/second', params: {} })
    }

    const reconnecting = client.reconnect(replacement)
    await flush()
    const concurrent = await client.startThread({ cwd: '/also-must-not-send' }).catch(error => error)
    expect(concurrent).toBeInstanceOf(AppServerRequestError)
    expect(concurrent.message).toContain('initializing')
    expect(observed).toEqual([])
    release()
    await reconnecting
    expect((await reentrant) as Error).toBeInstanceOf(AppServerRequestError)
    expect(((await reentrant) as Error).message).toContain('initializing')
    expect(observed).toEqual(['queued/first', 'queued/second', 'queued/nested'])
    expect(replacement.sent.some(message => message.method === 'thread/start')).toBe(false)
    expect(client.connectionState).toBe('ready')
  })

  test('reconnect retains a post-response failure and can recover on a later transport', async () => {
    const { client, transport } = await connected()
    transport.emitClose({ reason: 'replace transport' })
    const broken = new FakeTransport()
    broken.onSend = message => {
      if (message.method !== 'initialize') return
      broken.emit({
        id: message.id,
        result: {
          userAgent: `qofi-test/${CODEX_APP_SERVER_PROTOCOL_VERSION} (Mac OS; arm64)`,
          codexHome: '/runtime/.codex',
          platformFamily: 'unix',
          platformOs: 'macos',
        },
      })
      broken.emitRaw('{broken-after-response')
    }
    await expect(client.reconnect(broken)).rejects.toThrow('inbound message is not valid JSON')
    expect(client.connectionState).toBe('faulted')
    expect(broken.sent.map(message => message.method)).toEqual(['initialize'])

    const recovered = withAutomaticInitialize()
    await client.reconnect(recovered)
    expect(client.connectionState).toBe('ready')
  })

  test('injects an attested Unix WebSocket transport without constructing a network endpoint', async () => {
    const paths: string[] = []
    const transport = withAutomaticInitialize()
    const client = await connectCodexAppServerOverUnixWebSocket(
      '/private/var/run/qofi/codex.sock',
      path => {
        paths.push(path)
        return transport
      },
    )
    expect(paths).toEqual(['/private/var/run/qofi/codex.sock'])
    expect(client.connectionState).toBe('ready')
    await expect(connectCodexAppServerOverUnixWebSocket('relative.sock', () => transport)).rejects.toThrow(
      'must be absolute',
    )
  })
})
