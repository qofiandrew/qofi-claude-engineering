import { createServer, type IncomingMessage, type ServerResponse } from 'http'
import type { Socket } from 'net'
import { mkdtempSync, realpathSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, describe, expect, jest, test } from 'bun:test'
import {
  AppServerManagerClient,
  AppServerManagerClientError,
  MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS,
  MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS,
  ManagerLivenessMonitor,
  ManagerPreAdmissionMaintenanceMonitor,
  managerTurnResponseToCodexResult,
  validateManagerLivenessResponse,
} from './app-server-manager-client.ts'
import {
  APP_SERVER_MANAGER_SCHEMA,
  APP_SERVER_MANAGER_VERSION,
} from './app-server-manager.ts'
import { CODEX_APP_SERVER_PROTOCOL_VERSION } from './app-server-client.ts'
import {
  closeOwnedUnixServer,
  listenOwnerUnixSocket,
  type UnixSocketIdentity,
} from './app-server-unix-socket.ts'

type JsonObject = Record<string, unknown>
type Route = (
  request: IncomingMessage,
  response: ServerResponse,
  body: JsonObject,
) => void | Promise<void>

const roots: string[] = []
const TOKEN = 'a'.repeat(64)
const RESERVATION_TOKEN = 'b'.repeat(64)

afterEach(() => {
  if (jest.isFakeTimers()) jest.useRealTimers()
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function health(overrides: JsonObject = {}): JsonObject {
  return {
    schema: APP_SERVER_MANAGER_SCHEMA,
    status: 'ready',
    phase: 'idle',
    generation: 1,
    registeredSwarmCount: 0,
    upstreamReady: true,
    upstreamState: 'ready',
    managerVersion: APP_SERVER_MANAGER_VERSION,
    protocolVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
    cliVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
    ...overrides,
  }
}

function send(response: ServerResponse, value: unknown, status = 200): void {
  const bytes = Buffer.from(JSON.stringify(value))
  response.writeHead(status, {
    'content-type': 'application/json',
    'content-length': String(bytes.byteLength),
    connection: 'keep-alive',
  })
  response.end(bytes)
}

async function readBody(request: IncomingMessage): Promise<JsonObject> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of request) {
    const bytes = Buffer.from(chunk)
    total += bytes.byteLength
    if (total > 70 * 1024 * 1024) throw new Error('fixture body exceeded bound')
    chunks.push(bytes)
  }
  if (chunks.length === 0) return {}
  return JSON.parse(Buffer.concat(chunks).toString('utf8')) as JsonObject
}

async function fixture(routes: Record<string, Route>) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-manager-client.')))
  roots.push(root)
  const socketPath = join(root, 'manager.sock')
  const server = createServer((request, response) => {
    void (async () => {
      const route = routes[`${request.method} ${request.url}`]
      if (!route) {
        send(response, { error: 'missing fixture route', phase: 'idle', retryable: false }, 404)
        return
      }
      await route(request, response, await readBody(request))
    })().catch(error => send(response, { error: String(error), phase: 'ambiguous', retryable: false }, 500))
  })
  const identity = await listenOwnerUnixSocket(server, socketPath)
  const facadeSocketPath = join(root, 'facade.sock')
  let facadeServer = createServer()
  let facadeIdentity: UnixSocketIdentity | null = await listenOwnerUnixSocket(
    facadeServer,
    facadeSocketPath,
  )
  const client = new AppServerManagerClient({ socketPath, requestTimeoutMs: 2_000 })
  return {
    root,
    socketPath,
    server,
    identity,
    facadeSocketPath,
    client,
    removeFacade: async () => {
      if (!facadeIdentity) return
      const prior = facadeIdentity
      facadeIdentity = null
      await closeOwnedUnixServer(facadeServer, prior)
    },
    replaceFacade: async () => {
      if (facadeIdentity) {
        const prior = facadeIdentity
        facadeIdentity = null
        await closeOwnedUnixServer(facadeServer, prior)
      }
      facadeServer = createServer()
      facadeIdentity = await listenOwnerUnixSocket(facadeServer, facadeSocketPath)
    },
    close: async () => {
      client.close()
      await closeOwnedUnixServer(server, identity)
      if (facadeIdentity) {
        const prior = facadeIdentity
        facadeIdentity = null
        await closeOwnedUnixServer(facadeServer, prior)
      }
    },
  }
}

function registration(facadeEndpoint: string, reasoningEffort: 'medium' | 'ultra' = 'ultra'): JsonObject {
  return {
    registrationToken: TOKEN,
    generation: 1,
    facadeEndpoint,
    serverVersion: CODEX_APP_SERVER_PROTOCOL_VERSION,
    reasoningEffort,
    activeProfile: 'default',
    pool: 'default',
    thresholdPercent: 85,
    parkedUntilMs: null,
  }
}

function reservation(requestId: string, overrides: JsonObject = {}): JsonObject {
  return {
    reservationToken: RESERVATION_TOKEN,
    requestId,
    expiresAtMs: Date.now() + 30_000,
    generation: 1,
    profile: 'default',
    ...overrides,
  }
}

function terminal(
  status: 'completed' | 'interrupted' | 'failed' = 'completed',
): JsonObject {
  return {
    leaseId: 'lease-1',
    threadId: 'thread-1',
    turnId: 'turn-1',
    result: {
      ok: status === 'completed',
      threadId: 'thread-1',
      turnId: 'turn-1',
      status,
      messages: status === 'completed' ? ['done'] : [],
      ...(status === 'failed' ? { error: 'failed' } : {}),
      ambiguous: false,
    },
    cleanupRequired: true,
    generation: 1,
    profile: 'default',
    rotation: null,
  }
}

describe('AppServerManagerClient', () => {
  test('maps structured manager quota evidence to the hard usage-limit class', () => {
    const response = terminal('failed') as any
    response.result.quotaLimited = true
    response.result.error = 'bounded provider diagnostic'
    expect(managerTurnResponseToCodexResult(response).errorKind).toBe('usage-limit')
  })

  test('binds terminal completion begin, poll, and end to the exact held lease', async () => {
    let facade = ''
    const completionToken = 'c'.repeat(64)
    const reviewedHash = 'd'.repeat(64)
    let statusCalls = 0
    const f = await fixture({
      'GET /v1/health': (_request, response) => send(response, health()),
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response, body) => {
        send(response, reservation(String(body.requestId)))
      },
      'POST /v1/turn/start': (_request, response, body) => {
        expect(body.taskId).toBe('discord-message-1')
        send(response, terminal())
      },
      'POST /v1/reviewer/completion/begin': (_request, response, body) => {
        expect(body).toEqual({
          schema: 'qofi-codex-completion-review-begin/v1',
          registrationToken: TOKEN,
          leaseId: 'lease-1',
          reviewedDiffSha256: reviewedHash,
          arguments: {
            diff_or_files: 'qofi completion review: no workspace file changes',
            context_refs: [], mode: 'code',
          },
        })
        send(response, {
          schema: 'qofi-codex-completion-review-begin/v1', status: 'pending',
          leaseId: 'lease-1', completionToken, expiresAtMs: Date.now() + 60_000,
        })
      },
      'POST /v1/reviewer/completion/status': (_request, response, body) => {
        expect(body).toEqual({ registrationToken: TOKEN, leaseId: 'lease-1', completionToken })
        statusCalls += 1
        send(response, statusCalls === 1 ? { status: 'pending' } : {
          status: 'complete', reviewedDiffSha256: reviewedHash, verdict: 'review-unavailable',
          artifactName: 'fable-review-20260713T101112123456Z-0123456789abcdef.json',
          artifactSha256: 'e'.repeat(64),
        })
      },
      'POST /v1/reviewer/completion/end': (_request, response, body) => {
        expect(body).toEqual({ registrationToken: TOKEN, leaseId: 'lease-1', completionToken })
        send(response, { ended: true, leaseId: 'lease-1' })
      },
      'POST /v1/turn/cleanup-complete': (_request, response) => send(response, {
        generation: 2, ready: true, activeProfile: 'default', parkedUntilMs: null,
      }),
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root, sessions: [] })
      await f.client.reserveTurn({ timeoutMs: 1_000 })
      const execution = await f.client.runTurn({
        taskId: 'discord-message-1', threadId: null, prompt: 'review me',
      }, { timeoutMs: 5_000 })
      const admitted = await f.client.beginCompletionReview('lease-1', reviewedHash, {
        diff_or_files: 'qofi completion review: no workspace file changes',
        context_refs: [], mode: 'code',
      })
      expect(admitted.completionToken).toBe(completionToken)
      expect(await f.client.completionReviewStatus('lease-1', completionToken))
        .toEqual({ status: 'pending' })
      expect(await f.client.completionReviewStatus('lease-1', completionToken)).toMatchObject({
        status: 'complete', verdict: 'review-unavailable', reviewedDiffSha256: reviewedHash,
      })
      expect(await f.client.endCompletionReview('lease-1', completionToken))
        .toEqual({ ended: true, leaseId: 'lease-1' })
      await f.client.cleanupComplete(execution.leaseId, true)
      await expect(f.client.reviewerScope()).rejects.toThrow('requires an active turn')
    } finally {
      await f.close()
    }
  })

  test('strictly validates health and carries a >1MiB turn through the bounded lease channel', async () => {
    let turnSocket: Socket | null = null
    let cleanupSocket: Socket | null = null
    let turnBytes = 0
    let reservationRequestId = ''
    let facade = ''
    const f = await fixture({
      'GET /v1/health': (_request, response) => send(response, health()),
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response, body) => {
        expect(body.registrationToken).toBe(TOKEN)
        reservationRequestId = String(body.requestId)
        send(response, reservation(reservationRequestId))
      },
      'POST /v1/turn/start': (request, response, body) => {
        turnSocket = request.socket
        turnBytes = Number(request.headers['content-length'])
        expect((body.prompt as string).length).toBeGreaterThan(1024 * 1024)
        expect(body.requestId).toBe(reservationRequestId)
        expect(body.reservationToken).toBe(RESERVATION_TOKEN)
        send(response, terminal())
      },
      'POST /v1/sessions/replace': (_request, response, body) => {
        expect(body).toEqual({ registrationToken: TOKEN, sessions: ['thread-1'] })
        send(response, { generation: 1, facadeEndpoint: facade, sessionCount: 1 })
      },
      'POST /v1/turn/cleanup-complete': (request, response, body) => {
        cleanupSocket = request.socket
        expect(body).toEqual({ registrationToken: TOKEN, leaseId: 'lease-1', ok: true })
        send(response, { generation: 2, ready: true, activeProfile: 'default', parkedUntilMs: null })
      },
      'POST /v1/unregister': (_request, response) => send(response, { removed: true }),
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      expect(await f.client.health()).toEqual(health())
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root, sessions: [] })
      await f.client.reserveTurn({ timeoutMs: 1_000 })
      const execution = await f.client.runTurn({
        threadId: null,
        prompt: 'x'.repeat(2 * 1024 * 1024),
      }, { timeoutMs: 5_000 })
      expect(execution.result).toEqual({
        ok: true, threadId: 'thread-1', messages: ['done'],
      })
      expect(turnSocket?.destroyed).toBe(false)
      await f.client.replaceSessions(['thread-1'])
      await Promise.race([
        f.client.cleanupComplete(execution.leaseId, true),
        Bun.sleep(1_000).then(() => { throw new Error('cleanup request did not settle') }),
      ])
      expect(turnBytes).toBeGreaterThan(1024 * 1024)
      expect(cleanupSocket).not.toBe(turnSocket)
      expect(await f.client.unregister()).toEqual({ removed: true })
    } finally {
      await f.close()
    }
  })

  test('abort sends an exact concurrent interrupt without dropping the held turn response', async () => {
    let facade = ''
    let startResponse: ServerResponse | null = null
    let startSocket: Socket | null = null
    let startRequestId = ''
    let resolveStarted!: () => void
    const started = new Promise<void>(resolve => { resolveStarted = resolve })
    const f = await fixture({
      'GET /v1/health': (_request, response) => send(response, health()),
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response, body) => {
        send(response, reservation(String(body.requestId)))
      },
      'POST /v1/turn/start': (request, response, body) => {
        startSocket = request.socket
        startResponse = response
        startRequestId = String(body.requestId)
        resolveStarted()
      },
      'POST /v1/turn/interrupt': (request, response, body) => {
        expect(request.socket).not.toBe(startSocket)
        expect(body).toEqual({ registrationToken: TOKEN, requestId: startRequestId })
        send(response, { accepted: true, threadId: 'thread-1', turnId: 'turn-1' })
        send(startResponse!, terminal('interrupted'))
      },
      'POST /v1/turn/cleanup-complete': (_request, response) => {
        send(response, { generation: 2, ready: true, activeProfile: 'default', parkedUntilMs: null })
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.health()
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root, sessions: [] })
      await f.client.reserveTurn({ timeoutMs: 1_000 })
      const abort = new AbortController()
      const pending = f.client.runTurn({ threadId: null, prompt: 'hello' }, {
        signal: abort.signal,
        timeoutMs: 5_000,
      })
      await started
      abort.abort()
      const execution = await pending
      expect(execution.result.errorKind).toBe('aborted')
      await f.client.cleanupComplete(execution.leaseId, true)
    } finally {
      await f.close()
    }
  })

  test('registration retries exact nonfatal 409s with one immutable body', async () => {
    let facade = ''
    const bodies: JsonObject[] = []
    const request = {
      swarm: 'alpha', repo: '', stateDir: '', sessions: ['thread-1'],
      model: 'gpt-5.6-sol', reasoningEffort: 'medium' as const,
    }
    const f = await fixture({
      'POST /v1/register': (_request, response, body) => {
        bodies.push(body)
        if (bodies.length === 1) {
          request.sessions.push('mutated-after-first-send')
          send(response, { error: 'manager is active', phase: 'active', retryable: true }, 409)
        } else send(response, registration(facade, 'medium'))
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    request.repo = f.root
    request.stateDir = f.root
    try {
      expect(await f.client.register(request, { timeoutMs: 1_000 })).toEqual(registration(facade, 'medium'))
      expect(bodies).toHaveLength(2)
      expect(bodies[0]).toEqual(bodies[1])
      expect(bodies[1]!.sessions).toEqual(['thread-1'])
      expect(bodies[1]).toMatchObject({ model: 'gpt-5.6-sol', reasoningEffort: 'medium' })
    } finally {
      await f.close()
    }
  })

  test('registration fails closed when a stale manager omits or changes CPO effort', async () => {
    for (const mode of ['missing', 'mismatch'] as const) {
      let facade = ''
      const f = await fixture({
        'POST /v1/register': (_request, response) => {
          const body = registration(facade, mode === 'mismatch' ? 'ultra' : 'medium')
          if (mode === 'missing') delete body.reasoningEffort
          send(response, body)
        },
      })
      facade = `unix://${join(f.root, 'facade.sock')}`
      try {
        const error = await f.client.register({
          swarm: 'alpha', repo: f.root, stateDir: f.root,
          reasoningEffort: 'medium',
        }).then(() => null, value => value as AppServerManagerClientError)
        expect(error).toBeInstanceOf(AppServerManagerClientError)
        expect(error?.kind).toBe('protocol')
        expect(error?.ambiguous).toBe(true)
        await expect(f.client.register({
          swarm: 'alpha', repo: f.root, stateDir: f.root,
          reasoningEffort: 'medium',
        })).rejects.toThrow('closed or faulted')
      } finally {
        await f.close()
      }
    }
  })

  test('semantic idle 409, malformed error, fatal phase, and transport loss never poll registration', async () => {
    for (const mode of ['semantic', 'malformed', 'fatal', 'transport'] as const) {
      let calls = 0
      const f = await fixture({
        'POST /v1/register': (request, response) => {
          calls += 1
          if (mode === 'transport') request.socket.destroy()
          else if (mode === 'malformed') send(response, {
            error: 'missing retry discriminator', phase: 'idle',
          }, 409)
          else if (mode === 'fatal') send(response, {
            error: 'manager stopping', phase: 'stopping', retryable: false,
          }, 409)
          else send(response, {
            error: 'sessions do not match', phase: 'idle', retryable: false,
          }, 409)
        },
      })
      try {
        const error = await f.client.register({
          swarm: 'alpha', repo: f.root, stateDir: f.root,
        }, { timeoutMs: 1_000 }).then(() => null, value => value as AppServerManagerClientError)
        expect(error).toBeInstanceOf(AppServerManagerClientError)
        expect(calls).toBe(1)
        if (mode === 'semantic') {
          expect(error?.remoteHttpStatus).toBe(409)
          expect(error?.remotePhase).toBe('idle')
          expect(error?.remoteRetryable).toBe(false)
          expect(error?.message).toBe('sessions do not match')
        }
        if (mode === 'transport' || mode === 'malformed') {
          expect(error?.ambiguous).toBe(true)
          await expect(f.client.register({
            swarm: 'alpha', repo: f.root, stateDir: f.root,
          })).rejects.toThrow('closed or faulted')
        }
      } finally {
        await f.close()
      }
    }
  })

  test('unregister retries only explicit contention with one immutable token body', async () => {
    let facade = ''
    const bodies: JsonObject[] = []
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/unregister': (_request, response, body) => {
        bodies.push(body)
        if (bodies.length === 1) send(response, {
          error: 'manager is active', phase: 'active', retryable: true,
        }, 409)
        else send(response, { removed: true })
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      expect(await f.client.unregister({ timeoutMs: 1_000 })).toEqual({ removed: true })
      expect(bodies).toHaveLength(2)
      expect(bodies[0]).toEqual({ registrationToken: TOKEN })
      expect(bodies[1]).toEqual(bodies[0])
      expect(await f.client.unregister()).toBeNull()
    } finally {
      await f.close()
    }
  })

  test('semantic, fatal, and transport unregister failures are one-shot', async () => {
    for (const mode of ['semantic', 'fatal', 'transport'] as const) {
      let facade = ''
      let calls = 0
      const f = await fixture({
        'POST /v1/register': (_request, response) => send(response, registration(facade)),
        'POST /v1/unregister': (request, response) => {
          calls += 1
          if (mode === 'transport') request.socket.destroy()
          else if (mode === 'fatal') send(response, {
            error: 'manager stopping', phase: 'stopping', retryable: false,
          }, 409)
          else send(response, {
            error: 'registration cannot be removed', phase: 'idle', retryable: false,
          }, 409)
        },
      })
      facade = `unix://${join(f.root, 'facade.sock')}`
      try {
        await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
        const error = await f.client.unregister({ timeoutMs: 1_000 })
          .then(() => null, value => value as AppServerManagerClientError)
        expect(error).toBeInstanceOf(AppServerManagerClientError)
        expect(calls).toBe(1)
        if (mode === 'transport') {
          expect(error?.ambiguous).toBe(true)
          await expect(f.client.health()).rejects.toThrow('closed or faulted')
        }
      } finally {
        await f.close()
      }
    }
  })

  test('unregister refuses a locally held reservation before any manager request', async () => {
    let facade = ''
    let unregisterCalls = 0
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response, body) => {
        send(response, reservation(String(body.requestId)))
      },
      'POST /v1/unregister': (_request, response) => {
        unregisterCalls += 1
        send(response, { removed: true })
      },
      'POST /v1/turn/reservation-cancel': (_request, response) => {
        send(response, { cancelled: true })
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      await f.client.reserveTurn({ timeoutMs: 1_000 })
      await expect(f.client.unregister()).rejects.toThrow('active lease')
      expect(unregisterCalls).toBe(0)
      await f.client.cancelTurnReservation()
    } finally {
      await f.close()
    }
  })

  test('reservation retries exact contention and a lost idempotent acknowledgement with one requestId', async () => {
    let facade = ''
    const requestIds: string[] = []
    let reserveCalls = 0
    const cancelBodies: JsonObject[] = []
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (request, response, body) => {
        reserveCalls += 1
        requestIds.push(String(body.requestId))
        if (reserveCalls === 1) {
          send(response, { error: 'manager is active', phase: 'active', retryable: true }, 409)
        } else if (reserveCalls === 2) {
          request.socket.destroy()
        } else send(response, reservation(String(body.requestId)))
      },
      'POST /v1/turn/reservation-cancel': (request, response, body) => {
        cancelBodies.push(body)
        if (cancelBodies.length === 1) request.socket.destroy()
        else send(response, { cancelled: true })
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      const reserved = await f.client.reserveTurn({ timeoutMs: 1_500 })
      expect(reserveCalls).toBe(3)
      expect(new Set(requestIds).size).toBe(1)
      expect(reserved.requestId).toBe(requestIds[0])
      expect(f.client.hasTurnReservation).toBe(true)
      expect(await f.client.cancelTurnReservation()).toEqual({ cancelled: true })
      expect(cancelBodies).toHaveLength(2)
      expect(cancelBodies[0]).toEqual(cancelBodies[1])
      expect(cancelBodies[1]).toEqual({
        registrationToken: TOKEN,
        reservationToken: RESERVATION_TOKEN,
        requestId: requestIds[0],
      })
      expect(f.client.hasActiveLease).toBe(false)
    } finally {
      await f.close()
    }
  })

  test('pool exhaustion is surfaced once with its reset boundary and never contention-polled', async () => {
    let facade = ''
    let reserveCalls = 0
    const parkedUntilMs = Date.now() + 3_600_000
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response) => {
        reserveCalls += 1
        send(response, {
          error: 'Codex auth pool exhausted',
          phase: 'idle',
          retryable: true,
          parkedUntilMs,
        }, 409)
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      const error = await f.client.reserveTurn({ timeoutMs: 10_000 })
        .then(() => null, value => value as AppServerManagerClientError)
      expect(reserveCalls).toBe(1)
      expect(error).toMatchObject({
        kind: 'remote',
        ambiguous: false,
        remoteHttpStatus: 409,
        remotePhase: 'idle',
        remoteRetryable: true,
        remotePoolExhausted: true,
        remoteParkedUntilMs: parkedUntilMs,
      })
      expect(f.client.hasActiveLease).toBe(false)
    } finally {
      await f.close()
    }
  })

  test('persistent reserve response loss has a fixed ambiguity bound independent of caller timeout', async () => {
    let facade = ''
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
    })
    facade = `unix://${f.facadeSocketPath}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      let calls = 0
      ;(f.client as any).requestJson = async (_method: string, path: string) => {
        expect(path).toBe('/v1/turn/reserve')
        calls += 1
        throw new AppServerManagerClientError('persistent socket loss', 'transport', true)
      }
      jest.useFakeTimers()
      const startedAt = performance.now()
      const outcome = f.client.reserveTurn({ timeoutMs: 86_400_000 })
        .then(() => null, value => value as AppServerManagerClientError)
      await Promise.resolve()
      await Promise.resolve()
      for (let elapsed = 0; elapsed <= MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS; elapsed += 100) {
        jest.advanceTimersByTime(100)
        await Promise.resolve()
        await Promise.resolve()
      }
      const error = await outcome
      const elapsed = performance.now() - startedAt
      expect(error?.kind).toBe('timeout')
      expect(error?.ambiguous).toBe(true)
      expect(error?.message).toContain('ambiguous response loss exceeded 10000ms')
      expect(elapsed).toBeGreaterThanOrEqual(MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS)
      expect(elapsed).toBeLessThan(MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS + 500)
      expect(calls).toBeGreaterThan(2)
    } finally {
      if (jest.isFakeTimers()) jest.useRealTimers()
      await f.close()
    }
  })

  test('explicit contention proves non-admission and resets a prior response-loss window', async () => {
    let facade = ''
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
    })
    facade = `unix://${f.facadeSocketPath}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      let calls = 0
      ;(f.client as any).requestJson = async () => {
        calls += 1
        if (calls === 1) {
          throw new AppServerManagerClientError('one lost response', 'transport', true)
        }
        throw new AppServerManagerClientError(
          'manager is active', 'remote', false, 409, 'active', true,
        )
      }
      jest.useFakeTimers()
      const abort = new AbortController()
      let settled = false
      const outcome = f.client.reserveTurn({ signal: abort.signal, timeoutMs: 86_400_000 })
        .then(
          () => null,
          value => value as AppServerManagerClientError,
        ).finally(() => { settled = true })
      await Promise.resolve()
      await Promise.resolve()
      for (let elapsed = 0; elapsed < MANAGER_AMBIGUOUS_RESPONSE_LOSS_DEADLINE_MS + 5_000; elapsed += 100) {
        jest.advanceTimersByTime(100)
        await Promise.resolve()
        await Promise.resolve()
      }
      expect(settled).toBe(false)
      expect(calls).toBeGreaterThan(2)
      abort.abort()
      await Promise.resolve()
      await Promise.resolve()
      const error = await outcome
      expect(error?.ambiguous).toBe(false)
      expect(error?.message).toContain('pre-admission request aborted')
    } finally {
      if (jest.isFakeTimers()) jest.useRealTimers()
      await f.close()
    }
  })

  test('reservation abort while waiting clears only a proven-unacquired attempt', async () => {
    let facade = ''
    let reserveCalls = 0
    const abort = new AbortController()
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response) => {
        reserveCalls += 1
        send(response, { error: 'manager is reserved', phase: 'reserved', retryable: true }, 409)
        if (reserveCalls === 1) setTimeout(() => abort.abort(), 10)
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      const error = await f.client.reserveTurn({ signal: abort.signal, timeoutMs: 1_000 })
        .then(() => null, value => value as AppServerManagerClientError)
      expect(error).toBeInstanceOf(AppServerManagerClientError)
      expect(error?.ambiguous).toBe(false)
      expect(reserveCalls).toBe(1)
      expect(f.client.hasActiveLease).toBe(false)
    } finally {
      await f.close()
    }
  })

  test('reservation never retries an explicit ambiguous manager state', async () => {
    let facade = ''
    let reserveCalls = 0
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response) => {
        reserveCalls += 1
        send(response, {
          error: 'manager is ambiguous', phase: 'ambiguous', retryable: false,
        }, 409)
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      const error = await f.client.reserveTurn({ timeoutMs: 1_000 })
        .then(() => null, value => value as AppServerManagerClientError)
      expect(error?.ambiguous).toBe(true)
      expect(error?.remotePhase).toBe('ambiguous')
      expect(reserveCalls).toBe(1)
      await expect(f.client.health()).rejects.toThrow('closed or faulted')
    } finally {
      await f.close()
    }
  })

  test('run requires a reservation and exact pre-consumption rejection remains cancelable', async () => {
    let facade = ''
    let startBody: JsonObject | null = null
    const cancelBodies: JsonObject[] = []
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response, body) => {
        send(response, reservation(String(body.requestId)))
      },
      'POST /v1/turn/start': (_request, response, body) => {
        startBody = body
        send(response, { error: 'pre-consumption rejection', phase: 'reserved', retryable: false }, 409)
      },
      'POST /v1/turn/reservation-cancel': (_request, response, body) => {
        cancelBodies.push(body)
        if (cancelBodies.length === 1) send(response, {
          error: 'injected cancellation refusal', phase: 'reserved', retryable: false,
        }, 409)
        else send(response, { cancelled: true })
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      await expect(f.client.runTurn(
        { threadId: null, prompt: 'no reservation' }, { timeoutMs: 1_000 },
      )).rejects.toThrow('requires an active reservation')
      const reserved = await f.client.reserveTurn({ timeoutMs: 1_000 })
      const circular: Record<string, any> = {}
      circular.self = circular
      await expect(f.client.runTurn(
        { threadId: null, prompt: 'local serialization', environment: circular },
        { timeoutMs: 1_000 },
      )).rejects.toThrow('not JSON serializable')
      expect(f.client.hasTurnReservation).toBe(true)
      await expect(f.client.runTurn(
        { threadId: null, prompt: 'reserved' }, { timeoutMs: 1_000 },
      )).rejects.toBeInstanceOf(AppServerManagerClientError)
      expect(startBody).toMatchObject({
        registrationToken: TOKEN,
        reservationToken: RESERVATION_TOKEN,
        requestId: reserved.requestId,
      })
      expect(f.client.hasTurnReservation).toBe(true)
      await expect(f.client.cancelTurnReservation()).rejects.toThrow('injected cancellation refusal')
      expect(f.client.hasTurnReservation).toBe(true)
      await f.client.cancelTurnReservation()
      expect(cancelBodies).toHaveLength(2)
      expect(cancelBodies[0]).toEqual(cancelBodies[1])
      expect(cancelBodies[1]).toEqual({
        registrationToken: TOKEN,
        reservationToken: RESERVATION_TOKEN,
        requestId: reserved.requestId,
      })
    } finally {
      await f.close()
    }
  })

  test('exact ambiguous start rejection permits one narrow cancel but leaves the client faulted', async () => {
    let facade = ''
    let cancelCalls = 0
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response, body) => {
        send(response, reservation(String(body.requestId)))
      },
      'POST /v1/turn/start': (_request, response) => {
        send(response, { error: 'authority changed after reservation', phase: 'ambiguous', retryable: false }, 409)
      },
      'POST /v1/turn/reservation-cancel': (_request, response, body) => {
        cancelCalls += 1
        expect(body.reservationToken).toBe(RESERVATION_TOKEN)
        send(response, { cancelled: true })
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      await f.client.reserveTurn({ timeoutMs: 1_000 })
      const error = await f.client.runTurn(
        { threadId: null, prompt: 'drift' }, { timeoutMs: 1_000 },
      ).then(() => null, value => value as AppServerManagerClientError)
      expect(error?.remoteHttpStatus).toBe(409)
      expect(error?.remotePhase).toBe('ambiguous')
      expect(error?.ambiguous).toBe(true)
      expect(await f.client.cancelTurnReservation()).toEqual({ cancelled: true })
      expect(cancelCalls).toBe(1)
      await expect(f.client.health()).rejects.toThrow('closed or faulted')
    } finally {
      await f.close()
    }
  })

  test('transport-ambiguous start is faulted but may attempt the exact stored cancellation', async () => {
    let facade = ''
    let cancelCalls = 0
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'POST /v1/turn/reserve': (_request, response, body) => {
        send(response, reservation(String(body.requestId)))
      },
      'POST /v1/turn/start': (request) => request.socket.destroy(),
      'POST /v1/turn/reservation-cancel': (_request, response) => {
        cancelCalls += 1
        send(response, { cancelled: true })
      },
    })
    facade = `unix://${join(f.root, 'facade.sock')}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      await f.client.reserveTurn({ timeoutMs: 1_000 })
      await expect(f.client.runTurn(
        { threadId: null, prompt: 'lost' }, { timeoutMs: 1_000 },
      )).rejects.toBeInstanceOf(AppServerManagerClientError)
      expect(await f.client.cancelTurnReservation()).toEqual({ cancelled: true })
      expect(cancelCalls).toBe(1)
      await expect(f.client.health()).rejects.toThrow('closed or faulted')
    } finally {
      await f.close()
    }
  })

  test('incompatible or non-ready health fails closed', async () => {
    const f = await fixture({
      'GET /v1/health': (_request, response) => send(response, health({ status: 'busy', phase: 'active' })),
    })
    try {
      await expect(f.client.health()).rejects.toBeInstanceOf(AppServerManagerClientError)
    } finally {
      await f.close()
    }
  })

  test('liveness accepts only exact internally consistent nonfatal global states', async () => {
    const states = [
      health(),
      health({ status: 'busy', phase: 'idle' }),
      health({ status: 'busy', phase: 'reserved' }),
      health({ status: 'busy', phase: 'active' }),
      health({
        status: 'cleanup-pending', phase: 'terminal-cleanup-pending',
        upstreamReady: false, upstreamState: 'cleanup-pending',
      }),
      health({ status: 'drained', phase: 'drained', upstreamReady: false, upstreamState: 'stopped' }),
      health({ status: 'busy', phase: 'starting' }),
      health({ status: 'busy', phase: 'starting', upstreamReady: false, upstreamState: 'stopped' }),
    ]
    let index = 0
    const f = await fixture({
      'GET /v1/health': (_request, response) => send(response, states[index++]!),
    })
    try {
      const dispositions = []
      for (const _state of states) dispositions.push((await f.client.liveness()).disposition)
      expect(dispositions).toEqual([
        'ready',
        'shared-busy', 'shared-busy', 'shared-busy', 'shared-busy',
        'maintenance', 'maintenance', 'maintenance',
      ])
    } finally {
      await f.close()
    }
  })

  test('liveness rejects fatal, incompatible, ambiguous, and inconsistent tuples', () => {
    const rejected = [
      health({ status: 'ambiguous', phase: 'ambiguous', upstreamReady: false, upstreamState: 'ambiguous' }),
      health({ status: 'stopping', phase: 'stopping', upstreamReady: false, upstreamState: 'stopped' }),
      health({ status: 'busy', phase: 'active', upstreamReady: false, upstreamState: 'stopped' }),
      health({ status: 'busy', phase: 'reserved', upstreamReady: false, upstreamState: 'stopped' }),
      health({ status: 'ready', phase: 'idle', upstreamReady: false }),
      health({
        status: 'cleanup-pending', phase: 'terminal-cleanup-pending',
        upstreamReady: true, upstreamState: 'cleanup-pending',
      }),
      health({ status: 'drained', phase: 'drained' }),
      health({ status: 'drained', phase: 'drained', upstreamReady: true, upstreamState: 'stopped' }),
      health({ managerVersion: '0.2.0' }),
      { ...health(), unexpected: true },
    ]
    for (const state of rejected) {
      expect(() => validateManagerLivenessResponse(state)).toThrow(AppServerManagerClientError)
    }
  })

  test('registered liveness pins the exact facade and accepts intact shared activity', async () => {
    let facade = ''
    const f = await fixture({
      'POST /v1/register': (_request, response) => send(response, registration(facade)),
      'GET /v1/health': (_request, response) => send(response, health({
        status: 'busy', phase: 'active', registeredSwarmCount: 2,
      })),
    })
    facade = `unix://${f.facadeSocketPath}`
    try {
      await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
      expect((await f.client.liveness()).disposition).toBe('shared-busy')
    } finally {
      await f.close()
    }
  })

  test('registered liveness fails closed when its facade is unlinked or replaced', async () => {
    for (const mode of ['unlink', 'replace'] as const) {
      let facade = ''
      let healthCalls = 0
      const f = await fixture({
        'POST /v1/register': (_request, response) => send(response, registration(facade)),
        'GET /v1/health': (_request, response) => {
          healthCalls += 1
          send(response, health())
        },
      })
      facade = `unix://${f.facadeSocketPath}`
      try {
        await f.client.register({ swarm: 'alpha', repo: f.root, stateDir: f.root })
        if (mode === 'unlink') await f.removeFacade()
        else await f.replaceFacade()
        const error = await f.client.liveness()
          .then(() => null, value => value as AppServerManagerClientError)
        expect(error?.kind).toBe('boundary')
        expect(error?.message).toContain('registered manager facade')
        expect(healthCalls).toBe(0)
      } finally {
        await f.close()
      }
    }
  })

  test('an unregistered client checks only global manager liveness', async () => {
    const f = await fixture({
      'GET /v1/health': (_request, response) => send(response, health()),
    })
    try {
      await f.removeFacade()
      expect((await f.client.liveness()).disposition).toBe('ready')
    } finally {
      await f.close()
    }
  })

  test('another client may stay active beyond heartbeats and slow drain/resume has one deadline', () => {
    const monitor = new ManagerLivenessMonitor()
    const active = validateManagerLivenessResponse(health({ status: 'busy', phase: 'active' }))
    const drained = validateManagerLivenessResponse(health({
      status: 'drained', phase: 'drained', upstreamReady: false, upstreamState: 'stopped',
    }))
    const starting = validateManagerLivenessResponse(health({
      status: 'busy', phase: 'starting', upstreamReady: true, upstreamState: 'ready',
    }))
    const ready = validateManagerLivenessResponse(health())

    expect(monitor.observe(active, 0)).toBe(true)
    expect(monitor.observe(active, MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS * 3)).toBe(true)

    const maintenanceStart = MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS * 4
    expect(monitor.observe(drained, maintenanceStart)).toBe(false)
    expect(monitor.observe(drained, maintenanceStart + 25_000)).toBe(false)
    expect(monitor.observe(starting, maintenanceStart + 55_000)).toBe(false)
    expect(monitor.observe(ready, maintenanceStart + 59_999)).toBe(true)

    const stuckStart = maintenanceStart + 70_000
    expect(monitor.observe(drained, stuckStart)).toBe(false)
    expect(() => monitor.observe(
      starting,
      stuckStart + MANAGER_MAINTENANCE_LIVENESS_DEADLINE_MS,
    )).toThrow('manager maintenance exceeded 60000ms')
  })

  test('pre-admission drained and starting retries share the fixed maintenance deadline', () => {
    const monitor = new ManagerPreAdmissionMaintenanceMonitor()
    monitor.observe('drained', 10_000)
    expect(monitor.remaining(35_000)).toBe(35_000)
    monitor.observe('starting', 65_000)
    expect(monitor.remaining(69_999)).toBe(1)
    expect(() => monitor.remaining(70_000)).toThrow('manager maintenance exceeded 60000ms')

    monitor.observe('active', 70_001)
    expect(monitor.remaining(200_000)).toBeNull()
    monitor.observe('starting', 200_000)
    expect(monitor.remaining(200_001)).toBe(59_999)
  })
})
