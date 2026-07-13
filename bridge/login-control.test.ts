import { afterEach, expect, test } from 'bun:test'
import {
  chmodSync,
  linkSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { execFileSync } from 'child_process'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  LOGIN_CONTROL_PROTOCOL,
  LOGIN_CONTROL_READY_SCHEMA,
  LOGIN_CONTROL_REQUEST_SCHEMA,
  LOGIN_CONTROL_RESPONSE_SCHEMA,
  LoginControlStore,
  parseLoginControlCustomId,
  validAuthorizationCode,
} from './login-control.ts'

const OWNER = '1507069153335443608'
const OTHER = '999999999999999999'
const CHANNEL = '1508921858165047390'
const OTHER_CHANNEL = '1507159618453770291'
const MESSAGE = '222222222222222222'
const BOT = '333333333333333333'
const NONCE = '0123456789abcdef0123456789abcdef'
const NOW = 1_800_000_000
const CODE = `${'A'.repeat(48)}#${'b'.repeat(48)}`
const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'qofi-login-control.'))
  roots.push(root)
  const directory = join(root, 'login-control')
  const store = new LoginControlStore(directory, OWNER)
  const request = {
    schema: LOGIN_CONTROL_REQUEST_SCHEMA,
    protocol: LOGIN_CONTROL_PROTOCOL,
    nonce: NONCE,
    owner_id: OWNER,
    channel_id: CHANNEL,
    message_id: MESSAGE,
    bot_user_id: BOT,
    expires_at: NOW + 300,
    oauth_url: 'https://claude.ai/oauth/authorize?code=true&state=STATE',
  } as const
  writeFileSync(store.requestPath(NONCE), `${JSON.stringify(request)}\n`, { mode: 0o600 })
  return { root, directory, store, request }
}

function binding(overrides: Record<string, unknown> = {}) {
  return {
    nonce: NONCE,
    ownerId: OWNER,
    channelId: CHANNEL,
    messageId: MESSAGE,
    botUserId: BOT,
    nowSeconds: NOW,
    ownerAllowed: true,
    boundChannels: [CHANNEL],
    ...overrides,
  }
}

test('custom IDs are narrow, versioned, and nonce-bound', () => {
  expect(parseLoginControlCustomId(`qofi-login:open:v1:${NONCE}`)).toEqual({ action: 'open', nonce: NONCE })
  expect(parseLoginControlCustomId(`qofi-login:code:v1:${NONCE}`)).toEqual({ action: 'code', nonce: NONCE })
  expect(parseLoginControlCustomId(`qofi-login:submit:v1:${NONCE}`)).toEqual({ action: 'submit', nonce: NONCE })
  expect(parseLoginControlCustomId(`qofi-login:open:v2:${NONCE}`)).toBeNull()
  expect(parseLoginControlCustomId('qofi-login:open:v1:../response')).toBeNull()
})

test('authorization code mirrors Claude code#state shape but is bounded', () => {
  expect(validAuthorizationCode(CODE)).toBe(true)
  expect(validAuthorizationCode('missing-delimiter')).toBe(false)
  expect(validAuthorizationCode('a#')).toBe(false)
  expect(validAuthorizationCode('a#b#c')).toBe(false)
  expect(validAuthorizationCode('a b#c')).toBe(false)
  expect(validAuthorizationCode(`a#${'x'.repeat(2000)}`)).toBe(false)
})

test('request requires exact canonical owner, ACL, bound channel, bot, message, nonce and expiry', () => {
  const { store, request } = fixture()
  expect(store.readAuthorizedRequest(binding())).toEqual(request)
  for (const override of [
    { ownerId: OTHER },
    { ownerAllowed: false },
    { channelId: OTHER_CHANNEL },
    { boundChannels: [OTHER_CHANNEL] },
    { botUserId: OTHER },
    { messageId: OTHER },
    { nonce: 'fedcba9876543210fedcba9876543210' },
    { nowSeconds: NOW + 301 },
  ]) {
    expect(() => store.readAuthorizedRequest(binding(override))).toThrow()
  }
})

test('deployment owner can be supplied by trusted ACL binding without a code literal', () => {
  const root = mkdtempSync(join(tmpdir(), 'qofi-login-owner.'))
  roots.push(root)
  const store = new LoginControlStore(join(root, 'login-control'))
  const request = {
    schema: LOGIN_CONTROL_REQUEST_SCHEMA,
    protocol: LOGIN_CONTROL_PROTOCOL,
    nonce: NONCE,
    owner_id: OTHER,
    channel_id: CHANNEL,
    message_id: MESSAGE,
    bot_user_id: BOT,
    expires_at: NOW + 300,
    oauth_url: 'https://claude.ai/oauth/authorize?state=STATE',
  } as const
  writeFileSync(store.requestPath(NONCE), `${JSON.stringify(request)}\n`, { mode: 0o600 })
  const otherBinding = binding({ ownerId: OTHER, canonicalOwnerId: OTHER })
  expect(store.readAuthorizedRequest(otherBinding)).toEqual(request)
  expect(() => store.readAuthorizedRequest(binding({ ownerId: OTHER }))).toThrow()
  expect(() => store.readAuthorizedRequest(binding({ ownerId: OTHER, canonicalOwnerId: OWNER }))).toThrow()
})

test('request rejects a non-Anthropic URL and private-file boundary violations', () => {
  const { store } = fixture()
  const path = store.requestPath(NONCE)
  const raw = JSON.parse(readFileSync(path, 'utf8'))
  raw.oauth_url = 'https://evil.example/oauth/authorize?state=x'
  writeFileSync(path, `${JSON.stringify(raw)}\n`, { mode: 0o600 })
  expect(() => store.readAuthorizedRequest(binding())).toThrow()

  raw.oauth_url = 'https://claude.com/cai/oauth/authorize?state=x'
  writeFileSync(path, `${JSON.stringify(raw)}\n`)
  chmodSync(path, 0o644)
  expect(() => store.readAuthorizedRequest(binding())).toThrow()

  rmSync(path)
  const outside = join(store.directory, '..', 'outside.json')
  writeFileSync(outside, `${JSON.stringify(raw)}\n`, { mode: 0o600 })
  symlinkSync(outside, path)
  expect(() => store.readAuthorizedRequest(binding())).toThrow()
})

test('request rejects extra fields and hardlinked records', () => {
  const { store } = fixture()
  const path = store.requestPath(NONCE)
  const raw = JSON.parse(readFileSync(path, 'utf8'))
  raw.untrusted = true
  writeFileSync(path, `${JSON.stringify(raw)}\n`, { mode: 0o600 })
  expect(() => store.readAuthorizedRequest(binding())).toThrow()

  delete raw.untrusted
  writeFileSync(path, `${JSON.stringify(raw)}\n`, { mode: 0o600 })
  linkSync(path, join(store.directory, 'outside-name.json'))
  expect(() => store.readAuthorizedRequest(binding())).toThrow()
})

test('control store accepts a legacy 0755 owner-held state but keeps its leaf private', () => {
  const root = mkdtempSync(join(tmpdir(), 'qofi-login-parent.'))
  roots.push(root)
  chmodSync(root, 0o755)
  const directory = join(root, 'login-control')
  new LoginControlStore(directory, OWNER)
  const stat = lstatSync(directory)
  expect(stat.mode & 0o777).toBe(0o700)
  if (typeof process.getuid === 'function') expect(stat.uid).toBe(process.getuid())
  if (process.platform === 'darwin') {
    expect(execFileSync('/bin/ls', ['-lde', directory], { encoding: 'utf8' }).split(/\s+/, 1)[0]!.endsWith('+')).toBe(false)
  }
})

test('control store privately creates a missing account-aware state path', () => {
  const root = mkdtempSync(join(tmpdir(), 'qofi-login-missing.'))
  roots.push(root)
  const state = join(root, '.claude-accounts', 'max-a', 'channels', 'discord')
  const directory = join(state, 'login-control')
  new LoginControlStore(directory, OWNER)
  expect(lstatSync(state).mode & 0o777).toBe(0o700)
  expect(lstatSync(directory).mode & 0o777).toBe(0o700)
})

test('control store refuses writable, redirected, or permissive boundaries', () => {
  const root = mkdtempSync(join(tmpdir(), 'qofi-login-unsafe.'))
  roots.push(root)
  chmodSync(root, 0o775)
  expect(() => new LoginControlStore(join(root, 'login-control'), OWNER)).toThrow()

  chmodSync(root, 0o700)
  const realState = join(root, 'real-state')
  const redirectedState = join(root, 'discord')
  mkdirSync(realState, { mode: 0o700 })
  symlinkSync(realState, redirectedState)
  expect(() => new LoginControlStore(join(redirectedState, 'login-control'), OWNER)).toThrow()

  const realAccount = join(root, 'real-account')
  const linkedAccount = join(root, 'linked-account')
  mkdirSync(join(realAccount, 'channels', 'discord'), { recursive: true, mode: 0o700 })
  symlinkSync(realAccount, linkedAccount)
  expect(() => new LoginControlStore(
    join(linkedAccount, 'channels', 'discord', 'login-control'),
    OWNER,
  )).toThrow()

  const state = join(root, 'safe-state')
  const permissiveControl = join(state, 'login-control')
  mkdirSync(state, { mode: 0o755 })
  mkdirSync(permissiveControl, { mode: 0o755 })
  expect(() => new LoginControlStore(permissiveControl, OWNER)).toThrow()
})

test('control store refuses macOS extended ACLs', () => {
  const root = mkdtempSync(join(tmpdir(), 'qofi-login-acl.'))
  roots.push(root)

  if (process.platform === 'darwin') {
    const store = new LoginControlStore(join(root, 'login-control'), OWNER)
    const request = {
      schema: LOGIN_CONTROL_REQUEST_SCHEMA,
      protocol: LOGIN_CONTROL_PROTOCOL,
      nonce: NONCE,
      owner_id: OWNER,
      channel_id: CHANNEL,
      message_id: MESSAGE,
      bot_user_id: BOT,
      expires_at: NOW + 300,
      oauth_url: 'https://claude.ai/oauth/authorize?state=STATE',
    }
    const path = store.requestPath(NONCE)
    writeFileSync(path, `${JSON.stringify(request)}\n`, { mode: 0o600 })
    execFileSync('/bin/chmod', ['+a', 'everyone allow read', path])
    expect(() => store.readAuthorizedRequest(binding())).toThrow()

    execFileSync('/bin/chmod', ['+a', 'everyone allow read', store.directory])
    expect(() => store.publishReady(BOT, [CHANNEL], NOW)).toThrow()
  }
})

test('first valid modal wins one private response and cannot be replayed', () => {
  const { store } = fixture()
  store.acceptCode(binding({ messageId: undefined }), CODE)
  const responsePath = store.responsePath(NONCE)
  expect(lstatSync(responsePath).mode & 0o777).toBe(0o600)
  expect(lstatSync(responsePath).nlink).toBe(1)
  const response = JSON.parse(readFileSync(responsePath, 'utf8'))
  expect(response).toEqual({
    schema: LOGIN_CONTROL_RESPONSE_SCHEMA,
    protocol: LOGIN_CONTROL_PROTOCOL,
    nonce: NONCE,
    owner_id: OWNER,
    channel_id: CHANNEL,
    message_id: MESSAGE,
    bot_user_id: BOT,
    created_at: NOW,
    expires_at: NOW + 300,
    code: CODE,
  })
  expect(() => store.acceptCode(binding({ messageId: undefined }), CODE)).toThrow()
})

test('readiness is per-channel, v1, private and refreshed by one instance', () => {
  const { store } = fixture()
  store.publishReady(BOT, [CHANNEL, OTHER_CHANNEL], NOW)
  for (const channel of [CHANNEL, OTHER_CHANNEL]) {
    const path = store.readyPath(channel, BOT)
    expect(lstatSync(path).mode & 0o777).toBe(0o600)
    const ready = JSON.parse(readFileSync(path, 'utf8'))
    expect(ready.schema).toBe(LOGIN_CONTROL_READY_SCHEMA)
    expect(ready.protocol).toBe(LOGIN_CONTROL_PROTOCOL)
    expect(ready.channel_id).toBe(channel)
    expect(ready.bot_user_id).toBe(BOT)
    expect(ready.updated_at).toBe(NOW)
  }
  store.clearReady([CHANNEL, OTHER_CHANNEL], BOT)
  expect(lstatSync(store.readyPath(CHANNEL, BOT)).isFile()).toBe(true)
})

test('server handles login modal before permission/MCP routing and never notifies MCP with its value', () => {
  const source = readFileSync(join(import.meta.dir, 'server.ts'), 'utf8')
  const start = source.indexOf("client.on('interactionCreate'")
  const end = source.indexOf("client.on('messageCreate'", start)
  const handler = source.slice(start, end)
  const modal = handler.indexOf('activeLoginControl().acceptCode')
  const permission = handler.indexOf('pendingPermissions.delete')
  expect(modal).toBeGreaterThan(0)
  expect(permission).toBeGreaterThan(modal)
  expect(handler.slice(0, permission).includes("method: 'notifications/claude/channel'")).toBe(false)
})

test('server pins control state under account-aware Discord state', () => {
  const source = readFileSync(join(import.meta.dir, 'server.ts'), 'utf8')
  expect(source).toContain("process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude')")
  expect(source).toContain("const LOGIN_CONTROL_DIR = join(STATE_DIR, 'login-control')")
  expect(source).not.toContain('process.env.SWARM_LOGIN_CONTROL_DIR')
  expect(source).toContain('let loginControl: LoginControlStore | null = null')
  expect(source).toContain('continuing without login-control readiness')
  expect(source).toContain('if (loginControl)')
  expect(source).toContain('loginControlOwnerId')
  expect(source).not.toContain("const LOGIN_CONTROL_OWNER =")
})
