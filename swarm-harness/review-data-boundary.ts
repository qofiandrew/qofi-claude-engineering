import { createHash } from 'node:crypto'

export const REVIEW_DATA_ENVELOPE_SCHEMA = 'qofi-review-data-envelope/v1' as const

export type ReviewDirection = 'claude-to-codex' | 'codex-to-fable'

export type ReviewDataEnvelope = Readonly<{
  schema: typeof REVIEW_DATA_ENVELOPE_SCHEMA
  direction: ReviewDirection
  doctrine_sha256: string
  system_prompt: string
  reviewed_data: Readonly<{
    diff_or_files: string
    context_refs: readonly string[]
    mode: 'code' | 'security' | 'design' | 'directive'
  }>
  capabilities: Readonly<{
    write: false
    exec: false
    nested_mcp: false
    plugins: false
    agents: false
  }>
  terminal_hop: true
}>

const MAX_REVIEW_BYTES = 512 * 1024
const MAX_DOCTRINE_BYTES = 64 * 1024
const CONTEXT_REF = /^[a-z][a-z0-9_.:-]{0,127}$/

/**
 * Construct the common provider boundary. Reviewed bytes are placed only in a
 * dedicated data field; they are never interpolated into the system doctrine.
 */
export function buildReviewDataEnvelope(input: Readonly<{
  direction: ReviewDirection
  doctrine: string
  diffOrFiles: string
  contextRefs: readonly string[]
  mode: 'code' | 'security' | 'design' | 'directive'
}>): ReviewDataEnvelope {
  if (!['claude-to-codex', 'codex-to-fable'].includes(input.direction)) {
    throw new Error('review direction is invalid')
  }
  if (typeof input.doctrine !== 'string' || input.doctrine.length < 1
    || Buffer.byteLength(input.doctrine) > MAX_DOCTRINE_BYTES || input.doctrine.includes('\0')) {
    throw new Error('review doctrine is invalid')
  }
  if (typeof input.diffOrFiles !== 'string' || input.diffOrFiles.length < 1
    || Buffer.byteLength(input.diffOrFiles) > MAX_REVIEW_BYTES || input.diffOrFiles.includes('\0')) {
    throw new Error('reviewed data is invalid')
  }
  if (!Array.isArray(input.contextRefs) || input.contextRefs.length > 32
    || input.contextRefs.some(ref => typeof ref !== 'string' || !CONTEXT_REF.test(ref))
    || new Set(input.contextRefs).size !== input.contextRefs.length) {
    throw new Error('review context refs are invalid')
  }
  if (!['code', 'security', 'design', 'directive'].includes(input.mode)) {
    throw new Error('review mode is invalid')
  }
  const doctrine = input.doctrine
  return {
    schema: REVIEW_DATA_ENVELOPE_SCHEMA,
    direction: input.direction,
    doctrine_sha256: createHash('sha256').update(doctrine).digest('hex'),
    system_prompt: doctrine,
    reviewed_data: {
      diff_or_files: input.diffOrFiles,
      context_refs: [...input.contextRefs],
      mode: input.mode,
    },
    capabilities: {
      write: false,
      exec: false,
      nested_mcp: false,
      plugins: false,
      agents: false,
    },
    terminal_hop: true,
  }
}
