#!/usr/bin/env python3
"""Produce long, checkable terminal output to test Tether with very long sessions.

Run it on a server (or locally) inside a Tether terminal, then scroll up:

  python3 long-output-test.py                 # 50,000 numbered lines as fast as possible
  python3 long-output-test.py --lines 300000  # more than fits in memory (default keeps 10,000)
  python3 long-output-test.py --slow          # one line every 0.05 s, like `tail -f`
  python3 long-output-test.py --clear         # output, then Ctrl+L-style clears in between

Every line carries its number and a checksum of the number, so a missing, duplicated or
garbled line is easy to spot while scrolling: numbers must count down by one, and the
checksum column must match `check(n)` below (it is printed in the summary too).
"""
import argparse
import sys
import time
import zlib

COLORS = ["31", "32", "33", "34", "35", "36"]


def check(n: int) -> str:
    """Short checksum of a line number (8 hex digits)."""
    return f"{zlib.crc32(str(n).encode()):08x}"


def line(n: int, width: int) -> str:
    color = COLORS[n % len(COLORS)]
    body = f"\x1b[1m#{n:07d}\x1b[0m  {check(n)}  \x1b[{color}m{'block ' + str(n // 1000):<12}\x1b[0m"
    filler = ("abcdefghijklmnopqrstuvwxyz0123456789" * 4)[: max(0, width - 40)]
    return f"{body}{filler}"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lines", type=int, default=50_000, help="number of lines (default 50,000)")
    p.add_argument("--width", type=int, default=100, help="characters per line (default 100)")
    p.add_argument("--slow", action="store_true", help="print a line every 0.05 s (like tail -f)")
    p.add_argument("--clear", action="store_true", help="clear the screen (ESC[H ESC[2J) every 5,000 lines")
    args = p.parse_args()

    start = time.time()
    out = sys.stdout
    batch = []
    for n in range(1, args.lines + 1):
        batch.append(line(n, args.width))
        if args.clear and n % 5000 == 0:
            batch.append("\x1b[H\x1b[2J")
        if args.slow or len(batch) >= 500:
            out.write("\r\n".join(batch) + "\r\n")
            out.flush()
            batch = []
            if args.slow:
                time.sleep(0.05)
    if batch:
        out.write("\r\n".join(batch) + "\r\n")
    elapsed = time.time() - start
    print(f"\n\x1b[1mDone:\x1b[0m {args.lines:,} lines in {elapsed:.1f} s.")
    print(f"First line #{1:07d} has checksum {check(1)}; last line #{args.lines:07d} has {check(args.lines)}.")
    print("Scroll up: numbers must count down one by one with no gaps, and the view must not jump")
    print("when earlier lines are loaded. Select text across the boundary and copy it to check.")


if __name__ == "__main__":
    main()
