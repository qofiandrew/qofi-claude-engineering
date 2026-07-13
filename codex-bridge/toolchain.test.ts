import { describe, expect, test } from 'bun:test'
import {
  createToolShims,
  DEDICATED_PNPM_VERSION,
  DEDICATED_RUNNER_TOOL_PATH,
  DEDICATED_TOOLCHAIN_ROOT,
  detectWorkspaceToolNames,
  resolveToolchainPlan,
  safeTurnEnvironment,
} from './toolchain.ts'
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('toolchain boundary', () => {
  test('pins the singleton dedicated pnpm toolchain version', () => {
    expect(DEDICATED_PNPM_VERSION).toBe('9.12.3')
  })

  test('dedicated runner PATH and readable root include root-provisioned npm support', () => {
    expect(DEDICATED_RUNNER_TOOL_PATH).toBe(
      `${DEDICATED_TOOLCHAIN_ROOT}/bin:${DEDICATED_TOOLCHAIN_ROOT}:/Library/Developer/CommandLineTools/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
    )
  })

  test('resolves required host tools outside the writable workspace', () => {
    const plan = resolveToolchainPlan(process.cwd())
    for (const required of ['bun', 'git', 'python3']) {
      expect(plan.executables[required]).toBeString()
    }
    for (const projectTool of detectWorkspaceToolNames(process.cwd())) {
      if (Bun.which(projectTool)) expect(plan.executables[projectTool]).toBeString()
    }
    expect(plan.readableRoots.length).toBeGreaterThan(0)
    expect(plan.path).toContain('/bin')
    expect(plan.readableRoots.some(root => root.startsWith(process.cwd()))).toBe(false)
  })

  test('adds only a canonical in-repo virtualenv bin to sandboxed turn PATH', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-project-venv-'))
    try {
      mkdirSync(join(root, '.venv', 'bin'), { recursive: true })
      writeFileSync(join(root, '.venv', 'bin', 'project-tool'), '#!/bin/sh\n')
      const plan = resolveToolchainPlan(root)
      expect(plan.path.split(':')[0]).toBe(join(realpathSync(root), '.venv', 'bin'))
      expect(plan.readableRoots.some(path => path.startsWith(root))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('turn environment pins private temp and disables user package/git config', () => {
    const plan = resolveToolchainPlan(process.cwd())
    expect(safeTurnEnvironment('/private/turn-tmp', plan, '/private/shims')).toMatchObject({
      TMPDIR: '/private/turn-tmp',
      PATH: `/private/shims:${plan.path}`,
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_CONFIG_SYSTEM: '/dev/null',
      NPM_CONFIG_USERCONFIG: '/dev/null',
      NPM_CONFIG_STORE_DIR: '/private/turn-tmp/pnpm-store',
      NPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS: 'false',
      NPM_CONFIG_PACKAGE_MANAGER_STRICT: 'true',
      NPM_CONFIG_PACKAGE_MANAGER_STRICT_VERSION: 'true',
      PNPM_HOME: '/private/turn-tmp/pnpm-home',
      COREPACK_ENABLE_PROJECT_SPEC: '0',
      COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
      COREPACK_ENABLE_NETWORK: '0',
      XDG_DATA_HOME: '/private/turn-tmp/xdg-data',
      XDG_STATE_HOME: '/private/turn-tmp/xdg-state',
      PIP_CONFIG_FILE: '/dev/null',
      GOCACHE: '/private/turn-tmp/go-build-cache',
      GOPATH: '/private/turn-tmp/go-path',
      GOMODCACHE: '/private/turn-tmp/go-path/pkg/mod',
      CARGO_HOME: '/private/turn-tmp/cargo-home',
      CARGO_TARGET_DIR: '/private/turn-tmp/cargo-target',
      CLANG_MODULE_CACHE_PATH: '/private/turn-tmp/clang-module-cache',
      SWIFT_MODULE_CACHE_PATH: '/private/turn-tmp/swift-module-cache',
      DERIVED_DATA_DIR: '/private/turn-tmp/xcode/derived-data',
    })
  })

  test('rejects writable executable files and writable parent chains for every resolved tool', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-tool-workspace-'))
    const hostRoot = mkdtempSync(join(process.cwd(), '.codex-tool-trust-'))
    const bin = join(hostRoot, 'bin')
    const tool = join(bin, 'qofi-fake-tool')
    mkdirSync(bin, { mode: 0o700 })
    writeFileSync(tool, '#!/bin/sh\nexit 0\n', { mode: 0o777 })
    chmodSync(tool, 0o777)
    try {
      expect(() => resolveToolchainPlan(workspace, { PATH: bin }, ['qofi-fake-tool']))
        .toThrow('unsafe tool executable')
      chmodSync(tool, 0o700)
      chmodSync(bin, 0o777)
      expect(() => resolveToolchainPlan(workspace, { PATH: bin }, ['qofi-fake-tool']))
        .toThrow('untrusted parent directory')
      chmodSync(bin, 0o700)
      expect(() => resolveToolchainPlan(
        workspace, { PATH: bin }, ['qofi-fake-tool'], undefined, true,
      )).toThrow('no trusted executable')
    } finally {
      rmSync(workspace, { recursive: true, force: true })
      rmSync(hostRoot, { recursive: true, force: true })
    }
  })

  test('rustup proxy installs expose the validated sysroot and pin RUSTUP_HOME', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-rust-workspace-'))
    const hostRoot = mkdtempSync(join(process.cwd(), '.codex-rustup-trust-'))
    const home = join(hostRoot, 'home')
    const bin = join(home, '.cargo', 'bin')
    const rustup = join(bin, 'rustup')
    const rustupHome = join(home, '.rustup')
    mkdirSync(bin, { recursive: true, mode: 0o700 })
    mkdirSync(join(rustupHome, 'toolchains', 'stable'), { recursive: true, mode: 0o700 })
    writeFileSync(rustup, '#!/bin/sh\nexit 0\n', { mode: 0o700 })
    chmodSync(rustup, 0o700)
    symlinkSync('rustup', join(bin, 'cargo'))
    symlinkSync('rustup', join(bin, 'rustc'))
    try {
      const plan = resolveToolchainPlan(
        workspace,
        { PATH: bin },
        ['cargo', 'rustc'],
        home,
      )
      expect(plan.executables.cargo).toBe(realpathSync(rustup))
      expect(plan.runtimeEnv.RUSTUP_HOME).toBe(realpathSync(rustupHome))
      expect(plan.readableRoots).toContain(realpathSync(rustupHome))
      expect(safeTurnEnvironment('/private/turn', plan).RUSTUP_HOME)
        .toBe(realpathSync(rustupHome))
    } finally {
      rmSync(workspace, { recursive: true, force: true })
      rmSync(hostRoot, { recursive: true, force: true })
    }
  })

  test('mktemp shim routes implicit temp files and directories to private TMPDIR', () => {
    const root = mkdtempSync(join(tmpdir(), 'codex-tool-shims-'))
    try {
      const plan = resolveToolchainPlan(process.cwd())
      const shimDir = createToolShims(join(root, 'shims'), plan)
      const privateTmp = join(root, 'tmp')
      mkdirSync(privateTmp, { mode: 0o700 })
      const env = safeTurnEnvironment(privateTmp, plan, shimDir)
      const run = Bun.spawnSync([join(shimDir, 'mktemp'), '-d'], {
        env, stdout: 'pipe', stderr: 'pipe',
      })
      expect(run.exitCode, run.stderr.toString()).toBe(0)
      expect(run.stdout.toString().trim().startsWith(privateTmp + '/')).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
