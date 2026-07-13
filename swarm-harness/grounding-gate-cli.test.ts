import { afterEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  completionReviewPolicySha256,
  parseCompletionReviewPolicy,
} from './completion-review-policy.ts'
import { generateProductContextPack } from './product-context-pack.ts'
import {
  canonicalAuthorityJsonLine,
  HARNESS_PARITY_ADOPTION_SCHEMA,
  HARNESS_PARITY_ADOPTION_CONTRACT,
} from './parity-adoption.ts'
import { groundingAuthorityPaths } from './grounding-runtime-wrapper.ts'

const roots: string[] = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

const policy = parseCompletionReviewPolicy(await Bun.file(
  join(import.meta.dir, 'completion-review-policy.json'),
).json())
const cli = join(import.meta.dir, '..', 'bin', 'swarm-grounding-gate.ts')

function privateJson(path: string, value: unknown): void {
  writeFileSync(path, canonicalAuthorityJsonLine(value), { mode: 0o600 })
  chmodSync(path, 0o600)
}

function fixture(runtime: 'claude' | 'codex') {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `qofi-grounding-cli-${runtime}-`)))
  roots.push(root)
  const repo = join(root, 'repo')
  const state = join(root, 'private')
  mkdirSync(repo, { mode: 0o755 })
  mkdirSync(join(repo, 'docs'), { mode: 0o755 })
  writeFileSync(join(repo, 'docs', 'invariants.md'), 'SYNC != LIVE\n', { mode: 0o644 })
  writeFileSync(join(repo, 'docs', 'key-files.md'), 'src/index.ts\n', { mode: 0o644 })
  writeFileSync(join(repo, 'docs', 'module-map.md'), 'api -> database\n', { mode: 0o644 })
  for (const args of [
    ['init', '--quiet'],
    ['add', 'docs'],
    ['-c', 'user.name=Grounding Fixture', '-c', 'user.email=fixture@example.invalid',
      'commit', '--quiet', '-m', 'fixture corpus'],
  ]) {
    const git = Bun.spawnSync(['/usr/bin/git', '-C', repo, ...args], { stdout: 'pipe', stderr: 'pipe' })
    if (git.exitCode !== 0) throw new Error(`fixture git failed: ${git.stderr.toString()}`)
  }
  const corpusCommit = Bun.spawnSync(
    ['/usr/bin/git', '-C', repo, 'rev-parse', '--verify', 'HEAD^{commit}'],
    { stdout: 'pipe', stderr: 'pipe' },
  ).stdout.toString().trim()
  mkdirSync(state, { mode: 0o700 })
  chmodSync(state, 0o700)
  const pack = generateProductContextPack([
    { name: 'invariants', path: 'docs/invariants.md', content: 'SYNC != LIVE\n' },
    { name: 'key-files', path: 'docs/key-files.md', content: 'src/index.ts\n' },
    { name: 'module-map', path: 'docs/module-map.md', content: 'api -> database\n' },
  ]).pack
  const taskId = 'task-cli-grounding'
  const receiptPath = join(state, 'parity-receipt.json')
  const receipt = {
    schema: HARNESS_PARITY_ADOPTION_SCHEMA,
    contract: HARNESS_PARITY_ADOPTION_CONTRACT,
    swarm: 'press-backend',
    runtimes: ['claude', 'codex'],
    state_root: state,
    roadmap_repo_root: repo,
    dr_refs: ['ADR-0023'],
    completion_policy_sha256: completionReviewPolicySha256(policy),
  }
  privateJson(receiptPath, receipt)
  const paths = groundingAuthorityPaths({
    enabled: true,
    receiptPath,
    receiptSha256: 'a'.repeat(64),
    stateRoot: state,
    roadmapRepoRoot: repo,
    drRefs: ['ADR-0023'],
    completionPolicySha256: completionReviewPolicySha256(policy),
    swarm: 'press-backend',
  }, taskId)
  mkdirSync(join(state, 'grounding-authority'), { mode: 0o700 })
  mkdirSync(join(state, 'grounding-authority', 'task-briefs'), { mode: 0o700 })
  privateJson(paths.contextCache, {
    schema: 'qofi-product-context-cache/v1',
    corpus_commit: corpusCommit,
    pack,
  })
  privateJson(paths.taskBrief, {
    schema: 'qofi-product-context-brief/v1',
    taskId,
    productContext: { corpusSha256: pack.corpusSha256, refs: ['module-map'] },
  })
  const env = {
    ...process.env,
    SWARM_HARNESS_PARITY_RECEIPT: receiptPath,
    SWARM_WORKER_RUNTIME: runtime,
    SWARM_NAME: 'press-backend',
    SWARM_GROUNDING_TASK_ID: taskId,
    SWARM_GROUNDING_MAX_OPERATIONS: '1',
    ...(runtime === 'claude' ? { CLAUDE_PROJECT_DIR: repo } : { CODEX_BRIDGE_CWD: repo }),
  }
  const invoke = (input: unknown) => {
    const result = Bun.spawnSync([process.execPath, cli], {
      cwd: repo,
      env,
      stdin: Buffer.from(`${JSON.stringify(input)}\n`),
      stdout: 'pipe',
      stderr: 'pipe',
    })
    return {
      exitCode: result.exitCode,
      output: JSON.parse(result.stdout.toString()),
      stderr: result.stderr.toString(),
    }
  }
  return { repo, invoke }
}

function records(runtime: 'claude' | 'codex', repo: string) {
  const timestamp = '2026-07-13T10:00:00Z'
  return runtime === 'claude' ? {
    read: { tool_name: 'Read', tool_input: { file_path: join(repo, 'docs/module-map.md') }, timestamp },
    grep: { tool_name: 'Grep', tool_input: { path: repo, pattern: 'private query' }, timestamp },
    edit: { tool_name: 'Edit', tool_input: { file_path: join(repo, 'src.ts') }, timestamp },
  } : {
    read: {
      timestamp, payload: {
        type: 'function_call', name: 'read_file',
        arguments: { path: join(repo, 'docs/module-map.md') },
      },
    },
    grep: {
      timestamp, payload: {
        type: 'function_call', name: 'grep_files', arguments: { path: repo, query: 'private query' },
      },
    },
    edit: {
      timestamp, payload: { type: 'function_call', name: 'apply_patch', arguments: 'private diff' },
    },
  }
}

for (const runtime of ['claude', 'codex'] as const) {
  describe(`${runtime} production grounding gate entrypoint`, () => {
    test('holds N+1 edit, durably files the gap, then admits retry', () => {
      const f = fixture(runtime)
      const native = records(runtime, f.repo)
      expect(f.invoke(native.read)).toMatchObject({
        exitCode: 0, output: { adopted: true, ok: true, operation_count: 1 },
      })
      expect(f.invoke(native.grep)).toMatchObject({
        exitCode: 0,
        output: { adopted: true, ok: true, operation_count: 2, gap_report_required: true },
      })
      expect(f.invoke(native.edit)).toMatchObject({
        exitCode: 2,
        output: { adopted: true, ok: false, reason: 'grounding-gap-report-required' },
      })
      expect(f.invoke({
        action: 'file-pack-gap', missing_context_refs: ['database-schema'],
      })).toMatchObject({
        exitCode: 0,
        output: { adopted: true, ok: true, reason: 'durable-pack-gap-filed' },
      })
      expect(f.invoke(native.edit)).toMatchObject({
        exitCode: 0,
        output: { adopted: true, ok: true, first_substantive_edit_seen: true },
      })
    })
  })
}

test('production gate is a no-op when the shared receipt is absent', () => {
  const result = Bun.spawnSync([process.execPath, cli], {
    env: Object.fromEntries(Object.entries(process.env).filter(([key]) => (
      key !== 'SWARM_HARNESS_PARITY_RECEIPT' && !key.startsWith('CODEX_BRIDGE_HARNESS_')
    ))),
    stdin: Buffer.from('{}\n'), stdout: 'pipe', stderr: 'pipe',
  })
  expect(result.exitCode).toBe(0)
  expect(JSON.parse(result.stdout.toString())).toMatchObject({
    adopted: false, ok: true, reason: 'shared-parity-adoption-disabled',
  })
})
