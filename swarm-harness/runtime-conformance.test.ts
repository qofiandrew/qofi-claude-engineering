import {
  chmodSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { describe, expect, test } from 'bun:test'
import {
  RUNTIME_CONFORMANCE_SUITE_FILES,
  RuntimeConformanceStore,
  runRuntimeDiagnostic,
  evaluateRuntimeConformance,
  prepareRuntimeConformanceState,
  probeRuntime,
  probeRuntimeProductionSurface,
  type ConformanceRuntime,
  type RuntimeInvocation,
} from './runtime-conformance'

const sourceRoot = resolve(import.meta.dir, '..')

function fixture(): {
  root: string
  repo: string
  state: string
  cleanup: () => void
} {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'runtime-conformance-')))
  const repo = join(root, 'repo')
  const state = join(root, 'private', 'runtime-conformance')
  mkdirSync(repo, { mode: 0o700 })
  for (const relativePath of RUNTIME_CONFORMANCE_SUITE_FILES) {
    const target = join(repo, relativePath)
    mkdirSync(dirname(target), { recursive: true, mode: 0o700 })
    writeFileSync(target, readFileSync(join(sourceRoot, relativePath)), { mode: 0o600 })
  }
  prepareRuntimeConformanceState(state, repo)
  return { root, repo, state, cleanup: () => rmSync(root, { recursive: true, force: true }) }
}

function runtimeStub(root: string, runtime: ConformanceRuntime, version: string, compatible = true): {
  invocation: RuntimeInvocation
  setVersion: (next: string) => void
  argvLog: string
} {
  const control = join(root, `${runtime}-version`)
  const binary = join(root, `${runtime}-cli`)
  const argvFile = join(root, `${runtime}-entry`)
  const argvLog = join(root, `${runtime}-argv.log`)
  writeFileSync(control, `${version}\n`, { mode: 0o600 })
  writeFileSync(argvLog, '', { mode: 0o600 })
  if (runtime === 'codex') writeFileSync(argvFile, 'fixed Codex argv-prefix fixture\n', { mode: 0o600 })
  writeFileSync(binary, runtime === 'claude'
    ? `#!/bin/sh
printf '%s\\n' "$*" >> '${argvLog}'
case "\${1:-}" in
  --version) printf '%s (Claude Code)\\n' "$(/bin/cat '${control}')" ;;
  --help) /bin/cat <<'EOF'
Usage: claude [options]
  -p, --print                           Print response
  --output-format <format>              Output format
  --model <model>                       Model
  --tools <tools...>                    Tools
  --strict-mcp-config                   Strict MCP
  --setting-sources <sources>           Settings sources
  --settings <file-or-json>             Settings
  ${compatible ? '--safe-mode                           Safe mode' : '--removed-safe-mode                    incompatible fixture'}
EOF
    ;;
  *) exit 64 ;;
esac
`
    : `#!/bin/sh
printf '%s\\n' "$*" >> '${argvLog}'
[ "\${1:-}" = '${argvFile}' ] || exit 64
shift
case "\${1:-}" in
  --version) printf 'codex-cli %s\\n' "$(/bin/cat '${control}')" ;;
  --help) /bin/cat <<'EOF'
Codex CLI
  exec            Run Codex non-interactively
  app-server      Run the app server
      --remote <ADDR>  Remote endpoint
      --strict-config  Strict config
      ${compatible ? '--no-alt-screen  Inline TUI' : '--removed-alt-screen  incompatible fixture'}
EOF
    ;;
  exec)
    [ "\${2:-}" = --help ] || exit 64
    /bin/cat <<'EOF'
Usage: codex exec [OPTIONS]
      --strict-config  Strict config
      --json           JSONL output
EOF
    ;;
  app-server)
    [ "\${2:-}" = --help ] || exit 64
    /bin/cat <<'EOF'
Usage: codex app-server [OPTIONS]
      --listen <URL>   Listen endpoint
      --strict-config  Strict config
EOF
    ;;
  *) exit 64 ;;
esac
`, { mode: 0o700 })
  chmodSync(binary, 0o700)
  return {
    invocation: { runtime, binary, argvFiles: runtime === 'codex' ? [argvFile] : [] },
    setVersion: next => writeFileSync(control, `${next}\n`, { mode: 0o600 }),
    argvLog,
  }
}

describe('runtime upgrade parity conformance diagnostics', () => {
  test('suite digest inventories every current policy, adapter, broker, and production wrapper', () => {
    expect(new Set(RUNTIME_CONFORMANCE_SUITE_FILES).size).toBe(RUNTIME_CONFORMANCE_SUITE_FILES.length)
    for (const path of [
      'bin/qofi-harness-lifecycle-broker',
      'bin/qofi-codex-runner',
      'bin/swarm-codex-runtime.py',
      'bin/swarm-harness-authority-boundary.ts',
      'bin/swarm-grounding-gate.ts',
      'bin/swarm-stop-hook.ts',
      'codex-bridge/app-server-manager.ts',
      'codex-bridge/daemon.ts',
      'codex-bridge/fable-completion-review-runner.ts',
      'cto-watcher/checkin-coordinator.js',
      'cto-watcher/roadmap-coordinator.js',
      'swarm-harness/authority-state.ts',
      'swarm-harness/completion-review-policy.ts',
      'swarm-harness/grounding-runtime-wrapper.ts',
      'swarm-harness/runtime-adapters.ts',
      'swarm-harness/task-boundary.ts',
    ]) expect(RUNTIME_CONFORMANCE_SUITE_FILES).toContain(path)
  })

  for (const runtime of ['claude', 'codex'] as const) {
    test(`accepts only the exact diagnosed ${runtime} identity and version`, () => {
      const f = fixture()
      try {
        const stub = runtimeStub(f.root, runtime, runtime === 'claude' ? '2.1.207' : '0.144.1')
        const store = new RuntimeConformanceStore(f.state, f.repo)
        const certified = runRuntimeDiagnostic({
          invocation: stub.invocation,
          repoRoot: f.repo,
          store,
          runSuite: () => ({ ok: true }),
          now: () => new Date('2026-07-13T00:00:00.000Z'),
        })
        expect(certified.ok).toBe(true)
        expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
          ok: true,
          record: { runtime, outcome: 'passed' },
        })
      } finally { f.cleanup() }
    })
  }

  test('a changed CLI version is quarantined until that exact version passes', () => {
    const f = fixture()
    try {
      const stub = runtimeStub(f.root, 'claude', '2.1.207')
      const store = new RuntimeConformanceStore(f.state, f.repo)
      expect(runRuntimeDiagnostic({
        invocation: stub.invocation, repoRoot: f.repo, store, runSuite: () => ({ ok: true }),
      }).ok).toBe(true)
      stub.setVersion('2.1.208')
      expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
        ok: false, reason: 'runtime-changed',
      })
      expect(runRuntimeDiagnostic({
        invocation: stub.invocation, repoRoot: f.repo, store, runSuite: () => ({ ok: true }),
      }).ok).toBe(true)
      expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
        ok: true, record: { version: '2.1.208' },
      })
    } finally { f.cleanup() }
  })

  test('a stale suite digest and a failed result both remain quarantined', () => {
    const f = fixture()
    try {
      const stub = runtimeStub(f.root, 'codex', '0.144.1')
      const store = new RuntimeConformanceStore(f.state, f.repo)
      expect(runRuntimeDiagnostic({
        invocation: stub.invocation, repoRoot: f.repo, store, runSuite: () => ({ ok: true }),
      }).ok).toBe(true)
      const changed = join(f.repo, 'swarm-harness', 'parity-conformance.test.ts')
      writeFileSync(changed, `${readFileSync(changed, 'utf8')}\n// changed policy fixture\n`, { mode: 0o600 })
      expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
        ok: false, reason: 'suite-changed',
      })
      const failed = runRuntimeDiagnostic({
        invocation: stub.invocation,
        repoRoot: f.repo,
        store,
        runSuite: () => ({ ok: false, diagnostic: 'fixture failure' }),
      })
      expect(failed).toMatchObject({ ok: false, record: { outcome: 'failed', diagnostic: 'fixture failure' } })
      expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
        ok: false, reason: 'not-passed',
      })
    } finally { f.cleanup() }
  })

  test('missing, loose, and repository-local diagnostic state is never accepted', () => {
    const f = fixture()
    try {
      const stub = runtimeStub(f.root, 'claude', '2.1.207')
      const store = new RuntimeConformanceStore(f.state, f.repo)
      expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
        ok: false, reason: 'missing',
      })
      expect(() => prepareRuntimeConformanceState(join(f.repo, 'authority'), f.repo))
        .toThrow('outside the repository')
      runRuntimeDiagnostic({
        invocation: stub.invocation, repoRoot: f.repo, store, runSuite: () => ({ ok: true }),
      })
      chmodSync(join(f.state, 'claude.json'), 0o644)
      expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
        ok: false, reason: 'unsafe-record',
      })
    } finally { f.cleanup() }
  })

  test('CLI preserves the Codex argv-prefix as one exact file argument', () => {
    const f = fixture()
    try {
      const stub = runtimeStub(f.root, 'codex', '0.144.1')
      const cli = join(sourceRoot, 'bin', 'swarm-runtime-conformance.ts')
      const result = Bun.spawnSync([
        process.execPath,
        cli,
        'check',
        '--runtime', 'codex',
        '--binary', stub.invocation.binary,
        '--argv-file', stub.invocation.argvFiles![0],
        '--repo-root', f.repo,
        '--state-dir', f.state,
        '--bun', process.execPath,
      ], { stdout: 'pipe', stderr: 'pipe' })
      expect(result.exitCode).toBe(2)
      expect(result.stderr.toString()).toContain('quarantined codex: missing')
      expect(result.stderr.toString()).not.toContain('TypeError')
    } finally { f.cleanup() }
  })

  test('hard-linked runtime executables and argv-prefix files are refused', () => {
    const f = fixture()
    try {
      const claude = runtimeStub(f.root, 'claude', '2.1.207')
      linkSync(claude.invocation.binary, join(f.root, 'claude-hardlink'))
      expect(() => probeRuntime(claude.invocation)).toThrow('unsafe identity')

      const codex = runtimeStub(f.root, 'codex', '0.144.1')
      linkSync(codex.invocation.argvFiles![0], join(f.root, 'codex-entry-hardlink'))
      expect(() => probeRuntime(codex.invocation)).toThrow('unsafe identity')
    } finally { f.cleanup() }
  })

  for (const runtime of ['claude', 'codex'] as const) {
    test(`a version-spoofing but production-incompatible ${runtime} CLI cannot pass diagnosis`, () => {
      const f = fixture()
      try {
        const stub = runtimeStub(
          f.root, runtime, runtime === 'claude' ? '2.1.207' : '0.144.1', false,
        )
        const store = new RuntimeConformanceStore(f.state, f.repo)
        let suiteCalls = 0
        const result = runRuntimeDiagnostic({
          invocation: stub.invocation,
          repoRoot: f.repo,
          store,
          runSuite: () => { suiteCalls += 1; return { ok: true } },
        })
        expect(result).toMatchObject({
          ok: false,
          record: { runtime, outcome: 'failed' },
        })
        expect(result.record.diagnostic).toContain('production surface is incompatible')
        expect(suiteCalls).toBe(0)
        expect(evaluateRuntimeConformance(stub.invocation, f.repo, store)).toMatchObject({
          ok: false, reason: 'not-passed',
        })
      } finally { f.cleanup() }
    })
  }

  test('production probes execute only the exact binary and Codex argv-prefix ordering', () => {
    const f = fixture()
    try {
      const claude = runtimeStub(f.root, 'claude', '2.1.207')
      expect(probeRuntimeProductionSurface(claude.invocation).runtime).toBe('claude')
      const claudeArgv = readFileSync(claude.argvLog, 'utf8').trim().split('\n')
      expect(claudeArgv).toContain('--help')
      expect(claudeArgv.every(line => line === '--version' || line === '--help')).toBe(true)

      const codex = runtimeStub(f.root, 'codex', '0.144.1')
      expect(probeRuntimeProductionSurface(codex.invocation).runtime).toBe('codex')
      const prefix = codex.invocation.argvFiles![0]
      const codexArgv = readFileSync(codex.argvLog, 'utf8').trim().split('\n')
      expect(codexArgv).toContain(`${prefix} --help`)
      expect(codexArgv).toContain(`${prefix} exec --help`)
      expect(codexArgv).toContain(`${prefix} app-server --help`)
      expect(codexArgv.every(line => line.startsWith(`${prefix} `))).toBe(true)
    } finally { f.cleanup() }
  })

  test('check and removed ensure/certify never mint missing or changed bytes', () => {
    const f = fixture()
    try {
      const stub = runtimeStub(f.root, 'claude', '2.1.207')
      const store = new RuntimeConformanceStore(f.state, f.repo)
      const cli = join(sourceRoot, 'bin', 'swarm-runtime-conformance.ts')
      const argv = [
        '--runtime', 'claude', '--binary', stub.invocation.binary,
        '--repo-root', f.repo, '--state-dir', f.state, '--bun', process.execPath,
      ]
      const missing = Bun.spawnSync([process.execPath, cli, 'check', ...argv], {
        stdout: 'pipe', stderr: 'pipe',
      })
      expect(missing.exitCode).toBe(2)
      expect(store.read('claude')).toBeNull()
      const removed = Bun.spawnSync([process.execPath, cli, 'ensure', ...argv], {
        stdout: 'pipe', stderr: 'pipe',
      })
      expect(removed.exitCode).toBe(64)
      expect(store.read('claude')).toBeNull()

      const removedCertify = Bun.spawnSync([process.execPath, cli, 'certify', ...argv], {
        stdout: 'pipe', stderr: 'pipe',
      })
      expect(removedCertify.exitCode).toBe(64)
      expect(store.read('claude')).toBeNull()

      expect(runRuntimeDiagnostic({
        invocation: stub.invocation, repoRoot: f.repo, store, runSuite: () => ({ ok: true }),
      }).ok).toBe(true)
      stub.setVersion('2.1.208')
      const changed = Bun.spawnSync([process.execPath, cli, 'check', ...argv], {
        stdout: 'pipe', stderr: 'pipe',
      })
      expect(changed.exitCode).toBe(2)
      expect(store.read('claude')?.version).toBe('2.1.207')
    } finally { f.cleanup() }
  })

  test('diagnostic check does not create a missing state path', () => {
    const f = fixture()
    try {
      const stub = runtimeStub(f.root, 'claude', '2.1.207')
      const absent = join(f.root, 'absent-diagnostic-state')
      const cli = join(sourceRoot, 'bin', 'swarm-runtime-conformance.ts')
      const result = Bun.spawnSync([
        process.execPath,
        cli,
        'check',
        '--runtime', 'claude',
        '--binary', stub.invocation.binary,
        '--repo-root', f.repo,
        '--state-dir', absent,
        '--bun', process.execPath,
      ], { stdout: 'pipe', stderr: 'pipe' })
      expect(result.exitCode).toBe(2)
      expect(result.stderr.toString()).toContain('no diagnostic record exists')
      expect(() => realpathSync(absent)).toThrow()
    } finally { f.cleanup() }
  })

  test('operator diagnostic suite names real production lifecycle entrypoints', () => {
    const cli = readFileSync(join(sourceRoot, 'bin', 'swarm-runtime-conformance.ts'), 'utf8')
    for (const path of [
      'swarm-harness/task-boundary.test.ts',
      'swarm-harness/grounding-gate-cli.test.ts',
      'swarm-harness/claude-completion-authority.test.ts',
      'codex-bridge/daemon-lifecycle.test.ts',
      'codex-bridge/app-server-stdio-transport.test.ts',
      'tests/test-harness-root-authority.sh',
      'tests/test-runtime-conformance-launch-gate.sh',
    ]) expect(cli).toContain(path)
    const authority = readFileSync(join(sourceRoot, 'tests', 'test-harness-root-authority.sh'), 'utf8')
    for (const path of [
      'tests/test-harness-lifecycle-broker.py',
      'tests/test-claude-runtime-authority.py',
    ]) expect(authority).toContain(path)
  })
})
