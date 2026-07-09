import { describe, test, expect } from 'bun:test'
import { chunk } from './chunk.ts'

describe('chunk', () => {
  test('short text passes through unsplit', () => {
    expect(chunk('hello', 2000, 'length')).toEqual(['hello'])
  })

  test('length mode cuts exactly at the limit', () => {
    const out = chunk('a'.repeat(4500), 2000, 'length')
    expect(out.map(c => c.length)).toEqual([2000, 2000, 500])
  })

  test('newline mode prefers paragraph boundaries', () => {
    const p1 = 'x'.repeat(1500)
    const p2 = 'y'.repeat(1500)
    const out = chunk(`${p1}\n\n${p2}`, 2000, 'newline')
    expect(out).toEqual([p1, p2])
  })

  test('newline mode falls back to hard cut when no boundary in range', () => {
    const out = chunk('z'.repeat(2500), 2000, 'newline')
    expect(out.map(c => c.length)).toEqual([2000, 500])
  })

  test('every chunk respects the limit', () => {
    const text = Array.from({ length: 50 }, (_, i) => `para ${i} ${'w'.repeat(180)}`).join('\n\n')
    for (const mode of ['length', 'newline'] as const) {
      for (const c of chunk(text, 2000, mode)) expect(c.length).toBeLessThanOrEqual(2000)
    }
  })
})
