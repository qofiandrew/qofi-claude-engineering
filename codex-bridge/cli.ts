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

import { mkdirSync, writeFileSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { AccessStore, type Access } from './gate.ts'

const STATE_DIR = process.env.DISCORD_STATE_DIR ?? join(homedir(), '.codex', 'channels', 'discord')

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
      if (!a.allowFrom.includes(p.senderId)) a.allowFrom.push(p.senderId)
      delete a.pending[code]
      store.save(a)
      mkdirSync(store.approvedDir, { recursive: true, mode: 0o700 })
      writeFileSync(join(store.approvedDir, p.senderId), p.chatId)
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
          if (!Number.isFinite(n) || n < 1) return 'textChunkLimit: positive number'
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
