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

// Discord's hard cap on a message's `content` field. A relay body at or under
// this (counting the mention prefix the sender prepends) goes inline; over it,
// the body rides as a .md attachment and the content becomes a budgeted carrier.
export const CONTENT_LIMIT = 2000;
// Headroom under the hard cap so an off-by-a-few never recreates the 400.
export const OVERFLOW_MARGIN = 24;

/**
 * Cut `s` to at most `budget` chars, preferring a newline then a space boundary
 * (only when it's reasonably deep into the slice) so the excerpt ends on a clean
 * break, not mid-token. Trailing whitespace trimmed. Pure.
 */
export function sliceOnBoundary(s, budget) {
  if (budget <= 0 || !s) return '';
  if (s.length <= budget) return s;
  let cut = s.slice(0, budget);
  const nl = cut.lastIndexOf('\n');
  const sp = cut.lastIndexOf(' ');
  const floor = Math.floor(budget * 0.5);
  const at = nl >= floor ? nl : (sp >= floor ? sp : -1);
  if (at > 0) cut = cut.slice(0, at);
  return cut.replace(/\s+$/, '');
}

/**
 * Decide whether a relay body fits Discord's content limit once the mention
 * prefix the caller will prepend is counted. If it fits, the body is returned
 * unchanged. If not, build a CARRIER message — an explicit "fetch the attachment"
 * instruction + a budgeted head excerpt + a truncation marker — and the FULL body
 * as a .md attachment payload {name,data}. The budget subtracts the mention
 * prefix + instruction + marker FIRST, so a long mention or long filename shrinks
 * the excerpt rather than pushing the carrier over the limit: the carrier itself
 * can never exceed it, so the fix can never recreate the original 400. Pure (no
 * Date, no I/O).
 *
 * @returns {{overflow:boolean, carrierText:string, file:{name:string,data:Buffer}|null}}
 */
export function composeOverflow({
  text, mentionPrefix = '', filename = 'relay-overflow.md',
  limit = CONTENT_LIMIT, margin = OVERFLOW_MARGIN,
}) {
  const full = text ?? '';
  if (mentionPrefix.length + full.length <= limit) {
    return { overflow: false, carrierText: full, file: null };
  }
  const instruction = `[overflow: full body attached as ${filename} — call download_attachment then Read it]`;
  const marker = '\n…[truncated — full body is in the attached file]';
  const sep = '\n\n';
  const fixed = mentionPrefix.length + instruction.length + sep.length + marker.length + margin;
  const budget = Math.max(0, limit - fixed);
  const excerpt = sliceOnBoundary(full, budget);
  const carrierText = excerpt
    ? `${instruction}${sep}${excerpt}${marker}`
    : `${instruction}${marker}`;
  return { overflow: true, carrierText, file: { name: filename, data: Buffer.from(full, 'utf8') } };
}

/**
 * Orchestrate a single repost of text + re-uploaded .md/.txt files. All I/O is
 * injected so this is fully unit-testable without discord.js or the network:
 *   - download(url) -> Promise<Buffer>                       (the CDN fetch)
 *   - send(channelId, text, mentionUserId, files) -> Promise (the Discord post)
 *     `files` is [{name, data:Buffer}]; the wiring turns those into uploads.
 *   - overflowName() -> string                               (the .md filename; injected for tests)
 *
 * Guarantees the body is never lost:
 *   - a downloaded file that can't be fetched / is oversize degrades to a note
 *     (appendFailureNotes) and the rest of the message still goes;
 *   - a body over Discord's 2000-char `content` cap is carried as a .md
 *     attachment with a budgeted carrier message (composeOverflow) — chunking is
 *     deliberately NOT used so the single mention triggers the recipient once;
 *   - if the file-bearing send is rejected and there were DOWNLOADED files, it
 *     retries without them (the overflow file IS the body, so it's never shed);
 *     with no downloaded files, a rejection bubbles up so the delivery queue
 *     classifies it (a 413 on the overflow file is terminal → dead-letter).
 *
 * @returns {Promise<{sent:boolean, carried:string[], failed:{name,reason}[], overflowed:boolean, fellBackTextOnly:boolean}>}
 */
export async function relayMessage({
  channelId, text, mentionUserId = null, attachments = [],
  send, download, maxBytes = DEFAULT_MAX_ATTACHMENT_BYTES, log = () => {}, label = '',
  overflowName = () => 'relay-overflow.md',
}) {
  const eligible = attachments ?? [];
  const { files, failed } = eligible.length
    ? await resolveAttachments(eligible, { download, maxBytes })
    : { files: [], failed: [] };
  for (const f of failed) log(`[attach] ${label}: could not relay "${f.name}" (${f.reason})`);
  if (files.length > 0) log(`[attach] ${label}: carrying ${files.length} file(s): ${files.map((f) => f.name).join(', ')}`);

  const finalText = appendFailureNotes(text, failed);
  const mentionPrefix = mentionUserId ? `<@${mentionUserId}> ` : '';
  const ofName = overflowName();
  const { overflow, carrierText, file: ofFile } = composeOverflow({ text: finalText, mentionPrefix, filename: ofName });
  if (overflow) log(`[overflow] ${label}: body ${finalText.length} chars > content cap — carrying as ${ofName}`);
  const outFiles = ofFile ? [...files, ofFile] : files;

  try {
    await send(channelId, carrierText, mentionUserId, outFiles);
    return { sent: true, carried: files.map((f) => f.name), failed, overflowed: overflow, fellBackTextOnly: false };
  } catch (err) {
    // The overflow file IS the body — never shed it. Only the DOWNLOADED
    // attachments are sheddable: retry with the body-carrier (+ overflow file)
    // but drop the downloaded ones, noting each. With no downloaded files (only
    // the overflow file, or none), bubble up so the queue classifies it.
    if (files.length === 0) throw err;
    log(`[attach] ${label}: send with ${files.length} downloaded file(s) failed (${err?.message ?? err}); retrying without them`);
    const allNoted = appendFailureNotes(text, eligible.map((a) => ({ name: a?.name ?? 'attachment' })));
    const { carrierText: notedCarrier, file: notedOf } = composeOverflow({ text: allNoted, mentionPrefix, filename: ofName });
    await send(channelId, notedCarrier, mentionUserId, notedOf ? [notedOf] : []);
    return { sent: true, carried: [], failed, overflowed: !!notedOf, fellBackTextOnly: true };
  }
}
