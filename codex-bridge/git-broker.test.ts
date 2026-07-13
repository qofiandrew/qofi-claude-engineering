import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { describe, expect, test } from 'bun:test'
import { tmpdir } from 'os'
import { join } from 'path'
import { gitFileFingerprint, parseGitControlMessage, runGitBroker } from './git-broker.ts'
import { createToolShims, resolveToolchainPlan, safeTurnEnvironment } from './toolchain.ts'
import {
  captureWorkspaceSnapshot,
  INELIGIBLE_OVERSIZE_FINGERPRINT,
} from './turn-changes.ts'

function git(bin: string, cwd: string, args: string[]): number {
  return Bun.spawnSync([bin, ...args], { cwd, stdout: 'ignore', stderr: 'ignore' }).exitCode
}

function gitOutput(bin: string, cwd: string, args: string[]): string {
  const result = Bun.spawnSync([bin, ...args], { cwd, stdout: 'pipe', stderr: 'pipe' })
  expect(result.exitCode, result.stderr.toString()).toBe(0)
  return result.stdout.toString().trim()
}

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'codex-git-broker-'))
  const repo = join(root, 'repo')
  const state = join(root, 'state')
  const temp = join(root, 'temp')
  mkdirSync(repo)
  mkdirSync(state, { mode: 0o700 })
  mkdirSync(temp, { mode: 0o700 })
  const plan = resolveToolchainPlan(repo)
  const shim = createToolShims(join(state, 'shims'), plan)
  expect(git(plan.executables.git, repo, ['init', '-q'])).toBe(0)
  writeFileSync(join(repo, 'base.txt'), 'base\n')
  writeFileSync(join(repo, 'docs.md'), '# base docs\n')
  writeFileSync(join(repo, '.gitattributes'), 'new.txt filter=evil\n')
  expect(git(plan.executables.git, repo, ['add', 'base.txt', 'docs.md', '.gitattributes'])).toBe(0)
  expect(git(plan.executables.git, repo, [
    '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
    'commit', '--no-verify', '-qm', 'base',
  ])).toBe(0)
  const options = {
    cwd: repo,
    stateDir: state,
    gitBin: plan.executables.git,
    environment: safeTurnEnvironment(temp, plan, shim),
    timeoutMs: 10_000,
  }
  return { root, repo, state, plan, options }
}

function canonicalGitState(f: ReturnType<typeof fixture>) {
  const ref = gitOutput(f.plan.executables.git, f.repo, ['symbolic-ref', '-q', 'HEAD'])
  return {
    ref,
    head: gitOutput(f.plan.executables.git, f.repo, ['rev-parse', 'HEAD']),
    refTip: gitOutput(f.plan.executables.git, f.repo, ['rev-parse', ref]),
    index: Buffer.from(readFileSync(join(f.repo, '.git', 'index'))),
  }
}

function expectCanonicalGitStateUnchanged(
  before: ReturnType<typeof canonicalGitState>,
  after: ReturnType<typeof canonicalGitState>,
): void {
  expect(after.ref).toBe(before.ref)
  expect(after.head).toBe(before.head)
  expect(after.refTip).toBe(before.refTip)
  expect(after.index.equals(before.index)).toBe(true)
}

function allowed(repo: string, paths: string[]): Record<string, string | null> {
  const result: Record<string, string | null> = Object.create(null)
  for (const path of paths) {
    const absolute = join(repo, path)
    if (!existsSync(absolute)) result[path] = null
    else {
      const stat = lstatSync(absolute)
      result[path] = gitFileFingerprint(
        (stat.mode & 0o111) !== 0 ? '100755' : '100644',
        Buffer.from(readFileSync(absolute)),
      )
    }
  }
  return result
}

async function createBrokerBranch(f: ReturnType<typeof fixture>, name: string): Promise<void> {
  expect(await runGitBroker({ action: 'branch', name }, f.options))
    .toEqual({ ok: true, action: 'branch', branch: name })
}

describe('Git broker control parser', () => {
  test('accepts strict commit JSON and rejects injection/protected refs', () => {
    expect(parseGitControlMessage('hello')).toEqual({ matched: false })
    expect(parseGitControlMessage('!qofi-git commit {"message":"safe","paths":["src/a.ts"]}'))
      .toMatchObject({ matched: true, command: { action: 'commit', message: 'safe' } })
    expect(parseGitControlMessage('!qofi-git branch feature/safe'))
      .toEqual({ matched: true, command: { action: 'branch', name: 'feature/safe' } })
    expect(parseGitControlMessage('!qofi-git retire feature/safe'))
      .toEqual({ matched: true, command: { action: 'retire', name: 'feature/safe' } })
    expect(parseGitControlMessage('!qofi-git branch main').command).toBeNull()
    expect(parseGitControlMessage('!qofi-git branch feature/MAIN').command).toBeNull()
    expect(parseGitControlMessage('!qofi-git branch release_candidate').command).toBeNull()
    expect(parseGitControlMessage('!qofi-git branch x;touch').command).toBeNull()
    expect(parseGitControlMessage('!qofi-git retire main').command).toBeNull()
    expect(parseGitControlMessage('!qofi-git commit {"message":"x","paths":["a"],"extra":1}').command)
      .toBeNull()
  })
})

describe('Git broker integration', () => {
  test('rejects an oversized commit path even when its turn snapshot has an ineligible sentinel', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/oversized')
      writeFileSync(join(f.repo, 'large.pdf'), '12345')
      expect(await runGitBroker({
        action: 'commit', message: 'must remain ineligible', paths: ['large.pdf'],
      }, {
        ...f.options,
        allowedChanges: { 'large.pdf': INELIGIBLE_OVERSIZE_FINGERPRINT },
        maxFileBytes: 4,
      })).toMatchObject({
        ok: false,
        errorKind: 'invalid-path',
        detail: 'file exceeds broker size bound',
      })
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('rejects an aggregate metadata sentinel as a direct commit capability', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/deferred-metadata')
      writeFileSync(join(f.repo, 'deferred.md'), 'eligible content')
      const snapshot = captureWorkspaceSnapshot(f.repo, { maxTotalBytes: 0 })
      expect(await runGitBroker({
        action: 'commit', message: 'must require content fingerprint', paths: ['deferred.md'],
      }, {
        ...f.options,
        allowedChanges: { 'deferred.md': snapshot.files['deferred.md'] },
      })).toMatchObject({
        ok: false,
        errorKind: 'policy',
        detail: 'path changed after the latest serialized Codex turn',
      })
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('uses plumbing only, bypasses hostile hooks/filters, and leaves real index clean', async () => {
    const f = fixture()
    try {
      const canonicalBefore = canonicalGitState(f)
      await createBrokerBranch(f, 'feature/plumbing')
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
      const hookMarker = join(f.repo, 'hook-ran')
      const filterMarker = join(f.repo, 'filter-ran')
      for (const name of ['pre-commit', 'reference-transaction']) {
        const hook = join(f.repo, '.git', 'hooks', name)
        writeFileSync(hook, `#!/bin/sh\nprintf ran > ${JSON.stringify(hookMarker)}\n`)
        chmodSync(hook, 0o700)
      }
      const filter = join(f.repo, '.git', 'evil-filter')
      writeFileSync(filter, `#!/bin/sh\nprintf ran > ${JSON.stringify(filterMarker)}\ncat\n`)
      chmodSync(filter, 0o700)
      expect(git(f.plan.executables.git, f.repo, ['config', 'filter.evil.clean', filter])).toBe(0)
      writeFileSync(join(f.repo, 'new.txt'), 'new\n')
      writeFileSync(join(f.repo, 'PROJECT_SPEC.md'), '# Broker fixture spec\n')
      writeFileSync(join(f.repo, 'unrelated.txt'), 'leave unstaged\n')
      const result = await runGitBroker({
        action: 'commit', message: 'broker commit', paths: ['new.txt', 'PROJECT_SPEC.md'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['new.txt', 'PROJECT_SPEC.md']) })
      expect(result).toMatchObject({ ok: true, action: 'commit' })
      expect(existsSync(hookMarker)).toBe(false)
      expect(existsSync(filterMarker)).toBe(false)
      expect(git(f.plan.executables.git, f.repo, ['diff', '--cached', '--quiet'])).toBe(0)
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
      expect(git(f.plan.executables.git, f.repo, ['cat-file', '-e', 'feature/plumbing:new.txt'])).toBe(0)
      expect(git(f.plan.executables.git, f.repo, ['cat-file', '-e', 'feature/plumbing:PROJECT_SPEC.md'])).toBe(0)
      expect(git(f.plan.executables.git, f.repo, ['cat-file', '-e', 'feature/plumbing:unrelated.txt'])).not.toBe(0)
      expect(git(f.plan.executables.git, f.repo, ['cat-file', '-e', 'HEAD:new.txt'])).not.toBe(0)
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('path traversal, operator policy, escaping symlinks, and staged real index fail closed', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/path-policy')
      writeFileSync(join(f.repo, 'safe.txt'), 'safe')
      const options = { ...f.options, allowedChanges: allowed(f.repo, ['safe.txt']) }
      expect(await runGitBroker({ action: 'commit', message: 'x', paths: ['../outside'] }, options))
        .toMatchObject({ ok: false, errorKind: 'invalid-path' })
      expect(await runGitBroker({ action: 'commit', message: 'x', paths: ['.codex/config.toml'] }, options))
        .toMatchObject({ ok: false, errorKind: 'operator-owned' })
      const outside = join(f.root, 'outside')
      writeFileSync(outside, 'outside')
      symlinkSync(outside, join(f.repo, 'escape'))
      expect(await runGitBroker({ action: 'commit', message: 'x', paths: ['escape'] }, options))
        .toMatchObject({ ok: false, errorKind: 'invalid-path' })
      expect(git(f.plan.executables.git, f.repo, ['add', 'safe.txt'])).toBe(0)
      expect(await runGitBroker({ action: 'commit', message: 'x', paths: ['safe.txt'] }, options))
        .toMatchObject({ ok: false, errorKind: 'staged-changes' })
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('trusted policy blocks source-only and high-confidence secret commits', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/trusted-policy')
      writeFileSync(join(f.repo, 'source.ts'), 'export const x = 1\n')
      expect(await runGitBroker({
        action: 'commit', message: 'source only', paths: ['source.ts'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['source.ts']) }))
        .toMatchObject({ ok: false, errorKind: 'policy' })
      writeFileSync(
        join(f.repo, 'README.md'),
        ['gh', 'p_', 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJ', '\n'].join(''),
      )
      expect(await runGitBroker({
        action: 'commit', message: 'secret', paths: ['source.ts', 'README.md'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['source.ts', 'README.md']) }))
        .toMatchObject({ ok: false, errorKind: 'policy' })
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('a deleted doc does not satisfy the source-plus-doc gate', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/doc-delete')
      writeFileSync(join(f.repo, 'base.txt'), 'source changed\n')
      rmSync(join(f.repo, 'docs.md'))
      expect(await runGitBroker({
        action: 'commit', message: 'cannot count deleted docs', paths: ['base.txt', 'docs.md'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['base.txt', 'docs.md']) }))
        .toMatchObject({ ok: false, errorKind: 'policy' })
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('a source-only deletion still requires a non-deleted documentation change', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/source-delete')
      rmSync(join(f.repo, 'base.txt'))
      expect(await runGitBroker({
        action: 'commit', message: 'source deletion only', paths: ['base.txt'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['base.txt']) }))
        .toMatchObject({ ok: false, errorKind: 'policy' })
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('creates one side ref without switching and never retires it implicitly', async () => {
    const f = fixture()
    try {
      const canonicalBefore = canonicalGitState(f)
      expect(await runGitBroker({ action: 'branch', name: 'feature/broker' }, f.options))
        .toEqual({ ok: true, action: 'branch', branch: 'feature/broker' })
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
      expect(gitOutput(f.plan.executables.git, f.repo, ['rev-parse', 'feature/broker']))
        .toBe(canonicalBefore.head)
      expect(await runGitBroker({ action: 'branch', name: 'feature/broker' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'policy' })
      expect(await runGitBroker({ action: 'branch', name: 'feature/replacement' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'policy' })
      expect(git(f.plan.executables.git, f.repo, [
        'show-ref', '--verify', '--quiet', 'refs/heads/feature/broker',
      ])).toBe(0)
      expect(git(f.plan.executables.git, f.repo, [
        'show-ref', '--verify', '--quiet', 'refs/heads/feature/replacement',
      ])).not.toBe(0)
      const registry = JSON.parse(readFileSync(join(f.state, 'branches.json'), 'utf8'))
      expect(registry.branches).toEqual({ 'feature/broker': { tip: canonicalBefore.head } })
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('refuses commit and retirement while the side ref is the canonical checkout', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/canonical-checkout')
      expect(git(f.plan.executables.git, f.repo, [
        'checkout', '-q', 'feature/canonical-checkout',
      ])).toBe(0)
      writeFileSync(join(f.repo, 'docs.md'), '# canonical checkout must remain operator-owned\n')
      const before = canonicalGitState(f)
      const sideTip = gitOutput(f.plan.executables.git, f.repo, [
        'rev-parse', 'refs/heads/feature/canonical-checkout',
      ])

      expect(await runGitBroker({
        action: 'commit', message: 'must not advance checked out ref', paths: ['docs.md'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['docs.md']) }))
        .toMatchObject({ ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out') })
      expect(await runGitBroker({
        action: 'retire', name: 'feature/canonical-checkout',
      }, f.options))
        .toMatchObject({ ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out') })

      expect(gitOutput(f.plan.executables.git, f.repo, [
        'rev-parse', 'refs/heads/feature/canonical-checkout',
      ])).toBe(sideTip)
      expect(JSON.parse(readFileSync(join(f.state, 'branches.json'), 'utf8')).branches)
        .toEqual({ 'feature/canonical-checkout': { tip: sideTip } })
      expect(existsSync(join(f.state, 'transaction.json'))).toBe(false)
      expectCanonicalGitStateUnchanged(before, canonicalGitState(f))
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('refuses commit and retirement while a linked worktree checks out the side ref', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/linked-checkout')
      const linked = join(f.root, 'linked')
      expect(git(f.plan.executables.git, f.repo, [
        'worktree', 'add', '-q', linked, 'feature/linked-checkout',
      ])).toBe(0)
      writeFileSync(join(f.repo, 'docs.md'), '# linked checkout remains operator-owned\n')
      const canonicalBefore = canonicalGitState(f)
      const sideTip = gitOutput(f.plan.executables.git, f.repo, [
        'rev-parse', 'refs/heads/feature/linked-checkout',
      ])

      expect(await runGitBroker({
        action: 'commit', message: 'must not advance linked checkout', paths: ['docs.md'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['docs.md']) }))
        .toMatchObject({ ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out') })
      expect(await runGitBroker({
        action: 'retire', name: 'feature/linked-checkout',
      }, f.options))
        .toMatchObject({ ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out') })

      expect(gitOutput(f.plan.executables.git, linked, ['rev-parse', 'HEAD'])).toBe(sideTip)
      expect(gitOutput(f.plan.executables.git, f.repo, [
        'rev-parse', 'refs/heads/feature/linked-checkout',
      ])).toBe(sideTip)
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('revalidates linked worktrees after a durable journal and before each ref CAS', async () => {
    {
      const f = fixture()
      try {
        const linked = join(f.root, 'create-race-linked')
        const events: string[] = []
        let linkedAddExit: number | null = null
        const result = await runGitBroker({ action: 'branch', name: 'feature/create-race' }, {
          ...f.options,
          onDurabilityEvent: event => {
            events.push(event)
            if (event === 'branch-journal-durable') {
              linkedAddExit = git(f.plan.executables.git, f.repo, [
                'worktree', 'add', '-q', '-b', 'feature/create-race', linked,
              ])
            }
          },
        })
        expect(linkedAddExit).toBe(0)
        expect(result).toMatchObject({
          ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out'),
        })
        expect(events).toEqual([
          'branch-journal-durable',
          'branch-journal-removed-durable',
        ])
        expect(existsSync(join(f.state, 'branch-transaction.json'))).toBe(false)
        expect(existsSync(join(f.state, 'branches.json'))).toBe(false)
      } finally {
        rmSync(f.root, { recursive: true, force: true })
      }
    }

    {
      const f = fixture()
      try {
        await createBrokerBranch(f, 'feature/advance-race')
        writeFileSync(join(f.repo, 'docs.md'), '# advance race\n')
        const linked = join(f.root, 'advance-race-linked')
        const sideTip = gitOutput(f.plan.executables.git, f.repo, [
          'rev-parse', 'refs/heads/feature/advance-race',
        ])
        const events: string[] = []
        let linkedAddExit: number | null = null
        const result = await runGitBroker({
          action: 'commit', message: 'must lose checkout race safely', paths: ['docs.md'],
        }, {
          ...f.options,
          allowedChanges: allowed(f.repo, ['docs.md']),
          onDurabilityEvent: event => {
            events.push(event)
            if (event === 'commit-journal-durable') {
              linkedAddExit = git(f.plan.executables.git, f.repo, [
                'worktree', 'add', '-q', linked, 'feature/advance-race',
              ])
            }
          },
        })
        expect(linkedAddExit).toBe(0)
        expect(result).toMatchObject({
          ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out'),
        })
        expect(events).toEqual([
          'commit-journal-durable',
          'commit-private-state-removed-durable',
          'commit-journal-removed-durable',
        ])
        expect(gitOutput(f.plan.executables.git, f.repo, [
          'rev-parse', 'refs/heads/feature/advance-race',
        ])).toBe(sideTip)
        expect(existsSync(join(f.state, 'transaction.json'))).toBe(false)
        expect(readdirSync(f.state).some(name => name.startsWith('git-index-'))).toBe(false)
      } finally {
        rmSync(f.root, { recursive: true, force: true })
      }
    }
  })

  test('durably orders journal, ref CAS, registry, private cleanup, and journal removal', async () => {
    const f = fixture()
    try {
      const branchEvents: string[] = []
      expect(await runGitBroker({ action: 'branch', name: 'feature/durable-order' }, {
        ...f.options, onDurabilityEvent: event => branchEvents.push(event),
      })).toEqual({ ok: true, action: 'branch', branch: 'feature/durable-order' })
      expect(branchEvents).toEqual([
        'branch-journal-durable',
        'branch-ref-cas-complete',
        'registry-durable',
        'branch-journal-removed-durable',
      ])

      writeFileSync(join(f.repo, 'docs.md'), '# durable order\n')
      const commitEvents: string[] = []
      expect(await runGitBroker({
        action: 'commit', message: 'durable ordering', paths: ['docs.md'],
      }, {
        ...f.options,
        allowedChanges: allowed(f.repo, ['docs.md']),
        onDurabilityEvent: event => commitEvents.push(event),
      })).toMatchObject({ ok: true, action: 'commit' })
      expect(commitEvents).toEqual([
        'commit-journal-durable',
        'commit-ref-cas-complete',
        'registry-durable',
        'commit-private-state-removed-durable',
        'commit-journal-removed-durable',
      ])
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('retires only an exact side ref already integrated into canonical HEAD', async () => {
    const f = fixture()
    try {
      await createBrokerBranch(f, 'feature/retire-proof')
      writeFileSync(join(f.repo, 'docs.md'), '# integrated docs\n')
      expect(await runGitBroker({
        action: 'commit', message: 'document integration', paths: ['docs.md'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['docs.md']) }))
        .toMatchObject({ ok: true, action: 'commit' })

      expect(await runGitBroker({ action: 'retire', name: 'feature/retire-proof' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'policy' })
      expect(JSON.parse(readFileSync(join(f.state, 'branches.json'), 'utf8')).branches)
        .toHaveProperty('feature/retire-proof')

      expect(git(f.plan.executables.git, f.repo, ['reset', '--hard', '-q', 'HEAD'])).toBe(0)
      expect(git(f.plan.executables.git, f.repo, ['merge', '--ff-only', '-q', 'feature/retire-proof'])).toBe(0)
      const integrated = canonicalGitState(f)
      expect(await runGitBroker({ action: 'retire', name: 'feature/retire-proof' }, f.options))
        .toEqual({ ok: true, action: 'retire', branch: 'feature/retire-proof' })
      expectCanonicalGitStateUnchanged(integrated, canonicalGitState(f))
      expect(git(f.plan.executables.git, f.repo, [
        'show-ref', '--verify', '--quiet', 'refs/heads/feature/retire-proof',
      ])).toBe(0)
      expect(JSON.parse(readFileSync(join(f.state, 'branches.json'), 'utf8')).branches).toEqual({})
      expect(await runGitBroker({ action: 'branch', name: 'feature/next' }, f.options))
        .toEqual({ ok: true, action: 'branch', branch: 'feature/next' })
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('revalidates authorized files immediately before side-ref transaction', async () => {
    for (const mutation of ['edit', 'delete', 'symlink'] as const) {
      const f = fixture()
      try {
        await createBrokerBranch(f, `feature/toctou-${mutation}`)
        writeFileSync(join(f.repo, 'source.ts'), 'before\n')
        writeFileSync(join(f.repo, 'README.md'), '# docs\n')
        const beforeHead = Bun.spawnSync([f.plan.executables.git, 'rev-parse', 'HEAD'], {
          cwd: f.repo, stdout: 'pipe', stderr: 'pipe',
        }).stdout.toString().trim()
        const result = await runGitBroker({
          action: 'commit', message: 'race check', paths: ['source.ts', 'README.md'],
        }, {
          ...f.options,
          allowedChanges: allowed(f.repo, ['source.ts', 'README.md']),
          onBeforeRefTransaction: () => {
            rmSync(join(f.repo, 'source.ts'), { force: true })
            if (mutation === 'edit') writeFileSync(join(f.repo, 'source.ts'), 'after\n')
            if (mutation === 'symlink') symlinkSync(join(f.repo, 'base.txt'), join(f.repo, 'source.ts'))
          },
        })
        expect(result).toMatchObject({ ok: false })
        const afterHead = Bun.spawnSync([f.plan.executables.git, 'rev-parse', 'HEAD'], {
          cwd: f.repo, stdout: 'pipe', stderr: 'pipe',
        }).stdout.toString().trim()
        expect(afterHead).toBe(beforeHead)
        expect(git(f.plan.executables.git, f.repo, ['diff', '--cached', '--quiet'])).toBe(0)
        expect(existsSync(join(f.repo, '.git', 'index.lock'))).toBe(false)
        expect(existsSync(join(f.state, 'transaction.json'))).toBe(false)
      } finally {
        rmSync(f.root, { recursive: true, force: true })
      }
    }
  })

  test('already-aborted and in-progress Git states refuse before mutation', async () => {
    const f = fixture()
    try {
      const abort = new AbortController()
      abort.abort()
      expect(await runGitBroker({ action: 'branch', name: 'feature/aborted' }, {
        ...f.options, signal: abort.signal,
      })).toMatchObject({ ok: false, errorKind: 'aborted' })
      expect(existsSync(join(f.repo, '.git', 'refs', 'heads', 'feature', 'aborted'))).toBe(false)

      for (const state of ['MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG']) {
        writeFileSync(join(f.repo, '.git', state), 'state\n')
        expect(await runGitBroker({ action: 'branch', name: `feature/${state.toLowerCase()}` }, f.options))
          .toMatchObject({ ok: false, errorKind: 'workspace' })
        rmSync(join(f.repo, '.git', state))
      }
      for (const state of ['rebase-merge', 'rebase-apply', 'sequencer']) {
        mkdirSync(join(f.repo, '.git', state))
        expect(await runGitBroker({ action: 'branch', name: `feature/${state}` }, f.options))
          .toMatchObject({ ok: false, errorKind: 'workspace' })
        rmSync(join(f.repo, '.git', state), { recursive: true })
      }
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('restart journal completes a side-ref commit interrupted after ref CAS', async () => {
    const f = fixture()
    try {
      const canonicalBefore = canonicalGitState(f)
      await createBrokerBranch(f, 'feature/crash-source')
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
      writeFileSync(join(f.repo, 'source.ts'), 'crash-safe\n')
      writeFileSync(join(f.repo, 'README.md'), '# crash recovery\n')
      const marker = join(f.root, 'cas-landed')
      const helper = join(f.root, 'crash-helper.ts')
      const modulePath = join(import.meta.dir, 'git-broker.ts')
      writeFileSync(helper, `
import { writeFileSync } from 'fs'
import { runGitBroker } from ${JSON.stringify(modulePath)}
await runGitBroker(
  { action: 'commit', message: 'crash transaction', paths: ['source.ts', 'README.md'] },
  {
    cwd: ${JSON.stringify(f.options.cwd)},
    stateDir: ${JSON.stringify(f.options.stateDir)},
    gitBin: ${JSON.stringify(f.options.gitBin)},
    environment: ${JSON.stringify(f.options.environment)},
    allowedChanges: ${JSON.stringify(allowed(f.repo, ['source.ts', 'README.md']))},
    onAfterRefAdvance: () => {
      writeFileSync(${JSON.stringify(marker)}, 'landed')
      process.kill(process.pid, 'SIGKILL')
    },
  },
)
`)
      const crashed = Bun.spawnSync([f.plan.executables.bun, helper], {
        cwd: f.repo, stdout: 'pipe', stderr: 'pipe', env: process.env,
      })
      expect(crashed.exitCode).not.toBe(0)
      expect(existsSync(marker)).toBe(true)
      expect(existsSync(join(f.repo, '.git', 'index.lock'))).toBe(false)
      expect(existsSync(join(f.state, 'transaction.json'))).toBe(true)
      expect(readdirSync(f.state).some(name => name.startsWith('git-index-'))).toBe(true)
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))

      // Recovery runs before validating this deliberately protected request.
      expect(await runGitBroker({ action: 'branch', name: 'main' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'workspace' })
      expect(git(f.plan.executables.git, f.repo, ['diff', '--cached', '--quiet'])).toBe(0)
      expect(git(f.plan.executables.git, f.repo, ['cat-file', '-e', 'feature/crash-source:source.ts'])).toBe(0)
      const sideTip = gitOutput(f.plan.executables.git, f.repo, ['rev-parse', 'feature/crash-source'])
      expect(JSON.parse(readFileSync(join(f.state, 'branches.json'), 'utf8')).branches)
        .toEqual({ 'feature/crash-source': { tip: sideTip } })
      expect(existsSync(join(f.repo, '.git', 'index.lock'))).toBe(false)
      expect(existsSync(join(f.state, 'transaction.json'))).toBe(false)
      expect(readdirSync(f.state).some(name => name.startsWith('git-index-'))).toBe(false)
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('restart journal completes side-ref creation without changing canonical HEAD/index', async () => {
    const f = fixture()
    try {
      const canonicalBefore = canonicalGitState(f)
      const marker = join(f.root, 'branch-cas-landed')
      const helper = join(f.root, 'branch-crash-helper.ts')
      const modulePath = join(import.meta.dir, 'git-broker.ts')
      writeFileSync(helper, `
import { writeFileSync } from 'fs'
import { runGitBroker } from ${JSON.stringify(modulePath)}
await runGitBroker(
  { action: 'branch', name: 'feature/crash-target' },
  {
    cwd: ${JSON.stringify(f.options.cwd)},
    stateDir: ${JSON.stringify(f.options.stateDir)},
    gitBin: ${JSON.stringify(f.options.gitBin)},
    environment: ${JSON.stringify(f.options.environment)},
    onAfterBranchRefAdvance: () => {
      writeFileSync(${JSON.stringify(marker)}, 'landed')
      process.kill(process.pid, 'SIGKILL')
    },
  },
)
`)
      const crashed = Bun.spawnSync([f.plan.executables.bun, helper], {
        cwd: f.repo, stdout: 'pipe', stderr: 'pipe', env: process.env,
      })
      expect(crashed.exitCode).not.toBe(0)
      expect(existsSync(marker)).toBe(true)
      expect(existsSync(join(f.repo, '.git', 'index.lock'))).toBe(false)
      expect(existsSync(join(f.state, 'branch-transaction.json'))).toBe(true)
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))

      // A post-crash operator checkout does not prevent the already-landed
      // transaction from being reconciled, but it must fence every subsequent
      // advance or retirement of that recovered capability.
      const linked = join(f.root, 'recovered-linked')
      expect(git(f.plan.executables.git, f.repo, [
        'worktree', 'add', '-q', linked, 'feature/crash-target',
      ])).toBe(0)
      // Recovery runs before validating this deliberately protected request.
      expect(await runGitBroker({ action: 'branch', name: 'main' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'workspace' })
      expect(JSON.parse(readFileSync(join(f.state, 'branches.json'), 'utf8')).branches)
        .toEqual({ 'feature/crash-target': { tip: canonicalBefore.head } })
      expect(gitOutput(f.plan.executables.git, f.repo, ['rev-parse', 'feature/crash-target']))
        .toBe(canonicalBefore.head)
      expect(existsSync(join(f.repo, '.git', 'index.lock'))).toBe(false)
      expect(existsSync(join(f.state, 'branch-transaction.json'))).toBe(false)
      writeFileSync(join(f.repo, 'docs.md'), '# recovered checkout remains fenced\n')
      expect(await runGitBroker({
        action: 'commit', message: 'must not advance recovered checkout', paths: ['docs.md'],
      }, { ...f.options, allowedChanges: allowed(f.repo, ['docs.md']) }))
        .toMatchObject({ ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out') })
      expect(await runGitBroker({ action: 'retire', name: 'feature/crash-target' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'policy', detail: expect.stringContaining('checked out') })
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })

  test('branch registry write failure leaves a recoverable journal instead of blind rollback', async () => {
    const f = fixture()
    try {
      const canonicalBefore = canonicalGitState(f)
      const failed = await runGitBroker({ action: 'branch', name: 'feature/persist-later' }, {
        ...f.options,
        onBeforeBranchRegistrySave: () => { throw new Error('injected disk failure') },
      })
      expect(failed).toMatchObject({ ok: false, errorKind: 'git-failed' })
      expect(existsSync(join(f.state, 'branch-transaction.json'))).toBe(true)
      expect(existsSync(join(f.repo, '.git', 'index.lock'))).toBe(false)
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))

      expect(await runGitBroker({ action: 'branch', name: 'main' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'workspace' })
      expect(Object.keys(JSON.parse(readFileSync(join(f.state, 'branches.json'), 'utf8')).branches))
        .toEqual(['feature/persist-later'])
      expect(gitOutput(f.plan.executables.git, f.repo, ['rev-parse', 'feature/persist-later']))
        .toBe(canonicalBefore.head)
      expect(existsSync(join(f.state, 'branch-transaction.json'))).toBe(false)
      expect(await runGitBroker({ action: 'branch', name: 'feature/replacement' }, f.options))
        .toMatchObject({ ok: false, errorKind: 'policy' })
      expectCanonicalGitStateUnchanged(canonicalBefore, canonicalGitState(f))
    } finally {
      rmSync(f.root, { recursive: true, force: true })
    }
  })
})
