// Host-owned Discord control plane for Claude Code /login paste-back.
//
// OAuth URLs and authorization codes must never enter an ordinary Discord
// message: ordinary messages are model input.  The host relay writes one
// private, nonce-bound request; the bridge exposes the URL only through an
// ephemeral interaction and writes a modal submission to one private response
// file.  This module contains the filesystem and validation boundary so it can
// be tested without a live Discord gateway.

import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  linkSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'fs'
import { execFileSync } from 'child_process'
import { basename, dirname, join, resolve } from 'path'
import { randomBytes } from 'crypto'

export const LOGIN_CONTROL_PROTOCOL = 1
export const LOGIN_CONTROL_READY_SCHEMA = 'qofi-login-control-ready/v1'
export const LOGIN_CONTROL_REQUEST_SCHEMA = 'qofi-login-control-request/v1'
export const LOGIN_CONTROL_RESPONSE_SCHEMA = 'qofi-login-control-response/v1'
export const LOGIN_CONTROL_READY_MAX_AGE_SECONDS = 90

const NONCE_RE = /^[a-f0-9]{32}$/
const SNOWFLAKE_RE = /^[0-9]{1,24}$/
const INSTANCE_RE = /^[a-f0-9]{32}$/
// Claude Code 2.1.207 splits the manual value on '#', requiring two non-empty
// pieces.  The provider currently emits URL-safe pieces.  Keep the same
// structure while bounding length and excluding whitespace/control/markdown.
const AUTH_CODE_RE = /^[A-Za-z0-9._~+/=%:-]{1,1900}#[A-Za-z0-9._~+/=%:-]{1,1900}$/
const MAX_REQUEST_BYTES = 16 * 1024

export type LoginControlRequest = {
  schema: typeof LOGIN_CONTROL_REQUEST_SCHEMA
  protocol: typeof LOGIN_CONTROL_PROTOCOL
  nonce: string
  owner_id: string
  channel_id: string
  message_id: string
  bot_user_id: string
  expires_at: number
  oauth_url: string
}

export type LoginControlResponse = {
  schema: typeof LOGIN_CONTROL_RESPONSE_SCHEMA
  protocol: typeof LOGIN_CONTROL_PROTOCOL
  nonce: string
  owner_id: string
  channel_id: string
  message_id: string
  bot_user_id: string
  created_at: number
  expires_at: number
  code: string
}

export type ReadyRecord = {
  schema: typeof LOGIN_CONTROL_READY_SCHEMA
  protocol: typeof LOGIN_CONTROL_PROTOCOL
  instance: string
  pid: number
  bot_user_id: string
  channel_id: string
  updated_at: number
}

function mode(stat: ReturnType<typeof lstatSync>): number {
  return stat.mode & 0o777
}

function currentUid(): number | undefined {
  return typeof process.getuid === 'function' ? process.getuid() : undefined
}

function hasExtendedAcl(path: string): boolean {
  if (process.platform !== 'darwin') return false
  try {
    const first = execFileSync('/bin/ls', ['-lde', path], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).split(/\s+/, 1)[0] ?? ''
    return first.endsWith('+')
  } catch {
    // A boundary we cannot inspect is not a boundary we can trust.
    return true
  }
}

function assertNoSymlinkComponents(path: string): void {
  // A real final state directory beneath a symlinked account/config ancestor
  // is still redirected. Walk the existing lexical chain so that case cannot
  // be normalized away by realpath. macOS exposes three fixed root aliases;
  // those are OS topology, not operator-controlled account indirection.
  const allowedSystemAliases = process.platform === 'darwin'
    ? new Map([
        ['/var', '/private/var'],
        ['/tmp', '/private/tmp'],
        ['/etc', '/private/etc'],
      ])
    : new Map<string, string>()
  let cursor = resolve(path)
  for (;;) {
    try {
      const stat = lstatSync(cursor)
      if (stat.isSymbolicLink()) {
        const allowedTarget = allowedSystemAliases.get(cursor)
        if (!allowedTarget || resolve(realPath(cursor)) !== allowedTarget) {
          throw new Error('login-control path has a symlinked ancestor')
        }
      }
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
    }
    const parent = dirname(cursor)
    if (parent === cursor) break
    cursor = parent
  }
}

function assertUnredirectedDirectory(path: string, description: string): void {
  // Resolve only beneath the immediate parent. This rejects a symlinked leaf
  // while tolerating macOS's system /var -> /private/var alias in ancestors.
  const expected = join(realParent(path), basename(path))
  if (resolve(expected) !== resolve(realPath(path))) {
    throw new Error(`${description} is redirected`)
  }
}

function assertCompatibleStateDirectory(path: string): void {
  assertNoSymlinkComponents(path)
  const stat = lstatSync(path)
  const uid = currentUid()
  // The legacy channel setup commonly created this directory under umask 022.
  // Read/traverse bits are compatible because every credential file remains
  // 0600 and login-control is its own 0700 boundary. Write bits are not: an
  // untrusted local principal must not be able to replace that private leaf.
  if (!stat.isDirectory() || stat.isSymbolicLink() || (mode(stat) & 0o022) !== 0
      || (uid !== undefined && stat.uid !== uid) || hasExtendedAcl(path)) {
    throw new Error('Discord state directory is not owner-held')
  }
  assertUnredirectedDirectory(path, 'Discord state directory')
}

function assertPrivateDirectory(path: string): void {
  assertNoSymlinkComponents(path)
  const stat = lstatSync(path)
  const uid = currentUid()
  if (!stat.isDirectory() || stat.isSymbolicLink() || mode(stat) !== 0o700
      || (uid !== undefined && stat.uid !== uid) || hasExtendedAcl(path)) {
    throw new Error('login-control directory is not private')
  }
  assertUnredirectedDirectory(path, 'login-control directory')
}

function realPath(path: string): string {
  return realpathSync(path)
}

function realParent(path: string): string {
  return realPath(dirname(path))
}

export function ensureLoginControlDirectory(path: string): void {
  const stateDirectory = dirname(path)
  ensureCompatibleStateDirectory(stateDirectory)
  let created = false
  try {
    mkdirSync(path, { mode: 0o700 })
    created = true
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err
  }
  // mkdir modes are umask-sensitive. Only normalize a leaf this invocation
  // created; an unexpected pre-existing permissive leaf is evidence to refuse,
  // not something to silently bless after possible disclosure.
  if (created) chmodSync(path, 0o700)
  assertPrivateDirectory(path)
}

function ensureCompatibleStateDirectory(path: string): void {
  try {
    assertCompatibleStateDirectory(path)
    return
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
  }

  const parent = dirname(path)
  if (parent === path) throw new Error('cannot create Discord state root')
  ensureCompatibleStateDirectory(parent)

  let created = false
  try {
    mkdirSync(path, { mode: 0o700 })
    created = true
  } catch (err) {
    // Another bridge may initialize the same account concurrently. Validate
    // what won the race instead of changing its permissions.
    if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err
  }
  if (created) chmodSync(path, 0o700)
  assertCompatibleStateDirectory(path)
}

function readPrivateJson(path: string): unknown {
  assertPrivateDirectory(dirname(path))
  const before = lstatSync(path)
  const uid = currentUid()
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
      || mode(before) !== 0o600 || before.size < 1 || before.size > MAX_REQUEST_BYTES
      || (uid !== undefined && before.uid !== uid) || hasExtendedAcl(path)) {
    throw new Error('login-control record is not a private bounded file')
  }
  const noFollow = typeof constants.O_NOFOLLOW === 'number' ? constants.O_NOFOLLOW : 0
  const fd = openSync(path, constants.O_RDONLY | noFollow)
  try {
    const opened = fstatSync(fd)
    if (opened.dev !== before.dev || opened.ino !== before.ino
        || opened.size !== before.size || opened.nlink !== 1
        || opened.uid !== before.uid || mode(opened) !== mode(before)
        || opened.ctimeMs !== before.ctimeMs) {
      throw new Error('login-control record changed while opening')
    }
    const raw = readFileSync(fd, 'utf8')
    const after = fstatSync(fd)
    if (after.dev !== opened.dev || after.ino !== opened.ino
        || after.size !== opened.size || after.nlink !== 1
        || after.uid !== opened.uid || mode(after) !== mode(opened)
        || after.ctimeMs !== opened.ctimeMs || after.mtimeMs !== opened.mtimeMs) {
      throw new Error('login-control record changed while reading')
    }
    return JSON.parse(raw)
  } finally {
    closeSync(fd)
  }
}

function validOAuthUrl(raw: string): boolean {
  if (raw.length < 20 || raw.length > 8192) return false
  try {
    const url = new URL(raw)
    if (url.protocol !== 'https:' || !url.pathname.toLowerCase().includes('oauth')) return false
    const host = url.hostname.toLowerCase()
    return host === 'claude.ai' || host.endsWith('.claude.ai')
      || host === 'claude.com' || host.endsWith('.claude.com')
      || host === 'anthropic.com' || host.endsWith('.anthropic.com')
  } catch {
    return false
  }
}

export function validAuthorizationCode(raw: string): boolean {
  return raw.length <= 2000 && AUTH_CODE_RE.test(raw)
}

function parseRequest(value: unknown): LoginControlRequest {
  if (!value || typeof value !== 'object') throw new Error('invalid login-control request')
  const v = value as Record<string, unknown>
  const keys = Object.keys(v).sort().join(',')
  const expected = ['bot_user_id','channel_id','expires_at','message_id','nonce','oauth_url','owner_id','protocol','schema'].join(',')
  if (keys !== expected) throw new Error('invalid login-control request')
  if (v.schema !== LOGIN_CONTROL_REQUEST_SCHEMA || v.protocol !== LOGIN_CONTROL_PROTOCOL
      || typeof v.nonce !== 'string' || !NONCE_RE.test(v.nonce)
      || typeof v.owner_id !== 'string' || !SNOWFLAKE_RE.test(v.owner_id)
      || typeof v.channel_id !== 'string' || !SNOWFLAKE_RE.test(v.channel_id)
      || typeof v.message_id !== 'string' || !SNOWFLAKE_RE.test(v.message_id)
      || typeof v.bot_user_id !== 'string' || !SNOWFLAKE_RE.test(v.bot_user_id)
      || typeof v.expires_at !== 'number' || !Number.isSafeInteger(v.expires_at)
      || typeof v.oauth_url !== 'string' || !validOAuthUrl(v.oauth_url)) {
    throw new Error('invalid login-control request')
  }
  return v as LoginControlRequest
}

export type InteractionBinding = {
  nonce: string
  ownerId: string
  canonicalOwnerId?: string
  channelId: string
  botUserId: string
  messageId?: string
  nowSeconds?: number
  ownerAllowed: boolean
  boundChannels: readonly string[]
}

export class LoginControlStore {
  readonly instance = randomBytes(16).toString('hex')

  constructor(
    readonly directory: string,
    readonly canonicalOwnerId?: string,
  ) {
    if (canonicalOwnerId !== undefined && !SNOWFLAKE_RE.test(canonicalOwnerId)) {
      throw new Error('invalid canonical login-control owner')
    }
    ensureLoginControlDirectory(directory)
  }

  requestPath(nonce: string): string {
    if (!NONCE_RE.test(nonce)) throw new Error('invalid login-control nonce')
    return join(this.directory, `request-${nonce}.json`)
  }

  responsePath(nonce: string): string {
    if (!NONCE_RE.test(nonce)) throw new Error('invalid login-control nonce')
    return join(this.directory, `response-${nonce}.json`)
  }

  readyPath(channelId: string, botUserId: string): string {
    if (!SNOWFLAKE_RE.test(channelId)) throw new Error('invalid login-control channel')
    if (!SNOWFLAKE_RE.test(botUserId)) throw new Error('invalid login-control bot id')
    return join(this.directory, `ready-${channelId}-${botUserId}.json`)
  }

  readAuthorizedRequest(binding: InteractionBinding): LoginControlRequest {
    const canonicalOwnerId = binding.canonicalOwnerId ?? this.canonicalOwnerId
    if (!NONCE_RE.test(binding.nonce)
        || typeof canonicalOwnerId !== 'string'
        || !SNOWFLAKE_RE.test(canonicalOwnerId)
        || (this.canonicalOwnerId !== undefined
          && binding.canonicalOwnerId !== undefined
          && binding.canonicalOwnerId !== this.canonicalOwnerId)
        || binding.ownerId !== canonicalOwnerId
        || !binding.ownerAllowed
        || !binding.boundChannels.includes(binding.channelId)) {
      throw new Error('login-control interaction is not authorized')
    }
    const request = parseRequest(readPrivateJson(this.requestPath(binding.nonce)))
    const now = binding.nowSeconds ?? Math.floor(Date.now() / 1000)
    if (request.nonce !== binding.nonce
        || request.owner_id !== canonicalOwnerId
        || request.owner_id !== binding.ownerId
        || request.channel_id !== binding.channelId
        || request.bot_user_id !== binding.botUserId
        || (binding.messageId !== undefined && request.message_id !== binding.messageId)
        || request.expires_at < now) {
      throw new Error('login-control request binding failed')
    }
    return request
  }

  acceptCode(binding: InteractionBinding, rawCode: string): void {
    const request = this.readAuthorizedRequest(binding)
    const code = rawCode.trim()
    if (!validAuthorizationCode(code)) throw new Error('invalid authorization code')
    const now = binding.nowSeconds ?? Math.floor(Date.now() / 1000)
    const response: LoginControlResponse = {
      schema: LOGIN_CONTROL_RESPONSE_SCHEMA,
      protocol: LOGIN_CONTROL_PROTOCOL,
      nonce: request.nonce,
      owner_id: request.owner_id,
      channel_id: request.channel_id,
      message_id: request.message_id,
      bot_user_id: request.bot_user_id,
      created_at: now,
      expires_at: request.expires_at,
      code,
    }
    // Publish complete bytes atomically. link(2) is the exclusive replay
    // boundary: the first valid modal wins without ever exposing a partially
    // written response at the canonical name.
    const target = this.responsePath(request.nonce)
    const tmp = join(this.directory, `.response-${request.nonce}.${this.instance}.${randomBytes(8).toString('hex')}.tmp`)
    writeFileSync(tmp, `${JSON.stringify(response)}\n`, {
      flag: 'wx',
      mode: 0o600,
    })
    try {
      linkSync(tmp, target)
    } finally {
      try { unlinkSync(tmp) } catch {}
    }
  }

  publishReady(botUserId: string, channelIds: readonly string[], nowSeconds = Math.floor(Date.now() / 1000)): void {
    assertPrivateDirectory(this.directory)
    if (!SNOWFLAKE_RE.test(botUserId)) throw new Error('invalid login-control bot id')
    for (const channelId of channelIds) {
      if (!SNOWFLAKE_RE.test(channelId)) continue
      const record: ReadyRecord = {
        schema: LOGIN_CONTROL_READY_SCHEMA,
        protocol: LOGIN_CONTROL_PROTOCOL,
        instance: this.instance,
        pid: process.pid,
        bot_user_id: botUserId,
        channel_id: channelId,
        updated_at: nowSeconds,
      }
      const target = this.readyPath(channelId, botUserId)
      const tmp = join(this.directory, `.ready-${channelId}.${this.instance}.tmp`)
      try {
        writeFileSync(tmp, `${JSON.stringify(record)}\n`, { flag: 'wx', mode: 0o600 })
        renameSync(tmp, target)
      } finally {
        try { unlinkSync(tmp) } catch {}
      }
    }
  }

  clearReady(channelIds: readonly string[], botUserId?: string): void {
    // Deliberately leave the last marker to expire by timestamp.  Unlinking a
    // stable channel+bot path during shutdown can race a replacement bridge and
    // remove its newer marker (ABA).  The relay also proves the recorded PID is
    // live, so a stale marker never grants readiness.
    void channelIds
    void botUserId
  }
}

export function parseLoginControlCustomId(raw: string):
  | { action: 'open' | 'code' | 'submit'; nonce: string }
  | null {
  const match = /^qofi-login:(open|code|submit):v1:([a-f0-9]{32})$/.exec(raw)
  if (!match) return null
  return { action: match[1] as 'open' | 'code' | 'submit', nonce: match[2]! }
}
