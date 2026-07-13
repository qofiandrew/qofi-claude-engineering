import { lstatSync, readFileSync, readdirSync } from 'fs'
import { basename, join, relative, resolve, sep } from 'path'

export class WorkspaceScanError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'WorkspaceScanError'
  }
}

const SKIP_DIRS = new Set([
  'node_modules', '.venv', 'venv', 'dist', 'build', 'coverage', '.next', 'target',
  'vendor',
])
const PROVIDER_DIRS = new Set(['.aws', '.azure', '.gcloud', '.kube', '.ssh', '.gnupg'])
const ENV_EXAMPLES = /\.env\.(?:example|sample|template)(?:\.[A-Za-z0-9_-]+)?$/i
const SECRET_DATA_NAME = /(?:credential|credentials|secret|secrets|service[-_]?account|private[-_]?key|auth)[^/]*\.(?:json|ya?ml|toml|ini|cfg|conf|txt)$/i

const HIGH_CONFIDENCE_SECRET_PATTERNS = [
  /MT[A-Za-z0-9._-]{40,}/,
  /AKIA[0-9A-Z]{16}/,
  /gh[pousr]_[A-Za-z0-9]{36}/,
  /xox[baprs]-[0-9]{10,}-[A-Za-z0-9-]+/,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
] as const

export function containsHighConfidenceSecret(content: string | Buffer): boolean {
  const text = typeof content === 'string' ? content : content.toString('utf8')
  return HIGH_CONFIDENCE_SECRET_PATTERNS.some(pattern => pattern.test(text))
}

export function isSensitiveRelativePath(path: string): boolean {
  const normalized = path.split(sep).join('/')
  // Claude Code owns this entire tree. Its worktree-local `.git` pointer and
  // checkout contents are neither Codex input nor part of Codex's scan bound.
  if (normalized === '.claude/worktrees' || normalized.startsWith('.claude/worktrees/')) {
    return true
  }
  const name = basename(normalized).toLowerCase()
  if (ENV_EXAMPLES.test(name)) return false
  if (
    name === '.env'
    || (name.startsWith('.env.') && !ENV_EXAMPLES.test(name))
    || name.endsWith('.env')
    || name === 'tokens.env'
    || name === '.npmrc'
    || name === '.pypirc'
    || name === '.netrc'
    || name === '.git-credentials'
    || name === 'id_rsa'
    || name === 'id_ed25519'
    || name.endsWith('.pem')
    || name.endsWith('.key')
    || name.endsWith('.p12')
    || name.endsWith('.pfx')
    || /^settings\.local(?:\.|$)/i.test(name)
    || SECRET_DATA_NAME.test(name)
  ) return true
  const parts = normalized.toLowerCase().split('/')
  return parts.some(part => PROVIDER_DIRS.has(part))
}

export function isOperatorOwnedRelativePath(path: string): boolean {
  const normalized = path.split(sep).join('/').replace(/^\.\//, '')
  return (
    normalized === '.git' || normalized.startsWith('.git/')
    || normalized === '.codex' || normalized.startsWith('.codex/')
    || normalized === '.agents' || normalized.startsWith('.agents/')
    || normalized === '.claude' || normalized.startsWith('.claude/')
    || normalized === '.gitleaks.toml'
    || normalized.startsWith('.swarm-')
    || [
      'AGENTS.md', 'CLAUDE.md', 'TEAM_LEAD.md', 'ESCALATION.md',
      'CONVERSATION.md', 'EVALUATION.md', 'SURFACING.md', 'MEMORY.md',
      'READINESS_BAR.md', 'CPO_BUS_PROTOCOL.md',
    ].includes(normalized)
    || isSensitiveRelativePath(normalized)
  )
}

export type WorkspacePolicyDiscovery = {
  deniedPaths: string[]
  readableExamples: string[]
}

export function discoverWorkspacePolicy(
  cwd: string,
  limits: { maxEntries?: number; maxDepth?: number } = {},
): WorkspacePolicyDiscovery {
  const root = resolve(cwd)
  const maxEntries = limits.maxEntries ?? 50_000
  const maxDepth = limits.maxDepth ?? 32
  let visited = 0
  const denied = new Set<string>([
    join(root, '.git', 'credentials'),
  ])
  const readableExamples = new Set<string>()
  const stack: Array<{ dir: string; depth: number }> = [{ dir: root, depth: 0 }]
  while (stack.length > 0) {
    const { dir, depth } = stack.pop()!
    if (depth > maxDepth) throw new WorkspaceScanError(`workspace scan exceeded depth ${maxDepth}`)
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch (err) {
      throw new WorkspaceScanError(`workspace scan could not read ${relative(root, dir) || '.'}: ${err}`)
    }
    for (const entry of entries) {
      visited++
      if (visited > maxEntries) {
        throw new WorkspaceScanError(`workspace scan exceeded ${maxEntries} entries`)
      }
      const path = join(dir, entry.name)
      const rel = relative(root, path)
      if (entry.isSymbolicLink()) {
        if (isSensitiveRelativePath(rel)) denied.add(path)
        continue
      }
      if (entry.isDirectory()) {
        if (entry.name === '.git') continue
        if (rel.split(sep).join('/') === '.claude/worktrees') {
          denied.add(path)
          denied.add(`${path}/**`)
          continue
        }
        if (PROVIDER_DIRS.has(entry.name.toLowerCase())) {
          denied.add(`${path}/**`)
          continue
        }
        if (!SKIP_DIRS.has(entry.name)) stack.push({ dir: path, depth: depth + 1 })
        continue
      }
      if (entry.isFile()) {
        if (ENV_EXAMPLES.test(entry.name)) {
          try {
            const stat = lstatSync(path)
            if (
              !stat.isFile()
              || stat.isSymbolicLink()
              || stat.size > 64 * 1024
              || containsHighConfidenceSecret(readFileSync(path))
            ) denied.add(path)
            else readableExamples.add(path)
          } catch (err) {
            throw new WorkspaceScanError(`workspace scan could not validate env example ${rel}: ${err}`)
          }
        }
        else if (isSensitiveRelativePath(rel)) denied.add(path)
      }
    }
  }
  return {
    deniedPaths: [...denied].sort(),
    readableExamples: [...readableExamples].sort(),
  }
}

export function discoverSensitiveWorkspacePaths(
  cwd: string,
  limits: { maxEntries?: number; maxDepth?: number } = {},
): string[] {
  return discoverWorkspacePolicy(cwd, limits).deniedPaths
}
