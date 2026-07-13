import { readFileSync } from 'fs'
import { join } from 'path'
import { describe, expect, test } from 'bun:test'

const source = readFileSync(join(import.meta.dir, 'daemon.ts'), 'utf8')

describe('daemon App Server manager integration contract', () => {
  test('manager mode is opt-in and cannot silently fall back to exec', () => {
    expect(source).toContain('CODEX_BRIDGE_APP_SERVER_MANAGER_SOCKET')
    expect(source).toContain('if (APP_SERVER_MANAGER_SOCKET)')
    expect(source).toContain('if (!appServerManager && shouldRetryFresh(threadId, result))')
    expect(source).toContain('managerClientErrorToCodexResult(err, threadId)')
    expect(source).toContain("last_error: 'app-server:turn-uncertain'")
  })

  test('registration and reservation gate admission while heartbeat uses shared-manager liveness', () => {
    expect(source).not.toContain('await appServerManager.health()')
    expect(source).toContain(
      'parseDaemonRuntimeConfig(process.env, process.cwd(), BRIDGE_IDENTITY.archetype)',
    )
    const register = source.slice(
      source.indexOf('await appServerManager.register({'),
      source.indexOf('managerFacadeEndpoint = registration.facadeEndpoint'),
    )
    expect(register).toContain('timeoutMs: APP_SERVER_MANAGER_ADMISSION_TIMEOUT_MS')
    expect(register).toContain('reasoningEffort: codexCfg.reasoningEffort ?? null')
    expect(source).toContain('await appServerManager.reserveTurn({')
    const start = source.indexOf('let managerHeartbeatInFlight = false')
    const end = source.indexOf('heartbeat.unref()', start)
    const heartbeat = source.slice(start, end)
    expect(start).toBeGreaterThan(0)
    expect(heartbeat).toContain('appServerManager.liveness()')
    expect(heartbeat).toContain('managerLivenessMonitor.observe(liveness)')
    expect(heartbeat).toContain('if (shuttingDown) return')
    expect(heartbeat).toContain('client.isReady() && managerRuntimeAvailable')
    expect(heartbeat).not.toContain('appServerManager.health()')
    expect(heartbeat).toContain("last_error: 'app-server:health'")
    expect(heartbeat).toContain('void shutdown(1)')
  })

  test('long admission waits reprove authorization and every runtime boundary before ACL grant', () => {
    const start = source.indexOf('managerReservationHeld = true')
    const end = source.indexOf('grantTurnRuntimeAccess(', start)
    const postAdmission = source.slice(start, end)
    const required = [
      'revalidateDeliveryAuthorization({',
      'repoLease?.verifyOwnership()',
      'validatePrivateStateBoundary(STATE_DIR, false)',
      'verifyBaseRuntimeAccess(',
      'checkWorkspaceSafety(',
      'resolveToolchainPlan(',
      'resolveTrustedCodexExecutable(',
      'resolveTrustedCodexScript(',
      'validateDedicatedRuntimeBoundary({',
      'recheckProjectConfig(',
    ]
    expect(start).toBeGreaterThan(0)
    for (const fragment of required) expect(postAdmission).toContain(fragment)
    const failure = postAdmission.indexOf('if (postAdmissionFailure)')
    expect(failure).toBeGreaterThan(0)
    expect(postAdmission.indexOf('await finalizeTurnBoundary()', failure)).toBeLessThan(
      postAdmission.indexOf('(msg.channel as any).send(', failure),
    )
  })

  test('global reservation precedes every hidden-UID turn ACL and manager start', () => {
    const start = source.indexOf('async function runTurn(')
    const end = source.indexOf('\nasync function runGitControl', start)
    const turn = source.slice(start, end)
    const ordered = [
      "operation: 'turn'",
      'materializeTurnAttachments(',
      'appServerManager.reserveTurn({',
      'beforeSnapshot = captureWorkspaceSnapshot(codexCfg.cwd)',
      'grantTurnRuntimeAccess(',
      'appServerManager.runTurn({',
    ].map(fragment => turn.indexOf(fragment))
    expect(start).toBeGreaterThan(0)
    expect(ordered.every(index => index >= 0)).toBe(true)
    expect(ordered).toEqual([...ordered].sort((left, right) => left - right))
  })

  test('manager turn carries the exact roots/environment and never publishes a child pid', () => {
    const start = source.indexOf('managerExecution = await appServerManager.runTurn({')
    const end = source.indexOf('})\n        result = managerExecution.result', start)
    const request = source.slice(start, end)
    expect(start).toBeGreaterThan(0)
    expect(request).toContain('readableRoots: runnerOptions.readableRoots')
    expect(request).toContain('deniedPaths: runnerOptions.deniedPaths')
    expect(request).toContain('writableRoots: runnerOptions.writableRoots')
    expect(request).toContain('environment: runnerOptions.environment')
    expect(source).toContain('onChildPid: appServerManager')
  })

  test('cleanup ack follows snapshot, lease, ACL, attachment/temp, and session sync', () => {
    const start = source.indexOf('const finalizeTurnBoundary = async ()')
    const end = source.indexOf('\n  try {\n    retryNotices.register', start)
    const cleanup = source.slice(start, end)
    const ordered = [
      'revokeTurnRuntimeAccess(',
      'cleanupTurnAttachmentScope(',
      'rmSync(turnTempDir',
      'captureWorkspaceSnapshot(codexCfg.cwd)',
      'repoLease.release()',
      'appServerManager.cancelTurnReservation()',
      'appServerManager.replaceSessions(',
      'appServerManager.cleanupComplete(',
    ].map(fragment => cleanup.indexOf(fragment))
    expect(start).toBeGreaterThan(0)
    expect(ordered.every(index => index >= 0)).toBe(true)
    expect(ordered).toEqual([...ordered].sort((left, right) => left - right))
    expect(cleanup).toContain('managerCleanupOk = false')
  })

  test('turn boundary is finalized before attention relay or Discord output', () => {
    const start = source.indexOf('turnSucceeded = result.ok')
    const end = source.indexOf('\n  } catch (err) {', start)
    const completed = source.slice(start, end)
    const finalize = completed.indexOf('await finalizeTurnBoundary()')
    const relay = completed.indexOf('relaySwarmAttention(')
    const send = completed.indexOf('(msg.channel as any).send(')
    expect(start).toBeGreaterThan(0)
    expect(finalize).toBeGreaterThan(0)
    expect(relay).toBeGreaterThan(finalize)
    expect(send).toBeGreaterThan(finalize)

    const caught = source.slice(
      source.indexOf('} catch (err) {\n    process.stderr.write(`codex-bridge: turn failed'),
      source.indexOf('} finally {', source.indexOf('} catch (err) {\n    process.stderr.write(`codex-bridge: turn failed')),
    )
    expect(caught.indexOf('await finalizeTurnBoundary()')).toBeLessThan(
      caught.indexOf('(msg.channel as any).send('),
    )
  })

  test('review artifacts become post-cleanup candidates; adopted lifecycle admits only final-diff provenance', () => {
    const start = source.indexOf('// The reviewer is terminal and writes only private artifacts.')
    const end = source.indexOf('\n    const rotation = managerExecution?.response.rotation', start)
    const intake = source.slice(start, end)
    const cleanup = source.lastIndexOf('await finalizeTurnBoundary()', start)
    expect(start).toBeGreaterThan(cleanup)
    expect(intake.indexOf('if (reviewArtifactBaselineRefused)')).toBeLessThan(
      intake.indexOf('readFableReviewArtifacts('),
    )
    expect(intake).toContain("throw new Error('pre-execution review artifact baseline was refused')")
    expect(intake).toContain('readFableReviewArtifacts(')
    expect(intake).toContain("eventLog.emit('review.result_recorded'")
    expect(intake).toContain('if (!harnessLifecycle)')
    expect(intake).toContain("artifact.result.verdict === 'review-unavailable'")
    expect(intake).toContain("? 'review-pending'")
    expect(intake).toContain("artifact.result.verdict === 'block'")
    expect(intake).toContain('Ratification remains operator-owned.')
    expect(intake).not.toContain('artifact.result.findings')
    expect(intake).not.toContain('artifact.result.summary')

    const adopted = source.slice(
      source.indexOf('if (harnessLifecycle) {', source.indexOf('let text = codexReplyText(result)')),
      source.indexOf('\n    const chunks = suppressReply', source.indexOf('let text = codexReplyText(result)')),
    )
    expect(adopted).toContain('currentReviewArtifacts.length <= 2 && exactCandidates.length === 1')
    expect(adopted).toContain('artifact.reviewed_diff_sha256 === completionReviewMaterial!.hash')
    expect(adopted).toContain('await harnessLifecycle.completeTask({')
    expect(adopted).toContain('if (!completion.boundary.accepted)')
  })

  test('hard quota evidence rotates after cleanup and requeues inside the active FIFO job', () => {
    const start = source.indexOf('const rotation = managerExecution?.response.rotation')
    const end = source.indexOf('\n    const access = store.load()', start)
    const rotation = source.slice(start, end)
    expect(start).toBeGreaterThan(0)
    expect(rotation).toContain("rotation.reason === 'hard'")
    expect(rotation).toContain('return await runTurn(msg, content, attachments, atts, channelRole, nextAttempt)')
    expect(rotation).toContain("eventLog.emit('turn.requeued'")
    expect(rotation).toContain('retainRetryNotice = true')
    expect(rotation).toContain('rotation.parkedUntilMs ?? Date.now() + 5 * 60_000')
    expect(rotation).toContain('persistParkedTurn(msg, retryAt, nextAttempt)')
    expect(rotation).toContain('scheduleParkedTurn(current)')
    const cleanup = source.indexOf('await finalizeTurnBoundary()', source.indexOf('turnSucceeded = result.ok'))
    expect(start).toBeGreaterThan(cleanup)
  })

  test('parked admission releases the turn boundary and restart refetches the original task', () => {
    const reserve = source.indexOf('const reservation = await appServerManager.reserveTurn({')
    const reserveCatch = source.slice(reserve, source.indexOf('managerReservationHeld = true', reserve))
    expect(reserveCatch).toContain('err.remotePoolExhausted')
    expect(reserveCatch).toContain('await finalizeTurnBoundary()')
    expect(reserveCatch).toContain('persistParkedTurn(msg, retryAt')
    expect(reserveCatch).not.toContain('Bun.sleep')

    const replay = source.slice(
      source.indexOf('async function replayParkedTurn('),
      source.indexOf('\nasync function isMentioned(', source.indexOf('async function replayParkedTurn(')),
    )
    expect(replay).toContain('client.channels.fetch(entry.channel_id)')
    expect(replay).toContain('messages.fetch(messageId)')
    expect(replay).toContain('handleInbound(msg, entry.rotation_attempt, true)')
    expect(source).toContain('scheduleParkedTurnReplays()')
  })

  test('graceful shutdown unregisters before closing the manager and exiting', () => {
    const start = source.indexOf('async function shutdown(')
    const shutdown = source.slice(start)
    const unregister = shutdown.indexOf('await appServerManager.unregister()')
    const close = shutdown.indexOf('appServerManager.close()')
    const exit = shutdown.indexOf('process.exit(finalExitCode)')
    expect(unregister).toBeGreaterThan(0)
    expect(close).toBeGreaterThan(unregister)
    expect(exit).toBeGreaterThan(close)
  })

  test('security and integrity failures request a nonzero shutdown', () => {
    const errorShutdowns = source.match(/shutdown\(\)/g) ?? []
    // Bare shutdown is reserved for operator/signal lifecycle only.
    expect(errorShutdowns).toHaveLength(3)
    expect(source).toContain("process.on('SIGTERM', () => { void shutdown() })")
    expect(source).toContain("setTimeout(() => { void shutdown(1) }, 0)")
    expect(source).toContain("last_error: 'state:unsafe-boundary'")
    expect(source).toContain('void shutdown(1)')
  })
})
