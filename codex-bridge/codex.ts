/**
 * Codex CLI runner. One Codex thread per Discord chat, persisted in
 * sessions.json so conversation context survives daemon restarts.
 *
 * First message in a chat:   codex exec --json ... -   (prompt on stdin)
 * Every later message:       codex exec resume <threadId> --json ... -
 *
 * `--json` emits JSONL events on stdout. Observed stream (codex-cli 0.142.3):
 *   {"type":"thread.started","thread_id":"<uuid>"}
 *   {"type":"turn.started"}
 *   {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"..."}}
 *   {"type":"turn.completed","usage":{...}}
 * Failures surface as {"type":"turn.failed",...} or {"type":"error","message":...}.
 *
 * NOTE: `exec resume` does not accept `-s`/`-m` positional flags — sandbox and
 * model are passed uniformly as `-c key=value` overrides on both forms.
 */

import { spawn } from 'child_process'
import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'fs'
import { join } from 'path'

export type CodexTurnResult = {
  ok: boolean
  threadId: string | null
  /** All agent_message texts in the turn, in order. The last one is the reply. */
  messages: string[]
  error?: string
}

/** Parse a `codex exec --json` stdout stream. Pure — unit-tested on fixtures. */
export function parseCodexEvents(jsonl: string): CodexTurnResult {
  let threadId: string | null = null
  const messages: string[] = []
  let completed = false
  let error: string | undefined
  for (const line of jsonl.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    let ev: any
    try {
      ev = JSON.parse(trimmed)
    } catch {
      continue // non-JSON noise on stdout — ignore
    }
    switch (ev.type) {
      case 'thread.started':
        threadId = typeof ev.thread_id === 'string' ? ev.thread_id : threadId
        break
      case 'item.completed':
        if (ev.item?.type === 'agent_message' && typeof ev.item.text === 'string') {
          messages.push(ev.item.text)
        }
        break
      case 'turn.completed':
        completed = true
        break
      case 'turn.failed':
        error = ev.error?.message ?? ev.message ?? 'turn failed'
        break
      case 'error':
        error = ev.message ?? 'error'
        break
    }
  }
  if (error) return { ok: false, threadId, messages, error }
  if (!completed) return { ok: false, threadId, messages, error: 'stream ended without turn.completed' }
  return { ok: true, threadId, messages }
}

export type CodexConfig = {
  cwd: string
  /** sandbox_mode: read-only | workspace-write | danger-full-access */
  sandbox: string
  model?: string
  profile?: string
  timeoutMs: number
  bin?: string
}

export function buildCodexArgs(threadId: string | null, cfg: CodexConfig): string[] {
  const common = [
    '--json',
    '--skip-git-repo-check',
    '-c', `sandbox_mode="${cfg.sandbox}"`,
    ...(cfg.model ? ['-c', `model="${cfg.model}"`] : []),
    ...(cfg.profile ? ['-p', cfg.profile] : []),
    '-', // prompt on stdin — immune to argv length limits and leading-dash text
  ]
  return threadId ? ['exec', 'resume', threadId, ...common] : ['exec', ...common]
}

/** Run one Codex turn. Never rejects — errors come back in the result. */
export function runCodexTurn(
  threadId: string | null,
  prompt: string,
  cfg: CodexConfig,
): Promise<CodexTurnResult> {
  return new Promise(resolve => {
    const args = buildCodexArgs(threadId, cfg)
    let child
    try {
      child = spawn(cfg.bin ?? 'codex', args, {
        cwd: cfg.cwd,
        stdio: ['pipe', 'pipe', 'pipe'],
        env: process.env,
      })
    } catch (err) {
      resolve({ ok: false, threadId, messages: [], error: `spawn failed: ${err}` })
      return
    }

    let stdout = ''
    let stderr = ''
    let settled = false
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      child.kill('SIGKILL')
      resolve({
        ok: false,
        threadId,
        messages: [],
        error: `codex turn timed out after ${Math.round(cfg.timeoutMs / 1000)}s`,
      })
    }, cfg.timeoutMs)

    child.stdout.on('data', (d: Buffer) => { stdout += d.toString() })
    child.stderr.on('data', (d: Buffer) => { stderr += d.toString() })
    child.on('error', err => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve({ ok: false, threadId, messages: [], error: `codex spawn error: ${err.message}` })
    })
    child.on('close', code => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      const parsed = parseCodexEvents(stdout)
      if (!parsed.ok && code !== 0 && !parsed.error?.includes('turn failed')) {
        const tail = stderr.trim().split('\n').slice(-3).join(' | ')
        parsed.error = `codex exited ${code}${tail ? `: ${tail}` : ''}${parsed.error ? ` (${parsed.error})` : ''}`
      }
      resolve(parsed)
    })

    child.stdin.write(prompt)
    child.stdin.end()
  })
}

/** chat_id → Codex thread_id map, persisted atomically in the state dir. */
export class SessionStore {
  private readonly file: string
  private readonly dir: string

  constructor(stateDir: string) {
    this.dir = stateDir
    this.file = join(stateDir, 'sessions.json')
  }

  private read(): Record<string, string> {
    try {
      return JSON.parse(readFileSync(this.file, 'utf8'))
    } catch {
      return {}
    }
  }

  get(chatId: string): string | null {
    return this.read()[chatId] ?? null
  }

  set(chatId: string, threadId: string): void {
    const all = this.read()
    all[chatId] = threadId
    mkdirSync(this.dir, { recursive: true, mode: 0o700 })
    const tmp = this.file + '.tmp'
    writeFileSync(tmp, JSON.stringify(all, null, 2) + '\n', { mode: 0o600 })
    renameSync(tmp, this.file)
  }

  /** Drop a mapping — used when a resume fails because the thread is gone. */
  delete(chatId: string): void {
    const all = this.read()
    if (!(chatId in all)) return
    delete all[chatId]
    const tmp = this.file + '.tmp'
    writeFileSync(tmp, JSON.stringify(all, null, 2) + '\n', { mode: 0o600 })
    renameSync(tmp, this.file)
  }
}
