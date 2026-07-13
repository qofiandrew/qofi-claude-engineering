import { createHash } from 'crypto'
import { spawnSync } from 'child_process'
import {
  chmodSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { dirname, join } from 'path'
import { describe, expect, test } from 'bun:test'
import {
  DEDICATED_RUNNER_KILL_GRACE_MS,
  DEDICATED_RUNTIME_ATTESTATION,
  DEDICATED_RUNTIME_SCHEMA,
  isAttestedOperatorCanary,
  isExactDedicatedPnpmVersionOutput,
  reconcileOperatorWorkspacePaths,
  validateDedicatedRuntimeBoundary,
  validateSharedWorkspaceBoundary,
} from './dedicated-runtime.ts'
import { runCodexTurn } from './codex.ts'

describe('dedicated runtime attestation', () => {
  test('accepts only the bounded root-attested operator canary witness', () => {
    const value = 'qofi-canary:0123456789abcdef'
    const digest = createHash('sha256').update(value).digest('hex')
    expect(isAttestedOperatorCanary(value, digest)).toBe(true)
    expect(isAttestedOperatorCanary(`${value}!`, digest)).toBe(false)
    expect(isAttestedOperatorCanary(value, '0'.repeat(64))).toBe(false)
    expect(isAttestedOperatorCanary(undefined, digest)).toBe(false)
  })

  test('accepts only the exact singleton pnpm version output', () => {
    expect(isExactDedicatedPnpmVersionOutput('9.12.3')).toBe(true)
    expect(isExactDedicatedPnpmVersionOutput('9.12.3\n')).toBe(true)
    expect(isExactDedicatedPnpmVersionOutput('9.12.4\n')).toBe(false)
    expect(isExactDedicatedPnpmVersionOutput('9.12.3\nextra\n')).toBe(false)
  })

  test('uses the canonical macOS attestation path rather than the /etc alias', () => {
    expect(DEDICATED_RUNTIME_ATTESTATION).toBe('/private/etc/qofi-codex-runtime.json')
  })

  test('runner gets enough TERM grace to reap the dedicated uid before SIGKILL', () => {
    expect(DEDICATED_RUNNER_KILL_GRACE_MS).toBeGreaterThan(5_000)
    expect(DEDICATED_RUNNER_KILL_GRACE_MS).toBeLessThan(10_000)
  })

  test('shared workspace scan reconciles ordinary files and validates only the .git root', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-shared-workspace-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const source = join(workspace, 'src')
    mkdirSync(source)
    mkdirSync(join(workspace, '.codex'))
    mkdirSync(join(workspace, '.git'))
    writeFileSync(join(source, 'main.ts'), 'export {}\n')
    writeFileSync(join(workspace, '.env'), 'SECRET=value\n')
    writeFileSync(join(workspace, '.codex', 'config.toml'), '# managed\n')
    writeFileSync(join(workspace, 'AGENTS.md'), 'managed doctrine\n')
    writeFileSync(join(workspace, '.gitleaks.toml'), 'managed enforcement\n')
    symlinkSync('src/main.ts', join(workspace, 'main-link.ts'))
    writeFileSync(join(workspace, '.git', 'private'), 'git metadata')
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    expect(Bun.spawnSync(['/bin/chmod', '2770', source]).exitCode).toBe(0)
    expect(lstatSync(workspace).mode & 0o2000).toBe(0o2000)
    expect(lstatSync(source).mode & 0o2000).toBe(0o2000)
    chmodSync(join(source, 'main.ts'), 0o660)
    chmodSync(join(workspace, '.env'), 0o600)
    chmodSync(join(workspace, '.codex'), 0o755)
    chmodSync(join(workspace, '.codex', 'config.toml'), 0o644)
    chmodSync(join(workspace, 'AGENTS.md'), 0o644)
    chmodSync(join(workspace, '.gitleaks.toml'), 0o644)
    chmodSync(join(workspace, '.git'), 0o750)
    chmodSync(join(workspace, '.git', 'private'), 0o600)
    try {
      writeFileSync(join(source, 'operator-umask-file.ts'), 'first')
      chmodSync(join(source, 'operator-umask-file.ts'), 0o644)
      reconcileOperatorWorkspacePaths(workspace, gid, operatorUid)
      expect(lstatSync(join(source, 'operator-umask-file.ts')).mode & 0o060).toBe(0o060)
      expect(() => writeFileSync(join(source, 'operator-umask-file.ts'), 'second')).not.toThrow()
      expect(lstatSync(join(workspace, '.env')).mode & 0o077).toBe(0)
      expect(lstatSync(join(workspace, 'AGENTS.md')).mode & 0o022).toBe(0)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid)).not.toThrow()
      chmodSync(join(source, 'main.ts'), 0o640)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid)).toThrow('shared-group')
      chmodSync(join(source, 'main.ts'), 0o660)
      chmodSync(join(workspace, '.env'), 0o640)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid)).toThrow('operator-only')
      chmodSync(join(workspace, '.env'), 0o600)
      rmSync(join(workspace, '.env'))
      symlinkSync('src/main.ts', join(workspace, '.env'))
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid)).toThrow('cannot be a symlink')
      rmSync(join(workspace, '.env'))
      writeFileSync(join(workspace, '.env'), 'SECRET=value\n')
      chmodSync(join(workspace, '.env'), 0o600)

      const runtimeUid = operatorUid + 10_000
      const replacementOwner = (replacement: string) =>
        (path: string, actualUid: number) => path === replacement ? runtimeUid : actualUid
      expect(() => validateSharedWorkspaceBoundary(
        workspace, gid, operatorUid, 200_000,
        replacementOwner(join(realpathSync(workspace), 'AGENTS.md')),
      )).toThrow('operator-owned workspace path must be owned by the attested operator')
      expect(() => validateSharedWorkspaceBoundary(
        workspace, gid, operatorUid, 200_000,
        replacementOwner(join(realpathSync(workspace), '.env')),
      )).toThrow('workspace secret path must be owned by the attested operator')
      expect(() => validateSharedWorkspaceBoundary(
        workspace, gid, operatorUid, 200_000,
        replacementOwner(join(realpathSync(workspace), '.git')),
      )).toThrow('operator-owned workspace path must be owned by the attested operator')
      chmodSync(join(workspace, '.git'), 0o770)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid))
        .toThrow('operator-owned workspace path must not be group/world writable')
      chmodSync(join(workspace, '.git'), 0o750)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, runtimeUid))
        .toThrow('workspace root must be owned by the attested operator')
    } finally {
      rmSync(workspace, { recursive: true, force: true })
    }
  })

  test('rejects hard-linked regular files before reconciliation can mutate the workspace', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-hardlink-boundary-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const untouched = join(workspace, 'would-have-been-reconciled.txt')
    const source = join(workspace, 'source.txt')
    const alias = join(workspace, 'alias.txt')
    writeFileSync(untouched, 'unchanged\n')
    writeFileSync(source, 'linked\n')
    chmodSync(untouched, 0o644)
    chmodSync(source, 0o644)
    linkSync(source, alias)
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    try {
      expect(() => reconcileOperatorWorkspacePaths(workspace, gid, operatorUid))
        .toThrow('hard-linked or duplicate inode')
      expect(lstatSync(untouched).mode & 0o7777).toBe(0o644)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid))
        .toThrow('hard-linked or duplicate inode')
    } finally {
      rmSync(workspace, { recursive: true, force: true })
    }
  })

  test('accepts only closed immutable node_modules hard-link sets and never reconciles their inode', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-pnpm-hardlink-boundary-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const first = join(
      workspace,
      'node_modules/.pnpm/@esbuild+darwin-arm64@0.18.20/node_modules/@esbuild/darwin-arm64/bin/esbuild',
    )
    const second = join(
      workspace,
      'node_modules/.pnpm/esbuild@0.18.20/node_modules/esbuild/bin/esbuild',
    )
    mkdirSync(dirname(first), { recursive: true })
    mkdirSync(dirname(second), { recursive: true })
    writeFileSync(first, 'pnpm-managed-binary\n')
    chmodSync(first, 0o755)
    linkSync(first, second)
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    const preparedDirectories = new Set<string>()
    for (const leaf of [first, second]) {
      for (let dir = dirname(leaf); dir !== workspace; dir = dirname(dir)) {
        preparedDirectories.add(dir)
      }
    }
    for (const dir of preparedDirectories) {
      expect(Bun.spawnSync(['/bin/chmod', '2770', dir]).exitCode).toBe(0)
    }
    const before = lstatSync(first)
    try {
      reconcileOperatorWorkspacePaths(workspace, gid, operatorUid)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid)).not.toThrow()
      const after = lstatSync(first)
      expect({
        uid: after.uid,
        gid: after.gid,
        mode: after.mode & 0o7777,
        ino: after.ino,
        nlink: after.nlink,
        content: readFileSync(first, 'utf8'),
      }).toEqual({
        uid: before.uid,
        gid: before.gid,
        mode: before.mode & 0o7777,
        ino: before.ino,
        nlink: before.nlink,
        content: 'pnpm-managed-binary\n',
      })
      expect(lstatSync(second).ino).toBe(after.ino)

      chmodSync(first, 0o775)
      expect(() => reconcileOperatorWorkspacePaths(workspace, gid, operatorUid))
        .toThrow('must not be group/world writable')
      chmodSync(first, 0o755)
      const simulatedRuntimeUid = operatorUid + 10_000
      const canonicalFirst = realpathSync(first)
      expect(() => validateSharedWorkspaceBoundary(
        workspace,
        gid,
        operatorUid,
        200_000,
        (path, actualUid) => path === canonicalFirst ? simulatedRuntimeUid : actualUid,
      )).toThrow('must be owned by the attested operator')
    } finally {
      rmSync(workspace, { recursive: true, force: true })
    }
  })

  test('rejects a node_modules hard link whose other name is outside the workspace', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-pnpm-open-set-'))
    const outside = mkdtempSync(join(tmpdir(), 'codex-pnpm-outside-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const source = join(outside, 'operator-file')
    const alias = join(workspace, 'node_modules/.pnpm/pkg/node_modules/pkg/file')
    mkdirSync(dirname(alias), { recursive: true })
    writeFileSync(source, 'outside\n')
    chmodSync(source, 0o644)
    linkSync(source, alias)
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    try {
      expect(() => reconcileOperatorWorkspacePaths(workspace, gid, operatorUid))
        .toThrow('not a closed in-workspace alias set')
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid))
        .toThrow('not a closed in-workspace alias set')
      expect(readFileSync(source, 'utf8')).toBe('outside\n')
      expect(lstatSync(source).mode & 0o7777).toBe(0o644)
    } finally {
      rmSync(workspace, { recursive: true, force: true })
      rmSync(outside, { recursive: true, force: true })
    }
  })

  test('rejects regular-file privilege bits before reconciliation and never preserves them', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-special-mode-boundary-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const untouched = join(workspace, 'would-have-been-reconciled.txt')
    const privileged = join(workspace, 'privileged-file')
    writeFileSync(untouched, 'unchanged\n')
    writeFileSync(privileged, 'not executable content\n')
    chmodSync(untouched, 0o644)
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    try {
      for (const specialBit of [0o4000, 0o2000, 0o1000]) {
        expect(Bun.spawnSync([
          '/bin/chmod', (specialBit | 0o755).toString(8), privileged,
        ]).exitCode).toBe(0)
        expect(lstatSync(privileged).mode & 0o7000).toBe(specialBit)
        expect(() => reconcileOperatorWorkspacePaths(workspace, gid, operatorUid))
          .toThrow('setuid, setgid, or sticky bits')
        expect(lstatSync(untouched).mode & 0o7777).toBe(0o644)
        expect(lstatSync(privileged).mode & 0o7000).toBe(specialBit)
        expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid))
          .toThrow('setuid, setgid, or sticky bits')
      }
    } finally {
      rmSync(workspace, { recursive: true, force: true })
    }
  })

  test('rejects a cross-device entry before reconciliation can mutate the workspace', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-device-boundary-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const untouched = join(workspace, 'would-have-been-reconciled.txt')
    const mountedEntry = join(workspace, 'mounted-entry.txt')
    writeFileSync(untouched, 'unchanged\n')
    writeFileSync(mountedEntry, 'simulated mount content\n')
    chmodSync(untouched, 0o644)
    chmodSync(mountedEntry, 0o660)
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    const canonicalMountedEntry = realpathSync(mountedEntry)
    const replaceDevice = (path: string, actualDevice: number) =>
      path === canonicalMountedEntry ? actualDevice + 1 : actualDevice
    try {
      expect(() => reconcileOperatorWorkspacePaths(
        workspace, gid, operatorUid, 200_000, replaceDevice,
      )).toThrow('crosses device boundary')
      expect(lstatSync(untouched).mode & 0o7777).toBe(0o644)
      expect(() => validateSharedWorkspaceBoundary(
        workspace, gid, operatorUid, 200_000, undefined, replaceDevice,
      )).toThrow('crosses device boundary')
    } finally {
      rmSync(workspace, { recursive: true, force: true })
    }
  })

  test('Claude worktrees are opaque and never consume reconciliation or validation scan bounds', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-opaque-worktrees-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const worktrees = join(workspace, '.claude', 'worktrees')
    const checkout = join(worktrees, 'teammate')
    const source = join(checkout, 'src')
    mkdirSync(source, { recursive: true })
    writeFileSync(join(checkout, '.git'), 'gitdir: /operator/private/worktree\n')
    writeFileSync(join(source, 'main.ts'), 'export const claude = true\n')
    for (let i = 0; i < 32; i++) {
      writeFileSync(join(checkout, `ordinary-${i}.txt`), `${i}\n`)
    }
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    chmodSync(join(workspace, '.claude'), 0o755)
    chmodSync(worktrees, 0o700)
    chmodSync(checkout, 0o755)
    chmodSync(source, 0o755)
    chmodSync(join(checkout, '.git'), 0o644)
    chmodSync(join(source, 'main.ts'), 0o644)
    const snapshot = () => ({
      worktreesMode: lstatSync(worktrees).mode & 0o7777,
      checkoutMode: lstatSync(checkout).mode & 0o7777,
      sourceMode: lstatSync(source).mode & 0o7777,
      gitMode: lstatSync(join(checkout, '.git')).mode & 0o7777,
      git: readFileSync(join(checkout, '.git'), 'utf8'),
      mainMode: lstatSync(join(source, 'main.ts')).mode & 0o7777,
      main: readFileSync(join(source, 'main.ts'), 'utf8'),
      ordinaryMode: lstatSync(join(checkout, 'ordinary-31.txt')).mode & 0o7777,
      ordinary: readFileSync(join(checkout, 'ordinary-31.txt'), 'utf8'),
    })
    const before = snapshot()
    try {
      // Exactly root, .claude, and the opaque boundary may be inspected. Any
      // descent into the 34 checkout entries would exceed this cap.
      expect(() => reconcileOperatorWorkspacePaths(workspace, gid, operatorUid, 3)).not.toThrow()
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid, 3)).not.toThrow()
      expect(snapshot()).toEqual(before)
    } finally {
      rmSync(workspace, { recursive: true, force: true })
    }
  })

  test('rejects an unsafe Claude worktrees boundary without inspecting its descendants', () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-opaque-boundary-'))
    const outside = mkdtempSync(join(tmpdir(), 'codex-opaque-target-'))
    const gid = process.getgid?.() ?? 20
    const operatorUid = process.getuid?.() ?? 501
    const claude = join(workspace, '.claude')
    const worktrees = join(claude, 'worktrees')
    mkdirSync(worktrees, { recursive: true })
    expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
    chmodSync(claude, 0o755)
    chmodSync(worktrees, 0o755)
    try {
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid))
        .toThrow('opaque operator subtree must have mode 0700')
      rmSync(worktrees, { recursive: true })
      symlinkSync(outside, worktrees)
      expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid))
        .toThrow('opaque operator subtree must be a real canonical directory')
    } finally {
      rmSync(workspace, { recursive: true, force: true })
      rmSync(outside, { recursive: true, force: true })
    }
  })

  test.skipIf(process.platform !== 'darwin')(
    'rejects an extended ACL on the opaque Claude worktrees boundary',
    () => {
      const workspace = mkdtempSync(join(tmpdir(), 'codex-opaque-acl-'))
      const gid = process.getgid?.() ?? 20
      const operatorUid = process.getuid?.() ?? 501
      const claude = join(workspace, '.claude')
      const worktrees = join(claude, 'worktrees')
      mkdirSync(worktrees, { recursive: true })
      expect(Bun.spawnSync(['/bin/chmod', '2770', workspace]).exitCode).toBe(0)
      chmodSync(claude, 0o755)
      chmodSync(worktrees, 0o700)
      try {
        expect(spawnSync(
          '/bin/chmod', ['+a', 'everyone allow read', worktrees], { encoding: 'utf8' },
        ).status).toBe(0)
        expect(() => validateSharedWorkspaceBoundary(workspace, gid, operatorUid))
          .toThrow('opaque operator subtree must not have an extended ACL')
      } finally {
        spawnSync('/bin/chmod', ['-RN', workspace])
        rmSync(workspace, { recursive: true, force: true })
      }
    },
  )

  test('builds and spawns only the attested sudo + target-bootstrap + node/script route', async () => {
    const workspace = mkdtempSync(join(tmpdir(), 'codex-dedicated-workspace-'))
    const state = mkdtempSync(join(tmpdir(), 'codex-dedicated-state-'))
    const root = mkdtempSync(join(process.cwd(), '.codex-dedicated-fixture-'))
    const runtimeHome = join(root, 'runtime-home')
    const codexHome = join(runtimeHome, '.codex')
    const runtimeTemp = join(runtimeHome, '.tmp')
    const script = join(root, 'codex.js')
    const runner = join(root, 'qofi-codex-runner')
    const reviewer = join(root, 'qofi-fable-reviewer-mcp.py')
    const doctrine = join(root, 'fable-reviewer-doctrine.md')
    const reviewSchema = join(root, 'adversarial-review-output.schema.json')
    const attestation = join(root, 'attestation.json')
    const operatorUid = process.getuid?.() ?? 501
    const runtimeUid = operatorUid + 10_000
    mkdirSync(codexHome, { recursive: true, mode: 0o700 })
    mkdirSync(runtimeTemp, { mode: 0o700 })
    for (const path of [runtimeHome, codexHome, runtimeTemp]) chmodSync(path, 0o700)
    writeFileSync(join(codexHome, 'auth.json'), '{}', { mode: 0o600 })
    chmodSync(join(codexHome, 'auth.json'), 0o600)
    writeFileSync(join(codexHome, 'config.toml'), '# fixture managed config\n', { mode: 0o600 })
    chmodSync(join(codexHome, 'config.toml'), 0o600)
    writeFileSync(script, 'console.log("codex")\n', { mode: 0o600 })
    writeFileSync(runner, '#!/usr/bin/env python3\n', { mode: 0o700 })
    chmodSync(runner, 0o700)
    writeFileSync(reviewer, '#!/usr/bin/python3\n', { mode: 0o700 })
    chmodSync(reviewer, 0o700)
    writeFileSync(doctrine, 'fixture doctrine\n', { mode: 0o600 })
    writeFileSync(reviewSchema, '{}\n', { mode: 0o600 })
    const canary = 'fixture-secret'
    const value = {
      schema: DEDICATED_RUNTIME_SCHEMA,
      operator_uid: operatorUid,
      runtime_uid: runtimeUid,
      runtime_user: 'qofi_codex_test',
      runtime_gid: runtimeUid + 1,
      runtime_group: 'qofi_codex_group_test',
      runtime_home: realpathSync(runtimeHome),
      runner_path: realpathSync(runner),
      runner_sha256: createHash('sha256').update(readFileSync(runner)).digest('hex'),
      node_path: realpathSync(process.execPath),
      node_sha256: createHash('sha256').update(readFileSync(process.execPath)).digest('hex'),
      codex_script: realpathSync(script),
      codex_script_sha256: createHash('sha256').update(readFileSync(script)).digest('hex'),
      codex_home: realpathSync(codexHome),
      fable_reviewer_path: realpathSync(reviewer),
      fable_reviewer_sha256: createHash('sha256').update(readFileSync(reviewer)).digest('hex'),
      fable_doctrine_path: realpathSync(doctrine),
      fable_doctrine_sha256: createHash('sha256').update(readFileSync(doctrine)).digest('hex'),
      fable_schema_path: realpathSync(reviewSchema),
      fable_schema_sha256: createHash('sha256').update(readFileSync(reviewSchema)).digest('hex'),
      fable_reviewer_config_sha256: '3'.repeat(64),
      codex_config_sha256: createHash('sha256')
        .update(readFileSync(join(codexHome, 'config.toml'))).digest('hex'),
      launchd_canary_name: 'QOFI_CODEX_RUNTIME_CANARY_FIXTURE123',
      launchd_canary_sha256: createHash('sha256').update(canary).digest('hex'),
    }
    writeFileSync(attestation, JSON.stringify(value), { mode: 0o600 })
    chmodSync(attestation, 0o600)
    try {
      const boundaryOptions = {
        workspaceRoot: workspace,
        stateDir: state,
        trustedNodePath: process.execPath,
        trustedCodexScript: script,
        attestationPath: realpathSync(attestation),
        expectedAttestationUid: operatorUid,
        filesystemRuntimeUid: operatorUid,
        expectedRuntimeParentUid: operatorUid,
        skipAccountLookup: true,
        skipWorkspaceGroupValidation: true,
        runnerPathOverride: realpathSync(runner),
        expectedRunnerUid: operatorUid,
        expectedExecutableUid: operatorUid,
        fableReviewerPathOverride: realpathSync(reviewer),
        fableDoctrinePathOverride: realpathSync(doctrine),
        fableSchemaPathOverride: realpathSync(reviewSchema),
      }
      const authPath = join(codexHome, 'auth.json')
      rmSync(authPath)
      expect(() => validateDedicatedRuntimeBoundary(boundaryOptions))
        .toThrow('dedicated ChatGPT auth is not initialized')
      writeFileSync(authPath, '{}', { mode: 0o600 })
      chmodSync(authPath, 0o600)
      const authAlias = join(codexHome, 'auth-alias.json')
      linkSync(authPath, authAlias)
      expect(() => validateDedicatedRuntimeBoundary(boundaryOptions))
        .toThrow('dedicated Codex auth.json must be uid-owned regular mode 0600')
      rmSync(authAlias)

      const plan = validateDedicatedRuntimeBoundary(boundaryOptions)
      expect(plan.runtimeUid).toBe(runtimeUid)
      expect(plan.runtimeHome).toBe(realpathSync(runtimeHome))
      expect(plan.sudoArgvPrefix).toEqual([
        '-n',
        '--', realpathSync(runner), '--parent-pid', String(process.pid), '--',
      ])

      writeFileSync(doctrine, 'drifted doctrine\n', { mode: 0o600 })
      expect(() => validateDedicatedRuntimeBoundary(boundaryOptions))
        .toThrow('Fable reviewer authority ownership/mode/hash is invalid')
      writeFileSync(doctrine, 'fixture doctrine\n', { mode: 0o600 })

      const fakeSudo = join(root, 'fake-sudo')
      writeFileSync(fakeSudo, `#!/usr/bin/env bun
process.stdin.resume()
await new Promise(resolve => process.stdin.on('end', resolve))
console.log(JSON.stringify({type:'thread.started',thread_id:'dedicated'}))
console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:JSON.stringify(Bun.argv.slice(2))}}))
console.log(JSON.stringify({type:'turn.completed'}))
`, { mode: 0o700 })
      chmodSync(fakeSudo, 0o700)
      const turn = await runCodexTurn(null, 'test', {
        cwd: workspace,
        timeoutMs: 2000,
        bin: fakeSudo,
        binArgs: plan.sudoArgvPrefix,
      })
      expect(turn.ok).toBe(true)
      expect(JSON.parse(turn.messages[0]).slice(0, plan.sudoArgvPrefix.length))
        .toEqual(plan.sudoArgvPrefix)

      const accountCalls: string[] = []
      expect(() => validateDedicatedRuntimeBoundary({
        workspaceRoot: workspace,
        stateDir: state,
        trustedNodePath: process.execPath,
        trustedCodexScript: script,
        attestationPath: realpathSync(attestation),
        expectedAttestationUid: operatorUid,
        filesystemRuntimeUid: operatorUid,
        expectedRuntimeParentUid: operatorUid,
        skipWorkspaceGroupValidation: true,
        runnerPathOverride: realpathSync(runner),
        expectedRunnerUid: operatorUid,
        expectedExecutableUid: operatorUid,
        accountCommand(command, args) {
          const invocation = `${command} ${args.join(' ')}`
          accountCalls.push(invocation)
          if (command === '/usr/bin/python3') {
            const gid = process.getgid?.() ?? 20
            return {
              status: 0,
              stdout: `${operatorUid} ${operatorUid} ${gid} ${gid} ${gid},${value.runtime_gid}\n`,
            }
          }
          if (command === '/usr/bin/dscacheutil') {
            return { status: 0, stdout: `name: ${value.runtime_group}\ngid: ${value.runtime_gid}\n` }
          }
          if (args[0] === '-u') return { status: 0, stdout: `${runtimeUid}\n` }
          if (args[0] === '-nu') return { status: 0, stdout: 'fixture_operator\n' }
          if (args[0] === '-G' && args[1] === 'fixture_operator') {
            return { status: 0, stdout: `${value.runtime_gid}\n` }
          }
          if (args[0] === '-G' && args[1] === value.runtime_user) {
            return { status: 0, stdout: `${value.runtime_gid}\n` }
          }
          return { status: 1, stdout: '' }
        },
      })).not.toThrow()
      expect(accountCalls).toContain('/usr/bin/id -G fixture_operator')
      expect(accountCalls).not.toContain('/usr/bin/id -G')
      expect(accountCalls.some(call => call.startsWith('/usr/bin/python3 -I -S -c '))).toBe(true)
      expect(() => validateDedicatedRuntimeBoundary({
        workspaceRoot: workspace,
        stateDir: state,
        trustedNodePath: process.execPath,
        trustedCodexScript: script,
        attestationPath: realpathSync(attestation),
        expectedAttestationUid: operatorUid,
        filesystemRuntimeUid: operatorUid,
        expectedRuntimeParentUid: operatorUid,
        skipWorkspaceGroupValidation: true,
        runnerPathOverride: realpathSync(runner),
        expectedRunnerUid: operatorUid,
        expectedExecutableUid: operatorUid,
        currentProcessGroups: [],
        accountCommand(command, args) {
          if (command === '/usr/bin/dscacheutil') {
            return { status: 0, stdout: `gid: ${value.runtime_gid}\n` }
          }
          if (args[0] === '-u') return { status: 0, stdout: `${runtimeUid}\n` }
          if (args[0] === '-nu') return { status: 0, stdout: 'fixture_operator\n' }
          return { status: 0, stdout: `${value.runtime_gid}\n` }
        },
      })).toThrow('log out/in and restart tmux')

      writeFileSync(attestation, JSON.stringify({ ...value, operator_uid: 0 }), { mode: 0o600 })
      chmodSync(attestation, 0o600)
      expect(() => validateDedicatedRuntimeBoundary({
        workspaceRoot: workspace,
        stateDir: state,
        trustedNodePath: process.execPath,
        trustedCodexScript: script,
        attestationPath: realpathSync(attestation),
        expectedAttestationUid: operatorUid,
        filesystemRuntimeUid: operatorUid,
        expectedRuntimeParentUid: operatorUid,
        skipAccountLookup: true,
        skipWorkspaceGroupValidation: true,
        runnerPathOverride: realpathSync(runner),
        expectedRunnerUid: operatorUid,
        expectedExecutableUid: operatorUid,
      })).toThrow('operator_uid and daemon uid must be non-root')

      writeFileSync(attestation, JSON.stringify({ ...value, runtime_uid: operatorUid }), { mode: 0o600 })
      chmodSync(attestation, 0o600)
      expect(() => validateDedicatedRuntimeBoundary({
        workspaceRoot: workspace,
        stateDir: state,
        trustedNodePath: process.execPath,
        trustedCodexScript: script,
        attestationPath: realpathSync(attestation),
        expectedAttestationUid: operatorUid,
        filesystemRuntimeUid: operatorUid,
        expectedRuntimeParentUid: operatorUid,
        skipAccountLookup: true,
        skipWorkspaceGroupValidation: true,
        runnerPathOverride: realpathSync(runner),
        expectedRunnerUid: operatorUid,
        expectedExecutableUid: operatorUid,
      })).toThrow('distinct non-root')

      writeFileSync(attestation, JSON.stringify({ ...value, unexpected: true }), { mode: 0o600 })
      chmodSync(attestation, 0o600)
      expect(() => validateDedicatedRuntimeBoundary({
        workspaceRoot: workspace,
        stateDir: state,
        trustedNodePath: process.execPath,
        trustedCodexScript: script,
        attestationPath: realpathSync(attestation),
        expectedAttestationUid: operatorUid,
        filesystemRuntimeUid: operatorUid,
        expectedRuntimeParentUid: operatorUid,
        skipAccountLookup: true,
        skipWorkspaceGroupValidation: true,
        runnerPathOverride: realpathSync(runner),
        expectedRunnerUid: operatorUid,
        expectedExecutableUid: operatorUid,
      })).toThrow('keys do not exactly match v2')
    } finally {
      rmSync(workspace, { recursive: true, force: true })
      rmSync(state, { recursive: true, force: true })
      rmSync(root, { recursive: true, force: true })
    }
  })
})
