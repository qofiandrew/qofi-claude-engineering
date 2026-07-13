#!/usr/bin/env bun
/**
 * Access admin CLI — the Codex-side equivalent of the /discord:access skill.
 * Codex has no user-invocable skills at the session level, so access mutations
 * are a host-side command. Same file protocol as the plugin: edits access.json;
 * pairing approval drops approved/<senderId> (contents = DM channel id) which
 * the daemon polls to send the confirmation.
 *
 * Usage:  bun cli.ts [status]
 *         bun cli.ts pair <code> | deny <code>
 *         bun cli.ts allow <senderId> | remove <senderId>
 *         bun cli.ts policy <pairing|allowlist|disabled>
 *         bun cli.ts group add <channelId> [--require-mention] [--allow id1,id2]
 *         bun cli.ts group rm <channelId>
 *         bun cli.ts set <key> <value>
 *
 * Honors DISCORD_STATE_DIR (default ~/.codex/channels/discord).
 */

import { chmodSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { AccessStore, SAFE_STATE_ID, type Access } from './gate.ts'

const STATE_DIR = process.env.DISCORD_STATE_DIR ?? join(homedir(), '.codex', 'channels', 'discord')

function rotationStatus(stateDir: string): string[] {
  const path = join(stateDir, 'rotation-state.json')
  try {
    const stat = lstatSync(path)
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== uid
      || (stat.mode & 0o777) !== 0o600 || stat.size > 1024 * 1024) {
      throw new Error('unsafe file')
    }
    const value: unknown = JSON.parse(readFileSync(path, 'utf8'))
    if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('shape')
    const record = value as Record<string, unknown>
    if (record.schema !== 'qofi-codex-profile-rotation/v1'
      || typeof record.pool !== 'string'
      || (record.active_profile !== null && typeof record.active_profile !== 'string')
      || !Array.isArray(record.profiles)) throw new Error('schema')
    const lines = [
      `codex auth pool: ${record.pool}`,
      `active profile: ${record.active_profile ?? '(parked)'}`,
      `parked until: ${typeof record.parked_until_ms === 'number' && record.parked_until_ms > Date.now()
        ? new Date(record.parked_until_ms).toISOString() : '(not parked)'}`,
      'profile headroom / leases / cooldowns:',
    ]
    for (const raw of record.profiles.slice(0, 32)) {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('profile')
      const profile = raw as Record<string, unknown>
      if (typeof profile.label !== 'string' || !Array.isArray(profile.leased_by)) throw new Error('profile')
      const fresh = profile.telemetry_status === 'fresh'
        && typeof profile.observed_at_ms === 'number'
        && profile.observed_at_ms <= Date.now()
        && Date.now() - profile.observed_at_ms <= 30 * 60_000
      const headroom = fresh && typeof profile.headroom_percent === 'number'
        ? `${profile.headroom_percent.toFixed(1)}%`
        : 'unknown'
      const leases = profile.leased_by.filter(item => typeof item === 'string').join(',') || 'none'
      const cooldown = typeof profile.cooldown_until_ms === 'number' && profile.cooldown_until_ms > Date.now()
        ? new Date(profile.cooldown_until_ms).toISOString()
        : 'ready'
      lines.push(`  ${profile.label}: headroom=${headroom} leased_by=${leases} cooldown=${cooldown}`)
    }
    return lines
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return ['codex auth pool: (rotation state not initialized)']
    return ['codex auth pool: (rotation state unavailable)']
  }
}

export function runCli(argv: string[], stateDir = STATE_DIR): string {
  const store = new AccessStore(stateDir)
  const a = store.load()
  const [cmd, ...rest] = argv

  switch (cmd) {
    case undefined:
    case 'status': {
      const pending = Object.entries(a.pending)
        .map(([code, p]) => {
          const age = Math.round((Date.now() - p.createdAt) / 60000)
          return `  ${code}  sender ${p.senderId}  (${age}m ago)`
        })
        .join('\n')
      return [
        `state dir: ${stateDir}`,
        `dmPolicy: ${a.dmPolicy}`,
        `allowFrom (${a.allowFrom.length}): ${a.allowFrom.join(', ') || '(none)'}`,
        `groups (${Object.keys(a.groups).length}): ${Object.keys(a.groups).join(', ') || '(none)'}`,
        `pending (${Object.keys(a.pending).length}):${pending ? '\n' + pending : ' (none)'}`,
        ...rotationStatus(stateDir),
      ].join('\n')
    }
    case 'pair': {
      const code = rest[0]
      if (!code) return 'usage: pair <code>'
      const p = a.pending[code]
      if (!p) return `no pending pairing with code ${code}`
      if (p.expiresAt < Date.now()) {
        delete a.pending[code]
        store.save(a)
        return `code ${code} expired — ask the sender to DM again`
      }
      if (!SAFE_STATE_ID.test(p.senderId) || !SAFE_STATE_ID.test(p.chatId)) {
        return 'pending pairing contains an invalid sender/channel id'
      }
      if (!a.allowFrom.includes(p.senderId)) a.allowFrom.push(p.senderId)
      delete a.pending[code]
      store.save(a)
      mkdirSync(store.approvedDir, { recursive: true, mode: 0o700 })
      chmodSync(store.approvedDir, 0o700)
      writeFileSync(join(store.approvedDir, p.senderId), p.chatId, {
        flag: 'wx',
        mode: 0o600,
      })
      return `approved sender ${p.senderId} — the daemon will confirm on Discord`
    }
    case 'deny': {
      const code = rest[0]
      if (!code) return 'usage: deny <code>'
      if (!a.pending[code]) return `no pending pairing with code ${code}`
      delete a.pending[code]
      store.save(a)
      return `denied ${code}`
    }
    case 'allow': {
      const id = rest[0]
      if (!id) return 'usage: allow <senderId>'
      if (!a.allowFrom.includes(id)) a.allowFrom.push(id)
      store.save(a)
      return `allowFrom: ${a.allowFrom.join(', ')}`
    }
    case 'remove': {
      const id = rest[0]
      if (!id) return 'usage: remove <senderId>'
      a.allowFrom = a.allowFrom.filter(x => x !== id)
      store.save(a)
      return `allowFrom: ${a.allowFrom.join(', ') || '(none)'}`
    }
    case 'policy': {
      const mode = rest[0]
      if (mode !== 'pairing' && mode !== 'allowlist' && mode !== 'disabled') {
        return 'usage: policy <pairing|allowlist|disabled>'
      }
      a.dmPolicy = mode
      store.save(a)
      return `dmPolicy: ${mode}`
    }
    case 'group': {
      const [sub, channelId] = rest
      if (sub === 'add' && channelId) {
        const requireMention = rest.includes('--require-mention')
        const allowIdx = rest.indexOf('--allow')
        const allowFrom =
          allowIdx >= 0 && rest[allowIdx + 1] ? rest[allowIdx + 1].split(',').filter(Boolean) : []
        a.groups[channelId] = { requireMention, allowFrom }
        store.save(a)
        return `group ${channelId}: requireMention=${requireMention}, allowFrom=[${allowFrom.join(', ')}]`
      }
      if (sub === 'rm' && channelId) {
        delete a.groups[channelId]
        store.save(a)
        return `removed group ${channelId}`
      }
      return 'usage: group add <channelId> [--require-mention] [--allow id1,id2] | group rm <channelId>'
    }
    case 'set': {
      const [key, ...valueParts] = rest
      const value = valueParts.join(' ')
      switch (key) {
        case 'ackReaction':
          a.ackReaction = value
          break
        case 'replyToMode':
          if (value !== 'off' && value !== 'first' && value !== 'all') return 'replyToMode: off|first|all'
          a.replyToMode = value
          break
        case 'textChunkLimit': {
          const n = Number(value)
          if (!Number.isSafeInteger(n) || n < 1 || n > 2000) {
            return 'textChunkLimit: integer 1..2000'
          }
          a.textChunkLimit = n
          break
        }
        case 'chunkMode':
          if (value !== 'length' && value !== 'newline') return 'chunkMode: length|newline'
          a.chunkMode = value
          break
        case 'mentionPatterns': {
          try {
            const arr = JSON.parse(value)
            if (!Array.isArray(arr) || !arr.every(x => typeof x === 'string')) throw new Error()
            a.mentionPatterns = arr
          } catch {
            return 'mentionPatterns: JSON array of regex strings'
          }
          break
        }
        default:
          return 'set keys: ackReaction, replyToMode, textChunkLimit, chunkMode, mentionPatterns'
      }
      store.save(a)
      return `${key} set`
    }
    default:
      return `unknown command: ${cmd}\ncommands: status, pair, deny, allow, remove, policy, group, set`
  }
}

if (import.meta.main) {
  console.log(runCli(process.argv.slice(2)))
}
