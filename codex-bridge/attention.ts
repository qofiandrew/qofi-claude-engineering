import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { randomUUID } from 'crypto'
import { isAbsolute, join, resolve } from 'path'

export type AttentionDirective =
  | { action: 'raise'; reason: string }
  | { action: 'clear' }

export type ExtractedAttention = {
  visibleText: string
  directive: AttentionDirective | null
}

/** Parse only an exact final non-empty line; malformed/lookalike text is inert. */
export function extractAttentionDirective(text: string): ExtractedAttention {
  const normalized = text.replace(/\r\n/g, '\n')
  const lines = normalized.split('\n')
  while (lines.length > 0 && lines.at(-1)?.trim() === '') lines.pop()
  if (lines.length === 0) return { visibleText: text, directive: null }
  const final = lines.at(-1)!.trim()
  let directive: AttentionDirective | null = null
  if (final === '[[SWARM_ATTENTION_CLEAR]]') {
    directive = { action: 'clear' }
  } else if (final.startsWith('[[SWARM_ATTENTION_RAISE: ') && final.endsWith(']]')) {
    const raw = final.slice('[[SWARM_ATTENTION_RAISE: '.length, -2)
    const reason = raw
      .replace(/[\x00-\x1f\x7f]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 256)
    if (reason) directive = { action: 'raise', reason }
  }
  if (!directive) return { visibleText: text, directive: null }
  lines.pop()
  return { visibleText: lines.join('\n').trimEnd(), directive }
}

export type AttentionRelayResult =
  | { ok: true; action: 'raise' | 'clear'; swarmName: string }
  | { ok: false; errorKind: 'unavailable' | 'invalid-binding' | 'unsafe-path' | 'io'; detail: string }

export type AttentionRelayOptions = {
  /** Trusted launcher binding; never sourced from model output. */
  channelId?: string
  swarmName?: string
  stateDir?: string
}

function safeExistingFlag(path: string): boolean {
  try {
    const stat = lstatSync(path)
    return stat.isFile() && !stat.isSymbolicLink()
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return true
    return false
  }
}

/**
 * Narrow host capability: atomically create/remove one bound attention flag.
 * No shell, PATH tool, TMUX lookup, SWARM_HOME read, or mutable helper script.
 */
export async function relaySwarmAttention(
  directive: AttentionDirective,
  options: AttentionRelayOptions,
): Promise<AttentionRelayResult> {
  const { channelId, swarmName, stateDir } = options
  if (!channelId || !swarmName || !stateDir) {
    return { ok: false, errorKind: 'unavailable', detail: 'attention relay binding unavailable' }
  }
  if (!/^\d{1,32}$/.test(channelId) || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(swarmName)) {
    return { ok: false, errorKind: 'invalid-binding', detail: 'invalid attention channel or swarm name' }
  }
  const normalizedStateDir = resolve(stateDir)
  if (!isAbsolute(stateDir) || normalizedStateDir !== stateDir) {
    return { ok: false, errorKind: 'unsafe-path', detail: 'attention state dir must be normalized and absolute' }
  }

  let tmp = ''
  try {
    mkdirSync(stateDir, { recursive: true, mode: 0o700 })
    const dirStat = lstatSync(stateDir)
    if (
      !dirStat.isDirectory()
      || dirStat.isSymbolicLink()
      || realpathSync(stateDir) !== normalizedStateDir
    ) {
      return { ok: false, errorKind: 'unsafe-path', detail: 'attention state dir traverses a symlink' }
    }
    chmodSync(stateDir, 0o700)
    const flag = join(stateDir, `attention-${channelId}.flag`)
    if (!safeExistingFlag(flag)) {
      return { ok: false, errorKind: 'unsafe-path', detail: 'attention flag is not a regular file' }
    }

    if (directive.action === 'clear') {
      rmSync(flag, { force: true })
      return { ok: true, action: 'clear', swarmName }
    }

    const reason = directive.reason
      .replace(/[\x00-\x1f\x7f]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 256)
    if (!reason) {
      return { ok: false, errorKind: 'invalid-binding', detail: 'attention reason is empty' }
    }
    tmp = join(stateDir, `.attention-${channelId}.${process.pid}.${randomUUID()}.tmp`)
    writeFileSync(tmp, reason + '\n', { flag: 'wx', mode: 0o600 })
    chmodSync(tmp, 0o600)
    renameSync(tmp, flag)
    tmp = ''
    chmodSync(flag, 0o600)
    return { ok: true, action: 'raise', swarmName }
  } catch (err) {
    return {
      ok: false,
      errorKind: 'io',
      detail: String((err as Error).message ?? err).slice(0, 500),
    }
  } finally {
    if (tmp && existsSync(tmp)) {
      try { rmSync(tmp, { force: true }) } catch {}
    }
  }
}
