import { spawnSync } from 'child_process'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join, resolve } from 'path'
import { describe, expect, test } from 'bun:test'
import {
  MIN_PROJECT_DOC_MAX_BYTES,
  validateProjectConfigToml,
} from './project-config.ts'
import { inspectProjectConfig } from './preflight.ts'

const trustedCwd = resolve(import.meta.dir)
const checker = resolve(import.meta.dir, '../bin/codex-project-config-check.ts')
const bunSafetyArgs = [
  '--no-env-file', '--config=/dev/null', '--no-install', '--no-addons',
  '--no-macros', `--cwd=${trustedCwd}`,
]

describe('shared project config validation', () => {
  test('CLI checker and daemon validator accept and reject the same cases', () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-project-config-')))
    const cases: Array<[string, string, boolean]> = [
      ['empty', '', true],
      ['floor', `project_doc_max_bytes = ${MIN_PROJECT_DOC_MAX_BYTES}\n`, true],
      ['doctrine disabled', 'project_doc_max_bytes = 0\n', false],
      ['doctrine truncated', `project_doc_max_bytes = ${MIN_PROJECT_DOC_MAX_BYTES - 1}\n`, false],
      ['hooks false', '[features]\nhooks = false\ncodex_hooks = false\n', true],
      ['hooks enabled', '[features]\nhooks = true\n', false],
      ['codex hooks enabled', '[features]\ncodex_hooks = true\n', false],
      ['ultra effort', 'model_reasoning_effort = "ultra"\n', true],
      ['max effort', 'model_reasoning_effort = "max"\n', true],
      ['unknown effort', 'model_reasoning_effort = "extreme"\n', false],
      ['unknown key', 'model_provider = "ambient"\n', false],
    ]
    try {
      for (const [name, content, accepted] of cases) {
        let libraryAccepted = true
        try { validateProjectConfigToml(content) } catch { libraryAccepted = false }
        const caseRoot = join(root, name.replaceAll(' ', '-'))
        mkdirSync(join(caseRoot, '.codex'), { recursive: true, mode: 0o700 })
        const config = join(caseRoot, '.codex', 'config.toml')
        writeFileSync(config, content, { mode: 0o600 })
        const cli = spawnSync(process.execPath, [...bunSafetyArgs, checker, config], {
          cwd: root,
          encoding: 'utf8',
          env: { HOME: root, PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
        })
        expect(libraryAccepted, name).toBe(accepted)
        expect(cli.status === 0, `${name}: ${cli.stderr}`).toBe(accepted)
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('trusted Bun flags suppress invocation-cwd bunfig preload and .env', () => {
    const root = mkdtempSync(join(tmpdir(), 'qofi-hostile-bun-'))
    const marker = join(root, 'preload-ran')
    try {
      writeFileSync(join(root, '.env'), 'QOFI_HOSTILE_ENV=loaded\n')
      writeFileSync(join(root, 'bunfig.toml'), 'preload = ["./preload.ts"]\n')
      writeFileSync(join(root, 'preload.ts'),
        `await Bun.write(${JSON.stringify(marker)}, 'unsafe')\n`)
      const probe = spawnSync(process.execPath, [
        ...bunSafetyArgs,
        '-e', 'process.stdout.write(process.env.QOFI_HOSTILE_ENV ?? "")',
      ], {
        cwd: root,
        encoding: 'utf8',
        env: { HOME: root, PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
      })
      expect(probe.status, probe.stderr).toBe(0)
      expect(probe.stdout).toBe('')
      expect(existsSync(marker)).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('shared reader refuses symlinks, FIFOs, oversize/mutable files, and open races', () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-config-reader-')))
    const codexDir = join(root, '.codex')
    const config = join(codexDir, 'config.toml')
    const outside = join(root, 'outside.toml')
    mkdirSync(codexDir, { mode: 0o700 })
    writeFileSync(outside, 'allow_login_shell = false\n', { mode: 0o600 })
    try {
      symlinkSync(outside, config)
      expect(() => inspectProjectConfig(root)).toThrow('canonical owner-controlled')
      rmSync(config)

      expect(spawnSync('/usr/bin/mkfifo', [config]).status).toBe(0)
      chmodSync(config, 0o600)
      const fifo = spawnSync(process.execPath, [...bunSafetyArgs, checker, config], {
        cwd: root,
        encoding: 'utf8',
        timeout: 1000,
        env: { HOME: root, PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
      })
      expect(fifo.signal).toBeNull()
      expect(fifo.status).not.toBe(0)
      rmSync(config)

      writeFileSync(config, 'x'.repeat(64 * 1024 + 1), { mode: 0o600 })
      expect(() => inspectProjectConfig(root)).toThrow('<=64KiB')
      rmSync(config)

      writeFileSync(config, 'allow_login_shell = false\n', { mode: 0o660 })
      chmodSync(config, 0o660)
      expect(() => inspectProjectConfig(root)).toThrow('owner-controlled')
      rmSync(config)

      writeFileSync(config, 'allow_login_shell = false\n', { mode: 0o600 })
      const replacement = join(codexDir, 'replacement.toml')
      writeFileSync(replacement, 'allow_login_shell = false\n', { mode: 0o600 })
      expect(() => inspectProjectConfig(root, () => renameSync(replacement, config)))
        .toThrow('changed while opening')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
