import { afterEach, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'fs'
import { join } from 'path'
import WebSocket, { type RawData } from 'ws'
import { CodexNativeReadOnlyFacade } from './app-server-native-facade.ts'
import { buildAppServerThreadConfig, buildCodexArgs } from './codex.ts'
import {
  CPO_CODEX_REASONING_EFFORT,
  DEFAULT_CODEX_MODEL,
  DEFAULT_CODEX_REASONING_EFFORT,
  codexReasoningEffortForArchetype,
} from './model.ts'
import { parseDaemonRuntimeConfig } from './policy.ts'

const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function request(
  socket: WebSocket,
  id: string,
  method: string,
  params: Record<string, unknown> = {},
): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
    socket.once('error', reject)
    socket.once('message', (data: RawData) => {
      try { resolve(JSON.parse(data.toString())) } catch (error) { reject(error) }
    })
    socket.send(JSON.stringify({ id, method, params }))
  })
}

test('Codex stays on Sol while CPO workers use medium and review stays Ultra', async () => {
  expect(DEFAULT_CODEX_MODEL).toBe('gpt-5.6-sol')
  expect(DEFAULT_CODEX_REASONING_EFFORT).toBe('ultra')
  expect(CPO_CODEX_REASONING_EFFORT).toBe('medium')
  expect(codexReasoningEffortForArchetype('cpo')).toBe('medium')
  expect(codexReasoningEffortForArchetype('engineering-cto')).toBe('ultra')
  expect(codexReasoningEffortForArchetype('future-archetype')).toBe('ultra')

  const cpoDaemon = parseDaemonRuntimeConfig({}, '/tmp/qofi-model-contract', 'cpo')
  const ctoDaemon = parseDaemonRuntimeConfig({}, '/tmp/qofi-model-contract', 'engineering-cto')
  expect(cpoDaemon.codex).toMatchObject({
    model: DEFAULT_CODEX_MODEL, reasoningEffort: CPO_CODEX_REASONING_EFFORT,
  })
  expect(ctoDaemon.codex).toMatchObject({
    model: DEFAULT_CODEX_MODEL, reasoningEffort: DEFAULT_CODEX_REASONING_EFFORT,
  })

  const cpoClassicArgs = buildCodexArgs(null, cpoDaemon.codex)
  const ctoClassicArgs = buildCodexArgs(null, ctoDaemon.codex)
  expect(cpoClassicArgs).toContain(`model="${DEFAULT_CODEX_MODEL}"`)
  expect(cpoClassicArgs).toContain(`model_reasoning_effort="${CPO_CODEX_REASONING_EFFORT}"`)
  expect(ctoClassicArgs).toContain(`model_reasoning_effort="${DEFAULT_CODEX_REASONING_EFFORT}"`)

  const appServerConfig = buildAppServerThreadConfig(
    '/tmp/qofi-model-contract', [], [], [], {}, CPO_CODEX_REASONING_EFFORT,
  )
  expect(appServerConfig.model_reasoning_effort).toBe(CPO_CODEX_REASONING_EFFORT)

  const root = realpathSync(mkdtempSync('/tmp/qofi-model-contract-'))
  roots.push(root)
  chmodSync(root, 0o700)
  const repo = join(root, 'repo')
  const stateDir = join(root, 'state')
  mkdirSync(repo, { mode: 0o700 })
  mkdirSync(stateDir, { mode: 0o700 })
  const socketPath = join(stateDir, 'native.sock')
  const facade = new CodexNativeReadOnlyFacade({
    socketPath, swarmName: 'model-contract', repo, stateDir,
    model: DEFAULT_CODEX_MODEL, reasoningEffort: CPO_CODEX_REASONING_EFFORT,
  })
  await facade.start()
  const socket = new WebSocket(`ws+unix://${socketPath}:/rpc`)
  await new Promise<void>((resolve, reject) => {
    socket.once('open', () => resolve())
    socket.once('error', reject)
  })
  try {
    await request(socket, 'initialize', 'initialize', {
      clientInfo: { name: 'contract-test', version: '0.144.1' },
    })
    socket.send(JSON.stringify({ method: 'initialized' }))
    const config = (await request(socket, 'config', 'config/read', { cwd: repo })).result.config
    expect(config.model).toBe(DEFAULT_CODEX_MODEL)
    expect(config.model_reasoning_effort).toBe(CPO_CODEX_REASONING_EFFORT)
  } finally {
    socket.terminate()
    await facade.close()
  }

  // The contrarian lane remains Sol Ultra, but uses built-in review mode so
  // Codex internally disables model-level delegation for that review session.
  const review = readFileSync(join(import.meta.dir, '..', 'bin', 'codex-review.sh'), 'utf8')
  expect(review).toContain("--disable goals --disable memories --disable chronicle --disable multi_agent")
  expect(review).toContain("--disable shell_tool --disable unified_exec")
  expect(review).toContain(`-c 'model="${DEFAULT_CODEX_MODEL}"'`)
  expect(review).toContain(`-c 'model_reasoning_effort="${DEFAULT_CODEX_REASONING_EFFORT}"' review -`)
})
