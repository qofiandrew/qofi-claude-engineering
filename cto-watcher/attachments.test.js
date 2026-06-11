// attachments.test.js — the attachment-shuttling helpers. NO network, NO
// discord.js: the downloader is injected, so download success/failure/oversize
// and the "could not relay" degradation are all exercised deterministically.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  isShuttleEligible,
  filterShuttleAttachments,
  resolveAttachments,
  appendFailureNotes,
  relayMessage,
  DEFAULT_MAX_ATTACHMENT_BYTES,
} from './attachments.js';

// A capturing fake `send` — records every (channelId, text, mentionUserId, files)
// call so a test can assert exactly what was posted.
function fakeSend() {
  const calls = [];
  const fn = async (channelId, text, mentionUserId, files) => {
    calls.push({ channelId, text, mentionUserId, files: files ?? [] });
  };
  fn.calls = calls;
  return fn;
}

test('isShuttleEligible: .md/.txt only, case-insensitive', () => {
  assert.equal(isShuttleEligible('response.md'), true);
  assert.equal(isShuttleEligible('notes.txt'), true);
  assert.equal(isShuttleEligible('README.MD'), true);
  assert.equal(isShuttleEligible('LOG.TXT'), true);
  assert.equal(isShuttleEligible('image.png'), false);
  assert.equal(isShuttleEligible('archive.tar.gz'), false);
  assert.equal(isShuttleEligible('noextension'), false);
  assert.equal(isShuttleEligible(''), false);
  assert.equal(isShuttleEligible(undefined), false);
  assert.equal(isShuttleEligible(null), false);
});

test('filterShuttleAttachments: keeps only .md/.txt, preserves order', () => {
  const list = [
    { name: 'a.png', url: 'u1' },
    { name: 'b.md', url: 'u2' },
    { name: 'c.txt', url: 'u3' },
    { name: 'd.jpg', url: 'u4' },
  ];
  const out = filterShuttleAttachments(list);
  assert.deepEqual(out.map((a) => a.name), ['b.md', 'c.txt']);
});

test('filterShuttleAttachments: a .md AND a .png → only the .md is carried', () => {
  const out = filterShuttleAttachments([{ name: 'doc.md', url: 'u' }, { name: 'pic.png', url: 'u' }]);
  assert.equal(out.length, 1);
  assert.equal(out[0].name, 'doc.md');
});

test('filterShuttleAttachments: non-array / empty → []', () => {
  assert.deepEqual(filterShuttleAttachments(undefined), []);
  assert.deepEqual(filterShuttleAttachments(null), []);
  assert.deepEqual(filterShuttleAttachments([]), []);
  assert.deepEqual(filterShuttleAttachments([null, { name: 7 }]), []); // malformed entries dropped
});

test('resolveAttachments: success → bytes downloaded, original filename preserved', async () => {
  const calls = [];
  const download = async (url) => { calls.push(url); return Buffer.from('hello ' + url); };
  const { files, failed } = await resolveAttachments(
    [{ name: 'response.md', url: 'https://cdn/x.md', size: 11 }],
    { download },
  );
  assert.deepEqual(calls, ['https://cdn/x.md']);
  assert.equal(failed.length, 0);
  assert.equal(files.length, 1);
  assert.equal(files[0].name, 'response.md');
  assert.equal(files[0].data.toString(), 'hello https://cdn/x.md');
});

test('resolveAttachments: multiple .md/.txt → all carried', async () => {
  const download = async (url) => Buffer.from(url);
  const { files, failed } = await resolveAttachments(
    [{ name: 'a.md', url: 'A' }, { name: 'b.txt', url: 'B' }, { name: 'c.md', url: 'C' }],
    { download },
  );
  assert.equal(failed.length, 0);
  assert.deepEqual(files.map((f) => f.name), ['a.md', 'b.txt', 'c.md']);
});

test('resolveAttachments: download failure → recorded in failed, no crash, no file', async () => {
  const download = async () => { throw new Error('CDN timeout'); };
  const { files, failed } = await resolveAttachments([{ name: 'big.md', url: 'u' }], { download });
  assert.equal(files.length, 0);
  assert.equal(failed.length, 1);
  assert.equal(failed[0].name, 'big.md');
  assert.match(failed[0].reason, /CDN timeout/);
});

test('resolveAttachments: partial failure → good file carried, bad one noted', async () => {
  const download = async (url) => { if (url === 'BAD') throw new Error('boom'); return Buffer.from('ok'); };
  const { files, failed } = await resolveAttachments(
    [{ name: 'good.md', url: 'GOOD' }, { name: 'bad.txt', url: 'BAD' }],
    { download },
  );
  assert.deepEqual(files.map((f) => f.name), ['good.md']);
  assert.deepEqual(failed.map((f) => f.name), ['bad.txt']);
});

test('resolveAttachments: oversize by declared size → not downloaded, marked failed', async () => {
  let called = false;
  const download = async () => { called = true; return Buffer.from('x'); };
  const { files, failed } = await resolveAttachments(
    [{ name: 'huge.md', url: 'u', size: DEFAULT_MAX_ATTACHMENT_BYTES + 1 }],
    { download, maxBytes: DEFAULT_MAX_ATTACHMENT_BYTES },
  );
  assert.equal(called, false); // never fetched — we already knew it was too big
  assert.equal(files.length, 0);
  assert.equal(failed.length, 1);
  assert.match(failed[0].reason, /upload limit/);
});

test('resolveAttachments: oversize discovered after download (no declared size) → failed', async () => {
  const download = async () => Buffer.alloc(20);
  const { files, failed } = await resolveAttachments(
    [{ name: 'sneaky.txt', url: 'u' }],
    { download, maxBytes: 10 },
  );
  assert.equal(files.length, 0);
  assert.equal(failed.length, 1);
  assert.match(failed[0].reason, /upload limit/);
});

test('appendFailureNotes: no failures → text unchanged', () => {
  assert.equal(appendFailureNotes('[cto-7] hi', []), '[cto-7] hi');
});

test('appendFailureNotes: with text → note appended on its own line', () => {
  const out = appendFailureNotes('[cto-7] hi', [{ name: 'x.md' }]);
  assert.equal(out, '[cto-7] hi\n[watcher: could not relay attached x.md]');
});

test('appendFailureNotes: empty text (file-only failed) → note IS the body', () => {
  const out = appendFailureNotes('', [{ name: 'only.md' }]);
  assert.equal(out, '[watcher: could not relay attached only.md]');
});

test('appendFailureNotes: multiple failures → one line each', () => {
  const out = appendFailureNotes('body', [{ name: 'a.md' }, { name: 'b.txt' }]);
  assert.equal(out, 'body\n[watcher: could not relay attached a.md]\n[watcher: could not relay attached b.txt]');
});

// ── relayMessage orchestration (download + notes + send + fallback) ──────────

test('relayMessage: no attachments → one plain send, no download attempted', async () => {
  const send = fakeSend();
  let downloaded = false;
  const r = await relayMessage({
    channelId: 'C', text: '[cto-3] hi', mentionUserId: 'CPO', attachments: [],
    send, download: async () => { downloaded = true; return Buffer.from('x'); },
  });
  assert.equal(downloaded, false);
  assert.equal(send.calls.length, 1);
  assert.deepEqual(send.calls[0], { channelId: 'C', text: '[cto-3] hi', mentionUserId: 'CPO', files: [] });
  assert.deepEqual(r, { sent: true, carried: [], failed: [], fellBackTextOnly: false });
});

test('relayMessage: text + a .md → one send carrying the file with its name preserved', async () => {
  const send = fakeSend();
  const r = await relayMessage({
    channelId: 'BUS', text: '[cto-3] see file', mentionUserId: 'CPO',
    attachments: [{ name: 'design.md', url: 'u', size: 4 }],
    send, download: async () => Buffer.from('body'),
  });
  assert.equal(send.calls.length, 1);
  assert.equal(send.calls[0].text, '[cto-3] see file'); // unchanged: file rides ALONGSIDE the text
  assert.deepEqual(send.calls[0].files.map((f) => f.name), ['design.md']);
  assert.equal(send.calls[0].files[0].data.toString(), 'body');
  assert.deepEqual(r.carried, ['design.md']);
});

test('relayMessage: file-only (empty text) .md → still sent, file carried', async () => {
  const send = fakeSend();
  await relayMessage({
    channelId: 'BUS', text: '[cto-3] ', mentionUserId: 'CPO',
    attachments: [{ name: 'overflow.md', url: 'u', size: 4 }],
    send, download: async () => Buffer.from('long'),
  });
  assert.equal(send.calls.length, 1);
  assert.deepEqual(send.calls[0].files.map((f) => f.name), ['overflow.md']);
});

test('relayMessage: download failure → text still reposted WITH the "could not relay" note, no crash', async () => {
  const send = fakeSend();
  const r = await relayMessage({
    channelId: 'BUS', text: '[cto-3] body', mentionUserId: 'CPO',
    attachments: [{ name: 'lost.md', url: 'u' }],
    send, download: async () => { throw new Error('CDN 500'); },
  });
  assert.equal(send.calls.length, 1);
  assert.equal(send.calls[0].files.length, 0); // nothing to carry
  assert.equal(send.calls[0].text, '[cto-3] body\n[watcher: could not relay attached lost.md]');
  assert.deepEqual(r.failed.map((f) => f.name), ['lost.md']);
  assert.equal(r.fellBackTextOnly, false); // it never tried to send a file, so no fallback needed
});

test('relayMessage: file-bearing send REJECTED → falls back to a text-only send noting every file', async () => {
  const calls = [];
  let first = true;
  const send = async (channelId, text, mentionUserId, files) => {
    calls.push({ text, files: files ?? [] });
    if (first) { first = false; throw new Error('Request entity too large'); } // gateway upload-limit reject
  };
  const r = await relayMessage({
    channelId: 'BUS', text: '[cto-3] body', mentionUserId: 'CPO',
    attachments: [{ name: 'big.md', url: 'u' }],
    send, download: async () => Buffer.from('xxxx'),
  });
  assert.equal(calls.length, 2); // first with file (rejected), then text-only
  assert.equal(calls[0].files.length, 1);
  assert.equal(calls[1].files.length, 0);
  assert.equal(calls[1].text, '[cto-3] body\n[watcher: could not relay attached big.md]');
  assert.equal(r.fellBackTextOnly, true);
});

test('relayMessage: partial download failure THEN file-bearing send rejected → fallback notes EVERY file', async () => {
  // good.md downloads; bad.txt fails download; the send carrying good.md is then
  // rejected → the text-only fallback must note BOTH files as un-relayed.
  const calls = [];
  let first = true;
  const send = async (channelId, text, mentionUserId, files) => {
    calls.push({ text, files: files ?? [] });
    if (first) { first = false; throw new Error('upload too large'); }
  };
  const download = async (url) => { if (url === 'BAD') throw new Error('CDN down'); return Buffer.from('ok'); };
  const r = await relayMessage({
    channelId: 'BUS', text: '[cto-3] body', mentionUserId: 'CPO',
    attachments: [{ name: 'good.md', url: 'GOOD' }, { name: 'bad.txt', url: 'BAD' }],
    send, download,
  });
  assert.equal(calls.length, 2);
  // first attempt: carries good.md, text already notes the un-downloadable bad.txt
  assert.deepEqual(calls[0].files.map((f) => f.name), ['good.md']);
  assert.match(calls[0].text, /could not relay attached bad\.txt/);
  // fallback: text-only, notes BOTH files (good.md couldn't be sent, bad.txt couldn't download)
  assert.equal(calls[1].files.length, 0);
  assert.match(calls[1].text, /could not relay attached good\.md/);
  assert.match(calls[1].text, /could not relay attached bad\.txt/);
  assert.equal(r.fellBackTextOnly, true);
});

test('relayMessage: a text-only send that fails is a real error (bubbles up — no infinite fallback)', async () => {
  const send = async () => { throw new Error('channel not sendable'); };
  await assert.rejects(
    relayMessage({ channelId: 'X', text: 'no files', attachments: [], send, download: async () => Buffer.from('x') }),
    /channel not sendable/,
  );
});
