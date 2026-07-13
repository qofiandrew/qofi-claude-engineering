import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'os'
import { join } from 'path'
import { extractAttentionDirective, relaySwarmAttention } from './attention.ts'

describe('swarm attention relay', () => {
  test('extracts and removes only exact final-line directives with bounded reasons', () => {
    expect(extractAttentionDirective(
      'ESCALATE: blocked on operator\n[[SWARM_ATTENTION_RAISE: Need approval]]\n',
    )).toEqual({
      visibleText: 'ESCALATE: blocked on operator',
      directive: { action: 'raise', reason: 'Need approval' },
    })
    expect(extractAttentionDirective('Resolved\n[[SWARM_ATTENTION_CLEAR]]')).toEqual({
      visibleText: 'Resolved', directive: { action: 'clear' },
    })
    expect(extractAttentionDirective('quoted [[SWARM_ATTENTION_CLEAR]] text').directive).toBeNull()
    expect(extractAttentionDirective('[[SWARM_ATTENTION_RAISE: ]]').directive).toBeNull()
    const long = extractAttentionDirective(`Blocked\n[[SWARM_ATTENTION_RAISE: ${'x'.repeat(300)}]]`)
    expect(long.directive?.action === 'raise' && long.directive.reason.length).toBe(256)
  })

  test('atomically raises and clears only the bound private flag', async () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-attention-'))
    const stateDir = join(realpathSync(root), 'state')
    const binding = { channelId: '123456789', swarmName: 'payments', stateDir }
    try {
      expect(await relaySwarmAttention({ action: 'raise', reason: ' needs\noperator ' }, binding))
        .toEqual({ ok: true, action: 'raise', swarmName: 'payments' })
      const flag = join(stateDir, 'attention-123456789.flag')
      expect(readFileSync(flag, 'utf8')).toBe('needs operator\n')
      expect(lstatSync(stateDir).mode & 0o777).toBe(0o700)
      expect(lstatSync(flag).mode & 0o777).toBe(0o600)
      expect(await relaySwarmAttention({ action: 'clear' }, binding))
        .toEqual({ ok: true, action: 'clear', swarmName: 'payments' })
      expect(existsSync(flag)).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('rejects untrusted bindings and symlinked state/flag paths', async () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-attention-symlink-'))
    const canonicalRoot = realpathSync(root)
    const real = join(canonicalRoot, 'real')
    const linked = join(canonicalRoot, 'linked')
    const victim = join(canonicalRoot, 'victim')
    try {
      expect(await relaySwarmAttention({ action: 'clear' }, {
        channelId: '../bad', swarmName: 'safe', stateDir: real,
      })).toMatchObject({ ok: false, errorKind: 'invalid-binding' })
      writeFileSync(victim, 'unchanged')
      mkdirSync(real, { mode: 0o700 })
      symlinkSync(real, linked)
      expect(await relaySwarmAttention({ action: 'raise', reason: 'x' }, {
        channelId: '123', swarmName: 'safe', stateDir: linked,
      })).toMatchObject({ ok: false, errorKind: 'unsafe-path' })

      rmSync(linked, { force: true })
      // Create a safe state dir first, then replace only the bound flag with a symlink.
      expect(await relaySwarmAttention({ action: 'clear' }, {
        channelId: '123', swarmName: 'safe', stateDir: real,
      })).toMatchObject({ ok: true })
      symlinkSync(victim, join(real, 'attention-123.flag'))
      expect(await relaySwarmAttention({ action: 'raise', reason: 'x' }, {
        channelId: '123', swarmName: 'safe', stateDir: real,
      })).toMatchObject({ ok: false, errorKind: 'unsafe-path' })
      expect(readFileSync(victim, 'utf8')).toBe('unchanged')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
