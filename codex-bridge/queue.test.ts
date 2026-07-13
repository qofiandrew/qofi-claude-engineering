import { describe, expect, test } from 'bun:test'
import { BoundedSerialQueue } from './queue.ts'

describe('BoundedSerialQueue', () => {
  test('runs jobs serially in acceptance order', async () => {
    const seen: number[] = []
    const queue = new BoundedSerialQueue(4)
    expect(queue.tryEnqueue(async () => {
      await Bun.sleep(20)
      seen.push(1)
    })).toBe(true)
    expect(queue.tryEnqueue(async () => { seen.push(2) })).toBe(true)
    expect(queue.tryEnqueue(async () => { seen.push(3) })).toBe(true)
    await queue.drain()
    expect(seen).toEqual([1, 2, 3])
    expect(queue.snapshot).toEqual({ active: false, waiting: 0, size: 0 })
  })

  test('rejects work at capacity', async () => {
    const queue = new BoundedSerialQueue(1)
    expect(queue.tryEnqueue(async () => { await Bun.sleep(20) })).toBe(true)
    expect(queue.tryEnqueue(async () => {})).toBe(false)
    await queue.drain()
  })

  test('close drains the active job and drops waiting jobs', async () => {
    const seen: string[] = []
    const queue = new BoundedSerialQueue(3)
    queue.tryEnqueue(async () => {
      seen.push('active')
      await Bun.sleep(20)
    })
    queue.tryEnqueue(async () => { seen.push('should-not-run') }, () => seen.push('dropped'))
    await Bun.sleep(1)
    queue.close()
    await queue.drain()
    expect(seen).toEqual(['active', 'dropped'])
    expect(queue.tryEnqueue(async () => {})).toBe(false)
  })

  test('shutdown drain awaits a deterministic callback for every accepted waiting job', async () => {
    const seen: string[] = []
    let release!: () => void
    const active = new Promise<void>(resolve => { release = resolve })
    const queue = new BoundedSerialQueue(4)
    queue.tryEnqueue(async () => {
      seen.push('active')
      await active
    })
    for (const id of ['message-1', 'message-2']) {
      expect(queue.tryEnqueue(
        async () => { seen.push(`ran:${id}`) },
        async () => {
          await Bun.sleep(5)
          seen.push(`retry:${id}`)
        },
      )).toBe(true)
    }
    await Bun.sleep(1)
    queue.close()
    release()
    await queue.drain()
    expect(seen).toEqual(['active', 'retry:message-1', 'retry:message-2'])
    expect(queue.snapshot).toEqual({ active: false, waiting: 0, size: 0 })
  })
})
