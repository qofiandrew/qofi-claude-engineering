#!/usr/bin/env python3
"""
show_reorder_diff.py — print a section-level before/after diff for operator review.

For a pure reorder, a line-level diff is useless (entire file moved). What you
want to see is: which section was at position N before, and at position M after.
"""
import re
import sys
from pathlib import Path

SECTION_RE = re.compile(r"^## ", re.MULTILINE)


def parse(text):
    starts = [m.start() for m in SECTION_RE.finditer(text)]
    if not starts:
        return text, []
    preamble = text[: starts[0]]
    out = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(text)
        block = text[start:end]
        nl = block.find("\n")
        heading = (block[: nl] if nl >= 0 else block).strip()
        body = block
        lines = body.count("\n")
        out.append((heading, lines, body))
    return preamble, out


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: show_reorder_diff.py SRC REORDERED")
    src_pre, src_sects = parse(Path(sys.argv[1]).read_text())
    out_pre, out_sects = parse(Path(sys.argv[2]).read_text())

    print(f"Source:    {Path(sys.argv[1]).name}  "
          f"({len(src_sects)} sections, preamble {src_pre.count(chr(10))} lines)")
    print(f"Reordered: {Path(sys.argv[2]).name}  "
          f"({len(out_sects)} sections, preamble {out_pre.count(chr(10))} lines)")
    if src_pre == out_pre:
        print("Preamble:  IDENTICAL (byte-equal)")
    else:
        print("Preamble:  *** DIFFERS *** (this would be a reorder bug)")

    # Build heading -> old-position map
    src_pos = {h: i + 1 for i, (h, _, _) in enumerate(src_sects)}

    print()
    print("    NEW   OLD   Δ      LINES  HEADING")
    print("    ----  ----  -----  -----  -------")
    for new_pos, (heading, lines, _body) in enumerate(out_sects, 1):
        old_pos = src_pos.get(heading, -1)
        delta = old_pos - new_pos
        delta_s = f"{delta:+d}" if delta != 0 else " ="
        print(f"    {new_pos:>3d}.  {old_pos:>3d}.  {delta_s:>5}  {lines:>4d}  {heading}")
    print()
    # Sanity: every source heading must appear exactly once in reordered.
    out_headings = [h for h, _, _ in out_sects]
    src_headings = [h for h, _, _ in src_sects]
    assert sorted(out_headings) == sorted(src_headings), (
        "section set mismatch — NOT a pure reorder"
    )
    print(f"    Section set: identical ({len(src_sects)} headings, "
          f"both sets sort-equal).")


if __name__ == "__main__":
    main()
