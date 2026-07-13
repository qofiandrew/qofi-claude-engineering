/** A bounded FIFO whose jobs always run one at a time and in acceptance order. */
export type QueueSnapshot = {
  active: boolean
  waiting: number
  size: number
}

export class BoundedSerialQueue {
  private tail: Promise<void> = Promise.resolve()
  private count = 0
  private running = false
  private closed = false

  constructor(
    readonly capacity: number,
    private readonly onChange?: (snapshot: QueueSnapshot) => void,
    private readonly onError?: (error: unknown) => void,
  ) {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new Error('queue capacity must be a positive integer')
    }
  }

  get snapshot(): QueueSnapshot {
    return {
      active: this.running,
      waiting: Math.max(0, this.count - (this.running ? 1 : 0)),
      size: this.count,
    }
  }

  tryEnqueue(job: () => Promise<void>, onDrop?: () => void | Promise<void>): boolean {
    if (this.closed || this.count >= this.capacity) return false
    this.count++
    this.notify()

    this.tail = this.tail.then(async () => {
      if (this.closed) {
        try { await onDrop?.() } catch (err) {
          try { this.onError?.(err) } catch {}
        }
        this.count--
        this.notify()
        return
      }
      this.running = true
      this.notify()
      try {
        await job()
      } catch (err) {
        try { this.onError?.(err) } catch {}
      } finally {
        this.running = false
        this.count--
        this.notify()
      }
    })
    return true
  }

  drain(): Promise<void> {
    return this.tail
  }

  /** Reject new jobs and discard accepted jobs that have not started yet. */
  close(): void {
    this.closed = true
    this.notify()
  }

  private notify(): void {
    try { this.onChange?.(this.snapshot) } catch {}
  }
}
