import { describe, expect, test } from 'bun:test'
import {
  assessInboundBudget,
  canAcceptGitControl,
  boundedOutboundChunks,
  buildOutboundPayload,
  buildPairingPayload,
  codexReplyText,
  gatewayRuntimePatch,
  parseDaemonRuntimeConfig,
  parseTrustedBridgeIdentity,
  shouldSuppressSilentFinal,
  trustedChannelRole,
} from './policy.ts'
import {
  CPO_CODEX_REASONING_EFFORT,
  DEFAULT_CODEX_MODEL,
  DEFAULT_CODEX_REASONING_EFFORT,
} from './model.ts'
import {
  MAX_ATTACHMENTS_PER_MESSAGE,
  MAX_MESSAGE_ATTACHMENT_BYTES,
} from './attachments.ts'

describe('daemon outbound policy', () => {
  test('all payloads suppress mentions and optional replies cannot ping the author', () => {
    expect(buildOutboundPayload('@everyone <@123>', 'message-1')).toEqual({
      content: '@everyone <@123>',
      allowedMentions: { parse: [], repliedUser: false },
      reply: { messageReference: 'message-1', failIfNotExists: false },
    })
  })

  test('failure text exposes classification but not raw Codex diagnostics', () => {
    const text = codexReplyText({
      ok: false,
      threadId: 'thread-1',
      messages: [],
      errorKind: 'exit',
      error: 'stderr containing API_KEY=super-secret',
    })
    expect(text).toContain('(exit)')
    expect(text).not.toContain('super-secret')
    expect(codexReplyText({ ok: true, threadId: 't', messages: ['first', 'final'] }))
      .toBe('final')
  })

  test('outbound fan-out is capped and visibly truncated', () => {
    const chunks = boundedOutboundChunks('x'.repeat(100_000), 2000, 'length')
    expect(chunks).toHaveLength(20)
    expect(chunks.every(value => value.length <= 2000)).toBe(true)
    expect(chunks.at(-1)).toContain('[response truncated by codex-bridge]')

    const tiny = boundedOutboundChunks('x'.repeat(100), 1, 'length')
    expect(tiny).toHaveLength(20)
    expect(tiny.every(value => value.length <= 1)).toBe(true)
    expect(tiny.join('')).toContain('codex-bridge]')
  })

  test('pairing payload uses the active state directory and shell-quotes it', () => {
    const payload = buildPairingPayload("/tmp/swarm's state", 'a1b2c3', false)
    expect(payload.content).toContain("DISCORD_STATE_DIR='/tmp/swarm'\"'\"'s state'")
    expect(payload.allowedMentions).toEqual({ parse: [], repliedUser: false })
  })
})

describe('daemon admission policy', () => {
  test('queue capacity is checked before attachment work', () => {
    expect(assessInboundBudget(25, 25, [])).toEqual({ ok: false, reason: 'queue-full' })
  })

  test('attachment count, aggregate bytes, and invalid sizes fail closed', () => {
    expect(assessInboundBudget(0, 25, Array(MAX_ATTACHMENTS_PER_MESSAGE + 1).fill(1)))
      .toEqual({ ok: false, reason: 'attachment-budget' })
    expect(assessInboundBudget(0, 25, [MAX_MESSAGE_ATTACHMENT_BYTES + 1]))
      .toEqual({ ok: false, reason: 'attachment-budget' })
    expect(assessInboundBudget(0, 25, [Number.NaN]))
      .toEqual({ ok: false, reason: 'attachment-budget' })
    expect(assessInboundBudget(0, 25, [MAX_MESSAGE_ATTACHMENT_BYTES]))
      .toEqual({ ok: true })
  })

  test('Git control requires a completely idle serialized turn queue', () => {
    expect(canAcceptGitControl(0)).toBe(true)
    expect(canAcceptGitControl(1)).toBe(false)
    expect(canAcceptGitControl(25)).toBe(false)
    expect(canAcceptGitControl(-1)).toBe(false)
  })
})

describe('daemon runtime config policy', () => {
  test('parses explicit runtime controls', () => {
    const parsed = parseDaemonRuntimeConfig({
      CODEX_BRIDGE_CWD: '/repo',
      CODEX_MODEL: 'gpt-test',
      CODEX_PROFILE: 'discord',
      CODEX_TURN_TIMEOUT_MS: '9000',
      CODEX_BIN: '/bin/codex',
      CODEX_BRIDGE_CODEX_ARGV_PREFIX: '/lib/codex.js',
      CODEX_BRIDGE_REASONING_EFFORT: 'low',
      CODEX_BRIDGE_INGRESS_LIMIT: '7',
      CODEX_BRIDGE_QUEUE_LIMIT: '3',
    }, '/fallback', 'cpo')
    expect(parsed).toEqual({
      codex: {
        cwd: '/repo', model: 'gpt-test', profile: 'discord',
        reasoningEffort: CPO_CODEX_REASONING_EFFORT,
        timeoutMs: 9000, bin: '/bin/codex', binArgs: ['/lib/codex.js'],
      },
      ingressLimit: 7,
      turnLimit: 3,
    })
  })

  test('malformed values fall back safely', () => {
    const parsed = parseDaemonRuntimeConfig({
      CODEX_TURN_TIMEOUT_MS: 'NaN',
      CODEX_BRIDGE_INGRESS_LIMIT: '0',
      CODEX_BRIDGE_QUEUE_LIMIT: '-1',
    }, '/fallback')
    expect(parsed.codex).toMatchObject({
      cwd: '/fallback', model: DEFAULT_CODEX_MODEL,
      reasoningEffort: DEFAULT_CODEX_REASONING_EFFORT, timeoutMs: 4_500_000,
    })
    expect(parsed.ingressLimit).toBe(100)
    expect(parsed.turnLimit).toBe(25)
  })
})

describe('Discord gateway runtime policy', () => {
  test('disconnect/invalidation fail readiness closed and ready events use client truth', () => {
    expect(gatewayRuntimePatch('shard-disconnect', true)).toEqual({
      ready: false, last_error: 'discord:shard-disconnect',
    })
    expect(gatewayRuntimePatch('invalidated', true)).toEqual({
      ready: false, last_error: 'discord:invalidated',
    })
    expect(gatewayRuntimePatch('shard-resume', true)).toEqual({ ready: true })
    expect(gatewayRuntimePatch('shard-ready', false)).toEqual({ ready: false })
  })
})

describe('trusted CPO channel roles and silence', () => {
  test('requires complete distinct CPO bindings and resolves roles mechanically', () => {
    const identity = parseTrustedBridgeIdentity({
      CODEX_BRIDGE_ARCHETYPE: 'cpo',
      CODEX_BRIDGE_OPERATOR_CHANNEL: '12345',
      CODEX_BRIDGE_BUS_CHANNEL: '67890',
    })
    expect(trustedChannelRole(identity, '12345')).toBe('operator')
    expect(trustedChannelRole(identity, '67890')).toBe('bus')
    expect(trustedChannelRole(identity, '99999')).toBe('other')
    expect(() => parseTrustedBridgeIdentity({ CODEX_BRIDGE_ARCHETYPE: 'cpo' })).toThrow()
    expect(() => parseTrustedBridgeIdentity({
      CODEX_BRIDGE_ARCHETYPE: 'engineering-cto', CODEX_BRIDGE_BUS_CHANNEL: '67890',
    })).toThrow()
  })

  test('suppresses only the exact entire directive on a trusted CPO bus', () => {
    const cpo = parseTrustedBridgeIdentity({
      CODEX_BRIDGE_ARCHETYPE: 'cpo',
      CODEX_BRIDGE_OPERATOR_CHANNEL: '12345',
      CODEX_BRIDGE_BUS_CHANNEL: '67890',
    })
    expect(shouldSuppressSilentFinal('[[QOFI_SILENT]]', cpo, 'bus')).toBe(true)
    expect(shouldSuppressSilentFinal(' [[QOFI_SILENT]]\n', cpo, 'bus')).toBe(true)
    expect(shouldSuppressSilentFinal('ack\n[[QOFI_SILENT]]', cpo, 'bus')).toBe(false)
    expect(shouldSuppressSilentFinal('[[QOFI_SILENT]]', cpo, 'operator')).toBe(false)
    expect(shouldSuppressSilentFinal('[[QOFI_SILENT]]', { archetype: 'engineering-cto' }, 'bus')).toBe(false)
  })
})
