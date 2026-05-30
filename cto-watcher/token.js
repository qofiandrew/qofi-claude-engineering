// token.js — resolve the watcher's bot token without duplicating the secret.
//
// Pure, no side effects, importable by tests. Reads a shell-style env file
// (the repo's tokens.env uses `export VAR=value` lines) and returns one var.

import { readFileSync, existsSync } from 'node:fs';

/**
 * Read a single variable from a shell/dotenv-style file. Handles an optional
 * leading `export `, surrounding quotes, and trailing whitespace. Returns null
 * if the file is missing or the var is absent. Never throws on a missing file.
 *
 * @param {string} path
 * @param {string} varName
 * @returns {string | null}
 */
export function readTokenFromEnvFile(path, varName) {
  if (!path || !existsSync(path)) return null;
  const escaped = varName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`^\\s*(?:export\\s+)?${escaped}\\s*=\\s*(.+?)\\s*$`);
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(re);
    if (m) return m[1].replace(/^["']|["']$/g, '');
  }
  return null;
}
