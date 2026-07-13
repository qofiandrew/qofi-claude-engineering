// Discord transport and schedule around the shared harness roadmap policy.
// Parsing, CAS verification, query rendering, and digest rendering all execute
// in swarm-harness through HarnessPolicyClient.

export class RoadmapCoordinator {
  constructor({
    policy,
    store,
    enqueue,
    deliver,
    digestChannelId,
    digestIntervalMs,
    enabled = false,
    queryEnabled = false,
    log = () => {},
  }) {
    if (!policy
      || typeof policy.contract !== 'function'
      || typeof policy.roadmapQuery !== 'function'
      || typeof policy.activeTask !== 'function') {
      throw new Error('roadmap policy client is required');
    }
    if (!store || typeof store.repoRoot !== 'string' || typeof store.authorityFile !== 'string') {
      throw new Error('roadmap store scope is required');
    }
    if (typeof enqueue !== 'function' || typeof deliver !== 'function') {
      throw new Error('roadmap delivery transport is required');
    }
    if (!Number.isSafeInteger(digestIntervalMs) || digestIntervalMs < 60_000) {
      throw new Error('roadmap digest interval is invalid');
    }
    this.policy = policy;
    this.store = store;
    this.enqueue = enqueue;
    this.deliver = deliver;
    this.digestChannelId = digestChannelId;
    this.digestIntervalMs = digestIntervalMs;
    this.enabled = enabled;
    this.queryEnabled = queryEnabled;
    this.log = log;
    this.contract = null;
    this.previous = null;
    this.lastDeliveredAt = null;
    this.digestQueued = false;
    this.digestLoading = false;
  }

  async initialize() {
    const contract = await this.policy.contract();
    if (!contract
      || typeof contract.contract_sha256 !== 'string'
      || typeof contract.roadmap_query_command !== 'string'
      || typeof contract.checkin_schema !== 'string'
      || !Array.isArray(contract.swarm_states)) {
      throw new Error('shared harness contract is invalid');
    }
    this.contract = contract;
    return contract;
  }

  matchesQuery(content) {
    return this.queryEnabled
      && Boolean(this.contract)
      && typeof content === 'string'
      && content.trim().toLowerCase() === this.contract.roadmap_query_command;
  }

  async resolveTask(swarm, state, correlation) {
    try {
      const result = await this.policy.activeTask(this.store, swarm, state, correlation);
      if (!result || typeof result.current_task !== 'string') throw new Error('roadmap task result is invalid');
      return result;
    } catch (err) {
      this.log(`[roadmap] trusted task binding unavailable for ${swarm}`);
      return this.policy.activeTask({}, swarm, state, correlation);
    }
  }

  async enqueueQuery({ channelId, reply, label = 'roadmap query' }) {
    let result;
    try {
      result = await this.policy.roadmapQuery(this.store);
    } catch (err) {
      this.log('[roadmap] trusted query artifact unavailable');
      result = { text: '🧭 Roadmap unavailable · harness artifact not readable' };
    }
    if (!result || typeof result.text !== 'string' || !result.text) throw new Error('roadmap query result is invalid');
    const job = {
      watcherKind: 'roadmap-query',
      label,
      channelId,
      body: result.text,
      mention: null,
      run: async () => {
        try { await reply(result.text); } catch { throw new Error('roadmap Discord delivery failed'); }
      },
    };
    this.enqueue(job, label);
  }

  async tick(nowMs) {
    if (!this.enabled || this.digestQueued || this.digestLoading) return false;
    if (this.lastDeliveredAt !== null && nowMs - this.lastDeliveredAt < this.digestIntervalMs) return false;
    let result;
    this.digestLoading = true;
    try {
      result = await this.policy.roadmapDigest(this.store, this.previous);
    } catch (err) {
      this.log('[roadmap] trusted scheduled digest artifact unavailable');
      return false;
    } finally {
      this.digestLoading = false;
    }
    if (!result || typeof result.text !== 'string' || !result.document) {
      throw new Error('roadmap digest result is invalid');
    }
    this.digestQueued = true;
    const job = {
      watcherKind: 'roadmap-digest',
      label: 'scheduled roadmap digest',
      channelId: this.digestChannelId,
      body: result.text,
      mention: null,
      run: async () => {
        try {
          await this.deliver(this.digestChannelId, result.text, null);
        } catch {
          throw new Error('roadmap Discord delivery failed');
        }
        this.previous = result.document;
        this.lastDeliveredAt = nowMs;
        this.digestQueued = false;
        this.log(`[roadmap] scheduled digest delivered generated=${result.document.generated_at ?? 'no-events'}`);
      },
    };
    this.enqueue(job, job.label);
    return true;
  }

  deliveryDropped(job) {
    if (job?.watcherKind !== 'roadmap-digest') return false;
    this.digestQueued = false;
    return true;
  }
}
