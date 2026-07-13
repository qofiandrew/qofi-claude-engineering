import { afterEach, expect, test } from 'bun:test'
import { linkSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { loadSendableAttachment } from './sendable.ts'

const roots: string[] = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'qofi-sendable.'))
  roots.push(root)
  const state = join(root, 'state')
  const inbox = join(state, 'inbox')
  const repo = join(root, 'repo')
  mkdirSync(inbox, { recursive: true })
  mkdirSync(repo)
  return { root, state, inbox, repo }
}

test('snapshots a regular file and preserves its requested name', () => {
  const { state, repo } = fixture()
  const file = join(repo, 'report.txt')
  writeFileSync(file, 'verified bytes')
  const result = loadSendableAttachment(file, state, 1024)
  expect(result.name).toBe('report.txt')
  expect(result.attachment.toString()).toBe('verified bytes')
})

test('blocks direct and symlinked channel-state attachments but permits inbox files', () => {
  const { root, state, inbox, repo } = fixture()
  const secret = join(state, 'login-control', 'response.json')
  mkdirSync(join(state, 'login-control'))
  writeFileSync(secret, 'one-time-code')
  expect(() => loadSendableAttachment(secret, state, 1024)).toThrow()

  const alias = join(repo, 'innocent.txt')
  symlinkSync(secret, alias)
  expect(() => loadSendableAttachment(alias, state, 1024)).toThrow()

  const downloaded = join(inbox, 'download.txt')
  writeFileSync(downloaded, 'safe download')
  expect(loadSendableAttachment(downloaded, state, 1024).attachment.toString()).toBe('safe download')
  void root
})

test('blocks an out-of-state hardlink to a private inode', () => {
  const { state, repo } = fixture()
  const secret = join(state, 'access.json')
  writeFileSync(secret, 'private')
  const alias = join(repo, 'public.json')
  linkSync(secret, alias)
  expect(() => loadSendableAttachment(alias, state, 1024)).toThrow(/hardlinked/)
})

test('enforces the attachment size bound before reading', () => {
  const { state, repo } = fixture()
  const file = join(repo, 'large.bin')
  writeFileSync(file, Buffer.alloc(5))
  expect(() => loadSendableAttachment(file, state, 4)).toThrow(/too large/)
})
