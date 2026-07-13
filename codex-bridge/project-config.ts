/** Strict allowlist for project-owned `.codex/config.toml` in unattended turns. */

type Table = Record<string, unknown>

// Both stamped archetypes' AGENTS.md fit below this floor. A lower project
// override can silently truncate or completely disable the unattended doctrine
// before the model sees it, so only omission (the audited CLI default) or a
// value at/above this bound is accepted.
export const MIN_PROJECT_DOC_MAX_BYTES = 8_192
export const MAX_PROJECT_DOC_MAX_BYTES = 1_048_576

function table(value: unknown): Table | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Table
    : null
}

function has(value: Table, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key)
}

function isStringArray(value: unknown): boolean {
  return Array.isArray(value) && value.every(item => typeof item === 'string')
}

/** Parse and completely validate the intentionally tiny safe config surface. */
export function validateProjectConfigToml(content: string): void {
  let config: Table
  try {
    const parsed = Bun.TOML.parse(content)
    const root = table(parsed)
    if (!root) throw new Error('top level is not a TOML table')
    config = root
  } catch (err) {
    throw new Error(`project config is not valid TOML: ${err}`)
  }

  const findings = new Set<string>()
  const unknownKeys = (value: Table, allowed: readonly string[], prefix = '') => {
    for (const key of Object.keys(value)) {
      if (!allowed.includes(key)) findings.add(`${prefix}${key} (unreviewed key)`)
    }
  }
  unknownKeys(config, [
    'personality',
    'model_reasoning_effort',
    'project_doc_max_bytes',
    'allow_login_shell',
    'sandbox_mode',
    'sandbox_workspace_write',
    'shell_environment_policy',
    'features',
  ])

  if (has(config, 'personality') && (
    typeof config.personality !== 'string' || config.personality.length === 0
  )) findings.add('personality (must be a nonempty string)')
  if (has(config, 'model_reasoning_effort') && ![
    'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra',
  ].includes(String(config.model_reasoning_effort))) {
    findings.add('model_reasoning_effort (unknown value)')
  }
  if (has(config, 'project_doc_max_bytes') && (
    !Number.isSafeInteger(config.project_doc_max_bytes)
    || Number(config.project_doc_max_bytes) < MIN_PROJECT_DOC_MAX_BYTES
    || Number(config.project_doc_max_bytes) > MAX_PROJECT_DOC_MAX_BYTES
  )) findings.add(
    `project_doc_max_bytes (must be an integer from ${MIN_PROJECT_DOC_MAX_BYTES} through ${MAX_PROJECT_DOC_MAX_BYTES})`,
  )
  if (has(config, 'allow_login_shell') && config.allow_login_shell !== false) {
    findings.add('allow_login_shell (only false is allowed)')
  }
  if (has(config, 'sandbox_mode') && config.sandbox_mode !== 'read-only') {
    findings.add('sandbox_mode (only read-only is allowed in project config)')
  }

  if (has(config, 'sandbox_workspace_write')) {
    const sandbox = table(config.sandbox_workspace_write)
    if (!sandbox) findings.add('sandbox_workspace_write (must be a table)')
    else {
      unknownKeys(sandbox, ['network_access', 'writable_roots'], 'sandbox_workspace_write.')
      if (has(sandbox, 'network_access') && sandbox.network_access !== false) {
        findings.add('sandbox_workspace_write.network_access (only false is allowed)')
      }
      if (has(sandbox, 'writable_roots') && (
        !Array.isArray(sandbox.writable_roots) || sandbox.writable_roots.length !== 0
      )) findings.add('sandbox_workspace_write.writable_roots (must be empty)')
    }
  }

  if (has(config, 'shell_environment_policy')) {
    const shellEnv = table(config.shell_environment_policy)
    if (!shellEnv) findings.add('shell_environment_policy (must be a table)')
    else {
      unknownKeys(shellEnv, [
        'inherit', 'ignore_default_excludes', 'experimental_use_profile',
        'exclude', 'include_only', 'set',
      ], 'shell_environment_policy.')
      if (has(shellEnv, 'inherit') && !['none', 'core'].includes(String(shellEnv.inherit))) {
        findings.add('shell_environment_policy.inherit (only none/core are allowed)')
      }
      if (has(shellEnv, 'ignore_default_excludes') && shellEnv.ignore_default_excludes !== false) {
        findings.add('shell_environment_policy.ignore_default_excludes (only false is allowed)')
      }
      if (has(shellEnv, 'experimental_use_profile') && shellEnv.experimental_use_profile !== false) {
        findings.add('shell_environment_policy.experimental_use_profile (only false is allowed)')
      }
      for (const key of ['exclude', 'include_only'] as const) {
        if (has(shellEnv, key) && !isStringArray(shellEnv[key])) {
          findings.add(`shell_environment_policy.${key} (must be a string array)`)
        }
      }
      if (has(shellEnv, 'set')) {
        const injected = table(shellEnv.set)
        if (!injected || Object.keys(injected).length !== 0) {
          findings.add('shell_environment_policy.set (must be an empty table)')
        }
      }
    }
  }

  if (has(config, 'features')) {
    const features = table(config.features)
    if (!features) findings.add('features (must be a table)')
    else {
      unknownKeys(features, ['network_proxy', 'hooks', 'codex_hooks'], 'features.')
      if (has(features, 'network_proxy') && features.network_proxy !== false) {
        findings.add('features.network_proxy (only false is allowed)')
      }
      for (const key of ['hooks', 'codex_hooks'] as const) {
        if (has(features, key) && features[key] !== false) {
          findings.add(`features.${key} (only false is allowed)`)
        }
      }
    }
  }

  if (findings.size > 0) {
    throw new Error(`unsafe capability-bearing project config: ${[...findings].sort().join('; ')}`)
  }
}
