import { afterEach, describe, expect, test } from 'bun:test'
import {
  chmodSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  canonicalAuthorityJsonLine,
  HARNESS_PARITY_ADOPTION_CONTRACT,
  HARNESS_PARITY_ADOPTION_SCHEMA,
  readHarnessParityAdoption,
} from './parity-adoption.ts'

const POLICY = 'a'.repeat(64)
const roots: string[] = []

afterEach(() => {
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true })
})

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'qofi-parity-adoption-')))
  chmodSync(root, 0o700)
  roots.push(root)
  const authority = join(root, 'authority')
  const state = join(root, 'state')
  const workspace = join(root, 'workspace')
  for (const path of [authority, state, workspace]) mkdirSync(path, { mode: 0o700 })
  const receipt = join(authority, 'receipt.json')
  const value = {
    schema: HARNESS_PARITY_ADOPTION_SCHEMA,
    contract: HARNESS_PARITY_ADOPTION_CONTRACT,
    swarm: 'press-backend',
    runtimes: ['claude', 'codex'],
    state_root: state,
    roadmap_repo_root: workspace,
    dr_refs: ['ADR-0022', 'ADR-0023'],
    completion_policy_sha256: POLICY,
  }
  const write = (candidate: unknown = value) => {
    writeFileSync(receipt, canonicalAuthorityJsonLine(candidate), { mode: 0o600 })
  }
  const read = (env: NodeJS.ProcessEnv = { SWARM_HARNESS_PARITY_RECEIPT: receipt }) => (
    readHarnessParityAdoption(env, {
      expectedSwarm: 'press-backend',
      workspaceRoot: workspace,
      expectedCompletionPolicySha256: POLICY,
    })
  )
  return { root, authority, state, workspace, receipt, value, write, read }
}

describe('operator-issued atomic parity adoption', () => {
  test('is off by default and refuses legacy environment self-assertion', () => {
    const f = fixture()
    expect(f.read({})).toEqual({ enabled: false })
    expect(() => f.read({ CODEX_BRIDGE_HARNESS_ADOPTION: 'claude-codex-v1' }))
      .toThrow('operator receipt')
  })

  test('one canonical private receipt binds both runtimes, swarm, policy, and paths', () => {
    const f = fixture()
    f.write()
    expect(f.read()).toMatchObject({
      enabled: true,
      receiptPath: f.receipt,
      stateRoot: f.state,
      roadmapRepoRoot: f.workspace,
      drRefs: ['ADR-0022', 'ADR-0023'],
      completionPolicySha256: POLICY,
      swarm: 'press-backend',
    })
  })

  test('refuses partial runtime scope, wrong swarm, and wrong policy identity', () => {
    const partial = fixture()
    partial.write({ ...partial.value, runtimes: ['codex'] })
    expect(() => partial.read()).toThrow('atomically scoped')

    const scoped = fixture()
    scoped.write()
    expect(() => readHarnessParityAdoption(
      { SWARM_HARNESS_PARITY_RECEIPT: scoped.receipt },
      {
        expectedSwarm: 'other-swarm', workspaceRoot: scoped.workspace,
        expectedCompletionPolicySha256: POLICY,
      },
    )).toThrow('wrong swarm scope')
    expect(() => readHarnessParityAdoption(
      { SWARM_HARNESS_PARITY_RECEIPT: scoped.receipt },
      {
        expectedSwarm: 'press-backend', workspaceRoot: scoped.workspace,
        expectedCompletionPolicySha256: 'b'.repeat(64),
      },
    )).toThrow('wrong completion policy')
  })

  test('refuses noncanonical, permissive, and hard-linked authority bytes', () => {
    const noncanonical = fixture()
    writeFileSync(noncanonical.receipt, `${JSON.stringify(noncanonical.value)}\n`, { mode: 0o600 })
    expect(() => noncanonical.read()).toThrow('not canonical')

    const permissive = fixture()
    permissive.write()
    chmodSync(permissive.receipt, 0o640)
    expect(() => permissive.read()).toThrow('single-link mode 0600')

    const linked = fixture()
    linked.write()
    linkSync(linked.receipt, join(linked.authority, 'second-link.json'))
    expect(() => linked.read()).toThrow('single-link mode 0600')
  })

  test('refuses an authority state root inside the worker workspace', () => {
    const f = fixture()
    const nested = join(f.workspace, 'state')
    mkdirSync(nested, { mode: 0o700 })
    f.write({ ...f.value, state_root: nested })
    expect(() => f.read()).toThrow('outside the worker workspace')
  })

  test('refuses a worker-workspace receipt even when its file mode looks private', () => {
    const f = fixture()
    const workerAuthority = join(f.workspace, 'authority')
    mkdirSync(workerAuthority, { mode: 0o700 })
    const receipt = join(workerAuthority, 'receipt.json')
    writeFileSync(receipt, canonicalAuthorityJsonLine(f.value), { mode: 0o600 })
    expect(() => readHarnessParityAdoption(
      { SWARM_HARNESS_PARITY_RECEIPT: receipt },
      {
        expectedSwarm: 'press-backend', workspaceRoot: f.workspace,
        expectedCompletionPolicySha256: POLICY,
      },
    )).toThrow('receipt must be outside')
  })
})
