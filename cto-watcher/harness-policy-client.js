// Node transport for harness-policy-helper.ts. Policy remains in the shared
// swarm-harness TypeScript modules; this file only runs the bounded helper and
// validates its process envelope.

import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MAX_INPUT_BYTES = 64 * 1024;
const MAX_OUTPUT_BYTES = 512 * 1024;
const OPERATION = /^(?:contract|checkin\.(?:render|validate)|roadmap\.(?:query|digest)|event\.active-task)$/;

export class HarnessPolicyClient {
  constructor({
    bunPath = process.env.SWARM_BUN_BIN || 'bun',
    helperPath = join(HERE, 'harness-policy-helper.ts'),
    timeoutMs = 5000,
  } = {}) {
    if (typeof bunPath !== 'string' || !bunPath) throw new Error('Bun path is required');
    if (typeof helperPath !== 'string' || !helperPath) throw new Error('policy helper path is required');
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 30_000) {
      throw new Error('policy helper timeout is invalid');
    }
    this.bunPath = bunPath;
    this.helperPath = helperPath;
    this.timeoutMs = timeoutMs;
  }

  run(operation, payload = {}) {
    if (!OPERATION.test(operation)) return Promise.reject(new Error('policy operation is invalid'));
    const input = JSON.stringify(payload);
    if (Buffer.byteLength(input) > MAX_INPUT_BYTES) {
      return Promise.reject(new Error('policy payload exceeds bound'));
    }
    return new Promise((resolve, reject) => {
      const child = spawn(this.bunPath, [this.helperPath, operation], {
        stdio: ['pipe', 'pipe', 'pipe'],
        // The helper needs filesystem paths from the bounded payload, not the
        // watcher's Discord/provider credentials. Do not leak the daemon env.
        env: {
          PATH: process.env.PATH,
          HOME: process.env.HOME,
          TMPDIR: process.env.TMPDIR,
          BUN_TELEMETRY: '0',
        },
      });
      const stdout = [];
      const stderr = [];
      let stdoutBytes = 0;
      let stderrBytes = 0;
      let settled = false;
      const finish = (fn, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        fn(value);
      };
      const timer = setTimeout(() => {
        child.kill('SIGKILL');
        finish(reject, new Error('policy helper timed out'));
      }, this.timeoutMs);
      child.on('error', err => finish(reject, new Error(`policy helper unavailable: ${err.message}`)));
      child.stdout.on('data', chunk => {
        stdoutBytes += chunk.length;
        if (stdoutBytes > MAX_OUTPUT_BYTES) {
          child.kill('SIGKILL');
          finish(reject, new Error('policy helper output exceeds bound'));
          return;
        }
        stdout.push(chunk);
      });
      child.stderr.on('data', chunk => {
        stderrBytes += chunk.length;
        if (stderrBytes <= 8192) stderr.push(chunk);
      });
      child.on('close', code => {
        if (settled) return;
        if (code !== 0) {
          const lines = Buffer.concat(stderr).toString('utf8').trim().split('\n').map(line => line.trim());
          const detail = lines.find(line => line.startsWith('error: '))
            || lines.find(line => line && !line.startsWith('Bun v') && line !== '^')
            || `exit ${code}`;
          finish(reject, new Error(`policy helper failed: ${detail.slice(0, 500)}`));
          return;
        }
        try {
          const text = Buffer.concat(stdout).toString('utf8').trim();
          finish(resolve, JSON.parse(text));
        } catch {
          finish(reject, new Error('policy helper returned invalid JSON'));
        }
      });
      child.stdin.end(input);
    });
  }

  contract() { return this.run('contract'); }
  renderCheckIn(ping, attempt = 1, errors = []) {
    return this.run('checkin.render', { ping, attempt, errors });
  }
  validateCheckIn(candidate, expected) {
    return this.run('checkin.validate', { candidate, expected });
  }
  roadmapQuery(store) { return this.run('roadmap.query', store); }
  roadmapDigest(store, previous = null) { return this.run('roadmap.digest', { ...store, previous }); }
  activeTask(store, swarm, state, correlation) {
    return this.run('event.active-task', { ...store, swarm, state, correlation });
  }
}
