#!/usr/bin/env python3
"""
split.py — slice a reordered doctrine file into 3 fragments at BASE/ENG seams.

CONTRACT: cat(preamble, base, eng) must equal the input file byte-for-byte.

Usage:
    split.py SRC OUT_PREAMBLE OUT_BASE OUT_ENG BASE_HEADING ENG_HEADING

    BASE_HEADING and ENG_HEADING are the verbatim '## Heading' lines that
    mark the start of the base block and the eng block respectively.
"""
import sys
from pathlib import Path


def find_heading_offset(text, heading):
    """Find the byte offset where `heading\n` starts. Returns (offset_in_bytes)."""
    needle = f"\n{heading}\n"
    idx = text.find(needle)
    if idx < 0:
        sys.exit(f"split: heading not found: {heading!r}")
    # Start of heading line = idx + 1 (skip the leading \n that anchored the match).
    return idx + 1


def main():
    if len(sys.argv) != 7:
        sys.exit("usage: split.py SRC OUT_PRE OUT_BASE OUT_ENG BASE_HEAD ENG_HEAD")
    src_path = Path(sys.argv[1])
    out_pre = Path(sys.argv[2])
    out_base = Path(sys.argv[3])
    out_eng = Path(sys.argv[4])
    base_head = sys.argv[5]
    eng_head = sys.argv[6]

    text = src_path.read_text()
    base_start = find_heading_offset(text, base_head)
    eng_start = find_heading_offset(text, eng_head)
    if not (0 < base_start < eng_start):
        sys.exit(
            f"split: heading offsets out of order — "
            f"base@{base_start} eng@{eng_start}"
        )

    preamble = text[:base_start]
    base = text[base_start:eng_start]
    eng = text[eng_start:]

    # Sanity: literal cat must reproduce the source.
    if preamble + base + eng != text:
        sys.exit("split: cat(pre, base, eng) != src — extraction bug")

    out_pre.parent.mkdir(parents=True, exist_ok=True)
    out_base.parent.mkdir(parents=True, exist_ok=True)
    out_eng.parent.mkdir(parents=True, exist_ok=True)
    out_pre.write_text(preamble)
    out_base.write_text(base)
    out_eng.write_text(eng)

    # Report fragment shapes (last 2 bytes of each, to make the trailing-\n
    # invariant visible at a glance).
    def trailing(p):
        b = p.read_bytes()
        return b[-2:].hex() if len(b) >= 2 else b.hex()

    print(f"OK split {src_path.name}: {len(text)} chars")
    print(f"  preamble ({len(preamble):>5d} bytes) trailing={trailing(out_pre)}  -> {out_pre}")
    print(f"  base     ({len(base):>5d} bytes) trailing={trailing(out_base)}  -> {out_base}")
    print(f"  eng      ({len(eng):>5d} bytes) trailing={trailing(out_eng)}  -> {out_eng}")
    # Invariant check: non-final fragments must end with at least one \n (so
    # literal cat doesn't run them into the next fragment's heading). The final
    # fragment ends however the source file ended.
    pre_b = out_pre.read_bytes()
    base_b = out_base.read_bytes()
    if not pre_b.endswith(b"\n"):
        sys.exit("INVARIANT FAIL: preamble does not end with \\n")
    if not base_b.endswith(b"\n"):
        sys.exit("INVARIANT FAIL: base does not end with \\n")
    print("  invariant OK: non-final fragments end with \\n")


if __name__ == "__main__":
    main()
