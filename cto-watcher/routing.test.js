// routing.test.js — dry-run of the relay's decision core. NO network, NO
// discord.js. Everything-in-bus, two rigid grammars. Covers the spec's routing
// cases (STATE vs DIRECTIVE vs prose, fail-closed, loop guard, normalization).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  prepareContext,
  decideRoute,
  harnessDraftSurfaceEnabled,
  parseStateLines,
  parseDirective,
} from './routing.js';

const FAKE = {
  busChannelId: '1000000000000000001',
  cpoBotUserId: '2000000000000000002',
  alertUserIds: ['3000000000000000003'],
  ctoChannels: {
    'cto-7': { channelId: '4000000000000000004', botUserId: '4400000000000000044' },
    'cto-3': { channelId: '5000000000000000005', botUserId: '5500000000000000055' },
    'press-backend': '6000000000000000006', // shorthand: no delivery mention
  },
};
const SELF = '9000000000000000009';
const CTO_BOT = '7000000000000000007';
const RANDOM = '8000000000000000008';
const ctx = prepareContext(FAKE, SELF);

const busCpo = (content) => decideRoute({ channelId: FAKE.busChannelId, authorId: FAKE.cpoBotUserId, content }, ctx);

test('config: maps build; liveness OFF by default', () => {
  assert.equal(ctx.ctoByName.get('cto-7').channelId, '4000000000000000004');
  assert.equal(ctx.ctoById.get('4000000000000000004'), 'cto-7');
  assert.equal(ctx.livenessEnabled, false);
  assert.equal(ctx.structuredCheckInsEnabled, false);
  assert.equal(ctx.silenceThresholdMs, 1800000);
  assert.equal(ctx.roadmapEnabled, false);
  assert.equal(ctx.roadmapQueriesEnabled, false);
  assert.equal(ctx.roadmapDigestIntervalMs, 86400000);
  assert.equal(ctx.roadmapDigestChannelId, FAKE.busChannelId);
  assert.equal(ctx.checkInMaxAttempts, 3);
});

test('config: structured check-in adoption requires an explicit opt-in', () => {
  const legacy = prepareContext({ ...FAKE, livenessEnabled: true }, SELF);
  assert.equal(legacy.structuredCheckInsEnabled, false);
  assert.equal(harnessDraftSurfaceEnabled(legacy), false, 'legacy liveness launches no Bun/policy surface');
  const allBound = {
    ...FAKE,
    ctoChannels: {
      ...FAKE.ctoChannels,
      'press-backend': {
        channelId: '6000000000000000006',
        botUserId: '6600000000000000066',
      },
    },
  };
  assert.equal(
    prepareContext({ ...allBound, livenessEnabled: true, structuredCheckInsEnabled: true }, SELF).structuredCheckInsEnabled,
    true,
  );
  assert.throws(
    () => prepareContext({ ...FAKE, livenessEnabled: true, structuredCheckInsEnabled: true }, SELF),
    /requires botUserId\/authorId for CTO "press-backend"/,
  );
  assert.equal(harnessDraftSurfaceEnabled({ ...legacy, structuredCheckInsEnabled: true }), true);
});

test('config: roadmap query and scheduled digest have independent explicit opt-ins', () => {
  const query = prepareContext({ ...FAKE, roadmapQueriesEnabled: true }, SELF);
  assert.equal(query.roadmapQueriesEnabled, true);
  assert.equal(query.roadmapEnabled, false);
  const digest = prepareContext({ ...FAKE, roadmapEnabled: true }, SELF);
  assert.equal(digest.roadmapQueriesEnabled, false);
  assert.equal(digest.roadmapEnabled, true);
});

test('config: roadmap/check-in bounds fail closed', () => {
  assert.throws(() => prepareContext({ ...FAKE, roadmapDigestIntervalSeconds: 59 }, SELF), /60 seconds/);
  assert.throws(() => prepareContext({ ...FAKE, checkInMaxAttempts: 2.5 }, SELF), /integer/);
  assert.throws(() => prepareContext({ ...FAKE, checkInMaxAttempts: 1 }, SELF), /integer/);
  assert.throws(() => prepareContext({ ...FAKE, roadmapRepoRoot: '' }, SELF), /path string/);
});

test('STATE: line → state action, never shuttled', () => {
  const d = busCpo('STATE: cto-7 DRIVING');
  assert.equal(d.action, 'state');
  assert.deepEqual(d.states, [{ name: 'cto-7', state: 'DRIVING' }]);
  assert.deepEqual(d.unknownNames, []);
});

test('multi-line STATE message → both CTOs applied', () => {
  const d = busCpo('STATE: cto-7 DRIVING\nSTATE: cto-3 WAITING_FOR_OPERATOR');
  assert.equal(d.action, 'state');
  assert.deepEqual(d.states, [
    { name: 'cto-7', state: 'DRIVING' },
    { name: 'cto-3', state: 'WAITING_FOR_OPERATOR' },
  ]);
});

test('DIRECTIVE "[cto-7] do X" → route to cto-7 by id, @mention its bot', () => {
  const d = busCpo('[cto-7] do X');
  assert.equal(d.action, 'route');
  assert.equal(d.toChannelId, '4000000000000000004');
  assert.equal(d.toName, 'cto-7');
  assert.equal(d.text, 'do X');
  assert.equal(d.mentionUserId, '4400000000000000044');
});

test('DIRECTIVE to a shorthand CTO → no delivery mention', () => {
  const d = busCpo('[press-backend] status?');
  assert.equal(d.action, 'route');
  assert.equal(d.mentionUserId, null);
});

test('pure prose (no grammar) → ignore: not shuttled, no state, no reset signal', () => {
  const d = busCpo('making progress, looking good');
  assert.equal(d.action, 'ignore');
  assert.match(d.reason, /no grammar/);
});

test('STATE is matched BEFORE directive — a STATE line never leaks to a CTO channel', () => {
  // A message that has a STATE line is treated as state even if another line looks directive-ish.
  const d = busCpo('[cto-7] sneaky\nSTATE: cto-3 STOOD_DOWN');
  assert.equal(d.action, 'state'); // not 'route' — STATE wins, nothing shuttled
  assert.deepEqual(d.states, [{ name: 'cto-3', state: 'STOOD_DOWN' }]);
});

test('watcher-authored bus message → ignore (loop guard, covers shuttled traffic + own pings)', () => {
  const d = decideRoute({ channelId: FAKE.busChannelId, authorId: SELF, content: '[cto-7] echo' }, ctx);
  assert.equal(d.action, 'ignore');
  assert.match(d.reason, /loop guard/);
});

test('bus message from a non-CPO author → ignore', () => {
  const d = decideRoute({ channelId: FAKE.busChannelId, authorId: RANDOM, content: '[cto-7] not the cpo' }, ctx);
  assert.equal(d.action, 'ignore');
  assert.match(d.reason, /not authored by the CPO/);
});

test('enum normalization: lowercase and trailing space parse as DRIVING', () => {
  assert.deepEqual(parseStateLines('STATE: cto-7 driving'), [{ name: 'cto-7', state: 'DRIVING' }]);
  assert.deepEqual(parseStateLines('STATE: cto-7 DRIVING '), [{ name: 'cto-7', state: 'DRIVING' }]);
  assert.deepEqual(parseStateLines('STATE: cto-7 PAUSED'), []); // not a real enum → no match
});

test('unknown name in a DIRECTIVE → fail-closed alert, no send', () => {
  const d = busCpo('[cto-x] do something');
  assert.equal(d.action, 'alert');
  assert.equal(d.name, 'cto-x');
  assert.deepEqual(d.userIds, FAKE.alertUserIds);
  assert.equal(d.toChannelId, undefined);
});

test('unknown name in a STATE line → state action, no tracking, flagged for alert', () => {
  const d = busCpo('STATE: cto-x DRIVING');
  assert.equal(d.action, 'state');
  assert.deepEqual(d.states, []);          // not tracked
  assert.deepEqual(d.unknownNames, ['cto-x']); // → operator-alert in index.js
});

test('A1: CTO-channel message FROM the channel CTO → shuttle, @mention CPO, [name] prefix, ctoActivity', () => {
  // cto-3's author id is its botUserId (5500…055) since no explicit authorId is set.
  const d = decideRoute({ channelId: '5000000000000000005', authorId: '5500000000000000055', content: 'build green' }, ctx);
  assert.equal(d.action, 'shuttle');
  assert.equal(d.toChannelId, FAKE.busChannelId);
  assert.equal(d.text, '[cto-3] build green');
  assert.equal(d.mentionUserId, FAKE.cpoBotUserId);
  assert.equal(d.ctoActivity, true);
});

test('A1: operator-forwarded message (human author, empty content) → drop-foreign, NOT shuttled, no activity', () => {
  const d = decideRoute({ channelId: '5000000000000000005', authorId: RANDOM /* the human operator */, content: '' }, ctx);
  assert.equal(d.action, 'drop-foreign');
  assert.equal(d.sourceName, 'cto-3');
  assert.notEqual(d.ctoActivity, true);
});

test('A1: a different bot in a CTO channel (not the CTO author) → drop-foreign', () => {
  const d = decideRoute({ channelId: '4000000000000000004', authorId: CTO_BOT /* some other bot */, content: 'hi' }, ctx);
  assert.equal(d.action, 'drop-foreign');
  assert.equal(d.sourceName, 'cto-7');
});

test('A2: CTO author posts empty/embed-only → skip-empty (NOT shuttled) but STILL counts as activity', () => {
  const d = decideRoute({ channelId: '4000000000000000004', authorId: '4400000000000000044', content: '   ' }, ctx);
  assert.equal(d.action, 'skip-empty');
  assert.equal(d.sourceName, 'cto-7');
  assert.equal(d.ctoActivity, true); // the CTO is active even though nothing shuttles
});

test('A1 fail-closed: CTO channel with NO author id (shorthand, no botUserId) → drop-foreign', () => {
  // press-backend is shorthand "name": "channelId" -> authorId resolves to null.
  assert.equal(ctx.ctoByName.get('press-backend').authorId, null);
  const d = decideRoute({ channelId: '6000000000000000006', authorId: CTO_BOT, content: 'anything' }, ctx);
  assert.equal(d.action, 'drop-foreign'); // no author id -> nothing shuttles from here
});

test('A1 mirror: bus-side CPO parsing is unaffected by the inbound author allowlist', () => {
  // STATE and directive on the bus are author==CPO, a separate path from A1.
  assert.equal(busCpo('STATE: cto-7 DRIVING').action, 'state');
  assert.equal(busCpo('[cto-7] do X').action, 'route');
});

test('structured check-in provenance is bound to the named CTO channel and author', () => {
  const body = JSON.stringify({ schema: 'qofi.cto-checkin/v1', ping_id: 'idle-1' });
  const trusted = decideRoute({
    channelId: '5000000000000000005', authorId: '5500000000000000055', content: body,
  }, ctx);
  assert.equal(trusted.action, 'shuttle');
  assert.equal(trusted.sourceName, 'cto-3');
  const forged = decideRoute({
    channelId: '5000000000000000005', authorId: RANDOM, content: body,
  }, ctx);
  assert.equal(forged.action, 'drop-foreign');
});

test('parseDirective basics', () => {
  assert.deepEqual(parseDirective('[a] b'), { name: 'a', body: 'b' });
  assert.deepEqual(parseDirective('[a]b'), { name: 'a', body: 'b' });
  assert.equal(parseDirective('STATE: a DRIVING'), null);
  assert.equal(parseDirective('no bracket'), null);
});

test('config validation still refuses bus-as-CTO and self==CPO', () => {
  assert.throws(() => prepareContext({ ...FAKE, ctoChannels: { dup: FAKE.busChannelId } }, SELF), /also the bus channel/);
  assert.throws(() => prepareContext(FAKE, FAKE.cpoBotUserId), /must be its own bot identity/);
});

// ── Attachment shuttling (.md/.txt repost) ──────────────────────────────────
// The decision core only decides WHICH files ride along (the eligible .md/.txt
// subset, in order) and that a file-only message is no longer "empty". index.js
// does the actual download + re-upload.

const md = (name, extra = {}) => ({ name, url: `https://cdn/${name}`, size: 100, ...extra });

test('attach: config exposes attachment knobs with sane defaults', () => {
  assert.equal(ctx.maxAttachmentBytes, 8 * 1024 * 1024);
  assert.equal(ctx.attachmentDownloadTimeoutMs, 15000);
  const tuned = prepareContext({ ...FAKE, maxAttachmentBytes: 1234, attachmentDownloadTimeoutSeconds: 5 }, SELF);
  assert.equal(tuned.maxAttachmentBytes, 1234);
  assert.equal(tuned.attachmentDownloadTimeoutMs, 5000);
});

test('attach: CTO->bus message with text + a .md → shuttle with [name] prefix AND the .md carried', () => {
  const d = decideRoute({
    channelId: '5000000000000000005', authorId: '5500000000000000055',
    content: 'see attached', attachments: [md('design.md')],
  }, ctx);
  assert.equal(d.action, 'shuttle');
  assert.equal(d.text, '[cto-3] see attached'); // text still gets the [name] prefix
  assert.equal(d.mentionUserId, FAKE.cpoBotUserId);
  assert.deepEqual(d.attachments.map((a) => a.name), ['design.md']); // filename preserved for re-upload
});

test('attach: CPO->CTO directive with a .txt → route, prefix stripped, .txt carried', () => {
  const d = decideRoute({
    channelId: FAKE.busChannelId, authorId: FAKE.cpoBotUserId,
    content: '[cto-7] apply this', attachments: [md('patch.txt')],
  }, ctx);
  assert.equal(d.action, 'route');
  assert.equal(d.toChannelId, '4000000000000000004');
  assert.equal(d.text, 'apply this'); // [cto-7] prefix stripped
  assert.deepEqual(d.attachments.map((a) => a.name), ['patch.txt']);
});

test('attach: file-only CTO message (empty text + one .md) → NOT skip-empty; shuttles carrying the file', () => {
  // The overflow case: a long response sent purely as a file, no text body.
  const d = decideRoute({
    channelId: '5000000000000000005', authorId: '5500000000000000055',
    content: '', attachments: [md('overflow.md')],
  }, ctx);
  assert.equal(d.action, 'shuttle'); // NOT skip-empty
  assert.match(d.text, /^\[cto-3\]/); // still routes under the CTO's name
  assert.equal(d.attachments.length, 1);
  assert.equal(d.attachments[0].name, 'overflow.md');
  assert.equal(d.ctoActivity, true);
});

test('attach: file-only CTO message with NO eligible file (empty text + a .png) → still skip-empty', () => {
  const d = decideRoute({
    channelId: '5000000000000000005', authorId: '5500000000000000055',
    content: '', attachments: [{ name: 'pic.png', url: 'u', size: 5 }],
  }, ctx);
  assert.equal(d.action, 'skip-empty'); // a .png is not shuttle-eligible → nothing to carry → empty
  assert.equal(d.ctoActivity, true);
});

test('attach: a .md AND a .png on one message → only the .md is carried', () => {
  const d = decideRoute({
    channelId: '5000000000000000005', authorId: '5500000000000000055',
    content: 'mixed', attachments: [md('keep.md'), { name: 'drop.png', url: 'u', size: 9 }],
  }, ctx);
  assert.equal(d.action, 'shuttle');
  assert.deepEqual(d.attachments.map((a) => a.name), ['keep.md']); // .png ignored
});

test('attach: loop guard — the watcher\'s OWN reposted file-bearing bus message is not re-shuttled', () => {
  const d = decideRoute({
    channelId: FAKE.busChannelId, authorId: SELF,
    content: '[cto-7] echo', attachments: [md('reposted.md')],
  }, ctx);
  assert.equal(d.action, 'ignore'); // self-author wins regardless of attachments
  assert.match(d.reason, /loop guard/);
});

test('attach: allowlist still governs — a non-CTO author posting a .md in a CTO channel is dropped', () => {
  const d = decideRoute({
    channelId: '4000000000000000004', authorId: RANDOM, // not cto-7's author
    content: '', attachments: [md('sneaky.md')],
  }, ctx);
  assert.equal(d.action, 'drop-foreign'); // author check precedes the attachment/empty logic
  assert.notEqual(d.ctoActivity, true);
});

test('attach: a file-only CPO bus message with NO [name] directive → ignore (no destination)', () => {
  // Without a "[name]" prefix there's no way to know which CTO the file is for.
  const d = decideRoute({
    channelId: FAKE.busChannelId, authorId: FAKE.cpoBotUserId,
    content: '', attachments: [md('orphan.md')],
  }, ctx);
  assert.equal(d.action, 'ignore');
});
