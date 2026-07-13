import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  cleanupAttachmentPaths,
  cleanupInbox,
  cleanupTurnAttachmentScope,
  downloadAttachment,
  materializeTurnAttachments,
  validateDiscordAttachmentUrl,
} from './attachments.ts'
import { BoundedSerialQueue } from './queue.ts'

describe('attachment lifecycle', () => {
  const discordUrl = (name: string) => `https://cdn.discordapp.com/attachments/123/456/${name}`
  let dir: string
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'codex-attachments-')) })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))

  test('downloads a bounded response to a private file and cleans it up', async () => {
    const path = await downloadAttachment({
      id: '123', name: 'report.TXT', size: 5, url: discordUrl('report.TXT'),
    }, {
      inboxDir: dir,
      now: () => 1000,
      fetchImpl: async () => new Response('hello'),
    })
    expect(path).toBe(join(dir, '1000-123.txt'))
    expect(readFileSync(path, 'utf8')).toBe('hello')
    expect(statSync(path).mode & 0o777).toBe(0o600)
    cleanupAttachmentPaths([path])
    expect(existsSync(path)).toBe(false)
  })

  test('rejects a streamed response that exceeds the actual byte limit', async () => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('123'))
        controller.enqueue(new TextEncoder().encode('456'))
        controller.close()
      },
    })
    await expect(downloadAttachment({
      id: '1', name: 'x.bin', size: 3, url: discordUrl('x.bin'),
    }, {
      inboxDir: dir,
      maxBytes: 5,
      fetchImpl: async () => new Response(stream),
    })).rejects.toThrow('exceeded')
    expect(readdirSync(dir)).toEqual([])
  })

  test('rejects HTTP failures and clears stale inbox contents', async () => {
    await expect(downloadAttachment({
      id: '1', name: 'x.bin', size: 3, url: discordUrl('x.bin'),
    }, {
      inboxDir: dir,
      fetchImpl: async () => new Response('missing', { status: 404 }),
    })).rejects.toThrow('HTTP 404')
    writeFileSync(join(dir, 'stale.bin'), 'stale')
    cleanupInbox(dir)
    expect(readdirSync(dir)).toEqual([])
  })

  test('materialization enforces aggregate actual bytes, not only declared sizes', async () => {
    const scope = await materializeTurnAttachments([
      { id: 'a', name: 'a.bin', size: 1, url: discordUrl('a.bin') },
      { id: 'b', name: 'b.bin', size: 1, url: discordUrl('b.bin') },
    ], {
      inboxDir: dir,
      maxBytes: 10,
      maxTotalBytes: 5,
      fetchImpl: async () => new Response('123'),
    })
    expect(scope.paths).toEqual([])
    expect(scope.failures).toBe(2)
    expect(readdirSync(dir)).toEqual([])
  })

  test('queued turn files do not exist during the active turn and prior files are cleaned first', async () => {
    const inboxA = join(dir, 'message-a')
    const inboxB = join(dir, 'message-b')
    let releaseA!: () => void
    let markAReady!: () => void
    const holdA = new Promise<void>(resolve => { releaseA = resolve })
    const aReady = new Promise<void>(resolve => { markAReady = resolve })
    const order: string[] = []
    const queue = new BoundedSerialQueue(2)
    const attachment = (id: string) => ({
      id, name: `${id}.txt`, size: 4, url: discordUrl(`${id}.txt`),
    })
    const fetchImpl = async () => new Response('data')

    expect(queue.tryEnqueue(async () => {
      const scope = await materializeTurnAttachments([attachment('a')], {
        inboxDir: inboxA,
        fetchImpl,
      })
      try {
        order.push('a-active')
        expect(scope.paths.every(existsSync)).toBe(true)
        expect(existsSync(inboxB)).toBe(false)
        markAReady()
        await holdA
      } finally {
        cleanupTurnAttachmentScope(inboxA, scope.paths)
      }
    })).toBe(true)

    expect(queue.tryEnqueue(async () => {
      order.push('b-start')
      expect(existsSync(inboxA)).toBe(false)
      const scope = await materializeTurnAttachments([attachment('b')], {
        inboxDir: inboxB,
        fetchImpl,
      })
      try {
        expect(scope.paths.every(existsSync)).toBe(true)
      } finally {
        cleanupTurnAttachmentScope(inboxB, scope.paths)
      }
    })).toBe(true)

    await aReady
    expect(existsSync(inboxB)).toBe(false)
    releaseA()
    await queue.drain()
    expect(order).toEqual(['a-active', 'b-start'])
    expect(existsSync(inboxA)).toBe(false)
    expect(existsSync(inboxB)).toBe(false)
  })

  test('rejects local, non-HTTPS, non-CDN, credentialed, and malformed CDN URLs before fetch', async () => {
    const rejected = [
      'http://cdn.discordapp.com/attachments/1/2/x',
      'file:///etc/passwd',
      'https://127.0.0.1/attachments/1/2/x',
      'https://localhost/attachments/1/2/x',
      'https://example.com/attachments/1/2/x',
      'https://user@cdn.discordapp.com/attachments/1/2/x',
      'https://cdn.discordapp.com:444/attachments/1/2/x',
      'https://cdn.discordapp.com/not-attachments/1/2/x',
    ]
    let calls = 0
    for (const url of rejected) {
      expect(() => validateDiscordAttachmentUrl(url)).toThrow()
      await expect(downloadAttachment({ id: 'x', name: 'x', size: 1, url }, {
        inboxDir: dir,
        fetchImpl: async () => { calls++; return new Response('never') },
      })).rejects.toThrow()
    }
    expect(calls).toBe(0)
  })

  test('manually revalidates every redirect Location against the CDN allowlist', async () => {
    let calls = 0
    const allowedPath = await downloadAttachment({
      id: 'ok', name: 'ok.txt', size: 2, url: discordUrl('start.txt'),
    }, {
      inboxDir: dir,
      fetchImpl: async (_input, init) => {
        calls++
        expect(init?.redirect).toBe('manual')
        if (calls === 1) return new Response('', {
          status: 302,
          headers: { location: 'https://media.discordapp.net/attachments/123/456/final.txt' },
        })
        return new Response('ok')
      },
    })
    expect(readFileSync(allowedPath, 'utf8')).toBe('ok')

    calls = 0
    await expect(downloadAttachment({
      id: 'bad', name: 'bad.txt', size: 2, url: discordUrl('redirect.txt'),
    }, {
      inboxDir: dir,
      fetchImpl: async () => {
        calls++
        return new Response('', { status: 302, headers: { location: 'http://127.0.0.1/secret' } })
      },
    })).rejects.toThrow('Discord CDN allowlist')
    expect(calls).toBe(1)
  })
})
