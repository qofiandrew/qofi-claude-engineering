/** Owner-private Unix server socket creation, attestation, and cleanup. */

import {
  chmodSync,
  lstatSync,
  realpathSync,
  unlinkSync,
  type Stats,
} from 'fs'
import { dirname, isAbsolute, resolve } from 'path'
import { createConnection, type Server } from 'net'
import { assertNoExtendedAcl } from './security.ts'

export type UnixSocketIdentity = {
  path: string
  dev: number
  ino: number
  uid: number
}

function currentUid(): number {
  if (typeof process.getuid !== 'function') throw new Error('Unix uid support is required')
  return process.getuid()
}

function identity(path: string, info: Stats): UnixSocketIdentity {
  return { path, dev: info.dev, ino: info.ino, uid: info.uid }
}

export function assertOwnerPrivateSocketParent(socketPath: string): string {
  if (!isAbsolute(socketPath) || socketPath.includes('\0') || resolve(socketPath) !== socketPath) {
    throw new Error('Unix socket path must be absolute and normalized')
  }
  if (Buffer.byteLength(socketPath) > 100) {
    throw new Error('Unix socket path exceeds the portable macOS bound')
  }
  const parent = dirname(socketPath)
  if (realpathSync(parent) !== parent) throw new Error('Unix socket parent must be canonical')
  const info = lstatSync(parent)
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== currentUid() || (info.mode & 0o777) !== 0o700) {
    throw new Error('Unix socket parent must be an owner mode-0700 real directory')
  }
  assertNoExtendedAcl(parent, 'Unix socket parent')
  return parent
}

export function attestOwnerUnixSocket(socketPath: string): UnixSocketIdentity {
  const info = lstatSync(socketPath)
  if (!info.isSocket() || info.isSymbolicLink() || info.uid !== currentUid() || (info.mode & 0o777) !== 0o600) {
    throw new Error('Unix endpoint must be an owner mode-0600 socket')
  }
  assertNoExtendedAcl(socketPath, 'Unix endpoint')
  return identity(socketPath, info)
}

export function sameUnixSocket(
  expected: UnixSocketIdentity,
  observed: UnixSocketIdentity,
): boolean {
  return expected.path === observed.path
    && expected.dev === observed.dev
    && expected.ino === observed.ino
    && expected.uid === observed.uid
}

export async function listenOwnerUnixSocket(
  server: Server,
  socketPath: string,
): Promise<UnixSocketIdentity> {
  assertOwnerPrivateSocketParent(socketPath)
  let stale: UnixSocketIdentity | null = null
  try {
    stale = attestOwnerUnixSocket(socketPath)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  if (stale) {
    const active = await new Promise<boolean>((resolveProbe, rejectProbe) => {
      const socket = createConnection(socketPath)
      let settled = false
      const finish = (value: boolean) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        socket.destroy()
        resolveProbe(value)
      }
      const timer = setTimeout(() => finish(true), 500)
      timer.unref?.()
      socket.once('connect', () => finish(true))
      socket.once('error', error => {
        const code = (error as NodeJS.ErrnoException).code
        if (code === 'ECONNREFUSED' || code === 'ENOENT') finish(false)
        else {
          if (!settled) {
            settled = true
            clearTimeout(timer)
            rejectProbe(error)
          }
        }
      })
    })
    if (active) throw new Error('refusing to replace an active Unix endpoint')
    unlinkOwnedUnixSocket(stale)
  }

  await new Promise<void>((resolveListen, rejectListen) => {
    const onError = (error: Error) => {
      server.off('listening', onListening)
      rejectListen(error)
    }
    const onListening = () => {
      server.off('error', onError)
      resolveListen()
    }
    server.once('error', onError)
    server.once('listening', onListening)
    server.listen(socketPath)
  })
  try {
    chmodSync(socketPath, 0o600)
    return attestOwnerUnixSocket(socketPath)
  } catch (error) {
    await closeServer(server)
    try { unlinkSync(socketPath) } catch {}
    throw error
  }
}

export async function closeServer(server: Server): Promise<void> {
  if (!server.listening) return
  await new Promise<void>(resolveClose => {
    let settled = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const finish = () => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      resolveClose()
    }
    timer = setTimeout(finish, 1_000)
    timer.unref?.()
    try {
      server.close(finish)
      ;(server as Server & { closeAllConnections?: () => void }).closeAllConnections?.()
    } catch {
      finish()
    }
  })
}

/** Never unlink a path that has been replaced since this process bound it. */
export function unlinkOwnedUnixSocket(expected: UnixSocketIdentity): boolean {
  let observed: UnixSocketIdentity
  try {
    observed = attestOwnerUnixSocket(expected.path)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
    throw error
  }
  if (!sameUnixSocket(expected, observed)) {
    throw new Error('Unix endpoint identity changed before cleanup')
  }
  unlinkSync(expected.path)
  return true
}

export async function closeOwnedUnixServer(
  server: Server,
  expected: UnixSocketIdentity | null,
): Promise<void> {
  await closeServer(server)
  if (expected) unlinkOwnedUnixSocket(expected)
}
