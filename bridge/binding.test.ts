// Tests for the inbound channel binding. Run with: `bun test` in bridge/.
import { test, expect } from 'bun:test'
import { parseBoundChannels, isBoundDrop } from './binding.ts'

const OP = '1508921858165047390' // #qofi-product (operator)
const BUS = '1510301812434141194' // #cpo-cto-bus
const CTO = '1507159618453770291' // a CTO channel
const OTHER = '9999999999999999999'

test('parse: unset/empty → unbound (empty list)', () => {
  expect(parseBoundChannels(undefined)).toEqual([])
  expect(parseBoundChannels(null)).toEqual([])
  expect(parseBoundChannels('')).toEqual([])
  expect(parseBoundChannels('   ')).toEqual([])
})

test('parse: single id → one-element list (unchanged single case)', () => {
  expect(parseBoundChannels(CTO)).toEqual([CTO])
  expect(parseBoundChannels(`  ${CTO}  `)).toEqual([CTO])
})

test('parse: comma-separated → multi (CPO: operator + bus), tolerant of spaces/trailing comma', () => {
  expect(parseBoundChannels(`${OP},${BUS}`)).toEqual([OP, BUS])
  expect(parseBoundChannels(`${OP}, ${BUS} ,`)).toEqual([OP, BUS])
})

test('single-bound swarm (a CTO): its own channel passes, everything else drops', () => {
  const bound = parseBoundChannels(CTO)
  expect(isBoundDrop(bound, CTO)).toBe(false) // own channel inbound
  expect(isBoundDrop(bound, BUS)).toBe(true) // INVARIANT: a CTO never reads the bus
  expect(isBoundDrop(bound, OP)).toBe(true)
})

test('CPO bound to [operator, bus]: both pass, a third channel drops', () => {
  const bound = parseBoundChannels(`${OP},${BUS}`)
  expect(isBoundDrop(bound, OP)).toBe(false)
  expect(isBoundDrop(bound, BUS)).toBe(false)
  expect(isBoundDrop(bound, CTO)).toBe(true) // CPO still does NOT read CTO channels
  expect(isBoundDrop(bound, OTHER)).toBe(true)
})

test('unbound (empty list) → nothing dropped on this rule (legacy)', () => {
  expect(isBoundDrop([], BUS)).toBe(false)
  expect(isBoundDrop([], CTO)).toBe(false)
})
