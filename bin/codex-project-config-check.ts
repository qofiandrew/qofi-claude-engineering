#!/usr/bin/env bun
/**
 * Thin CLI around the daemon's single project-config validator. The launcher
 * invokes this from a trusted cwd with Bun repo discovery/loaders disabled.
 */

import { resolve } from 'path'
import { inspectProjectConfig } from '../codex-bridge/preflight.ts'

const path = process.argv[2]
if (!path || process.argv.length !== 3) {
  console.error('usage: codex-project-config-check.ts <.codex/config.toml>')
  process.exit(2)
}

try {
  const root = resolve(path, '..', '..')
  const expected = resolve(root, '.codex', 'config.toml')
  if (resolve(path) !== expected || inspectProjectConfig(root) === null) {
    throw new Error('project config path must be the canonical .codex/config.toml')
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(3)
}
