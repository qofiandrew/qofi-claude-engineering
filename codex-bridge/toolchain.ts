import {
  accessSync,
  chmodSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { userInfo } from 'os'
import { delimiter, dirname, isAbsolute, join, parse, resolve, sep } from 'path'

export class ToolchainResolutionError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ToolchainResolutionError'
  }
}

export type ToolchainPlan = {
  readableRoots: string[]
  executables: Record<string, string>
  path: string
  runtimeEnv: Record<string, string>
}

/** Root-provisioned tools and the exact PATH used by the dedicated root runner. */
export const DEDICATED_TOOLCHAIN_ROOT = '/usr/local/libexec/qofi-codex-toolchain'
export const DEDICATED_TOOLCHAIN_BIN = join(DEDICATED_TOOLCHAIN_ROOT, 'bin')
export const DEDICATED_PNPM_VERSION = '9.12.3'
export const DEDICATED_RUNNER_TOOL_PATH = [
  DEDICATED_TOOLCHAIN_BIN,
  DEDICATED_TOOLCHAIN_ROOT,
  '/Library/Developer/CommandLineTools/usr/bin',
  '/usr/bin', '/bin', '/usr/sbin', '/sbin',
].join(delimiter)

function ownerControlled(stat: ReturnType<typeof lstatSync>, requireRootOwned = false): boolean {
  const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
  return (stat.uid === 0 || (!requireRootOwned && stat.uid === uid)) && (stat.mode & 0o022) === 0
}

function assertTrustedDirectoryChain(path: string, label: string, requireRootOwned = false): void {
  let current = realpathSync(path)
  for (;;) {
    const stat = lstatSync(current)
    if (!stat.isDirectory() || stat.isSymbolicLink() || !ownerControlled(stat, requireRootOwned)) {
      throw new ToolchainResolutionError(`${label} has an untrusted parent directory: ${current}`)
    }
    const parent = dirname(current)
    if (parent === current) break
    current = parent
  }
}

function assertTrustedExecutable(
  found: string,
  canonical: string,
  name: string,
  requireRootOwned = false,
): void {
  const target = lstatSync(canonical)
  if (
    !target.isFile()
    || target.isSymbolicLink()
    || !ownerControlled(target, requireRootOwned)
    || (target.mode & 0o111) === 0
  ) throw new ToolchainResolutionError(`unsafe tool executable: ${name}`)

  const invocation = lstatSync(found)
  const uid = typeof process.getuid === 'function' ? process.getuid() : invocation.uid
  if (!invocation.isFile() && !invocation.isSymbolicLink()) {
    throw new ToolchainResolutionError(`tool invocation is not a file/symlink: ${name}`)
  }
  if ((invocation.uid !== 0 && (requireRootOwned || invocation.uid !== uid)) || (
    !invocation.isSymbolicLink() && (invocation.mode & 0o022) !== 0
  )) throw new ToolchainResolutionError(`unsafe tool invocation entry: ${name}`)

  assertTrustedDirectoryChain(dirname(canonical), `tool ${name}`, requireRootOwned)
  assertTrustedDirectoryChain(dirname(found), `tool ${name}`, requireRootOwned)
}

function executableCandidates(
  name: string,
  env: NodeJS.ProcessEnv,
  dedicatedRunnerPath = false,
): string[] {
  const candidates: string[] = []
  if (
    process.platform === 'darwin'
    && (name === 'git' || (!dedicatedRunnerPath && name === 'python3'))
  ) {
    const clt = `/Library/Developer/CommandLineTools/usr/bin/${name}`
    try {
      accessSync(clt, constants.X_OK)
      candidates.push(clt)
    } catch {}
  }
  if (process.platform === 'darwin' && dedicatedRunnerPath && name === 'python3') {
    try {
      accessSync('/usr/bin/python3', constants.X_OK)
      candidates.push('/usr/bin/python3')
    } catch {}
  }
  if (process.platform === 'darwin' && name === 'xcodebuild') {
    const direct = '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild'
    try {
      accessSync(direct, constants.X_OK)
      candidates.push(direct)
    } catch {}
    if (dedicatedRunnerPath) return candidates
  }
  for (const dedicated of [
    join(DEDICATED_TOOLCHAIN_BIN, name),
    join(DEDICATED_TOOLCHAIN_ROOT, name),
  ]) {
    try {
      accessSync(dedicated, constants.X_OK)
      candidates.push(dedicated)
    } catch {}
  }
  for (const rawDir of (env.PATH ?? '').split(delimiter)) {
    if (!rawDir || !isAbsolute(rawDir)) continue
    const candidate = join(rawDir, name)
    try {
      accessSync(candidate, constants.X_OK)
      if (!candidates.includes(candidate)) candidates.push(candidate)
    } catch {}
  }
  return candidates
}

function versionRoot(path: string): string | null {
  const normalized = path.split(sep).join('/')
  const match = normalized.match(/^(.*\/\.nvm\/versions\/node\/[^/]+)(?:\/|$)/)
    ?? normalized.match(/^(.*\/\.asdf\/installs\/(?:nodejs|bun|python)\/[^/]+)(?:\/|$)/)
    ?? normalized.match(/^(.*\/\.local\/share\/mise\/installs\/[^/]+\/[^/]+)(?:\/|$)/)
    ?? normalized.match(/^(.*\/\.rustup\/toolchains\/[^/]+)(?:\/|$)/)
    ?? normalized.match(/^(\/(?:opt\/homebrew|usr\/local)\/Cellar\/[^/]+\/[^/]+)(?:\/|$)/)
    ?? normalized.match(/^(\/usr\/local\/go)(?:\/|$)/)
  return match?.[1] ?? null
}

export function detectWorkspaceToolNames(workspaceRoot: string): string[] {
  const workspace = realpathSync(resolve(workspaceRoot))
  const tools = new Set<string>()
  const packagePath = join(workspace, 'package.json')
  if (existsSync(packagePath)) {
    tools.add('node'); tools.add('npm'); tools.add('npx')
    try {
      const info = lstatSync(packagePath)
      if (!info.isFile() || info.isSymbolicLink() || info.size < 2 || info.size > 1024 * 1024) {
        throw new ToolchainResolutionError('project package.json is not a bounded regular file')
      }
      const value = JSON.parse(readFileSync(packagePath, 'utf8')) as {
        packageManager?: unknown
        scripts?: unknown
      }
      const manager = typeof value.packageManager === 'string'
        ? value.packageManager.split('@', 1)[0].toLowerCase()
        : ''
      if (['bun', 'pnpm', 'yarn'].includes(manager)) tools.add(manager)
      if (value.scripts && typeof value.scripts === 'object' && !Array.isArray(value.scripts)) {
        const scripts = Object.values(value.scripts)
          .filter((item): item is string => typeof item === 'string').join('\n')
        for (const name of ['bun', 'pnpm', 'yarn', 'deno', 'uv', 'cargo', 'go', 'swift', 'xcrun']) {
          if (new RegExp(`(?:^|[\\s;&|()])${name}(?:$|[\\s;&|()])`, 'm').test(scripts)) tools.add(name)
        }
      }
    } catch (error) {
      if (error instanceof ToolchainResolutionError) throw error
      throw new ToolchainResolutionError(`could not parse project package.json: ${error}`)
    }
  }
  if (existsSync(join(workspace, 'bun.lock')) || existsSync(join(workspace, 'bun.lockb'))) tools.add('bun')
  if (existsSync(join(workspace, 'pnpm-lock.yaml'))) tools.add('pnpm')
  if (existsSync(join(workspace, 'yarn.lock'))) tools.add('yarn')
  if (existsSync(join(workspace, 'deno.json')) || existsSync(join(workspace, 'deno.jsonc'))) tools.add('deno')
  if (
    existsSync(join(workspace, 'pyproject.toml'))
    || existsSync(join(workspace, 'uv.lock'))
    || existsSync(join(workspace, 'requirements.txt'))
  ) {
    tools.add('python3')
    if (existsSync(join(workspace, 'uv.lock'))) tools.add('uv')
  }
  if (existsSync(join(workspace, 'Cargo.toml'))) {
    tools.add('cargo'); tools.add('rustc')
  }
  if (existsSync(join(workspace, 'go.mod'))) tools.add('go')
  let xcodeProject = false
  try {
    xcodeProject = readdirSync(workspace, { withFileTypes: true }).some(
      entry => !entry.isSymbolicLink()
        && (entry.name.endsWith('.xcodeproj') || entry.name.endsWith('.xcworkspace')),
    )
  } catch {}
  if (existsSync(join(workspace, 'Package.swift')) || xcodeProject) {
    tools.add('swift'); tools.add('swiftc'); tools.add('xcrun')
    if (xcodeProject) tools.add('xcodebuild')
  }
  return [...tools].sort()
}

export function resolveToolchainPlan(
  workspaceRoot: string,
  env: NodeJS.ProcessEnv = process.env,
  required = ['git', 'python3', 'bun'],
  systemHomeOverride = userInfo().homedir,
  requireRootOwned = false,
): ToolchainPlan {
  const workspace = realpathSync(resolve(workspaceRoot))
  const roots = new Set<string>()
  const pathDirs = new Set<string>()
  const executables: Record<string, string> = Object.create(null)
  const runtimeEnv: Record<string, string> = Object.create(null)
  let usesRustupShim = false

  // A repo-local virtualenv is untrusted host code, but it is useful inside
  // the already-sandboxed turn. Add only a canonical in-workspace directory
  // to the turn PATH; never execute it during daemon preflight or expose it as
  // a host-readable exception.
  if (!requireRootOwned) {
    const venvBin = join(workspace, '.venv', 'bin')
    try {
      const venv = lstatSync(join(workspace, '.venv'))
      const bin = lstatSync(venvBin)
      if (
        venv.isDirectory()
        && !venv.isSymbolicLink()
        && bin.isDirectory()
        && !bin.isSymbolicLink()
        && realpathSync(venvBin).startsWith(workspace + sep)
      ) pathDirs.add(venvBin)
    } catch {}
  }

  const requestedTools = [...new Set([...required, ...detectWorkspaceToolNames(workspace)])]
  for (const name of requestedTools) {
    const candidateEnv = requireRootOwned ? { PATH: DEDICATED_RUNNER_TOOL_PATH } : env
    const candidates = executableCandidates(name, candidateEnv, requireRootOwned)
    let selected: { found: string; canonical: string } | null = null
    let lastError: unknown
    for (const found of candidates) {
      try {
        const canonical = realpathSync(found)
        if (canonical === workspace || canonical.startsWith(workspace + sep)) {
          throw new ToolchainResolutionError(`refusing workspace-controlled tool executable: ${canonical}`)
        }
        assertTrustedExecutable(found, canonical, name, requireRootOwned)
        const invocationReal = realpathSync(dirname(found))
        if (invocationReal === workspace || invocationReal.startsWith(workspace + sep)) {
          throw new ToolchainResolutionError(`refusing workspace-controlled tool directory: ${dirname(found)}`)
        }
        selected = { found, canonical }
        break
      } catch (err) {
        lastError = err
      }
    }
    if (!selected) {
      if (requestedTools.includes(name)) {
        const detail = lastError ? `; last candidate failed: ${lastError}` : ''
        throw new ToolchainResolutionError(`required tool has no trusted executable: ${name}${detail}`)
      }
      continue
    }
    const { found, canonical } = selected
    const invocationDir = realpathSync(dirname(found))
    const invocationReal = realpathSync(invocationDir)
    executables[name] = canonical
    if ((name === 'cargo' || name === 'rustc') && canonical.endsWith(`${sep}rustup`)) {
      usesRustupShim = true
    }
    pathDirs.add(invocationDir)
    roots.add(invocationReal)
    if (
      canonical === DEDICATED_TOOLCHAIN_ROOT
      || canonical.startsWith(DEDICATED_TOOLCHAIN_ROOT + sep)
      || invocationReal === DEDICATED_TOOLCHAIN_ROOT
      || invocationReal.startsWith(DEDICATED_TOOLCHAIN_ROOT + sep)
    ) roots.add(DEDICATED_TOOLCHAIN_ROOT)
    const managedRoot = versionRoot(canonical)
    roots.add(managedRoot ?? dirname(canonical))
  }


  const rustTool = executables.rustc ?? executables.cargo
  const rustupMatch = rustTool?.split(sep).join('/').match(/^(.*\/\.rustup)\/toolchains\/[^/]+(?:\/|$)/)
  if (rustupMatch || usesRustupShim) {
    const expectedRustupHome = join(systemHomeOverride, '.rustup')
    let rustupHome: string
    try { rustupHome = realpathSync(rustupMatch?.[1] ?? expectedRustupHome) } catch (err) {
      throw new ToolchainResolutionError(`rustup tool was found without a readable default .rustup sysroot: ${err}`)
    }
    if (env.RUSTUP_HOME) {
      let requested: string
      try { requested = realpathSync(resolve(env.RUSTUP_HOME)) } catch (err) {
        throw new ToolchainResolutionError(`could not validate RUSTUP_HOME: ${err}`)
      }
      if (requested !== rustupHome) {
        throw new ToolchainResolutionError('custom RUSTUP_HOME is unsupported for unattended turns')
      }
    }
    if (rustupHome === workspace || rustupHome.startsWith(workspace + sep)) {
      throw new ToolchainResolutionError('refusing workspace-controlled Rust sysroot')
    }
    assertTrustedDirectoryChain(rustupHome, 'Rust sysroot', requireRootOwned)
    roots.add(rustupHome)
    runtimeEnv.RUSTUP_HOME = rustupHome
  }

  const fixedCandidates = process.platform === 'darwin'
    ? [
        '/System',
        '/usr/lib',
        '/Library/Developer/CommandLineTools',
        '/Library/Frameworks',
        '/Applications/Xcode.app/Contents/Developer',
      ]
    : ['/lib', '/lib64', '/usr/lib', '/usr/lib64']
  for (const candidate of fixedCandidates) {
    try {
      const canonical = realpathSync(candidate)
      if (canonical !== parse(canonical).root && lstatSync(canonical).isDirectory()) {
        if (requireRootOwned) assertTrustedDirectoryChain(canonical, 'fixed toolchain root', true)
        roots.add(canonical)
      }
    } catch {}
  }

  for (const root of roots) {
    const stat = lstatSync(root)
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid
    if (
      !stat.isDirectory()
      || stat.isSymbolicLink()
      || (stat.uid !== 0 && (requireRootOwned || stat.uid !== uid))
      || (stat.mode & 0o022) !== 0
      || root === parse(root).root
    ) {
      throw new ToolchainResolutionError(`unsafe toolchain root: ${root}`)
    }
  }
  for (const systemPath of ['/bin', '/usr/bin', '/usr/sbin', '/sbin']) {
    try { if (lstatSync(systemPath).isDirectory()) pathDirs.add(systemPath) } catch {}
  }
  return {
    readableRoots: [...roots].sort(),
    executables,
    path: requireRootOwned ? DEDICATED_RUNNER_TOOL_PATH : [...pathDirs].join(delimiter),
    runtimeEnv,
  }
}

export function createToolShims(shimDir: string, plan: ToolchainPlan): string {
  const dir = resolve(shimDir)
  try { rmSync(dir, { recursive: true, force: true }) } catch {}
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  chmodSync(dir, 0o700)
  const shim = join(dir, 'mktemp')
  const bun = plan.executables.bun
  writeFileSync(shim, `#!${bun}
const input = Bun.argv.slice(2)
const args = []
let hasTemplate = false
for (let i = 0; i < input.length; i++) {
  if (input[i] === '-t' && i + 1 < input.length) {
    const prefix = input[++i].replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 64) || 'tmp'
    args.push(process.env.TMPDIR + '/' + prefix + '.XXXXXXXX')
    hasTemplate = true
  } else {
    args.push(input[i])
    if (input[i].includes('X')) hasTemplate = true
  }
}
if (!hasTemplate) args.push(process.env.TMPDIR + '/tmp.XXXXXXXX')
const child = Bun.spawnSync(['/usr/bin/mktemp', ...args], {stdin:'inherit',stdout:'inherit',stderr:'inherit',env:process.env})
process.exit(child.exitCode)
`, { mode: 0o500 })
  return dir
}

export function safeTurnEnvironment(
  tempDir: string,
  plan: ToolchainPlan,
  shimDir?: string,
): NodeJS.ProcessEnv {
  return {
    ...plan.runtimeEnv,
    PATH: shimDir ? `${shimDir}${delimiter}${plan.path}` : plan.path,
    TMPDIR: tempDir,
    TMP: tempDir,
    TEMP: tempDir,
    XDG_CONFIG_HOME: join(tempDir, 'xdg-config'),
    XDG_CACHE_HOME: join(tempDir, 'xdg-cache'),
    XDG_DATA_HOME: join(tempDir, 'xdg-data'),
    XDG_STATE_HOME: join(tempDir, 'xdg-state'),
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_SYSTEM: '/dev/null',
    GIT_TERMINAL_PROMPT: '0',
    GIT_ASKPASS: '/usr/bin/false',
    NPM_CONFIG_USERCONFIG: '/dev/null',
    NPM_CONFIG_CACHE: join(tempDir, 'npm-cache'),
    NPM_CONFIG_UPDATE_NOTIFIER: 'false',
    NPM_CONFIG_AUDIT: 'false',
    NPM_CONFIG_FUND: 'false',
    NPM_CONFIG_STORE_DIR: join(tempDir, 'pnpm-store'),
    NPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS: 'false',
    NPM_CONFIG_PACKAGE_MANAGER_STRICT: 'true',
    NPM_CONFIG_PACKAGE_MANAGER_STRICT_VERSION: 'true',
    PNPM_HOME: join(tempDir, 'pnpm-home'),
    COREPACK_ENABLE_PROJECT_SPEC: '0',
    COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
    COREPACK_ENABLE_NETWORK: '0',
    BUN_INSTALL_CACHE_DIR: join(tempDir, 'bun-cache'),
    UV_CACHE_DIR: join(tempDir, 'uv-cache'),
    PIP_CONFIG_FILE: '/dev/null',
    PIP_CACHE_DIR: join(tempDir, 'pip-cache'),
    PYTHONNOUSERSITE: '1',
    GOCACHE: join(tempDir, 'go-build-cache'),
    GOPATH: join(tempDir, 'go-path'),
    GOMODCACHE: join(tempDir, 'go-path', 'pkg', 'mod'),
    CARGO_HOME: join(tempDir, 'cargo-home'),
    CARGO_TARGET_DIR: join(tempDir, 'cargo-target'),
    CLANG_MODULE_CACHE_PATH: join(tempDir, 'clang-module-cache'),
    SWIFT_MODULE_CACHE_PATH: join(tempDir, 'swift-module-cache'),
    SWIFTPM_CACHE_PATH: join(tempDir, 'swiftpm-cache'),
    SWIFTPM_CONFIG_PATH: join(tempDir, 'swiftpm-config'),
    SWIFTPM_SECURITY_PATH: join(tempDir, 'swiftpm-security'),
    OBJROOT: join(tempDir, 'xcode', 'obj'),
    SYMROOT: join(tempDir, 'xcode', 'build'),
    SHARED_PRECOMPS_DIR: join(tempDir, 'xcode', 'precompiled'),
    DERIVED_DATA_DIR: join(tempDir, 'xcode', 'derived-data'),
  }
}
