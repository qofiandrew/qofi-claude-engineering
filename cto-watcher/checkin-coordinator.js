// Discord transport/correlation for the shared swarm-harness check-in policy.
// Shape, state vocabulary, redaction, and render decisions are delegated to
// HarnessPolicyClient; authenticated routing calls receive() only after the
// existing channel/author allowlist has identified the named CTO.

const NAME = /^[a-z][a-z0-9-]{0,63}$/;
const CHANNEL = /^\d{5,25}$/;

export class CheckInCoordinator {
  constructor({
    policy,
    enqueue,
    deliver,
    metricSink = async () => {},
    onEscalate = async () => {},
    log = () => {},
    now = Date.now,
    maxAttempts = 3,
  }) {
    if (!policy || typeof policy.renderCheckIn !== 'function' || typeof policy.validateCheckIn !== 'function') {
      throw new Error('check-in policy client is required');
    }
    if (typeof enqueue !== 'function' || typeof deliver !== 'function') {
      throw new Error('check-in delivery transport is required');
    }
    if (!Number.isSafeInteger(maxAttempts) || maxAttempts < 2 || maxAttempts > 8) {
      throw new Error('check-in attempt bound is invalid');
    }
    this.policy = policy;
    this.enqueue = enqueue;
    this.deliver = deliver;
    this.metricSink = metricSink;
    this.onEscalate = onEscalate;
    this.log = log;
    this.now = now;
    this.maxAttempts = maxAttempts;
    this.pending = new Map();
    this.issuing = new Map();
    this.processing = new Set();
    this.sequence = 0;
  }

  hasPending(name) { return this.pending.has(name); }
  hasOutstanding(name) { return this.pending.has(name) || this.issuing.has(name); }
  currentTask(name) { return this.pending.get(name)?.currentTask ?? null; }

  async issue({ name, targetChannelId, targetBotUserId, currentTask, status, sentAtMs = this.now() }) {
    if (!NAME.test(name)) throw new Error('check-in CTO name is invalid');
    if (!CHANNEL.test(targetChannelId) || !CHANNEL.test(targetBotUserId)) throw new Error('check-in Discord scope is invalid');
    if (this.hasOutstanding(name)) return { issued: false, reason: 'already-outstanding' };
    const pingId = `idle-${name}-${sentAtMs.toString(36)}-${(++this.sequence).toString(36)}`;
    this.issuing.set(name, pingId);
    const ping = {
      pingId,
      channelId: targetChannelId,
      addressee: name,
      currentTask,
      sentAtMs,
    };
    try {
      const rendered = await this.policy.renderCheckIn(ping, 1, []);
      if (!rendered || typeof rendered.text !== 'string' || !rendered.text) {
        throw new Error('check-in policy returned no message');
      }
      const pending = {
        pingId,
        name,
        targetChannelId,
        targetBotUserId,
        currentTask,
        status,
        firstSentAtMs: sentAtMs,
        attempt: 1,
        repingQueued: false,
      };
      const job = {
        watcherKind: 'checkin-ping',
        watcherName: name,
        pingId,
        currentTask,
        label: `check-in request "${name}"`,
        channelId: targetChannelId,
        body: rendered.text,
        mention: targetBotUserId,
        run: async () => {
          if (this.issuing.get(name) !== pingId) return;
          try {
            await this.deliver(targetChannelId, rendered.text, targetBotUserId);
          } catch {
            throw new Error('check-in Discord delivery failed');
          }
          this.issuing.delete(name);
          if (!this.pending.has(name)) this.pending.set(name, pending);
          this.log(`[checkin] requested ${name} task=${currentTask} status=${status} ping=${pingId}`);
        },
      };
      this.enqueue(job, job.label);
      return { issued: true, pingId };
    } catch (err) {
      this.issuing.delete(name);
      throw err;
    }
  }

  async receive(name, candidate, receivedAtMs = this.now()) {
    const pending = this.pending.get(name);
    if (!pending || pending.repingQueued || this.processing.has(name)) return null;
    this.processing.add(name);
    try {
      const expected = {
        pingId: pending.pingId,
        addressee: pending.name,
        currentTask: pending.currentTask,
        status: pending.status,
      };
      const validation = await this.policy.validateCheckIn(candidate, expected);
      if (!validation || typeof validation.ok !== 'boolean' || !Array.isArray(validation.errors)) {
        throw new Error('check-in policy returned an invalid verdict');
      }
      const latency = receivedAtMs - pending.firstSentAtMs;
      if (!Number.isSafeInteger(latency) || latency < 0) throw new Error('check-in latency is invalid');
      const metric = {
        schema: 'qofi.cto-checkin-metric/v1',
        ping_id: pending.pingId,
        addressee: pending.name,
        current_task: pending.currentTask,
        outcome: validation.ok ? 'accepted' : 'rejected',
        latency_ms: latency,
        attempt: pending.attempt,
        errors: validation.errors,
        recorded_at_ms: receivedAtMs,
      };
      await this.metricSink(metric);
      if (validation.ok) {
        this.pending.delete(name);
        this.log(`[checkin] accepted ${name} task=${pending.currentTask} latency=${latency}ms attempt=${pending.attempt}`);
        return { accepted: true, checkIn: validation.value, metric };
      }

      if (pending.attempt >= this.maxAttempts) {
        this.pending.delete(name);
        await this.onEscalate({ name, currentTask: pending.currentTask, errors: validation.errors, latencyMs: latency });
        this.log(`[checkin] rejected ${name} at bound=${this.maxAttempts}; escalated`);
        return { accepted: false, bounded: true, errors: validation.errors, metric };
      }

      const nextAttempt = pending.attempt + 1;
      const rendered = await this.policy.renderCheckIn({
        pingId: pending.pingId,
        channelId: pending.targetChannelId,
        addressee: pending.name,
        currentTask: pending.currentTask,
        sentAtMs: pending.firstSentAtMs,
      }, nextAttempt, validation.errors);
      if (!rendered || typeof rendered.text !== 'string' || !rendered.text) {
        throw new Error('check-in policy returned no escalation message');
      }
      pending.repingQueued = true;
      const job = {
        watcherKind: 'checkin-reping',
        watcherName: name,
        pingId: pending.pingId,
        label: `check-in escalation "${name}"`,
        channelId: pending.targetChannelId,
        body: rendered.text,
        mention: pending.targetBotUserId,
        run: async () => {
          if (this.pending.get(name) !== pending) return;
          try {
            await this.deliver(pending.targetChannelId, rendered.text, pending.targetBotUserId);
          } catch {
            throw new Error('check-in Discord delivery failed');
          }
          pending.attempt = nextAttempt;
          pending.repingQueued = false;
          this.log(`[checkin] re-pinged ${name} attempt=${nextAttempt}`);
        },
      };
      this.enqueue(job, job.label);
      return { accepted: false, bounded: false, errors: validation.errors, metric };
    } finally {
      this.processing.delete(name);
    }
  }

  cancel(name, reason = 'scope changed') {
    const pending = this.pending.get(name);
    this.pending.delete(name);
    this.issuing.delete(name);
    if (pending) this.log(`[checkin] cancelled ${name} ping=${pending.pingId}: ${reason}`);
  }

  async deliveryDropped(job, err) {
    if (!job || !['checkin-ping', 'checkin-reping'].includes(job.watcherKind)) return false;
    const name = job.watcherName;
    const pending = this.pending.get(name);
    this.pending.delete(name);
    this.issuing.delete(name);
    await this.onEscalate({
      name,
      currentTask: pending?.currentTask ?? job.currentTask ?? 'pending-unavailable',
      errors: ['check-in delivery exhausted its retry queue'],
      latencyMs: null,
      deliveryError: err?.message ?? String(err),
    });
    return true;
  }
}
