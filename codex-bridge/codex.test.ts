import { describe, test, expect, beforeEach, afterEach } from 'bun:test'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { homedir, tmpdir } from 'os'
import { join } from 'path'
import {
  parseCodexEvents,
  buildAppServerThreadConfig,
  buildCodexArgs,
  buildPermissionFilesystem,
  buildPermissionFilesystemConfig,
  buildPermissionProfileArgs,
  CODEX_PERMISSION_PROFILE,
  isMissingThreadError,
  runCodexTurn,
  safeExecutionOverrides,
  sanitizedCodexEnv,
  shouldRetryFresh,
  MAX_SESSION_ENTRIES,
  MAX_SESSION_FILE_BYTES,
  SessionStore,
  SessionStoreError,
  type CodexConfig,
  workspaceSecretDenyPaths,
} from './codex.ts'
import { createToolShims, resolveToolchainPlan, safeTurnEnvironment } from './toolchain.ts'
import { discoverWorkspacePolicy } from './workspace.ts'
import {
  CPO_CODEX_REASONING_EFFORT,
  DEFAULT_CODEX_MODEL,
  DEFAULT_CODEX_REASONING_EFFORT,
} from './model.ts'

// Captured verbatim from codex-cli 0.142.3 `codex exec --json`.
const HAPPY = [
  '{"type":"thread.started","thread_id":"019f4576-8f36-72b2-80f6-0ab9a3adbed4"}',
  '{"type":"turn.started"}',
  '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pong"}}',
  '{"type":"turn.completed","usage":{"input_tokens":12387,"cached_input_tokens":9600,"output_tokens":20,"reasoning_output_tokens":13}}',
].join('\n')

describe('parseCodexEvents', () => {
  test('happy path: thread id + final message', () => {
    const r = parseCodexEvents(HAPPY)
    expect(r.ok).toBe(true)
    expect(r.threadId).toBe('019f4576-8f36-72b2-80f6-0ab9a3adbed4')
    expect(r.messages).toEqual(['pong'])
  })

  test('multiple agent messages: all collected, in order', () => {
    const jsonl = [
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"working on it"}}',
      '{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls"}}',
      '{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"done"}}',
      '{"type":"turn.completed","usage":{}}',
    ].join('\n')
    const r = parseCodexEvents(jsonl)
    expect(r.messages).toEqual(['working on it', 'done'])
    expect(r.messages.at(-1)).toBe('done')
  })

  test('turn.failed surfaces the error', () => {
    const jsonl = [
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"turn.failed","error":{"message":"model overloaded"}}',
    ].join('\n')
    const r = parseCodexEvents(jsonl)
    expect(r.ok).toBe(false)
    expect(r.error).toBe('model overloaded')
    expect(r.threadId).toBe('t1') // still captured — session may be resumable
  })

  test('truncated stream (no turn.completed) is not ok', () => {
    const r = parseCodexEvents('{"type":"thread.started","thread_id":"t1"}\n{"type":"turn.started"}')
    expect(r.ok).toBe(false)
  })

  test('non-JSON noise between events is ignored', () => {
    const r = parseCodexEvents('some warning\n' + HAPPY + '\ntrailing junk')
    expect(r.ok).toBe(true)
    expect(r.messages).toEqual(['pong'])
  })

  test('valid JSON scalars and arrays are ignored as protocol noise', () => {
    const r = parseCodexEvents([
      'null',
      '42',
      '[]',
      '{"type":"item.completed","item":{"type":"agent_message","text":"safe"}}',
      '{"type":"turn.completed"}',
    ].join('\n'))
    expect(r.ok).toBe(true)
    expect(r.messages).toEqual(['safe'])
  })

  test('empty stream is not ok', () => {
    expect(parseCodexEvents('').ok).toBe(false)
  })
})

describe('buildCodexArgs', () => {
  test('Git read access excludes hooks, credentials, fetch URLs, and nested module config', () => {
    const denied = workspaceSecretDenyPaths('/workspace')
    expect(denied).toContain('/workspace/.git/hooks/**')
    expect(denied).toContain('/workspace/.git/credentials')
    expect(denied).toContain('/workspace/.git/FETCH_HEAD')
    expect(denied).toContain('/workspace/.git/modules/**/config')
    expect(denied).toContain('/workspace/.git/modules/**/hooks/**')
  })

  const cfg: CodexConfig = { cwd: '/x', timeoutMs: 1000 }

  test('fresh thread uses exec with stdin prompt', () => {
    const args = buildCodexArgs(null, cfg)
    expect(args[0]).toBe('exec')
    expect(args).toContain('--json')
    expect(args).toContain('--skip-git-repo-check')
    expect(args).toContain('--ignore-user-config')
    expect(args).toContain('--ignore-rules')
    expect(args).toContain('multi_agent')
    expect(args).toContain('--disable')
    expect(args).toContain('plugins')
    expect(args).toContain('apps')
    expect(args).toContain('computer_use')
    expect(args).toContain('goals')
    expect(args).toContain('memories')
    expect(args).toContain('chronicle')
    expect(args).toContain('workspace_dependencies')
    expect(args).toContain('shell_snapshot')
    expect(args).toContain('hooks')
    const disabled = args.flatMap((value, index) => value === '--disable' ? [args[index + 1]] : [])
    expect(disabled).not.toContain('multi_agent')
    expect(args.join(' ')).toContain('mcp_servers={}')
    expect(args.join(' ')).toContain(`model="${DEFAULT_CODEX_MODEL}"`)
    expect(args.join(' ')).toContain(`model_reasoning_effort="${DEFAULT_CODEX_REASONING_EFFORT}"`)
    expect(args.join(' ')).toContain('allow_login_shell=false')
    expect(args.join(' ')).toContain('forced_login_method="chatgpt"')
    expect(args.join(' ')).toContain('cli_auth_credentials_store="file"')
    expect(args.join(' ')).toContain('web_search="disabled"')
    expect(args.join(' ')).toContain('shell_environment_policy.inherit="all"')
    expect(args.join(' ')).toContain('shell_environment_policy.set={}')
    expect(args.join(' ')).toContain(`default_permissions="${CODEX_PERMISSION_PROFILE}"`)
    expect(args.join(' ')).toContain(`permissions.${CODEX_PERMISSION_PROFILE}.extends=":workspace"`)
    expect(args.join(' ')).toContain(`permissions.${CODEX_PERMISSION_PROFILE}.network.enabled=false`)
    expect(args.join(' ')).toContain('"/x/.codex"="read"')
    expect(args.join(' ')).toContain('"/x/.claude"="read"')
    expect(args.at(-1)).toBe('-')
    expect(args.join(' ')).not.toContain('sandbox_mode')
    expect(args.join(' ')).not.toContain('sandbox_workspace_write')
    expect(args).not.toContain('resume')
  })

  test('only absolute non-root active attachment paths extend filesystem read access', () => {
    const filesystem = buildPermissionFilesystem([
      '/private/current turn', '/private/current turn', 'relative', '/',
    ])
    expect(filesystem).toContain('":root"="deny"')
    expect(filesystem).toContain('":minimal"="read"')
    expect(filesystem).toContain('":tmpdir"="deny"')
    expect(filesystem).toContain('":slash_tmp"="deny"')
    expect(filesystem).toContain('"/private/current turn"="read"')
    expect(filesystem.match(/\/private\/current turn/g)?.length).toBe(1)
    expect(filesystem).not.toContain('relative')

    const args = buildCodexArgs(null, cfg, ['/private/current turn'])
    expect(args.join(' ')).toContain('"/private/current turn"="read"')
  })

  test('App Server threads receive the exact nested permission and fixed-environment config', () => {
    const config = buildAppServerThreadConfig(
      '/workspace',
      ['/runtime/read', 'relative-read', '/'],
      ['/workspace/private', 'relative-deny'],
      ['/runtime/write', '/'],
      {
        PATH: '/fixed/bin',
        TMPDIR: '/runtime/write',
        OPENAI_API_KEY: 'must-not-cross',
        UNLISTED: 'must-not-cross',
      },
    )
    expect(config).toEqual({
      model_reasoning_effort: DEFAULT_CODEX_REASONING_EFFORT,
      default_permissions: CODEX_PERMISSION_PROFILE,
      permissions: {
        [CODEX_PERMISSION_PROFILE]: {
          extends: ':workspace',
          filesystem: buildPermissionFilesystemConfig([
            '/workspace/.codex',
            '/workspace/.agents',
            '/workspace/.claude',
            '/workspace/.gitleaks.toml',
            '/workspace/AGENTS.md',
            '/workspace/CLAUDE.md',
            '/workspace/TEAM_LEAD.md',
            '/workspace/ESCALATION.md',
            '/workspace/CONVERSATION.md',
            '/workspace/EVALUATION.md',
            '/workspace/SURFACING.md',
            '/workspace/MEMORY.md',
            '/workspace/READINESS_BAR.md',
            '/workspace/CPO_BUS_PROTOCOL.md',
            '/runtime/read',
          ], [
            ...workspaceSecretDenyPaths('/workspace'),
            '/workspace/.swarm-*',
            '/workspace/private',
          ], ['/runtime/write']),
          network: { enabled: false },
        },
      },
      approval_policy: 'never',
      forced_login_method: 'chatgpt',
      cli_auth_credentials_store: 'file',
      allow_login_shell: false,
      web_search: 'disabled',
      shell_environment_policy: {
        inherit: 'none',
        set: { PATH: '/fixed/bin', TMPDIR: '/runtime/write' },
        experimental_use_profile: false,
        ignore_default_excludes: false,
      },
    })
  })

  test('existing thread uses exec resume <id>', () => {
    const args = buildCodexArgs('t-123', cfg)
    expect(args.slice(0, 3)).toEqual(['exec', 'resume', 't-123'])
    expect(args.at(-1)).toBe('-')
    // resume rejects -m; model and permissions must ride as -c overrides.
    expect(args).not.toContain('-s')
    expect(args).not.toContain('-m')
  })

  test('model and profile are passed when set', () => {
    const args = buildCodexArgs(null, {
      ...cfg,
      model: 'gpt-test-override',
      reasoningEffort: CPO_CODEX_REASONING_EFFORT,
      profile: 'swarm',
    })
    expect(args.join(' ')).toContain('model="gpt-test-override"')
    expect(args.join(' ')).toContain('model_reasoning_effort="medium"')
    expect(args.slice(0, 3)).toEqual(['-p', 'swarm', 'exec'])
  })

  test('App Server thread config carries the selected CPO effort', () => {
    const config = buildAppServerThreadConfig(
      '/workspace', [], [], [], {}, CPO_CODEX_REASONING_EFFORT,
    )
    expect(config.model_reasoning_effort).toBe('medium')
  })

  test('unattended turns disable command hooks and never bypass hook trust', () => {
    const args = buildCodexArgs(null, cfg)
    const disabled = args.flatMap((value, index) => value === '--disable' ? [args[index + 1]] : [])
    expect(disabled).toContain('hooks')
    expect(args).not.toContain('--dangerously-bypass-hook-trust')
  })

  const codexBin = Bun.which('codex')
  const codexArgv = (() => {
    if (!codexBin) return null
    const prefix = readFileSync(realpathSync(codexBin)).subarray(0, 64).toString('utf8')
    if (!prefix.startsWith('#!/usr/bin/env node')) return [codexBin]
    const node = Bun.which('node')
    return node ? [node, codexBin] : null
  })()
  test('required CI sandbox runtime cannot be silently skipped', () => {
    if (process.env.QOFI_REQUIRE_CODEX_SANDBOX === '1') {
      expect(codexArgv, 'CI must install the pinned Codex CLI and its interpreter for real sandbox tests').not.toBeNull()
    }
  })
  test.skipIf(!codexArgv)('custom profile denies host secrets while preserving repo read/write', () => {
    const dir = mkdtempSync(join(process.cwd(), '.codex-sandbox-contract-'))
    const fallbackHostDir = mkdtempSync(join(tmpdir(), 'codex-host-secret-'))
    const fallbackHostSecret = join(fallbackHostDir, 'secret.txt')
    writeFileSync(fallbackHostSecret, 'host-secret')
    const authFile = join(homedir(), '.codex', 'auth.json')
    const hostSecret = existsSync(authFile) ? authFile : fallbackHostSecret
    writeFileSync(join(dir, 'repo-readable'), 'repo-data')
    mkdirSync(join(dir, '.codex'), { recursive: true })
    mkdirSync(join(dir, '.claude', 'hooks'), { recursive: true })
    mkdirSync(join(dir, '.claude', 'worktrees', 'teammate'), { recursive: true })
    writeFileSync(join(dir, '.codex', 'config.toml'), '# safe-config\n')
    writeFileSync(join(dir, '.claude', 'hooks', 'stop.sh'), 'safe-hook')
    writeFileSync(join(dir, '.claude', 'settings.json'), '{}')
    writeFileSync(join(dir, '.claude', 'worktrees', 'teammate', '.git'), 'gitdir: /operator/private\n')
    writeFileSync(join(dir, '.claude', 'worktrees', 'teammate', 'private.txt'), 'claude-private\n')
    writeFileSync(join(dir, 'AGENTS.md'), 'managed doctrine')
    writeFileSync(join(dir, 'PROJECT_SPEC.md'), 'authored spec')
    writeFileSync(join(dir, '.gitleaks.toml'), 'managed enforcement')
    writeFileSync(join(dir, '.env'), 'TOP_SECRET=value')
    writeFileSync(join(dir, '.env.example'), 'PUBLIC_NAME=')
    mkdirSync(join(dir, 'nested'), { recursive: true })
    writeFileSync(join(dir, 'nested', 'tokens.env'), 'BOT_TOKEN=value')
    writeFileSync(join(dir, 'package.json'), '{"name":"sandbox-smoke","private":true}')
    writeFileSync(join(dir, 'smoke.test.ts'), `import {expect,test} from 'bun:test'; test('smoke',()=>expect(2+2).toBe(4))\n`)
    if (Bun.which('go')) {
      writeFileSync(join(dir, 'go.mod'), 'module example.test/sandbox-smoke\n\ngo 1.20\n')
      mkdirSync(join(dir, 'go-smoke'))
      writeFileSync(join(dir, 'go-smoke', 'main_test.go'), `package gosmoke\nimport "testing"\nfunc TestSmoke(t *testing.T) {}\n`)
    }
    if (Bun.which('cargo') && Bun.which('rustc')) {
      mkdirSync(join(dir, 'cargo-smoke', 'src'), { recursive: true })
      writeFileSync(join(dir, 'cargo-smoke', 'Cargo.toml'), `[package]\nname="sandbox-smoke"\nversion="0.1.0"\nedition="2021"\n`)
      writeFileSync(join(dir, 'cargo-smoke', 'src', 'main.rs'), 'fn main() { assert_eq!(2 + 2, 4); }\n')
    }
    if (Bun.which('rustc')) writeFileSync(join(dir, 'rust-smoke.rs'), 'fn main() { assert_eq!(2 + 2, 4); }\n')
    if (Bun.which('swiftc')) writeFileSync(join(dir, 'swift-smoke.swift'), 'precondition(2 + 2 == 4)\n')
    if (Bun.which('clang') || Bun.which('xcrun')) writeFileSync(join(dir, 'clang-smoke.c'), 'int main(void) { return 0; }\n')
    const toolchain = resolveToolchainPlan(dir)
    const gitInit = Bun.spawnSync([toolchain.executables.git, 'init', '-q'], {
      cwd: dir, stdout: 'pipe', stderr: 'pipe',
    })
    expect(gitInit.exitCode, gitInit.stderr.toString()).toBe(0)
    writeFileSync(join(dir, '.git', 'hooks', 'qofi-probe'), 'original-hook\n')
    writeFileSync(join(dir, '.git', 'credentials'), 'https://user:secret@example.invalid\n')
    writeFileSync(join(dir, '.git', 'FETCH_HEAD'), 'deadbeef\thttps://user:secret@example.invalid\n')
    mkdirSync(join(dir, '.git', 'modules', 'nested', 'hooks'), { recursive: true })
    writeFileSync(join(dir, '.git', 'modules', 'nested', 'config'), '[remote "origin"]\nurl=https://user:secret@example.invalid\n')
    writeFileSync(join(dir, '.git', 'modules', 'nested', 'hooks', 'post-checkout'), 'embedded-secret\n')
    const gitBase = Bun.spawnSync([
      toolchain.executables.git,
      '-c', 'user.name=Sandbox Fixture', '-c', 'user.email=fixture@example.test',
      'add', 'repo-readable',
    ], { cwd: dir, stdout: 'pipe', stderr: 'pipe' })
    expect(gitBase.exitCode, gitBase.stderr.toString()).toBe(0)
    const gitCommit = Bun.spawnSync([
      toolchain.executables.git,
      '-c', 'user.name=Sandbox Fixture', '-c', 'user.email=fixture@example.test',
      'commit', '--no-verify', '-qm', 'sandbox base',
    ], { cwd: dir, stdout: 'pipe', stderr: 'pipe' })
    expect(gitCommit.exitCode, gitCommit.stderr.toString()).toBe(0)
    const originalGitConfig = readFileSync(join(dir, '.git', 'config'), 'utf8')
    // Keep the explicit per-turn grant outside both the selected workspace and
    // the process TMPDIR. A path nested below TMPDIR is intentionally covered
    // by the stronger `:tmpdir = deny` rule and cannot demonstrate the narrow
    // production regrant used by the Discord daemon.
    const turnTempRoot = mkdtempSync(join(process.cwd(), '.codex-turn-contract-'))
    const turnTemp = join(realpathSync(turnTempRoot), 'turn-tmp')
    mkdirSync(turnTemp, { recursive: true, mode: 0o700 })
    const shimDir = createToolShims(join(realpathSync(fallbackHostDir), 'tool-shims'), toolchain)
    const turnEnv = safeTurnEnvironment(turnTemp, toolchain, shimDir)
    const ambientTemp = realpathSync(process.env.TMPDIR ?? tmpdir())
    const sandboxEnv = {
      ...process.env,
      ...turnEnv,
      // `codex sandbox` resolves `:tmpdir` from its own environment. Keep that
      // ambient path distinct, then install the turn environment inside the
      // sandbox just as App Server does through shell_environment_policy.set.
      TMPDIR: ambientTemp,
      TMP: ambientTemp,
      TEMP: ambientTemp,
    }
    const workspacePolicy = discoverWorkspacePolicy(dir)
    const processCanary = `QOFI_HOST_PROCESS_CANARY_${Date.now()}`
    const hostProcess = Bun.spawn(['/bin/sh', '-c', 'sleep 30'], {
      env: { PATH: '/bin:/usr/bin', QOFI_HOST_PROCESS_CANARY: processCanary },
      stdout: 'ignore', stderr: 'ignore',
    })
    try {
      const result = Bun.spawnSync([
        ...codexArgv!,
        'sandbox',
        '-P', CODEX_PERMISSION_PROFILE,
        '-C', dir,
        ...buildPermissionProfileArgs(
          [...toolchain.readableRoots, shimDir, ...workspacePolicy.readableExamples],
          false,
          dir,
          workspacePolicy.deniedPaths,
          [turnTemp],
        ),
        '--', '/bin/sh', '-c', [
          'export TMPDIR="$4" TMP="$4" TEMP="$4"',
          'if cat "$1" >/dev/null 2>&1; then echo HOST_READABLE; else echo HOST_DENIED; fi',
          'if cat repo-readable >/dev/null 2>&1; then echo REPO_READABLE; else echo REPO_DENIED; fi',
          'if printf safe > repo-written 2>/dev/null; then echo REPO_WRITABLE; else echo REPO_WRITE_DENIED; fi',
          'if printf unsafe > .codex/config.toml 2>/dev/null; then echo CODEX_WRITABLE; else echo CODEX_WRITE_DENIED; fi',
          'if printf unsafe > .claude/hooks/stop.sh 2>/dev/null; then echo HOOK_WRITABLE; else echo HOOK_WRITE_DENIED; fi',
          'if printf unsafe > .claude/settings.json 2>/dev/null; then echo SETTINGS_WRITABLE; else echo SETTINGS_WRITE_DENIED; fi',
          'if cat .claude/worktrees/teammate/private.txt >/dev/null 2>&1; then echo CLAUDE_WORKTREE_READABLE; else echo CLAUDE_WORKTREE_READ_DENIED; fi',
          'if printf unsafe > .claude/worktrees/teammate/private.txt 2>/dev/null; then echo CLAUDE_WORKTREE_WRITABLE; else echo CLAUDE_WORKTREE_WRITE_DENIED; fi',
          'if printf unsafe > AGENTS.md 2>/dev/null; then echo DOCTRINE_WRITABLE; else echo DOCTRINE_WRITE_DENIED; fi',
          'if printf unsafe > doctrine-replacement && mv -f doctrine-replacement AGENTS.md 2>/dev/null; then echo DOCTRINE_REPLACED; else rm -f doctrine-replacement; echo DOCTRINE_REPLACE_DENIED; fi',
          'if printf authored > PROJECT_SPEC.md 2>/dev/null; then echo PROJECT_SPEC_WRITABLE; else echo PROJECT_SPEC_WRITE_DENIED; fi',
          'if printf unsafe > .gitleaks.toml 2>/dev/null; then echo GITLEAKS_WRITABLE; else echo GITLEAKS_WRITE_DENIED; fi',
          'if mv .codex .codex-runtime-moved 2>/dev/null; then echo CODEX_DIR_RENAMED; else echo CODEX_DIR_RENAME_DENIED; fi',
          'if cat .env >/dev/null 2>&1; then echo ENV_READABLE; else echo ENV_DENIED; fi',
          'if cat .env.example >/dev/null 2>&1; then echo ENV_EXAMPLE_OK; else echo ENV_EXAMPLE_DENIED; fi',
          'if cat nested/tokens.env >/dev/null 2>&1; then echo TOKENS_READABLE; else echo TOKENS_DENIED; fi',
          'gout=$(git status --short 2>&1); if [ $? -eq 0 ] && ! printf "%s" "$gout" | grep -q "Operation not permitted" && git diff --no-ext-diff >/dev/null 2>&1; then echo GIT_OK; else echo GIT_DENIED; fi',
          'if printf unsafe > .git/config 2>/dev/null; then echo GIT_CONFIG_WRITABLE; else echo GIT_CONFIG_WRITE_DENIED; fi',
          'if printf unsafe > .git/hooks/qofi-probe 2>/dev/null; then echo GIT_HOOK_WRITABLE; else echo GIT_HOOK_WRITE_DENIED; fi',
          'if cat .git/hooks/qofi-probe >/dev/null 2>&1; then echo GIT_HOOK_READABLE; else echo GIT_HOOK_READ_DENIED; fi',
          'if cat .git/credentials >/dev/null 2>&1; then echo GIT_CREDENTIALS_READABLE; else echo GIT_CREDENTIALS_DENIED; fi',
          'if cat .git/FETCH_HEAD >/dev/null 2>&1; then echo GIT_FETCH_HEAD_READABLE; else echo GIT_FETCH_HEAD_DENIED; fi',
          'if cat .git/modules/nested/config >/dev/null 2>&1; then echo GIT_MODULE_CONFIG_READABLE; else echo GIT_MODULE_CONFIG_DENIED; fi',
          'if cat .git/modules/nested/hooks/post-checkout >/dev/null 2>&1; then echo GIT_MODULE_HOOK_READABLE; else echo GIT_MODULE_HOOK_DENIED; fi',
          'head_before=$(git rev-parse HEAD 2>/dev/null)',
          'if git add repo-written >/dev/null 2>&1; then echo GIT_ADD_MUTATED; else echo GIT_ADD_DENIED; fi',
          'if git branch sandbox-mutation >/dev/null 2>&1; then echo GIT_BRANCH_MUTATED; else echo GIT_BRANCH_DENIED; fi',
          'if git -c user.name=Sandbox -c user.email=sandbox@example.test commit -m unsafe >/dev/null 2>&1; then echo GIT_COMMIT_MUTATED; else echo GIT_COMMIT_DENIED; fi',
          'head_after=$(git rev-parse HEAD 2>/dev/null); if [ "$head_before" = "$head_after" ] && ! git show-ref --verify --quiet refs/heads/sandbox-mutation && git diff --cached --quiet; then echo GIT_METADATA_UNCHANGED; else echo GIT_METADATA_CHANGED; fi',
          'if mv .git .git-runtime-moved 2>/dev/null; then echo GIT_ROOT_RENAMED; else echo GIT_ROOT_RENAME_DENIED; fi',
          'if python3 -c "print(1)" >/dev/null 2>&1; then echo PYTHON_OK; else echo PYTHON_DENIED; fi',
          toolchain.executables.node
            ? 'if node -e "process.exit(0)"; then echo NODE_OK; else echo NODE_DENIED; fi'
            : 'echo NODE_OPTIONAL',
          'if bun --version >/dev/null 2>&1; then echo BUN_OK; else echo BUN_DENIED; fi',
          toolchain.executables.npm
            ? 'if npm --version >/dev/null 2>&1; then echo NPM_OK; else echo NPM_DENIED; fi'
            : 'echo NPM_OPTIONAL',
          toolchain.executables.uv
            ? 'if uv --version >/dev/null 2>&1; then echo UV_OK; else echo UV_DENIED; fi'
            : 'echo UV_OPTIONAL',
          toolchain.executables.go
            ? 'if go test ./go-smoke >/dev/null 2>&1; then echo GO_BUILD_OK; else echo GO_BUILD_DENIED; fi'
            : 'echo GO_BUILD_OPTIONAL',
          toolchain.executables.rustc
            ? 'if rustc rust-smoke.rs -o "$TMPDIR/rust-smoke" >/dev/null 2>&1 && "$TMPDIR/rust-smoke"; then echo RUST_BUILD_OK; else echo RUST_BUILD_DENIED; fi'
            : 'echo RUST_BUILD_OPTIONAL',
          toolchain.executables.cargo && toolchain.executables.rustc
            ? 'if cargo build --manifest-path cargo-smoke/Cargo.toml >/dev/null 2>&1; then echo CARGO_BUILD_OK; else echo CARGO_BUILD_DENIED; fi'
            : 'echo CARGO_BUILD_OPTIONAL',
          toolchain.executables.swift && toolchain.executables.xcrun
            ? 'if swift --version >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1; then echo SWIFT_OK; else echo SWIFT_DENIED; fi'
            : 'echo SWIFT_OPTIONAL',
          toolchain.executables.swiftc
            ? toolchain.executables.xcrun && toolchain.readableRoots.includes('/Applications/Xcode.app/Contents/Developer')
              ? 'if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc swift-smoke.swift -o "$TMPDIR/swift-smoke" >/dev/null 2>&1 && "$TMPDIR/swift-smoke"; then echo SWIFT_BUILD_OK; else echo SWIFT_BUILD_DENIED; fi'
              : 'if swiftc swift-smoke.swift -o "$TMPDIR/swift-smoke" >/dev/null 2>&1 && "$TMPDIR/swift-smoke"; then echo SWIFT_BUILD_OK; else echo SWIFT_BUILD_DENIED; fi'
            : 'echo SWIFT_BUILD_OPTIONAL',
          toolchain.executables.xcodebuild && toolchain.readableRoots.includes('/Applications/Xcode.app/Contents/Developer')
            ? 'if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version >/dev/null 2>&1; then echo XCODE_OK; else echo XCODE_DENIED; fi'
            : 'echo XCODE_OPTIONAL',
          toolchain.executables.xcrun
            && toolchain.readableRoots.includes('/Applications/Xcode.app/Contents/Developer')
            ? 'if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun clang clang-smoke.c -o "$TMPDIR/clang-smoke" >/dev/null 2>&1 && "$TMPDIR/clang-smoke"; then echo XCODE_BUILD_OK; else echo XCODE_BUILD_DENIED; fi'
            : 'echo XCODE_BUILD_OPTIONAL',
          'if printf temp > "$TMPDIR/qofi-turn-temp-probe" 2>/dev/null && rm -f "$TMPDIR/qofi-turn-temp-probe"; then echo TURN_TEMP_OK; else echo TURN_TEMP_DENIED; fi',
          'if printf unsafe > "$5/qofi-codex-ambient-temp-$$" 2>/dev/null; then rm -f "$5/qofi-codex-ambient-temp-$$"; echo AMBIENT_TEMP_WRITABLE; else echo AMBIENT_TEMP_DENIED; fi',
          'if bun test smoke.test.ts >/dev/null 2>&1; then echo TEST_OK; else echo TEST_DENIED; fi',
          'if ps eww -p "$2" 2>/dev/null | grep -q "$3"; then echo PROCESS_ENV_EXPOSED; else echo PROCESS_ENV_DENIED; fi',
        ].join('; '), 'sandbox-contract', hostSecret, String(hostProcess.pid), processCanary,
        turnTemp, ambientTemp,
      ], { cwd: dir, stdout: 'pipe', stderr: 'pipe', env: sandboxEnv })
      const stdout = result.stdout.toString()
      expect(result.exitCode, result.stderr.toString()).toBe(0)
      expect(stdout).toContain('HOST_DENIED')
      expect(stdout).toContain('REPO_READABLE')
      expect(stdout).toContain('REPO_WRITABLE')
      expect(stdout).toContain('CODEX_WRITE_DENIED')
      expect(stdout).toContain('HOOK_WRITE_DENIED')
      expect(stdout).toContain('SETTINGS_WRITE_DENIED')
      expect(stdout).toContain('CLAUDE_WORKTREE_READ_DENIED')
      expect(stdout).toContain('CLAUDE_WORKTREE_WRITE_DENIED')
      expect(stdout).toContain('DOCTRINE_WRITE_DENIED')
      expect(stdout).toContain('DOCTRINE_REPLACE_DENIED')
      expect(stdout).toContain('PROJECT_SPEC_WRITABLE')
      expect(stdout).toContain('GITLEAKS_WRITE_DENIED')
      expect(stdout).toContain('CODEX_DIR_RENAME_DENIED')
      expect(stdout).toContain('ENV_DENIED')
      expect(stdout).toContain('ENV_EXAMPLE_OK')
      expect(stdout).toContain('TOKENS_DENIED')
      expect(stdout).toContain('GIT_OK')
      expect(stdout).toContain('GIT_CONFIG_WRITE_DENIED')
      expect(stdout).toContain('GIT_HOOK_WRITE_DENIED')
      expect(stdout).toContain('GIT_HOOK_READ_DENIED')
      expect(stdout).toContain('GIT_CREDENTIALS_DENIED')
      expect(stdout).toContain('GIT_FETCH_HEAD_DENIED')
      expect(stdout).toContain('GIT_MODULE_CONFIG_DENIED')
      expect(stdout).toContain('GIT_MODULE_HOOK_DENIED')
      expect(stdout).toContain('GIT_ADD_DENIED')
      expect(stdout).toContain('GIT_BRANCH_DENIED')
      expect(stdout).toContain('GIT_COMMIT_DENIED')
      expect(stdout).toContain('GIT_METADATA_UNCHANGED')
      expect(stdout).toContain('GIT_ROOT_RENAME_DENIED')
      expect(stdout).toContain('PYTHON_OK')
      expect(stdout).toContain(toolchain.executables.node ? 'NODE_OK' : 'NODE_OPTIONAL')
      expect(stdout).toContain('BUN_OK')
      expect(stdout).toContain(toolchain.executables.npm ? 'NPM_OK' : 'NPM_OPTIONAL')
      expect(stdout).toContain(toolchain.executables.uv ? 'UV_OK' : 'UV_OPTIONAL')
      expect(stdout).toContain(toolchain.executables.go ? 'GO_BUILD_OK' : 'GO_BUILD_OPTIONAL')
      expect(stdout).toContain(toolchain.executables.rustc ? 'RUST_BUILD_OK' : 'RUST_BUILD_OPTIONAL')
      expect(stdout).toContain(
        toolchain.executables.cargo && toolchain.executables.rustc
          ? 'CARGO_BUILD_OK'
          : 'CARGO_BUILD_OPTIONAL',
      )
      expect(stdout).toContain(
        toolchain.executables.swift && toolchain.executables.xcrun ? 'SWIFT_OK' : 'SWIFT_OPTIONAL',
      )
      expect(stdout).toContain(toolchain.executables.swiftc ? 'SWIFT_BUILD_OK' : 'SWIFT_BUILD_OPTIONAL')
      expect(stdout).toContain(
        toolchain.executables.xcodebuild
          && toolchain.readableRoots.includes('/Applications/Xcode.app/Contents/Developer')
          ? 'XCODE_OK'
          : 'XCODE_OPTIONAL',
      )
      expect(stdout).toContain(
        toolchain.executables.xcrun
          && toolchain.readableRoots.includes('/Applications/Xcode.app/Contents/Developer')
          ? 'XCODE_BUILD_OK'
          : 'XCODE_BUILD_OPTIONAL',
      )
      expect(stdout).toContain('TURN_TEMP_OK')
      expect(stdout).toContain('AMBIENT_TEMP_DENIED')
      expect(stdout).toContain('TEST_OK')
      expect(stdout).toContain('PROCESS_ENV_DENIED')
      expect(readFileSync(join(dir, '.codex', 'config.toml'), 'utf8')).toBe('# safe-config\n')
      expect(readFileSync(join(dir, 'AGENTS.md'), 'utf8')).toBe('managed doctrine')
      expect(readFileSync(join(dir, '.claude', 'hooks', 'stop.sh'), 'utf8')).toBe('safe-hook')
      expect(readFileSync(join(dir, '.claude', 'worktrees', 'teammate', 'private.txt'), 'utf8')).toBe('claude-private\n')
      expect(readFileSync(join(dir, '.git', 'config'), 'utf8')).toBe(originalGitConfig)
      expect(readFileSync(join(dir, '.git', 'hooks', 'qofi-probe'), 'utf8')).toBe('original-hook\n')
    } finally {
      try { hostProcess.kill() } catch {}
      rmSync(dir, { recursive: true, force: true })
      rmSync(fallbackHostDir, { recursive: true, force: true })
      rmSync(turnTempRoot, { recursive: true, force: true })
    }
  }, 30_000)

  test.skipIf(!codexArgv)('custom profile cannot rewrite a linked-worktree .git pointer', () => {
    const root = mkdtempSync(join(process.cwd(), '.codex-linked-sandbox-contract-'))
    const main = join(root, 'main')
    const linked = join(root, 'linked')
    const privateRoot = mkdtempSync(join(tmpdir(), 'codex-linked-private-'))
    mkdirSync(main)
    const hostGit = Bun.which('git')!
    const runGit = (args: string[]) => Bun.spawnSync([hostGit, ...args], {
      cwd: main, stdout: 'pipe', stderr: 'pipe',
    })
    try {
      expect(runGit(['init', '-q']).exitCode).toBe(0)
      writeFileSync(join(main, 'base.txt'), 'base\n')
      expect(runGit(['add', 'base.txt']).exitCode).toBe(0)
      expect(runGit([
        '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
        'commit', '--no-verify', '-qm', 'base',
      ]).exitCode).toBe(0)
      expect(runGit(['worktree', 'add', '-q', '-b', 'feature/linked', linked]).exitCode).toBe(0)
      const pointer = readFileSync(join(linked, '.git'), 'utf8')
      const plan = resolveToolchainPlan(linked)
      const turnTemp = join(privateRoot, 'tmp')
      mkdirSync(turnTemp, { mode: 0o700 })
      const shim = createToolShims(join(privateRoot, 'shims'), plan)
      const result = Bun.spawnSync([
        ...codexArgv!, 'sandbox', '-P', CODEX_PERMISSION_PROFILE, '-C', linked,
        ...buildPermissionProfileArgs(plan.readableRoots, false, linked, [], [turnTemp]),
        '--', '/bin/sh', '-c',
        'if printf unsafe > .git 2>/dev/null; then echo POINTER_WRITABLE; else echo POINTER_WRITE_DENIED; fi',
      ], {
        cwd: linked,
        stdout: 'pipe', stderr: 'pipe',
        env: { ...process.env, ...safeTurnEnvironment(turnTemp, plan, shim) },
      })
      expect(result.exitCode, result.stderr.toString()).toBe(0)
      expect(result.stdout.toString()).toContain('POINTER_WRITE_DENIED')
      expect(readFileSync(join(linked, '.git'), 'utf8')).toBe(pointer)
    } finally {
      rmSync(root, { recursive: true, force: true })
      rmSync(privateRoot, { recursive: true, force: true })
    }
  }, 30_000)
})

describe('runner hardening', () => {
  test('sanitized child env removes secret-like variables', () => {
    const clean = sanitizedCodexEnv({
      PATH: '/bin',
      DISCORD_BOT_TOKEN: 'discord-secret',
      OPENAI_API_KEY: 'openai-secret',
      CODEX_API_KEY: 'codex-secret',
      GH_TOKEN: 'github-secret',
      AWS_ACCESS_KEY_ID: 'aws-secret',
      DATABASE_URL: 'postgres://secret',
      SSH_AUTH_SOCK: '/tmp/agent.sock',
      BASH_ENV: '/tmp/host-startup.sh',
      SWARM_HOME: '/safe',
      CODEX_BRIDGE_OPERATOR_CANARY_VALUE: 'parent-only-witness',
      CODEX_BRIDGE_ENV_ALLOWLIST: 'SWARM_HOME,AWS_ACCESS_KEY_ID,BASH_ENV,CODEX_BRIDGE_OPERATOR_CANARY_VALUE',
    })
    expect(clean).toEqual({ PATH: '/bin', SWARM_HOME: '/safe' })
  })

  test('operator allowlist adds only non-credential project variables', () => {
    expect(sanitizedCodexEnv({
      HOME: '/home/test',
      PROJECT_MODE: 'test',
      AWS_REGION: 'us-east-1',
      CODEX_BRIDGE_ENV_ALLOWLIST: 'PROJECT_MODE,AWS_REGION',
    })).toEqual({ HOME: '/home/test', PROJECT_MODE: 'test' })
  })

  test('fixed build/cache environment survives both argv policy and child spawn filtering', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-bridge-build-env-'))
    const bin = join(dir, 'fake-codex')
    writeFileSync(bin, `#!/usr/bin/env bun
process.stdin.resume()
await new Promise(resolve => process.stdin.on('end', resolve))
const text = JSON.stringify({
  go: process.env.GOCACHE,
  cargo: process.env.CARGO_HOME,
  swift: process.env.SWIFT_MODULE_CACHE_PATH,
  xcode: process.env.DERIVED_DATA_DIR,
  argv: process.argv.some(value => value.includes('GOCACHE') && value.includes('CARGO_HOME')),
  injected: process.env.UNSAFE_INJECTED,
})
console.log(JSON.stringify({type:'thread.started',thread_id:'t-env'}))
console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text}}))
console.log(JSON.stringify({type:'turn.completed'}))
`)
    chmodSync(bin, 0o700)
    const plan = resolveToolchainPlan(process.cwd())
    const environment = {
      ...safeTurnEnvironment('/private/turn', plan),
      UNSAFE_INJECTED: 'must-not-pass',
    }
    expect(safeExecutionOverrides(environment)).not.toHaveProperty('UNSAFE_INJECTED')
    try {
      const result = await runCodexTurn(null, 'hello', {
        cwd: dir, timeoutMs: 2000, bin,
      }, { environment })
      expect(result.ok).toBe(true)
      expect(JSON.parse(result.messages[0])).toEqual({
        go: '/private/turn/go-build-cache',
        cargo: '/private/turn/cargo-home',
        swift: '/private/turn/swift-module-cache',
        xcode: '/private/turn/xcode/derived-data',
        argv: true,
      })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('missing-thread classification is narrow', () => {
    expect(isMissingThreadError('no rollout found for thread id abc')).toBe(true)
    expect(isMissingThreadError('thread/resume failed: session not found')).toBe(true)
    expect(isMissingThreadError('model not found')).toBe(false)
    expect(isMissingThreadError('model overloaded')).toBe(false)
  })

  test('fresh retry is limited to confidently missing persisted threads', () => {
    expect(shouldRetryFresh('t1', {
      ok: false, threadId: null, messages: [], error: 'missing', errorKind: 'missing-thread',
    })).toBe(true)
    for (const errorKind of ['timeout', 'turn-failed', 'exit', 'protocol'] as const) {
      expect(shouldRetryFresh('t1', {
        ok: false, threadId: 't1', messages: [], error: errorKind, errorKind,
      })).toBe(false)
    }
    expect(shouldRetryFresh(null, {
      ok: false, threadId: null, messages: [], error: 'missing', errorKind: 'missing-thread',
    })).toBe(false)
  })

  test('runCodexTurn streams events and never exposes parent secrets', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-bridge-runner-'))
    const bin = join(dir, 'fake-codex')
    writeFileSync(bin, `#!/usr/bin/env bun
process.stdin.resume()
await new Promise(resolve => process.stdin.on('end', resolve))
console.log(JSON.stringify({type:'thread.started',thread_id:'t-safe'}))
console.log(JSON.stringify({type:'item.completed',item:{id:'i1',type:'agent_message',text:process.env.DISCORD_BOT_TOKEN ?? 'clean'}}))
console.log(JSON.stringify({type:'turn.completed'}))
`)
    chmodSync(bin, 0o700)
    const old = process.env.DISCORD_BOT_TOKEN
    process.env.DISCORD_BOT_TOKEN = 'must-not-leak'
    try {
      const events: string[] = []
      const result = await runCodexTurn(null, 'hello', {
        cwd: dir, timeoutMs: 2000, bin,
      }, { onEvent: event => events.push(event.type) })
      expect(result).toEqual({ ok: true, threadId: 't-safe', messages: ['clean'] })
      expect(events).toContain('item.completed')
    } finally {
      if (old === undefined) delete process.env.DISCORD_BOT_TOKEN
      else process.env.DISCORD_BOT_TOKEN = old
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('nonzero CLI exit fails even after a parsed turn.completed event', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-bridge-nonzero-'))
    const bin = join(dir, 'fake-codex')
    writeFileSync(bin, `#!/usr/bin/env bun
console.log(JSON.stringify({type:'thread.started',thread_id:'must-not-persist'}))
console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:'premature'}}))
console.log(JSON.stringify({type:'turn.completed'}))
process.exit(7)
`)
    chmodSync(bin, 0o700)
    try {
      const result = await runCodexTurn(null, 'hello', {
        cwd: dir, timeoutMs: 2000, bin,
      })
      expect(result).toMatchObject({ ok: false, errorKind: 'exit' })
      expect(result.error).toContain('exited 7')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('runCodexTurn preserves a JSON event split inside a multibyte UTF-8 code point', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-bridge-utf8-'))
    const bin = join(dir, 'fake-codex')
    writeFileSync(bin, `#!/usr/bin/env bun
const line = Buffer.from(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:'café'}}) + '\\n')
const split = line.indexOf(Buffer.from('é')) + 1
process.stdout.write(line.subarray(0, split))
await Bun.sleep(10)
process.stdout.write(line.subarray(split))
console.log(JSON.stringify({type:'turn.completed'}))
`)
    chmodSync(bin, 0o700)
    try {
      const result = await runCodexTurn(null, 'hello', {
        cwd: dir, timeoutMs: 2000, bin,
      })
      expect(result.ok).toBe(true)
      expect(result.messages).toEqual(['café'])
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('timeout kills the whole child process group before resolving', async () => {
    if (process.platform === 'win32') return
    const dir = mkdtempSync(join(tmpdir(), 'codex-bridge-group-'))
    const bin = join(dir, 'fake-codex')
    const marker = join(dir, 'orphan-wrote')
    writeFileSync(bin, `#!/usr/bin/env bun
Bun.spawn(['/bin/sh','-c','sleep 0.3; touch "$AUDIT_MARKER"'], {env: process.env})
await Bun.sleep(10_000)
`)
    chmodSync(bin, 0o700)
    const old = process.env.AUDIT_MARKER
    const oldAllowlist = process.env.CODEX_BRIDGE_ENV_ALLOWLIST
    process.env.AUDIT_MARKER = marker
    process.env.CODEX_BRIDGE_ENV_ALLOWLIST = 'AUDIT_MARKER'
    try {
      const result = await runCodexTurn(null, 'hello', {
        cwd: dir, timeoutMs: 50, killGraceMs: 20, bin,
      })
      expect(result.errorKind).toBe('timeout')
      await Bun.sleep(400)
      expect(existsSync(marker)).toBe(false)
    } finally {
      if (old === undefined) delete process.env.AUDIT_MARKER
      else process.env.AUDIT_MARKER = old
      if (oldAllowlist === undefined) delete process.env.CODEX_BRIDGE_ENV_ALLOWLIST
      else process.env.CODEX_BRIDGE_ENV_ALLOWLIST = oldAllowlist
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('normal completion also kills backgrounded tool descendants', async () => {
    if (process.platform === 'win32') return
    const dir = mkdtempSync(join(tmpdir(), 'codex-bridge-background-'))
    const bin = join(dir, 'fake-codex')
    const marker = join(dir, 'background-wrote')
    const ready = join(dir, 'background-ready')
    const release = join(dir, 'background-release')
    const pidFile = join(dir, 'background-pid')
    const controlMarker = join(dir, 'control-wrote')
    const controlReady = join(dir, 'control-ready')
    const controlRelease = join(dir, 'control-release')
    const controlPidFile = join(dir, 'control-pid')
    writeFileSync(bin, `#!/usr/bin/env bun
const command = [
  'echo "$$" > "$AUDIT_PID"',
  ': > "$AUDIT_READY"',
  'while [ ! -e "$AUDIT_RELEASE" ]; do sleep 0.01; done',
  ': > "$AUDIT_MARKER"',
].join('; ')
const child = Bun.spawn(['/bin/sh','-c',command], {env: process.env, stdout:'ignore', stderr:'ignore'})
child.unref()
while (!(await Bun.file(process.env.AUDIT_READY).exists())) await Bun.sleep(1)
console.log(JSON.stringify({type:'thread.started',thread_id:'t1'}))
console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:'done'}}))
console.log(JSON.stringify({type:'turn.completed'}))
`)
    chmodSync(bin, 0o700)
    const auditEnvironment: Record<string, string> = {
      AUDIT_MARKER: marker,
      AUDIT_READY: ready,
      AUDIT_RELEASE: release,
      AUDIT_PID: pidFile,
    }
    const oldEnvironment: Record<string, string | undefined> = {}
    for (const name of [...Object.keys(auditEnvironment), 'CODEX_BRIDGE_ENV_ALLOWLIST']) {
      oldEnvironment[name] = process.env[name]
    }
    Object.assign(process.env, auditEnvironment)
    process.env.CODEX_BRIDGE_ENV_ALLOWLIST = Object.keys(auditEnvironment).join(',')
    let controlPid: number | undefined
    let descendantPid: number | undefined

    const waitForFile = async (path: string): Promise<void> => {
      const deadline = Date.now() + 5_000
      while (!existsSync(path)) {
        if (Date.now() >= deadline) throw new Error(`timed out waiting for ${path}`)
        await Bun.sleep(5)
      }
    }
    const readPid = (path: string): number => {
      const pid = Number.parseInt(readFileSync(path, 'utf8').trim(), 10)
      if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error(`invalid descendant pid in ${path}`)
      return pid
    }
    const waitForProcessExit = async (pid: number): Promise<void> => {
      const deadline = Date.now() + 5_000
      while (true) {
        try {
          process.kill(pid, 0)
        } catch (err) {
          if ((err as NodeJS.ErrnoException).code === 'ESRCH') return
          throw err
        }
        if (Date.now() >= deadline) throw new Error(`timed out waiting for descendant ${pid} to exit`)
        await Bun.sleep(5)
      }
    }
    try {
      // Control: the same fake binary leaves a background descendant that
      // writes successfully when no runner owns/kills its process group.
      const control = Bun.spawn([bin], {
        env: {
          ...process.env,
          AUDIT_MARKER: controlMarker,
          AUDIT_READY: controlReady,
          AUDIT_RELEASE: controlRelease,
          AUDIT_PID: controlPidFile,
        },
        stdout: 'ignore', stderr: 'ignore',
      })
      await control.exited
      await waitForFile(controlReady)
      controlPid = readPid(controlPidFile)
      writeFileSync(controlRelease, '')
      await waitForProcessExit(controlPid)
      controlPid = undefined
      expect(existsSync(controlMarker)).toBe(true)

      const result = await runCodexTurn(null, 'hello', {
        cwd: dir, timeoutMs: 5000, bin,
      })
      expect(result.ok).toBe(true)
      await waitForFile(ready)
      descendantPid = readPid(pidFile)
      writeFileSync(release, '')
      await waitForProcessExit(descendantPid)
      descendantPid = undefined
      expect(existsSync(marker)).toBe(false)
    } finally {
      for (const releasePath of [controlRelease, release]) {
        try { writeFileSync(releasePath, '') } catch {}
      }
      for (const pid of [controlPid, descendantPid]) {
        if (pid === undefined) continue
        try { process.kill(pid, 'SIGKILL') } catch {}
      }
      for (const [name, value] of Object.entries(oldEnvironment)) {
        if (value === undefined) delete process.env[name]
        else process.env[name] = value
      }
      rmSync(dir, { recursive: true, force: true })
    }
  }, 15_000)

  test('stdout limit fails closed after reaping the child', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'codex-bridge-output-'))
    const bin = join(dir, 'fake-codex')
    writeFileSync(bin, `#!/usr/bin/env bun
console.log('x'.repeat(4096))
await Bun.sleep(10_000)
`)
    chmodSync(bin, 0o700)
    try {
      const result = await runCodexTurn(null, 'hello', {
        cwd: dir, timeoutMs: 2000,
        maxStdoutBytes: 512, killGraceMs: 20, bin,
      })
      expect(result.errorKind).toBe('output-limit')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('SessionStore', () => {
  let dir: string
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'codex-bridge-sess-')) })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))

  test('get/set/delete roundtrip', () => {
    const s = new SessionStore(dir)
    expect(s.get('chat1')).toBeNull()
    s.set('chat1', 'thread-a')
    s.set('chat2', 'thread-b')
    const listed = s.list()
    expect(listed).toEqual([
      { chat_id: 'chat1', profile_id: 'default', thread_id: 'thread-a' },
      { chat_id: 'chat2', profile_id: 'default', thread_id: 'thread-b' },
    ])
    listed[0]!.thread_id = 'caller-mutation'
    expect(s.get('chat1')).toBe('thread-a')
    expect(new SessionStore(dir).get('chat2')).toBe('thread-b') // persisted
    s.delete('chat1')
    expect(s.get('chat1')).toBeNull()
    expect(s.get('chat2')).toBe('thread-b')
  })

  test('migrates a private legacy object map on the next write', () => {
    const path = join(dir, 'sessions.json')
    writeFileSync(path, JSON.stringify({ chat1: 'thread-a', chat2: 'thread-b' }), { mode: 0o600 })
    chmodSync(path, 0o600)
    const store = new SessionStore(dir)
    expect(store.get('chat1')).toBe('thread-a')
    store.set('chat3', 'thread-c')
    const persisted = JSON.parse(readFileSync(path, 'utf8'))
    expect(persisted.schema).toBe('codex-bridge-sessions/v2')
    expect(persisted.entries).toEqual([
      { chat_id: 'chat1', profile_id: 'default', thread_id: 'thread-a' },
      { chat_id: 'chat2', profile_id: 'default', thread_id: 'thread-b' },
      { chat_id: 'chat3', profile_id: 'default', thread_id: 'thread-c' },
    ])
  })

  test('migrates schema v1 to default and keeps one thread per chat/profile pair', () => {
    const path = join(dir, 'sessions.json')
    writeFileSync(path, JSON.stringify({
      schema: 'codex-bridge-sessions/v1',
      entries: [{ chat_id: 'chat1', thread_id: 'thread-default' }],
    }), { mode: 0o600 })
    chmodSync(path, 0o600)
    const store = new SessionStore(dir)
    expect(store.get('chat1')).toBe('thread-default')
    expect(store.get('chat1', 'premium_a')).toBeNull()

    store.set('chat1', 'thread-premium', 'premium_a')
    expect(store.list()).toEqual([
      { chat_id: 'chat1', profile_id: 'default', thread_id: 'thread-default' },
      { chat_id: 'chat1', profile_id: 'premium_a', thread_id: 'thread-premium' },
    ])
    expect(store.get('chat1')).toBe('thread-default')
    expect(store.get('chat1', 'premium_a')).toBe('thread-premium')

    store.delete('chat1', 'premium_a')
    expect(store.get('chat1', 'premium_a')).toBeNull()
    expect(store.get('chat1')).toBe('thread-default')
    const persisted = JSON.parse(readFileSync(path, 'utf8'))
    expect(persisted.schema).toBe('codex-bridge-sessions/v2')
    expect(persisted.entries).toEqual([
      { chat_id: 'chat1', profile_id: 'default', thread_id: 'thread-default' },
    ])
  })

  test('malformed, duplicate, oversized, or unsafe existing state is refused without replacement', () => {
    const path = join(dir, 'sessions.json')
    const cases: Array<{ content: string | Buffer; mode?: number }> = [
      { content: 'null', mode: 0o600 },
      { content: '{bad json', mode: 0o600 },
      { content: JSON.stringify({ valid: 'thread-ok', invalid: null }), mode: 0o600 },
      { content: JSON.stringify({ schema: 'future', entries: [] }), mode: 0o600 },
      { content: JSON.stringify({
        schema: 'codex-bridge-sessions/v2',
        entries: [
          { chat_id: 'same', profile_id: 'default', thread_id: 'thread-a' },
          { chat_id: 'same', profile_id: 'default', thread_id: 'thread-b' },
        ],
      }), mode: 0o600 },
      { content: Buffer.alloc(MAX_SESSION_FILE_BYTES + 1, 0x20), mode: 0o600 },
      { content: JSON.stringify({}), mode: 0o644 },
    ]
    for (const invalid of cases) {
      rmSync(path, { force: true })
      writeFileSync(path, invalid.content, { mode: invalid.mode })
      chmodSync(path, invalid.mode!)
      const before = readFileSync(path)
      const store = new SessionStore(dir)
      expect(() => store.get('chat1')).toThrow(SessionStoreError)
      expect(() => store.set('chat1', 'thread1')).toThrow(SessionStoreError)
      expect(readFileSync(path)).toEqual(before)
    }

    rmSync(path)
    const target = join(dir, 'target')
    writeFileSync(target, '{}', { mode: 0o600 })
    symlinkSync(target, path)
    expect(() => new SessionStore(dir).get('chat1')).toThrow(SessionStoreError)
    expect(readFileSync(target, 'utf8')).toBe('{}')
  })

  test('validates identifiers and detects external corruption after caching', () => {
    const path = join(dir, 'sessions.json')
    const store = new SessionStore(dir)
    expect(() => store.get('../escape')).toThrow(SessionStoreError)
    expect(() => store.set('chat', 'bad/thread')).toThrow(SessionStoreError)
    expect(() => store.get('chat', '../profile')).toThrow(SessionStoreError)
    expect(() => store.set('chat', 'thread-ok', 'bad/profile')).toThrow(SessionStoreError)
    store.set('chat', 'thread-ok')
    expect(store.get('chat')).toBe('thread-ok')
    writeFileSync(path, 'null', { mode: 0o600 })
    chmodSync(path, 0o600)
    expect(() => store.get('chat')).toThrow(SessionStoreError)
  })

  test('evicts the deterministic least-recently-successful entry at hard caps', () => {
    const store = new SessionStore(dir)
    for (let i = 0; i < MAX_SESSION_ENTRIES + 2; i++) {
      store.set(`chat${i}`, `thread-${i}`)
    }
    expect(store.get('chat0')).toBeNull()
    expect(store.get('chat1')).toBeNull()
    expect(store.get('chat2')).toBe('thread-2')

    // A successful turn refreshes chat2 to newest; chat3 is now oldest.
    store.set('chat2', 'thread-refreshed')
    store.set('chat-new', 'thread-new')
    expect(store.get('chat2')).toBe('thread-refreshed')
    expect(store.get('chat3')).toBeNull()

    const bytes = readFileSync(join(dir, 'sessions.json'))
    const persisted = JSON.parse(bytes.toString('utf8'))
    expect(persisted.entries).toHaveLength(MAX_SESSION_ENTRIES)
    expect(bytes.byteLength).toBeLessThanOrEqual(MAX_SESSION_FILE_BYTES)
  })
})
