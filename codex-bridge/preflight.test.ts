import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'fs'
import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  DEDICATED_CODEX_PREFLIGHT_TIMEOUT_MS,
  isSupportedCodexVersion,
  parseCodexVersion,
  runCodexPreflight,
  checkWorkspaceSafety,
  recheckProjectConfig,
} from './preflight.ts'

describe('Codex daemon preflight', () => {
  test('dedicated CLI proof budget covers a cold macOS bootstrap but stays bounded', () => {
    expect(DEDICATED_CODEX_PREFLIGHT_TIMEOUT_MS).toBeGreaterThanOrEqual(20_000)
    expect(DEDICATED_CODEX_PREFLIGHT_TIMEOUT_MS).toBeLessThanOrEqual(60_000)
  })

  test('refuses to expose a workspace root containing the swarm token vault', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-workspace-vault-'))
    try {
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: true })
      writeFileSync(join(dir, 'tokens.env'), 'BOT_SECRET=value')
      expect(checkWorkspaceSafety(dir)).toMatchObject({
        ok: false, errorKind: 'workspace-vault',
      })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('refuses a workspace that contains or sits inside the host runtime source', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-runtime-overlap-'))
    const child = join(dir, 'runtime', 'workspace')
    mkdirSync(child, { recursive: true })
    try {
      expect(checkWorkspaceSafety(dir, [join(dir, 'runtime')]))
        .toMatchObject({ ok: false, errorKind: 'workspace-vault' })
      expect(checkWorkspaceSafety(child, [dir]))
        .toMatchObject({ ok: false, errorKind: 'workspace-vault' })
      expect(checkWorkspaceSafety(child, ['/definitely/missing/runtime-root']))
        .toMatchObject({ ok: false, errorKind: 'workspace-scan' })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('rejects linked-worktree .git pointer files at startup', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-linked-worktree-'))
    try {
      writeFileSync(join(dir, '.git'), 'gitdir: /tmp/host-controlled-gitdir\n')
      expect(checkWorkspaceSafety(dir)).toMatchObject({
        ok: false,
        errorKind: 'workspace-vault',
      })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('allows only the in-repo immutable hooksPath and rejects credential/include config', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-git-config-'))
    try {
      mkdirSync(join(dir, '.git', 'hooks'), { recursive: true })
      writeFileSync(join(dir, '.git', 'config'), `[core]\n\thooksPath = ${join(dir, '.git', 'hooks')}\n`)
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: true })
      writeFileSync(join(dir, '.git', 'config'), '[remote "origin"]\n url = https://user:token@example.com/repo.git\n')
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-vault' })
      writeFileSync(join(dir, '.git', 'config'), '[include]\n path = /tmp/host-gitconfig\n')
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-vault' })
      for (const hostile of [
        '[http]\n extraHeader = X-Debug: value\n',
        '[remote "origin"]\n url = https://token@example.com/repo.git\n',
        '[remote "origin"]\n url = https://example.com/repo.git?access_token=value\n',
        '[credential]\n helper = /tmp/host-helper\n',
        `[remote "origin"]\n url = https://example.com/${['gh', 'p_', 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJ'].join('')}\n`,
      ]) {
        writeFileSync(join(dir, '.git', 'config'), hostile)
        expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-vault' })
      }
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('project Codex config must be bounded regular and retain exact identity', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-project-config-'))
    try {
      mkdirSync(join(dir, '.codex'))
      const config = join(dir, '.codex', 'config.toml')
      writeFileSync(config, 'personality = "pragmatic"\nallow_login_shell = false\n')
      const first = checkWorkspaceSafety(dir)
      expect(first).toMatchObject({ ok: true })
      if (!first.ok) throw new Error('expected safe config')
      expect(recheckProjectConfig(first.cwd, first.projectConfig)).toBe(true)
      writeFileSync(config, 'personality = "friendly"\nallow_login_shell = false\n')
      expect(recheckProjectConfig(first.cwd, first.projectConfig)).toBe(false)

      writeFileSync(config, 'mcp_servers.host.command = "/tmp/escape"\n')
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-scan' })

      writeFileSync(config, 'sandbox_workspace_write.network_access = true\n')
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-scan' })

      writeFileSync(
        config,
        `token = "${['gh', 'p_', 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJ'].join('')}"\n`,
      )
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-scan' })

      rmSync(config)
      symlinkSync(join(dir, 'target.toml'), config)
      writeFileSync(join(dir, 'target.toml'), 'model = "linked"\n')
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-scan' })
      rmSync(config)

      const fifo = Bun.spawnSync(['mkfifo', config], { stdout: 'pipe', stderr: 'pipe' })
      expect(fifo.exitCode, fifo.stderr.toString()).toBe(0)
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-scan' })
      rmSync(config)
      writeFileSync(config, Buffer.alloc(64 * 1024 + 1))
      expect(checkWorkspaceSafety(dir)).toMatchObject({ ok: false, errorKind: 'workspace-scan' })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
  test('accepts only the audited 0.144.x CLI window', () => {
    expect(parseCodexVersion('codex-cli 0.144.1\n')).toBe('0.144.1')
    expect(isSupportedCodexVersion('0.144.1')).toBe(true)
    expect(isSupportedCodexVersion('0.144.9')).toBe(true)
    expect(isSupportedCodexVersion('0.144.0')).toBe(false)
    expect(isSupportedCodexVersion('0.145.0')).toBe(false)
    expect(isSupportedCodexVersion('1.0.0')).toBe(false)
  })

  test('stub binary proves ChatGPT auth and sanitized preflight environment', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-preflight-'))
    const bin = join(dir, 'codex-stub')
    writeFileSync(bin, `#!/usr/bin/env bun
if (Bun.argv[2] === '--version') {
  console.log('codex-cli 0.144.1')
} else if (Bun.argv[2] === 'login' && Bun.argv.at(-1) === 'status') {
  const exact = Bun.argv.includes('forced_login_method="chatgpt"')
    && Bun.argv.includes('cli_auth_credentials_store="file"')
  console.log(process.env.OPENAI_API_KEY || process.env.DISCORD_BOT_TOKEN || !exact ? 'unsafe env' : 'Logged in using ChatGPT')
} else process.exit(2)
`)
    chmodSync(bin, 0o700)
    try {
      expect(runCodexPreflight(bin, {
        PATH: process.env.PATH,
        OPENAI_API_KEY: 'must-not-pass',
        DISCORD_BOT_TOKEN: 'must-not-pass',
      })).toEqual({ ok: true, version: '0.144.1' })
      expect(runCodexPreflight(process.execPath, {
        PATH: process.env.PATH,
      }, 5000, [bin])).toEqual({ ok: true, version: '0.144.1' })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('rejects unsupported versions and non-ChatGPT auth', () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-preflight-reject-'))
    const bin = join(dir, 'codex-stub')
    writeFileSync(bin, `#!/usr/bin/env bun
if (Bun.argv[2] === '--version') console.log(process.env.TEST_VERSION || 'codex-cli 0.144.1')
else if (Bun.argv[2] === 'login') console.log('Logged in using an API key')
`)
    chmodSync(bin, 0o700)
    try {
      expect(runCodexPreflight(bin, {
        PATH: process.env.PATH,
        CODEX_BRIDGE_ENV_ALLOWLIST: 'TEST_VERSION',
        TEST_VERSION: 'codex-cli 0.145.0',
      })).toMatchObject({ ok: false, errorKind: 'unsupported-version' })
      expect(runCodexPreflight(bin, { PATH: process.env.PATH }))
        .toMatchObject({ ok: false, errorKind: 'auth-mode' })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
