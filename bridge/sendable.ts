import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
} from 'fs'
import { basename, join, sep } from 'path'

/**
 * Snapshot one outbound Discord attachment across a descriptor-validated
 * boundary. Channel state is never attachable (except downloaded inbox files),
 * and hardlinks cannot move a private inode behind an apparently safe path.
 */
export function loadSendableAttachment(
  file: string,
  stateDirectory: string,
  maxBytes: number,
): { attachment: Buffer; name: string } {
  const real = realpathSync(file)
  const stateReal = realpathSync(stateDirectory)
  const inbox = join(stateReal, 'inbox')
  if ((real === stateReal || real.startsWith(stateReal + sep))
      && !real.startsWith(inbox + sep)) {
    throw new Error(`refusing to send channel state: ${file}`)
  }

  const before = lstatSync(real)
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1) {
    throw new Error(`refusing non-regular or hardlinked attachment: ${file}`)
  }
  if (before.size > maxBytes) {
    throw new Error(`file too large: ${file} (${(before.size / 1024 / 1024).toFixed(1)}MB, max ${(maxBytes / 1024 / 1024).toFixed(0)}MB)`)
  }

  const noFollow = typeof constants.O_NOFOLLOW === 'number' ? constants.O_NOFOLLOW : 0
  const fd = openSync(real, constants.O_RDONLY | noFollow)
  try {
    const opened = fstatSync(fd)
    if (!opened.isFile() || opened.nlink !== 1
        || opened.dev !== before.dev || opened.ino !== before.ino
        || opened.size !== before.size || opened.ctimeMs !== before.ctimeMs) {
      throw new Error(`attachment changed while opening: ${file}`)
    }
    const attachment = readFileSync(fd)
    const after = fstatSync(fd)
    if (after.dev !== opened.dev || after.ino !== opened.ino
        || after.nlink !== 1 || after.size !== opened.size
        || after.ctimeMs !== opened.ctimeMs || after.mtimeMs !== opened.mtimeMs) {
      throw new Error(`attachment changed while reading: ${file}`)
    }
    return { attachment, name: basename(file) }
  } finally {
    closeSync(fd)
  }
}
