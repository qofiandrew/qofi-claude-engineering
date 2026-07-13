#!/usr/bin/env bun
/**
 * Adoption-gated production process seam for Claude PreToolUse records and
 * Codex pre-dispatch rollout records. The same harness policy handles both;
 * callers MUST withhold native tool execution when this process exits 2.
 *
 * Activation is intentionally absent by default. A validated shared
 * Claude+Codex parity receipt, fixed state-root pack/task authority records,
 * and a harness-injected task scope are all required before policy runs.
 */
import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join, resolve } from 'node:path'
import {
  completionReviewPolicySha256,
  parseCompletionReviewPolicy,
} from '../swarm-harness/completion-review-policy.ts'
import {
  createAdoptedGroundingWrapperFromAuthority,
  GROUNDING_WRAPPER_DECISION_SCHEMA,
} from '../swarm-harness/grounding-runtime-wrapper.ts'
import {
  HARNESS_PARITY_RECEIPT_ENV,
  readHarnessParityAdoption,
} from '../swarm-harness/parity-adoption.ts'

process.umask(0o077)

const MAX_INPUT_BYTES = 1024 * 1024

async function boundedStdin(): Promise<string> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const value of process.stdin) {
    const chunk = Buffer.from(value)
    total += chunk.length
    if (total > MAX_INPUT_BYTES) throw new Error('grounding gate input exceeds its byte bound')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString('utf8')
}

function disabledDecision(): Record<string, unknown> {
  return {
    schema: GROUNDING_WRAPPER_DECISION_SCHEMA,
    adopted: false,
    ok: true,
    reason: 'shared-parity-adoption-disabled',
    appended_event_ids: [],
    operation_count: 0,
    gap_report_required: false,
    first_substantive_edit_seen: false,
  }
}

function refuse(reason: string): never {
  process.stdout.write(`${JSON.stringify({
    schema: GROUNDING_WRAPPER_DECISION_SCHEMA,
    adopted: true,
    ok: false,
    reason,
    appended_event_ids: [],
    gap_report_required: false,
  })}\n`)
  process.stderr.write(`swarm-grounding-gate: BLOCKED — ${reason}\n`)
  process.exit(2)
}

function integerPolicy(value: string | undefined): number {
  const parsed = Number(value ?? '36')
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 1024) {
    throw new Error('grounding operation budget is invalid')
  }
  return parsed
}

function observedCorpusCommit(workspace: string): string {
  // The macOS system Git is outside worker-controlled PATH/tool shims. The
  // gate consumes only one full object id and never retains command output.
  const result = spawnSync(
    '/usr/bin/git',
    ['-C', workspace, 'rev-parse', '--verify', 'HEAD^{commit}'],
    {
      encoding: 'utf8', timeout: 10_000, maxBuffer: 64 * 1024,
      env: { PATH: '/usr/bin:/bin', LANG: 'C', LC_ALL: 'C' },
    },
  )
  const output = result.status === 0 ? result.stdout.trim() : ''
  if (!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(output)) {
    throw new Error('worker corpus commit is unavailable')
  }
  return output
}

const receipt = String(process.env[HARNESS_PARITY_RECEIPT_ENV] ?? '').trim()
const legacyConfigured = [
  process.env.CODEX_BRIDGE_HARNESS_ADOPTION,
  process.env.CODEX_BRIDGE_HARNESS_STATE_DIR,
  process.env.CODEX_BRIDGE_HARNESS_ROADMAP_REPO_ROOT,
  process.env.CODEX_BRIDGE_HARNESS_DR_REFS,
].some(value => value !== undefined && value !== '')
if (!receipt && !legacyConfigured) {
  process.stdout.write(`${JSON.stringify(disabledDecision())}\n`)
  process.exit(0)
}

try {
  const runtime = process.env.SWARM_WORKER_RUNTIME
  if (runtime !== 'claude' && runtime !== 'codex') throw new Error('grounding runtime is invalid')
  const swarm = String(process.env.SWARM_NAME ?? '').trim()
  const taskId = String(process.env.SWARM_GROUNDING_TASK_ID ?? '').trim()
  const workspace = resolve(String(
    runtime === 'claude' ? process.env.CLAUDE_PROJECT_DIR : process.env.CODEX_BRIDGE_CWD,
  ))
  const policy = parseCompletionReviewPolicy(JSON.parse(readFileSync(
    join(import.meta.dir, '..', 'swarm-harness', 'completion-review-policy.json'),
    'utf8',
  )))
  const adoption = readHarnessParityAdoption(process.env, {
    expectedSwarm: swarm,
    workspaceRoot: workspace,
    expectedCompletionPolicySha256: completionReviewPolicySha256(policy),
  })
  if (!adoption.enabled) {
    process.stdout.write(`${JSON.stringify(disabledDecision())}\n`)
    process.exit(0)
  }
  const wrapper = createAdoptedGroundingWrapperFromAuthority({
    adoption,
    runtime,
    repoRoot: workspace,
    taskId,
    observedCorpusCommit: observedCorpusCommit(workspace),
    budgetPolicy: { maxOperationsBeforeFirstEdit: integerPolicy(
      process.env.SWARM_GROUNDING_MAX_OPERATIONS,
    ) },
  })
  const text = await boundedStdin()
  let input: unknown
  try { input = JSON.parse(text) } catch { throw new Error('grounding gate input is not JSON') }
  const isAction = input !== null && typeof input === 'object' && !Array.isArray(input)
    && (input as Record<string, unknown>).action === 'file-pack-gap'
  const decision = isAction
    ? wrapper.filePackGap((input as Record<string, unknown>).missing_context_refs as string[])
    : wrapper.process(
      input !== null && typeof input === 'object' && !Array.isArray(input)
        && (input as Record<string, unknown>).action === 'runtime-record'
        ? (input as Record<string, unknown>).record
        : input,
    )
  process.stdout.write(`${JSON.stringify({ adopted: true, ...decision })}\n`)
  if (!decision.ok) {
    process.stderr.write(`swarm-grounding-gate: BLOCKED — ${decision.reason}\n`)
    process.exit(2)
  }
} catch {
  // Raw tool bytes, paths, credentials, and OS errors never reach output.
  refuse('grounding-gate-unavailable')
}
