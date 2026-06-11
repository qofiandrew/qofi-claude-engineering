// attachments.js — attachment-shuttling helpers for the cto-watcher relay.
//
// The watcher REPOSTS messages (it composes a brand-new message *as itself*); it
// does NOT use Discord's native forward. Native forward carries a file along for
// free via the forward snapshot — a repost does not. So to make a file ride along
// on a repost the watcher must DOWNLOAD the original attachment's bytes from its
// CDN url and RE-UPLOAD them as a fresh attachment on the reposted message. This
// is the gap this module closes: it is why hand-forwards already carry files but
// the watcher's auto-repost path used to drop them.
//
// Scope: only `.md` and `.txt` files shuttle (the message-overflow case sends a
// long body as an attached file). Everything else is ignored.
//
// Everything here is pure or dependency-injected (the network downloader is passed
// in), so the whole module is unit-testable without discord.js or a real network.

// Filenames whose extension makes them shuttle-eligible (lower-cased compare).
export const SHUTTLE_EXTENSIONS = ['.md', '.txt'];

// Per-file upload ceiling. Conservative default (8 MiB) so it sits under every
// Discord boost tier's limit; overridable via config.maxAttachmentBytes. Files
// above this are not downloaded — they're noted as "could not relay" instead.
export const DEFAULT_MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024;

/** True if `name` ends in a shuttle-eligible extension (.md/.txt), case-insensitive. */
export function isShuttleEligible(name) {
  if (typeof name !== 'string') return false;
  const lower = name.toLowerCase();
  return SHUTTLE_EXTENSIONS.some((ext) => lower.endsWith(ext));
}

/**
 * Filter a list of attachment descriptors to the shuttle-eligible ones, preserving
 * order. Each descriptor is `{ name, url, size?, contentType? }` (the minimal shape
 * index.js lifts off a discord.js Attachment). Non-eligible types (.png, etc.) and
 * malformed entries (no string name) are dropped.
 * @returns {{name:string,url:string,size?:number,contentType?:string|null}[]}
 */
export function filterShuttleAttachments(attachments) {
  if (!Array.isArray(attachments)) return [];
  return attachments.filter((a) => a && isShuttleEligible(a.name));
}

/**
 * Resolve eligible attachments into re-upload payloads. Downloads each file's bytes
 * with the injected `download(url) -> Promise<Buffer>` fn.
 *
 * NEVER throws: a file that is oversize (by declared size or downloaded length) or
 * whose download rejects/times out is recorded in `failed` (by name + reason) and
 * skipped — so the caller can still repost the text plus a "could not relay" note
 * rather than losing the whole shuttle. A file that downloads fine lands in `files`
 * with its ORIGINAL filename preserved.
 *
 * @param {{name:string,url:string,size?:number}[]} eligible  pre-filtered list (see filterShuttleAttachments)
 * @param {{download:(url:string)=>Promise<Buffer>, maxBytes?:number}} deps
 * @returns {Promise<{files:{name:string,data:Buffer}[], failed:{name:string,reason:string}[]}>}
 */
export async function resolveAttachments(eligible, { download, maxBytes = DEFAULT_MAX_ATTACHMENT_BYTES } = {}) {
  const files = [];
  const failed = [];
  for (const a of eligible ?? []) {
    const name = a?.name ?? 'attachment';
    // Pre-check the declared size so we never download a file we already know is
    // too big to re-upload.
    if (typeof a?.size === 'number' && a.size > maxBytes) {
      failed.push({ name, reason: `exceeds ${maxBytes}-byte upload limit (declared ${a.size} bytes)` });
      continue;
    }
    try {
      const data = await download(a.url);
      if (data == null) throw new Error('download returned no data');
      if (data.length > maxBytes) {
        failed.push({ name, reason: `exceeds ${maxBytes}-byte upload limit (${data.length} bytes)` });
        continue;
      }
      files.push({ name, data });
    } catch (err) {
      failed.push({ name, reason: err?.message ?? String(err) });
    }
  }
  return { files, failed };
}

/**
 * Append one "[watcher: could not relay attached <name>]" line per failed file to
 * `text`, so the recipient at least learns a file was attempted. When `text` is
 * empty (a file-only message whose only file failed), the notes become the whole
 * body — never returns empty when there are failures.
 */
export function appendFailureNotes(text, failed) {
  if (!failed || failed.length === 0) return text;
  const notes = failed.map((f) => `[watcher: could not relay attached ${f.name}]`).join('\n');
  return text ? `${text}\n${notes}` : notes;
}

/**
 * Orchestrate a single repost of text + re-uploaded .md/.txt files. All I/O is
 * injected so this is fully unit-testable without discord.js or the network:
 *   - download(url) -> Promise<Buffer>                       (the CDN fetch)
 *   - send(channelId, text, mentionUserId, files) -> Promise (the Discord post)
 *     `files` is [{name, data:Buffer}]; the wiring turns those into uploads.
 *
 * Guarantees the text is never lost:
 *   - a file that can't be downloaded / is oversize degrades to a note (see
 *     appendFailureNotes) and the rest of the message still goes;
 *   - if the file-bearing send itself is rejected (e.g. the gateway upload limit),
 *     it falls back to a text-only send that notes every file as un-relayed.
 *
 * @returns {Promise<{sent:boolean, carried:string[], failed:{name,reason}[], fellBackTextOnly:boolean}>}
 */
export async function relayMessage({
  channelId, text, mentionUserId = null, attachments = [],
  send, download, maxBytes = DEFAULT_MAX_ATTACHMENT_BYTES, log = () => {}, label = '',
}) {
  const eligible = attachments ?? [];
  if (eligible.length === 0) {
    await send(channelId, text, mentionUserId, []);
    return { sent: true, carried: [], failed: [], fellBackTextOnly: false };
  }

  const { files, failed } = await resolveAttachments(eligible, { download, maxBytes });
  for (const f of failed) log(`[attach] ${label}: could not relay "${f.name}" (${f.reason})`);
  if (files.length > 0) log(`[attach] ${label}: carrying ${files.length} file(s): ${files.map((f) => f.name).join(', ')}`);

  const finalText = appendFailureNotes(text, failed);
  try {
    await send(channelId, finalText, mentionUserId, files);
    return { sent: true, carried: files.map((f) => f.name), failed, fellBackTextOnly: false };
  } catch (err) {
    if (files.length === 0) throw err; // text-only send failed → a real error, bubble up
    // The file-bearing send was rejected (oversize at the gateway, etc.). Fall back
    // to a text-only send so the recipient still gets the message + a note per file.
    log(`[attach] ${label}: send with ${files.length} file(s) failed (${err?.message ?? err}); retrying text-only`);
    const allNoted = appendFailureNotes(text, eligible.map((a) => ({ name: a?.name ?? 'attachment' })));
    await send(channelId, allNoted, mentionUserId, []);
    return { sent: true, carried: [], failed, fellBackTextOnly: true };
  }
}
