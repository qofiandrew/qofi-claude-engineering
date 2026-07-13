import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const daemon = readFileSync(join(import.meta.dir, 'daemon.ts'), 'utf8')
const lifecycle = readFileSync(join(import.meta.dir, 'daemon-lifecycle.ts'), 'utf8')

describe('daemon harness lifecycle wiring contract', () => {
  test('requires explicit shared parity adoption and constructs the ground-truth stores', () => {
    expect(daemon).toContain('parseDaemonHarnessAdoption(process.env, {')
    expect(lifecycle).toContain('HARNESS_PARITY_ADOPTION_CONTRACT')
    expect(lifecycle).toContain('return readHarnessParityAdoption(env, options)')
    expect(daemon).toContain("'SWARM_HARNESS_PARITY_RECEIPT'")
    expect(daemon).toContain('new NormalizedEventStore(eventsDir')
    expect(daemon).toContain('new RoadmapStore(')
    expect(daemon).toContain("status: 'draft-disabled'")
  })

  test('derives final review material under the repository lease before release', () => {
    const finalizerStart = daemon.indexOf('const finalizeTurnBoundary = async ()')
    const finalizerEnd = daemon.indexOf('\n  try {\n    retryNotices.register', finalizerStart)
    const finalizer = daemon.slice(finalizerStart, finalizerEnd)
    const snapshot = finalizer.indexOf('const changes = diffWorkspaceSnapshots(')
    const material = finalizer.indexOf('harnessLifecycle.deriveCompletionMaterial(changes)')
    const leaseRelease = finalizer.indexOf('repoLease.release()')
    expect(snapshot).toBeGreaterThan(0)
    expect(material).toBeGreaterThan(snapshot)
    expect(leaseRelease).toBeGreaterThan(material)
  })

  test('runs the host completion review and root receipt handoff at the terminal boundary', () => {
    const finalizerStart = daemon.indexOf('const finalizeTurnBoundary = async ()')
    const finalizerEnd = daemon.indexOf('\n  try {\n    retryNotices.register', finalizerStart)
    const finalizer = daemon.slice(finalizerStart, finalizerEnd)
    const revoke = finalizer.indexOf('revokeTurnRuntimeAccess(')
    const material = finalizer.indexOf('harnessLifecycle.deriveCompletionMaterial(changes)')
    const begin = finalizer.indexOf('appServerManager.beginCompletionReview(')
    const poll = finalizer.indexOf('appServerManager.completionReviewStatus(')
    const release = finalizer.indexOf('repoLease.release()')
    const broker = finalizer.indexOf('completeCodexTaskViaRootBroker({')
    const end = finalizer.indexOf('appServerManager.endCompletionReview(')
    const cleanup = finalizer.indexOf('appServerManager.cleanupComplete(')
    expect(revoke).toBeGreaterThan(0)
    expect(material).toBeGreaterThan(revoke)
    expect(begin).toBeGreaterThan(material)
    expect(poll).toBeGreaterThan(begin)
    expect(release).toBeGreaterThan(poll)
    expect(broker).toBeGreaterThan(release)
    expect(end).toBeGreaterThan(broker)
    expect(cleanup).toBeGreaterThan(end)
  })

  test('uses the common stop boundary and emits done only after accepted delivery/review evidence', () => {
    const start = daemon.indexOf('if (harnessLifecycle) {', daemon.indexOf('let text = codexReplyText(result)'))
    const end = daemon.indexOf('\n    const chunks = suppressReply', start)
    const adopted = daemon.slice(start, end)
    expect(adopted).toContain('new StopDeliveryPipeline({')
    expect(adopted).toContain('await harnessLifecycle.completeTask({')
    expect(adopted).toContain('if (!completion.boundary.accepted)')
    const rootAccepted = adopted.indexOf('if (rootBrokerCompletion)')
    const rootDone = adopted.indexOf("eventLog.emit('turn.completed'", rootAccepted)
    const localGate = adopted.indexOf('if (!completion.boundary.accepted)')
    const localDone = adopted.indexOf("eventLog.emit('turn.completed'", localGate)
    expect(rootDone).toBeGreaterThan(rootAccepted)
    expect(localDone).toBeGreaterThan(localGate)
    expect(adopted).not.toContain('boundedOutboundChunks(')
    expect(adopted).not.toContain('(msg.channel as any).send(')
  })

  test('normalizes start/activity/review/delivery/finish and never stores final prose', () => {
    for (const fragment of [
      "type: 'task.started'",
      "type: 'runtime.activity'",
      "type: 'result.landed'",
      "result_kind: 'review'",
      "result_kind: 'delivery'",
      "type: 'task.finished'",
      'rebuildRoadmapFromEventStore(this.eventStore, this.roadmapStore)',
    ]) expect(lifecycle).toContain(fragment)
    const eventMethod = lifecycle.slice(
      lifecycle.indexOf('private event('),
      lifecycle.indexOf('\n  startTask(', lifecycle.indexOf('private event(')),
    )
    for (const forbidden of ['summary', 'prompt', 'findings', 'profile']) {
      expect(eventMethod).not.toContain(forbidden)
    }
  })

  test('formerly silent block/rotation/final-boundary sends are receipt-checked or loud', () => {
    expect(daemon).toContain('block review notice failed')
    expect(daemon).toContain('profile rotation notice failed')
    expect(daemon).toContain('verified lifecycle notice failed')
    expect(daemon).toContain("error_kind: 'discord-send'")
  })
})
