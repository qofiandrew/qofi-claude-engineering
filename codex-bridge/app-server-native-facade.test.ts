import { afterEach, describe, expect, test } from 'bun:test'
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import WebSocket, { type RawData } from 'ws'
import {
  CodexNativeReadOnlyFacade,
  appServerNotificationThreadId,
} from './app-server-native-facade.ts'
import {
  CPO_CODEX_REASONING_EFFORT,
  DEFAULT_CODEX_MODEL,
  DEFAULT_CODEX_MODEL_DISPLAY_NAME,
  DEFAULT_CODEX_REASONING_EFFORT,
} from './model.ts'

const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-native-facade-')))
  roots.push(root)
  chmodSync(root, 0o700)
  const repo = join(root, 'repo')
  const stateDir = join(root, 'state')
  mkdirSync(repo, { mode: 0o700 })
  mkdirSync(stateDir, { mode: 0o700 })
  return { root, repo, stateDir, socketPath: join(stateDir, 'native.sock') }
}

async function connect(path: string): Promise<WebSocket> {
  const socket = new WebSocket(`ws+unix://${path}:/rpc`)
  await new Promise<void>((resolve, reject) => {
    socket.once('open', () => resolve())
    socket.once('error', reject)
  })
  return socket
}

async function next(socket: WebSocket): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
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
}

async function request(
  socket: WebSocket,
  id: string,
  method: string,
  params: Record<string, unknown> = {},
): Promise<Record<string, any>> {
  const pending = next(socket)
  socket.send(JSON.stringify({ id, method, params }))
  return pending
}

describe('read-only native Codex facade', () => {
  test('projects the selected CPO medium effort across every native read', async () => {
    const f = fixture()
    const facade = new CodexNativeReadOnlyFacade({
      socketPath: f.socketPath, swarmName: 'alpha', repo: f.repo, stateDir: f.stateDir,
      reasoningEffort: CPO_CODEX_REASONING_EFFORT,
    })
    facade.replaceThreadIds(['thread-1'])
    await facade.start()
    const socket = await connect(f.socketPath)
    await request(socket, 'initialize', 'initialize')
    socket.send(JSON.stringify({ method: 'initialized' }))
    expect((await request(socket, 'model', 'model/list')).result.data[0])
      .toMatchObject({ defaultReasoningEffort: 'medium' })
    expect((await request(socket, 'config', 'config/read', { cwd: f.repo })).result.config)
      .toMatchObject({ model: DEFAULT_CODEX_MODEL, model_reasoning_effort: 'medium' })
    expect((await request(socket, 'resume', 'thread/resume', { threadId: 'thread-1' })).result)
      .toMatchObject({ model: DEFAULT_CODEX_MODEL, reasoningEffort: 'medium' })
    facade.setReasoningEffort(DEFAULT_CODEX_REASONING_EFFORT)
    expect((await request(socket, 'updated', 'config/read', { cwd: f.repo })).result.config)
      .toMatchObject({ model_reasoning_effort: 'ultra' })
    socket.terminate()
    await facade.close()
  })

  test('creates an owner-0600 Unix WebSocket and implements the traced bootstrap', async () => {
    const f = fixture()
    const facade = new CodexNativeReadOnlyFacade({
      socketPath: f.socketPath,
      swarmName: 'alpha',
      repo: f.repo,
      stateDir: f.stateDir,
    })
    facade.replaceThreadIds(['thread-1'])
    facade.cacheThread('thread-1', {
      id: 'thread-1', preview: 'cached', turns: [{ id: 'turn-1', status: 'completed', items: [] }],
    })
    await facade.start()
    expect(lstatSync(f.socketPath).isSocket()).toBe(true)
    expect(lstatSync(f.socketPath).mode & 0o777).toBe(0o600)

    const socket = await connect(f.socketPath)
    const initialized = await request(socket, 'initialize', 'initialize', {
      clientInfo: { name: 'codex-tui', title: null, version: '0.144.1' },
      capabilities: { experimentalApi: true, requestAttestation: false },
    })
    expect(initialized.result.userAgent).toBe('qofi-codex-native-facade/0.144.1')
    expect(initialized.result.codexHome).toBe(join(f.stateDir, 'native-view'))
    socket.send(JSON.stringify({ method: 'initialized' }))

    const readThread = (await request(socket, 'read', 'thread/read', {
      threadId: 'thread-1', includeTurns: false,
    })).result.thread
    expect(readThread).toMatchObject({
      id: 'thread-1', cwd: f.repo, modelProvider: 'openai', turns: [],
    })
    for (const field of [
      'id', 'sessionId', 'cliVersion', 'createdAt', 'updatedAt', 'cwd', 'ephemeral',
      'modelProvider', 'preview', 'source', 'status', 'turns', 'extra',
      'forkedFromId', 'gitInfo', 'historyMode', 'name', 'parentThreadId', 'path',
      'recencyAt', 'threadSource', 'agentRole', 'agentNickname',
    ]) expect(Object.prototype.hasOwnProperty.call(readThread, field)).toBe(true)
    const nativeResumed = (await request(socket, 'native-resume', 'thread/resume', {
      threadId: 'thread-1', cwd: '/tmp/escape', approvalPolicy: 'on-request',
    })).result
    expect(nativeResumed.thread.turns).toEqual([{ id: 'turn-1', status: 'completed', items: [] }])
    expect(nativeResumed.initialTurnsPage).toBeNull()

    const resumed = (await request(socket, 'paged-resume', 'thread/resume', {
      threadId: 'thread-1', cwd: '/tmp/escape', approvalPolicy: 'on-request',
      excludeTurns: true,
      initialTurnsPage: { limit: 1, sortDirection: 'desc' },
    })).result
    expect(resumed).toMatchObject({
      model: DEFAULT_CODEX_MODEL, modelProvider: 'openai', cwd: f.repo,
      approvalPolicy: 'never', approvalsReviewer: 'user',
      reasoningEffort: DEFAULT_CODEX_REASONING_EFFORT,
      activePermissionProfile: { id: 'qofi-workspace-only', extends: ':workspace' },
      runtimeWorkspaceRoots: [f.repo],
      thread: { turns: [] },
    })
    expect(resumed.sandbox).toEqual({
      type: 'workspaceWrite', networkAccess: false, writableRoots: [],
      excludeTmpdirEnvVar: true, excludeSlashTmp: true,
    })
    expect(resumed.initialTurnsPage).toMatchObject({
      data: [{ id: 'turn-1' }], nextCursor: null, backwardsCursor: 'qofi:asc:1',
    })
    const includedPage = (await request(socket, 'included-page-resume', 'thread/resume', {
      threadId: 'thread-1', initialTurnsPage: { limit: 1, sortDirection: 'desc' },
    })).result
    expect(includedPage.thread.turns).toEqual([{ id: 'turn-1', status: 'completed', items: [] }])
    expect(includedPage.initialTurnsPage.data).toEqual([{ id: 'turn-1', status: 'completed', items: [] }])
    const excluded = (await request(socket, 'excluded-resume', 'thread/resume', {
      threadId: 'thread-1', excludeTurns: true,
    })).result
    expect(excluded.thread.turns).toEqual([])
    expect(excluded.initialTurnsPage).toBeNull()
    expect((await request(socket, 'loaded', 'thread/loaded/list')).result.data).toEqual(['thread-1'])
    expect((await request(socket, 'list', 'thread/list')).result.data[0].turns).toEqual([])

    facade.cacheThread('thread-1', {
      id: 'thread-1',
      turns: Array.from({ length: 70 }, (_, id) => ({ id: `turn-${id}`, status: 'completed', items: [] })),
    })
    const newest = (await request(socket, 'turns-desc', 'thread/turns/list', {
      threadId: 'thread-1', limit: 10, sortDirection: 'desc', cursor: null,
    })).result
    expect(newest.data.map((turn: any) => turn.id)).toEqual(
      Array.from({ length: 10 }, (_, index) => `turn-${69 - index}`),
    )
    expect(newest.nextCursor).toBe('qofi:desc:60')
    expect(newest.backwardsCursor).toBe('qofi:asc:70')
    const oldest = (await request(socket, 'turns-asc', 'thread/turns/list', {
      threadId: 'thread-1', limit: 3, sortDirection: 'asc', cursor: null,
    })).result
    expect(oldest.data.map((turn: any) => turn.id)).toEqual(['turn-0', 'turn-1', 'turn-2'])
    expect(oldest.nextCursor).toBe('qofi:asc:3')
    expect(oldest.backwardsCursor).toBe('qofi:desc:0')
    const replay = (await request(socket, 'read-replay', 'thread/read', {
      threadId: 'thread-1', includeTurns: true,
    })).result.thread.turns
    expect(replay).toHaveLength(64)
    expect(replay[0].id).toBe('turn-6')
    expect(replay[63].id).toBe('turn-69')
    const resumedReplay = (await request(socket, 'resume-replay', 'thread/resume', {
      threadId: 'thread-1',
    })).result.thread.turns
    expect(resumedReplay.map((turn: any) => turn.id)).toEqual(replay.map((turn: any) => turn.id))
    expect((await request(socket, 'account', 'account/read', { refreshToken: false })).result)
      .toMatchObject({ account: { type: 'chatgpt' }, requiresOpenaiAuth: true })
    expect((await request(socket, 'hooks', 'hooks/list', { cwds: [f.repo] })).result).toEqual({ data: [] })
    expect((await request(socket, 'models', 'model/list', {
      cursor: null, limit: null, includeHidden: true,
    })).result.data[0]).toMatchObject({
      model: DEFAULT_CODEX_MODEL,
      displayName: DEFAULT_CODEX_MODEL_DISPLAY_NAME,
      defaultReasoningEffort: DEFAULT_CODEX_REASONING_EFFORT,
      supportedReasoningEfforts: expect.arrayContaining([
        { reasoningEffort: 'max', description: 'Maximum reasoning depth for the hardest problems' },
        { reasoningEffort: 'ultra', description: 'Maximum reasoning with automatic task delegation' },
      ]),
    })
    const facadeConfig = (await request(socket, 'config', 'config/read', { cwd: f.repo })).result.config
    expect(facadeConfig)
      .toMatchObject({ model: DEFAULT_CODEX_MODEL, model_reasoning_effort: DEFAULT_CODEX_REASONING_EFFORT })
    expect(facadeConfig).not.toHaveProperty('mcp_servers')

    socket.terminate()
    await facade.close()
    expect(() => lstatSync(f.socketPath)).toThrow()
  })

  test('never forwards mutations, response envelopes, server requests, or foreign notifications', async () => {
    const f = fixture()
    const facade = new CodexNativeReadOnlyFacade({
      socketPath: f.socketPath, swarmName: 'alpha', repo: f.repo, stateDir: f.stateDir,
    })
    facade.replaceThreadIds(['thread-1'])
    await facade.start()
    const socket = await connect(f.socketPath)
    await request(socket, 'initialize', 'initialize')
    socket.send(JSON.stringify({ method: 'initialized' }))
    await request(socket, 'resume', 'thread/resume', { threadId: 'thread-1' })

    const refused = await request(socket, 'turn', 'turn/start', {
      threadId: 'thread-1', input: [{ type: 'text', text: 'escape' }],
    })
    expect(refused.error).toMatchObject({ code: -32601, message: 'read-only native facade' })
    expect(facade.publish({
      id: 'server-request', method: 'item/commandExecution/requestApproval',
      params: { threadId: 'thread-1' },
    })).toBe(false)
    expect(facade.publish({
      method: 'turn/completed', params: { threadId: 'foreign', turn: { id: 'x' } },
    })).toBe(false)

    const notification = next(socket)
    expect(facade.publish({
      method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'ok' } },
    })).toBe(true)
    expect((await notification).method).toBe('turn/completed')

    const closed = new Promise<number>(resolve => socket.once('close', code => resolve(code)))
    socket.send(JSON.stringify({ id: 'not-issued', result: {} }))
    expect(await closed).toBe(1008)
    await facade.close()
  })

  test('extracts only explicit thread-scoped notification targets', () => {
    expect(appServerNotificationThreadId({ method: 'item/started', params: { threadId: 't1' } })).toBe('t1')
    expect(appServerNotificationThreadId({ method: 'thread/started', params: { thread: { id: 't2' } } })).toBe('t2')
    expect(appServerNotificationThreadId({ method: 'account/updated', params: {} })).toBeNull()
    expect(appServerNotificationThreadId({ id: 1, method: 'request', params: { threadId: 't1' } })).toBe('t1')
  })
})
