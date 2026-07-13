import type { CodexConfig, CodexTurnResult } from './codex.ts'
import {
  DEFAULT_CODEX_MODEL,
  codexReasoningEffortForArchetype,
} from './model.ts'
import {
  MAX_ATTACHMENTS_PER_MESSAGE,
  MAX_MESSAGE_ATTACHMENT_BYTES,
} from './attachments.ts'
import { buildPairingInstruction } from './prompt.ts'
import { chunk } from './chunk.ts'
import { resolve } from 'path'

export type OutboundPayload = {
  content: string
  allowedMentions: { parse: []; repliedUser: false }
  reply?: { messageReference: string; failIfNotExists: false }
}

/** Every bridge-authored Discord payload suppresses user/role/everyone pings. */
export function buildOutboundPayload(content: string, replyTo?: string): OutboundPayload {
  return {
    content,
    allowedMentions: { parse: [], repliedUser: false },
    ...(replyTo
      ? { reply: { messageReference: replyTo, failIfNotExists: false as const } }
      : {}),
  }
}

export function buildPairingPayload(
  stateDir: string,
  code: string,
  isResend: boolean,
): OutboundPayload {
  return buildOutboundPayload(buildPairingInstruction(stateDir, code, isResend))
}

/** Raw CLI diagnostics stay in the operator log and never cross into Discord. */
export function codexReplyText(result: CodexTurnResult): string {
  if (!result.ok) {
    return `⚠️ codex turn failed (${result.errorKind ?? 'unknown'}). Check the codex-bridge operator view for status.`
  }
  return result.messages.at(-1) || '(codex completed the turn without a reply message)'
}

export const MAX_OUTBOUND_CHUNKS = 20
const TRUNCATION_NOTICE = '\n\n[response truncated by codex-bridge]'

/** Bound Discord API fan-out even if Codex emits megabytes or limit is tiny. */
export function boundedOutboundChunks(
  text: string,
  limit: number,
  mode: 'length' | 'newline',
  maxChunks = MAX_OUTBOUND_CHUNKS,
): string[] {
  const safeLimit = Number.isSafeInteger(limit) && limit > 0 ? limit : 1
  const safeMax = Number.isSafeInteger(maxChunks) && maxChunks > 0
    ? Math.min(maxChunks, MAX_OUTBOUND_CHUNKS)
    : MAX_OUTBOUND_CHUNKS
  // Bound allocation before invoking the paragraph-aware chunker. Its cuts
  // may be shorter than limit, so enforce the count independently afterward.
  const sourceLimit = safeLimit * safeMax
  const source = text.slice(0, sourceLimit)
  const chunks = chunk(source, safeLimit, mode)
  const truncated = text.length > source.length || chunks.length > safeMax
  if (!truncated) return chunks

  // On truncation, use fixed cuts so paragraph-boundary shortening cannot
  // push the notice beyond the capped final chunk. Tiny limits still carry as
  // much of the notice suffix as the total delivery budget permits.
  const marker = TRUNCATION_NOTICE.slice(-Math.min(TRUNCATION_NOTICE.length, sourceLimit))
  const bounded = text.slice(0, Math.max(0, sourceLimit - marker.length)) + marker
  return chunk(bounded, safeLimit, 'length').slice(0, safeMax)
}

export type AdmissionFailure = 'queue-full' | 'attachment-budget'

export function assessInboundBudget(
  turnQueueSize: number,
  turnQueueCapacity: number,
  attachmentSizes: readonly number[],
): { ok: true } | { ok: false; reason: AdmissionFailure } {
  if (turnQueueSize >= turnQueueCapacity) return { ok: false, reason: 'queue-full' }
  if (attachmentSizes.length > MAX_ATTACHMENTS_PER_MESSAGE) {
    return { ok: false, reason: 'attachment-budget' }
  }
  let total = 0
  for (const size of attachmentSizes) {
    if (!Number.isFinite(size) || size < 0) return { ok: false, reason: 'attachment-budget' }
    total += size
    if (total > MAX_MESSAGE_ATTACHMENT_BYTES) {
      return { ok: false, reason: 'attachment-budget' }
    }
  }
  return { ok: true }
}

/** Git controls never queue behind or alongside a workspace-writing turn. */
export function canAcceptGitControl(turnQueueSize: number): boolean {
  return Number.isSafeInteger(turnQueueSize) && turnQueueSize === 0
}

export type BridgeArchetype = 'cpo' | 'engineering-cto' | 'unknown'
export type TrustedChannelRole = 'operator' | 'bus' | 'other'
export type TrustedBridgeIdentity = {
  archetype: BridgeArchetype
  operatorChannel?: string
  busChannel?: string
}

const CHANNEL_ID = /^\d{5,30}$/

/** Parse launcher-owned role metadata; CPO routing must be complete and distinct. */
export function parseTrustedBridgeIdentity(env: NodeJS.ProcessEnv): TrustedBridgeIdentity {
  const raw = env.CODEX_BRIDGE_ARCHETYPE
  const archetype: BridgeArchetype = raw === undefined || raw === ''
    ? 'unknown'
    : raw === 'cpo' || raw === 'engineering-cto'
      ? raw
      : (() => { throw new Error('invalid CODEX_BRIDGE_ARCHETYPE') })()
  const operatorChannel = env.CODEX_BRIDGE_OPERATOR_CHANNEL || undefined
  const busChannel = env.CODEX_BRIDGE_BUS_CHANNEL || undefined
  if (operatorChannel && !CHANNEL_ID.test(operatorChannel)) throw new Error('invalid operator channel binding')
  if (busChannel && !CHANNEL_ID.test(busChannel)) throw new Error('invalid bus channel binding')
  if (archetype === 'cpo' && (!operatorChannel || !busChannel || operatorChannel === busChannel)) {
    throw new Error('CPO bridge requires distinct operator and bus channel bindings')
  }
  if (archetype === 'engineering-cto' && busChannel) {
    throw new Error('engineering bridge must not bind a CPO bus channel')
  }
  return { archetype, operatorChannel, busChannel }
}

export function trustedChannelRole(
  identity: TrustedBridgeIdentity,
  channelId: string,
): TrustedChannelRole {
  if (identity.operatorChannel === channelId) return 'operator'
  if (identity.busChannel === channelId) return 'bus'
  return 'other'
}

export const SILENT_FINAL_DIRECTIVE = '[[QOFI_SILENT]]'

/** Silence is a CPO bus semantic only; operator/engineering responses always post. */
export function shouldSuppressSilentFinal(
  text: string,
  identity: TrustedBridgeIdentity,
  role: TrustedChannelRole,
): boolean {
  return identity.archetype === 'cpo'
    && role === 'bus'
    && text.trim() === SILENT_FINAL_DIRECTIVE
}

export type DaemonRuntimeConfig = {
  codex: CodexConfig
  ingressLimit: number
  turnLimit: number
}

export type GatewayLifecycleEvent =
  | 'ready'
  | 'shard-ready'
  | 'shard-resume'
  | 'shard-disconnect'
  | 'invalidated'

export function gatewayRuntimePatch(
  event: GatewayLifecycleEvent,
  clientReady: boolean,
): { ready: boolean; last_error?: string } {
  if (event === 'shard-disconnect' || event === 'invalidated') {
    return { ready: false, last_error: `discord:${event}` }
  }
  return { ready: clientReady }
}

function positiveInt(raw: string | undefined, fallback: number): number {
  const value = Number(raw)
  return Number.isSafeInteger(value) && value > 0 ? value : fallback
}

// The terminal Fable reviewer may wait behind one full one-hour budget window
// and then use its bounded ten-minute provider deadline. Keep the managed turn
// alive for that queue plus cleanup margin; the MCP's own timeout is aligned
// independently in the rendered CODEX_HOME config.
export const DEFAULT_CODEX_TURN_TIMEOUT_MS = 75 * 60 * 1000

/** Parse operator-controlled environment once, with safe defaults on bad input. */
export function parseDaemonRuntimeConfig(
  env: NodeJS.ProcessEnv,
  fallbackCwd: string,
  archetype?: string,
): DaemonRuntimeConfig {
  return {
    codex: {
      cwd: resolve(env.CODEX_BRIDGE_CWD || fallbackCwd),
      model: env.CODEX_MODEL || DEFAULT_CODEX_MODEL,
      reasoningEffort: codexReasoningEffortForArchetype(archetype),
      profile: env.CODEX_PROFILE || undefined,
      timeoutMs: positiveInt(env.CODEX_TURN_TIMEOUT_MS, DEFAULT_CODEX_TURN_TIMEOUT_MS),
      bin: env.CODEX_BIN || undefined,
      ...(env.CODEX_BRIDGE_CODEX_ARGV_PREFIX
        ? { binArgs: [env.CODEX_BRIDGE_CODEX_ARGV_PREFIX] }
        : {}),
    },
    ingressLimit: positiveInt(env.CODEX_BRIDGE_INGRESS_LIMIT, 100),
    turnLimit: positiveInt(env.CODEX_BRIDGE_QUEUE_LIMIT, 25),
  }
}
