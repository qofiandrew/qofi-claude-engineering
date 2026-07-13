#!/usr/bin/env bun
import { dirname, join, resolve } from 'node:path'
import { homedir } from 'node:os'
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  realpathSync,
  rmSync,
} from 'node:fs'
import {
  RuntimeConformanceStore,
  runRuntimeDiagnostic,
  evaluateRuntimeConformance,
  prepareRuntimeConformanceState,
  type ConformanceRuntime,
  type RuntimeInvocation,
} from '../swarm-harness/runtime-conformance'

process.umask(0o077)

type Parsed = {
  command: 'check' | 'diagnose'
  runtime: ConformanceRuntime
  binary: string
  argvFiles: string[]
  repoRoot: string
  stateDir: string
  bun: string
}

function usage(): never {
  process.stderr.write(
    'usage: swarm-runtime-conformance.ts check|diagnose --runtime claude|codex '
    + '--binary /absolute/path [--argv-file /absolute/path] --repo-root /absolute/path '
    + '[--state-dir /absolute/path] [--bun /absolute/path]\n',
  )
  process.exit(64)
}

function parseArgs(argv: string[]): Parsed {
  const command = argv.shift()
  if (command !== 'check' && command !== 'diagnose') usage()
  let runtime = ''
  let binary = ''
  let repoRoot = ''
  let stateDir = ''
  let bun = process.execPath
  const argvFiles: string[] = []
  while (argv.length > 0) {
    const flag = argv.shift()
    const value = argv.shift()
    if (!value) usage()
    if (flag === '--runtime') runtime = value
    else if (flag === '--binary') binary = value
    else if (flag === '--argv-file') argvFiles.push(value)
    else if (flag === '--repo-root') repoRoot = value
    else if (flag === '--state-dir') stateDir = value
    else if (flag === '--bun') bun = value
    else usage()
  }
  if ((runtime !== 'claude' && runtime !== 'codex') || !binary || !repoRoot || argvFiles.length > 4) usage()
  if (!stateDir) stateDir = join(homedir(), '.swarm-harness', 'runtime-conformance')
  return {
    command,
    runtime,
    binary: resolve(binary),
    argvFiles: argvFiles.map(value => resolve(value)),
    repoRoot: resolve(repoRoot),
    stateDir: resolve(stateDir),
    bun: realpathSync(resolve(bun)),
  }
}

const parsed = parseArgs(process.argv.slice(2))
const invocation: RuntimeInvocation = {
  runtime: parsed.runtime,
  binary: parsed.binary,
  argvFiles: parsed.argvFiles,
}

if (parsed.command === 'check') {
  // This command is diagnostic only. In particular it never creates a state
  // directory on a launch/check path. Production launch authority comes from
  // the fixed root broker, not from this operator-uid record store.
  if (!existsSync(parsed.stateDir)) {
    process.stderr.write(`runtime-conformance: quarantined ${parsed.runtime}: missing: no diagnostic record exists\n`)
    process.exit(2)
  }
  const store = new RuntimeConformanceStore(parsed.stateDir, parsed.repoRoot)
  const decision = evaluateRuntimeConformance(invocation, parsed.repoRoot, store)
  if (!decision.ok) {
    process.stderr.write(`runtime-conformance: quarantined ${parsed.runtime}: ${decision.reason}: ${decision.detail}\n`)
    process.exit(2)
  }
  process.stdout.write(`runtime-conformance: accepted ${parsed.runtime} ${decision.record.version}\n`)
  process.exit(0)
}

// Mutable repository tests must never execute as root. This command is a
// non-authoritative operator diagnostic; the separately installed/attested
// root workflow is intentionally absent while Claude parity is restricted.
if (process.geteuid?.() === 0) {
  process.stderr.write('runtime-conformance: diagnose refuses root execution of mutable repository tests\n')
  process.exit(77)
}
prepareRuntimeConformanceState(parsed.stateDir, parsed.repoRoot)
const store = new RuntimeConformanceStore(parsed.stateDir, parsed.repoRoot)

const commonLifecycleTests = [
  'swarm-harness/authority-state.test.ts',
  'swarm-harness/checkin.test.ts',
  'swarm-harness/completion-review-policy.test.ts',
  'swarm-harness/event-store.test.ts',
  'swarm-harness/events.test.ts',
  'swarm-harness/grounding-budget.test.ts',
  'swarm-harness/parity-conformance.test.ts',
  'swarm-harness/task-boundary.test.ts',
  'swarm-harness/runtime-adapters.test.ts',
  'swarm-harness/stop-delivery.test.ts',
  'swarm-harness/parity-adoption.test.ts',
  'swarm-harness/product-context-cache.test.ts',
  'swarm-harness/product-context-pack.test.ts',
  'swarm-harness/roadmap.test.ts',
  'swarm-harness/grounding-runtime-wrapper.test.ts',
  'swarm-harness/grounding-gate-cli.test.ts',
  'cto-watcher/checkin-coordinator.test.js',
  'cto-watcher/checkin-metrics.test.js',
  'cto-watcher/harness-policy-client.test.js',
  'cto-watcher/roadmap-coordinator.test.js',
] as const

const runtimeLifecycleTests = parsed.runtime === 'claude'
  ? ['swarm-harness/claude-completion-authority.test.ts'] as const
  : [
      'codex-bridge/app-server-manager-client.test.ts',
      'codex-bridge/app-server-manager.test.ts',
      'codex-bridge/daemon-lifecycle.test.ts',
      'codex-bridge/daemon-lifecycle-contract.test.ts',
      'codex-bridge/daemon-manager-contract.test.ts',
      'codex-bridge/harness-lifecycle-broker-client.test.ts',
      'codex-bridge/app-server-stdio-transport.test.ts',
    ] as const

const CLAUDE_SUPERVISED_COMPLETION_RESTRICTION =
  'restricted-no-attested-exact-final-reviewer' as const

function runProductionLifecycleSuite(): { ok: boolean, diagnostic?: string } {
  // Keep AF_UNIX fixture paths below macOS's portable 100-byte ceiling. This
  // random owner-private directory holds test-only state; diagnostic records
  // remain in the separately validated state root.
  const suiteTmp = realpathSync(mkdtempSync('/tmp/qrc.'))
  chmodSync(suiteTmp, 0o700)
  const previousUmask = process.umask(0o022)
  const controlSuiteEnvironment = {
    HOME: process.env.HOME,
    TMPDIR: process.env.TMPDIR,
    PATH: `${dirname(parsed.bun)}:/usr/bin:/bin:/usr/sbin:/sbin`,
    LANG: 'C',
    LC_ALL: 'C',
    NO_COLOR: '1',
  }
  const productionSuiteEnvironment = {
    ...controlSuiteEnvironment,
    TMPDIR: suiteTmp,
  }
  try {
    const tests = [...commonLifecycleTests, ...runtimeLifecycleTests]
      .map(path => join(parsed.repoRoot, path))
    const run = Bun.spawnSync([parsed.bun, 'test', ...tests], {
      cwd: parsed.repoRoot,
      stdout: 'inherit',
      stderr: 'inherit',
      env: productionSuiteEnvironment,
    })
    if (run.exitCode !== 0) {
      return { ok: false, diagnostic: `production lifecycle tests exited ${run.exitCode}` }
    }
    const shellTests = [
      'tests/test-harness-root-authority.sh',
      'tests/test-runtime-conformance-launch-gate.sh',
    ]
    for (const relativePath of shellTests) {
      const shell = Bun.spawnSync(['/bin/bash', join(parsed.repoRoot, relativePath)], {
        cwd: parsed.repoRoot,
        stdout: 'inherit',
        stderr: 'inherit',
        env: controlSuiteEnvironment,
      })
      if (shell.exitCode !== 0) {
        return { ok: false, diagnostic: `${relativePath} exited ${shell.exitCode}` }
      }
    }
    for (const relativePath of [
      'tests/test-fable-reviewer-mcp.py',
      'tests/test-qofi-review-normalize.py',
    ]) {
      const python = Bun.spawnSync(['/usr/bin/python3', join(parsed.repoRoot, relativePath)], {
        cwd: parsed.repoRoot,
        stdout: 'inherit',
        stderr: 'inherit',
        env: controlSuiteEnvironment,
      })
      if (python.exitCode !== 0) {
        return { ok: false, diagnostic: `${relativePath} exited ${python.exitCode}` }
      }
    }
    // No root-attested supervised print runner/exact-final Codex reviewer is
    // shipped for Claude completion. A synthetic review-unavailable artifact
    // is not review evidence. Preserve atomic parity by refusing the Claude
    // half; no mutable diagnostic may publish a Claude+Codex pass manifest.
    if (parsed.runtime === 'claude') {
      return { ok: false, diagnostic: CLAUDE_SUPERVISED_COMPLETION_RESTRICTION }
    }
    return { ok: true }
  } finally {
    process.umask(previousUmask)
    rmSync(suiteTmp, { recursive: true, force: true })
  }
}

const result = runRuntimeDiagnostic({
  invocation,
  repoRoot: parsed.repoRoot,
  store,
  runSuite: runProductionLifecycleSuite,
})

if (!result.ok) {
  process.stderr.write(
    `runtime-conformance: ${parsed.runtime} remains quarantined: ${result.record.diagnostic ?? 'suite failed'}\n`,
  )
  process.exit(2)
}
process.stdout.write(`runtime-conformance: diagnostic passed for ${parsed.runtime} ${result.record.version}\n`)
