import { chmodSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from 'fs'
import { join } from 'path'

export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024
export const MAX_MESSAGE_ATTACHMENT_BYTES = 50 * 1024 * 1024
export const MAX_ATTACHMENTS_PER_MESSAGE = 10

export type DownloadableAttachment = {
  id: string
  name: string | null
  size: number
  url: string
}

export type AttachmentDownloadOptions = {
  inboxDir: string
  maxBytes?: number
  timeoutMs?: number
  signal?: AbortSignal
  fetchImpl?: typeof fetch
  now?: () => number
}

const DISCORD_ATTACHMENT_HOSTS = new Set(['cdn.discordapp.com', 'media.discordapp.net'])
const DISCORD_ATTACHMENT_PATH = /^\/(?:attachments|ephemeral-attachments)\/\d{1,30}\/\d{1,30}\/[^/]+$/
const REDIRECT_STATUS = new Set([301, 302, 303, 307, 308])

export function validateDiscordAttachmentUrl(raw: string, base?: URL): URL {
  if (raw.length === 0 || raw.length > 4096) throw new Error('attachment URL is invalid or oversized')
  let url: URL
  try { url = base ? new URL(raw, base) : new URL(raw) } catch {
    throw new Error('attachment URL is invalid')
  }
  if (
    url.protocol !== 'https:'
    || url.port !== ''
    || url.username !== ''
    || url.password !== ''
    || url.hash !== ''
    || !DISCORD_ATTACHMENT_HOSTS.has(url.hostname.toLowerCase())
    || !DISCORD_ATTACHMENT_PATH.test(url.pathname)
  ) throw new Error('attachment URL is outside the Discord CDN allowlist')
  return url
}

async function fetchDiscordAttachment(
  rawUrl: string,
  signal: AbortSignal,
  fetchImpl: typeof fetch,
): Promise<Response> {
  let url = validateDiscordAttachmentUrl(rawUrl)
  for (let redirects = 0; redirects <= 3; redirects++) {
    const response = await fetchImpl(url, { signal, redirect: 'manual' })
    if (!REDIRECT_STATUS.has(response.status)) return response
    const location = response.headers.get('location')
    try { await response.body?.cancel() } catch {}
    if (!location) throw new Error('attachment redirect omitted Location')
    if (redirects === 3) throw new Error('attachment exceeded redirect limit')
    url = validateDiscordAttachmentUrl(location, url)
  }
  throw new Error('attachment exceeded redirect limit')
}

export async function downloadAttachment(
  att: DownloadableAttachment,
  options: AttachmentDownloadOptions,
): Promise<string> {
  const maxBytes = options.maxBytes ?? MAX_ATTACHMENT_BYTES
  if (!Number.isFinite(att.size) || att.size < 0 || att.size > maxBytes) {
    throw new Error(`attachment too large: ${(att.size / 1024 / 1024).toFixed(1)}MB, max ${maxBytes / 1024 / 1024}MB`)
  }

  const controller = new AbortController()
  const onAbort = () => controller.abort()
  options.signal?.addEventListener('abort', onAbort, { once: true })
  if (options.signal?.aborted) controller.abort()
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? 30_000)
  timeout.unref?.()
  try {
    const res = await fetchDiscordAttachment(
      att.url,
      controller.signal,
      options.fetchImpl ?? fetch,
    )
    if (!res.ok) throw new Error(`attachment download returned HTTP ${res.status}`)
    const contentLength = Number(res.headers.get('content-length'))
    if (Number.isFinite(contentLength) && contentLength > maxBytes) {
      throw new Error(`attachment response too large: ${contentLength} bytes, max ${maxBytes}`)
    }
    if (!res.body) throw new Error('attachment response had no body')

    const chunks: Uint8Array[] = []
    let bytes = 0
    const reader = res.body.getReader()
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      if (!value) continue
      bytes += value.byteLength
      if (bytes > maxBytes) {
        await reader.cancel('attachment size limit exceeded').catch(() => {})
        throw new Error(`attachment response exceeded ${maxBytes} bytes`)
      }
      chunks.push(value)
    }

    const name = att.name ?? att.id
    const rawExt = name.includes('.') ? name.slice(name.lastIndexOf('.') + 1) : 'bin'
    const ext = (rawExt.replace(/[^a-zA-Z0-9]/g, '').slice(0, 16) || 'bin').toLowerCase()
    const safeId = att.id.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64) || 'attachment'
    const path = join(options.inboxDir, `${(options.now ?? Date.now)()}-${safeId}.${ext}`)
    mkdirSync(options.inboxDir, { recursive: true, mode: 0o700 })
    try { chmodSync(options.inboxDir, 0o700) } catch {}
    writeFileSync(path, Buffer.concat(chunks.map(chunk => Buffer.from(chunk)), bytes), { mode: 0o600 })
    return path
  } finally {
    clearTimeout(timeout)
    options.signal?.removeEventListener('abort', onAbort)
  }
}

export function cleanupAttachmentPaths(paths: string[]): void {
  for (const path of paths) {
    try { rmSync(path, { force: true }) } catch {}
  }
}

export type TurnAttachmentScope = {
  paths: string[]
  failures: number
}

/** Materialize one active turn's attachments; callers must cleanup the scope. */
export async function materializeTurnAttachments(
  attachments: readonly DownloadableAttachment[],
  options: AttachmentDownloadOptions & {
    maxTotalBytes?: number
    onError?: (error: unknown) => void
  },
): Promise<TurnAttachmentScope> {
  const paths: string[] = []
  let failures = 0
  let totalBytes = 0
  const maxTotalBytes = options.maxTotalBytes ?? MAX_MESSAGE_ATTACHMENT_BYTES
  for (let index = 0; index < attachments.length; index++) {
    const attachment = attachments[index]
    let downloadedPath: string | undefined
    let aggregateLimited = false
    try {
      const remaining = maxTotalBytes - totalBytes
      if (remaining <= 0) throw new Error('aggregate attachment response reached message limit')
      aggregateLimited = remaining < (options.maxBytes ?? MAX_ATTACHMENT_BYTES)
      downloadedPath = await downloadAttachment(attachment, {
        ...options,
        maxBytes: Math.min(options.maxBytes ?? MAX_ATTACHMENT_BYTES, remaining),
      })
      totalBytes += statSync(downloadedPath).size
      if (totalBytes > maxTotalBytes) {
        cleanupAttachmentPaths([...paths, downloadedPath])
        paths.length = 0
        failures = attachments.length
        try { options.onError?.(new Error('aggregate attachment response exceeded message limit')) } catch {}
        break
      }
      paths.push(downloadedPath)
    } catch (err) {
      if (downloadedPath) cleanupAttachmentPaths([downloadedPath])
      if (aggregateLimited) {
        cleanupAttachmentPaths(paths)
        paths.length = 0
        failures = attachments.length
        try { options.onError?.(new Error('aggregate attachment response exceeded message limit')) } catch {}
        break
      }
      failures++
      try { options.onError?.(err) } catch {}
    }
  }
  return { paths, failures }
}

export function cleanupTurnAttachmentScope(inboxDir: string, paths: string[]): void {
  cleanupAttachmentPaths(paths)
  try { rmSync(inboxDir, { recursive: true, force: true }) } catch {}
}

/** State dirs are single-daemon; leftovers at boot are necessarily stale. */
export function cleanupInbox(inboxDir: string): void {
  let names: string[]
  try { names = readdirSync(inboxDir) } catch { return }
  for (const name of names) {
    try { rmSync(join(inboxDir, name), { recursive: true, force: true }) } catch {}
  }
}
