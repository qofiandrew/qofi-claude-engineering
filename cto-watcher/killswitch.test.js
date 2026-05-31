// killswitch.test.js — DM kill switch: command grammar, fail-closed auth keyed
// off the OPERATOR group's allowFrom (NOT the bus group), and pause state.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { parseDmCommand, readOperatorAllowFrom, authorizeDm, KillSwitch } from './killswitch.js';

const OPERATOR_CH = '1508921858165047390';
const BUS_CH = '1510301812434141194';
const OPERATOR_ID = '1507069153335443608'; // human, in operator group's allowFrom
const WATCHER_BOT = '1510298728148369448'; // in the BUS group's allowFrom (wrong list)
const STRANGER = '4040404040404040404';

// Write a temp access.json mirroring the live shape (operator + bus groups).
function writeAccess(dir, body) {
  const p = join(dir, 'access.json');
  writeFileSync(p, JSON.stringify(body));
  return p;
}
const TMP = mkdtempSync(join(tmpdir(), 'ks-'));
const ACCESS = writeAccess(TMP, {
  dmPolicy: 'pairing',
  allowFrom: [],
  groups: {
    [OPERATOR_CH]: { requireMention: false, allowFrom: [OPERATOR_ID] },
    [BUS_CH]: { requireMention: true, allowFrom: [WATCHER_BOT] },
  },
  pending: {},
});

test('parseDmCommand: exact, case-insensitive, trimmed; else null', () => {
  assert.equal(parseDmCommand('!watcher stop'), 'stop');
  assert.equal(parseDmCommand('  !WATCHER STOP  '), 'stop');
  assert.equal(parseDmCommand('!watcher start'), 'start');
  assert.equal(parseDmCommand('!watcher status'), 'status');
  assert.equal(parseDmCommand('!watcher state'), 'state');
  assert.equal(parseDmCommand('  !WATCHER STATE  '), 'state');
  assert.equal(parseDmCommand('!watcher pause'), null);
  assert.equal(parseDmCommand('watcher stop'), null);
  assert.equal(parseDmCommand('hello'), null);
  assert.equal(parseDmCommand(''), null);
});

test('authorize: DM "!watcher state" from operator id → authorized (same auth as kill switch)', () => {
  const d = authorizeDm({ isDM: true, senderId: OPERATOR_ID, content: '!watcher state', allowFrom: [OPERATOR_ID] });
  assert.deepEqual(d, { command: 'state', authorized: true, reason: 'ok' });
});

test('authorize: "!watcher state" from a non-operator id → NOT authorized (ignored)', () => {
  const d = authorizeDm({ isDM: true, senderId: STRANGER, content: '!watcher state', allowFrom: [OPERATOR_ID] });
  assert.equal(d.command, 'state');
  assert.equal(d.authorized, false);
});

test('DM-only: "!watcher state" in a GUILD channel → not a command path (not a DM)', () => {
  const d = authorizeDm({ isDM: false, senderId: OPERATOR_ID, content: '!watcher state', allowFrom: [OPERATOR_ID] });
  assert.equal(d.command, 'state');
  assert.equal(d.authorized, false);
  assert.match(d.reason, /not a DM/);
});

test('readOperatorAllowFrom: reads the OPERATOR group', () => {
  assert.deepEqual(readOperatorAllowFrom(ACCESS, OPERATOR_CH), [OPERATOR_ID]);
});

test('readOperatorAllowFrom is fail-closed: missing file / bad path / unset id → []', () => {
  assert.deepEqual(readOperatorAllowFrom(join(TMP, 'nope.json'), OPERATOR_CH), []);
  assert.deepEqual(readOperatorAllowFrom(ACCESS, null), []);
  assert.deepEqual(readOperatorAllowFrom(ACCESS, 'channel-with-no-group'), []);
  const bad = writeAccess(mkdtempSync(join(tmpdir(), 'ks-bad-')), {}); // no groups
  assert.deepEqual(readOperatorAllowFrom(bad, OPERATOR_CH), []);
});

test('authorize: DM "!watcher stop" from operator id → authorized', () => {
  const d = authorizeDm({ isDM: true, senderId: OPERATOR_ID, content: '!watcher stop', allowFrom: [OPERATOR_ID] });
  assert.deepEqual(d, { command: 'stop', authorized: true, reason: 'ok' });
});

test('authorize: DM from a stranger (not in operator allowFrom) → NOT authorized', () => {
  const d = authorizeDm({ isDM: true, senderId: STRANGER, content: '!watcher stop', allowFrom: [OPERATOR_ID] });
  assert.equal(d.command, 'stop');
  assert.equal(d.authorized, false);
});

test('LOCKOUT GUARD: DM from the watcher bot / bus allowFrom id → NOT authorized (keyed off OPERATOR group)', () => {
  // The bus group's allowFrom is the watcher bot. Auth uses the OPERATOR allowFrom,
  // which does NOT contain the watcher — so a bus-listed id can never pause.
  const d = authorizeDm({ isDM: true, senderId: WATCHER_BOT, content: '!watcher stop', allowFrom: [OPERATOR_ID] });
  assert.equal(d.authorized, false);
});

test('DM-only: a valid command in a GUILD channel → NOT authorized (not a DM)', () => {
  const d = authorizeDm({ isDM: false, senderId: OPERATOR_ID, content: '!watcher stop', allowFrom: [OPERATOR_ID] });
  assert.equal(d.command, 'stop');
  assert.equal(d.authorized, false);
  assert.match(d.reason, /not a DM/);
});

test('fail-closed: empty operator allowFrom (unreadable ACL) authorizes NO ONE', () => {
  const d = authorizeDm({ isDM: true, senderId: OPERATOR_ID, content: '!watcher stop', allowFrom: [] });
  assert.equal(d.authorized, false);
});

test('KillSwitch: default ACTIVE (pm2 restart → active); stop halts relay + liveness; start resumes', () => {
  const ks = new KillSwitch();
  assert.equal(ks.paused, false); // restart-while-paused → back ACTIVE
  assert.equal(ks.relayHalted(), false);
  assert.equal(ks.livenessHalted(), false);
  ks.stop();
  assert.equal(ks.paused, true);
  assert.equal(ks.relayHalted(), true); // CTO message would NOT be shuttled
  assert.equal(ks.livenessHalted(), true); // DRIVING-past-threshold would NOT be pinged
  ks.start();
  assert.equal(ks.relayHalted(), false); // shuttling/pinging work again
  assert.equal(ks.livenessHalted(), false);
});
