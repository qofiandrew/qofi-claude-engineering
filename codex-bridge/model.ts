/** Managed Codex model contract, pinned to the live 0.144.1 catalog. */

export const DEFAULT_CODEX_MODEL = 'gpt-5.6-sol' as const
export const DEFAULT_CODEX_MODEL_DISPLAY_NAME = 'GPT-5.6-Sol' as const
export const DEFAULT_CODEX_REASONING_EFFORT = 'ultra' as const
export const CPO_CODEX_REASONING_EFFORT = 'medium' as const

export const CODEX_REASONING_EFFORT_OPTIONS = [
  { reasoningEffort: 'low', description: 'Fast responses with lighter reasoning' },
  { reasoningEffort: 'medium', description: 'Balances speed and reasoning depth for everyday tasks' },
  { reasoningEffort: 'high', description: 'Greater reasoning depth for complex problems' },
  { reasoningEffort: 'xhigh', description: 'Extra high reasoning depth for complex problems' },
  { reasoningEffort: 'max', description: 'Maximum reasoning depth for the hardest problems' },
  { reasoningEffort: 'ultra', description: 'Maximum reasoning with automatic task delegation' },
] as const

export const CODEX_REASONING_EFFORT_VALUES = CODEX_REASONING_EFFORT_OPTIONS
  .map(option => option.reasoningEffort)

export type CodexReasoningEffort =
  (typeof CODEX_REASONING_EFFORT_OPTIONS)[number]['reasoningEffort']

export type ManagedCodexReasoningEffort =
  | typeof CPO_CODEX_REASONING_EFFORT
  | typeof DEFAULT_CODEX_REASONING_EFFORT

export function isCodexReasoningEffort(value: unknown): value is CodexReasoningEffort {
  return typeof value === 'string'
    && CODEX_REASONING_EFFORT_VALUES.includes(value as CodexReasoningEffort)
}

export function isManagedCodexReasoningEffort(value: unknown): value is ManagedCodexReasoningEffort {
  return value === CPO_CODEX_REASONING_EFFORT || value === DEFAULT_CODEX_REASONING_EFFORT
}

/**
 * Primary-worker effort is an archetype policy, not a mutable home/project
 * preference. Unknown/future archetypes fail toward the engineering default.
 */
export function codexReasoningEffortForArchetype(archetype?: string): ManagedCodexReasoningEffort {
  return archetype === 'cpo' ? CPO_CODEX_REASONING_EFFORT : DEFAULT_CODEX_REASONING_EFFORT
}
