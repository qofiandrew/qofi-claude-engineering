import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs'
import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  discoverSensitiveWorkspacePaths,
  discoverWorkspacePolicy,
  isOperatorOwnedRelativePath,
  isSensitiveRelativePath,
  WorkspaceScanError,
} from './workspace.ts'

describe('workspace secret discovery', () => {
  test('discovers high-risk files but permits explicit examples', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-workspace-scan-'))
    try {
      mkdirSync(join(dir, 'config'), { recursive: true })
      writeFileSync(join(dir, '.env'), 'secret')
      writeFileSync(join(dir, '.env.example'), 'NAME=')
      writeFileSync(
        join(dir, '.env.sample'),
        ['GH_TOKEN=gh', 'p_', 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJ'].join(''),
      )
      writeFileSync(join(dir, '.env.template'), Buffer.alloc(64 * 1024 + 1))
      writeFileSync(join(dir, 'config', 'prod-credentials.json'), '{}')
      writeFileSync(join(dir, 'settings.local.json'), '{}')
      const denied = discoverSensitiveWorkspacePaths(dir)
      expect(denied).toContain(join(dir, '.env'))
      expect(denied).toContain(join(dir, 'config', 'prod-credentials.json'))
      expect(denied).toContain(join(dir, 'settings.local.json'))
      expect(denied).not.toContain(join(dir, '.env.example'))
      expect(denied).toContain(join(dir, '.env.sample'))
      expect(denied).toContain(join(dir, '.env.template'))
      expect(discoverWorkspacePolicy(dir).readableExamples).toContain(join(dir, '.env.example'))
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('scan limits fail closed', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-workspace-limit-'))
    try {
      writeFileSync(join(dir, 'a'), 'a')
      writeFileSync(join(dir, 'b'), 'b')
      expect(() => discoverSensitiveWorkspacePaths(dir, { maxEntries: 1 }))
        .toThrow(WorkspaceScanError)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('treats Claude worktrees as an opaque denied subtree', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-claude-worktrees-'))
    try {
      const checkout = join(dir, '.claude', 'worktrees', 'teammate')
      mkdirSync(checkout, { recursive: true })
      writeFileSync(join(checkout, '.git'), 'gitdir: /operator/owned/worktree\n')
      for (let i = 0; i < 20; i++) writeFileSync(join(checkout, `private-${i}`), 'claude\n')

      const policy = discoverWorkspacePolicy(dir, { maxEntries: 5 })
      expect(policy.deniedPaths).toContain(join(dir, '.claude', 'worktrees'))
      expect(policy.deniedPaths).toContain(`${join(dir, '.claude', 'worktrees')}/**`)
      expect(isSensitiveRelativePath('.claude/worktrees/teammate/secret.txt')).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('git broker path policy rejects operator and secret state', () => {
    expect(isSensitiveRelativePath('.env.example')).toBe(false)
    expect(isSensitiveRelativePath('nested/tokens.env')).toBe(true)
    expect(isOperatorOwnedRelativePath('.codex/config.toml')).toBe(true)
    expect(isOperatorOwnedRelativePath('.claude/hooks/stop.sh')).toBe(true)
    expect(isOperatorOwnedRelativePath('.claude/worktrees/teammate/src.ts')).toBe(true)
    expect(isOperatorOwnedRelativePath('.gitleaks.toml')).toBe(true)
    expect(isOperatorOwnedRelativePath('PROJECT_SPEC.md')).toBe(false)
    expect(isOperatorOwnedRelativePath('LEARNINGS.md')).toBe(false)
    expect(isOperatorOwnedRelativePath('src/app.ts')).toBe(false)
  })
})
