#!/usr/bin/env python3
"""Compact table from harness summary lines: fmt.py [keys...] < results (keys = descriptor fields to show)."""
import re, sys
keys = sys.argv[1:] or ["TH"]
rows = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("set="): continue
    g = lambda k, d="?": (re.search(r"\b%s=([^\s|]+)" % re.escape(k), line) or [None, d])[1]
    jm = re.search(r"jumps move=\d+ \(([\d.]+)/s\) hold=\d+ \(([\d.]+)/s\)", line)
    face = re.search(r"face=\[([^\]]*)\]", line).group(1)
    pop = re.search(r"pop n=(\d+) mean=([\d.]+)cm feet=([\d.]+)cm max=([\d.]+)cm", line)
    acc = re.search(r"acc p95=(\d+) max=(\d+) snaps=(\d+)", line)
    ha = re.search(r"hands mean=(\d+) p95=(\d+)", line) or [None, "-", "-"]
    sl = re.search(r"slide=([\d.]+)cm/s moving=([\d.]+)cm/s", line)
    sk = re.search(r"skate=([\d.]+)cm/s max=(\d+)", line) or [None, "-", "-"]
    wp = re.search(r"warp=(\d+)deg/s moving=(\d+)deg/s(?: slow=(\d+)deg/s)?", line) or [None, "-", "-", "-"]
    pl = re.search(r"plant=([\d.]+)cm/s moving=([\d.]+)cm/s frames=(\d+)%", line) or [None, "-", "-", "-"]
    rows.append([g("set"), g("scen")] + [k + "=" + g(k) for k in keys] +
                [jm.group(1), jm.group(2), g("mean"), g("back"), face or "-", g("|dv|"), g("mean", "?") if False else re.search(r"dist mean=([\d.]+)", line).group(1),
                 g("firstHold").rstrip("s"), pop.group(1), pop.group(2), pop.group(3), acc.group(1), acc.group(2), acc.group(3), ha[1], ha[2], sl.group(1), sl.group(2), sk[1], sk[2], wp[1], wp[2], wp[3] or "-", pl[1], pl[2], pl[3]])
rows.sort()
hdr = ["set", "scen"] + keys + ["jmp/s", "hold/s", "err", "back", "face", "|dv|", "dist", "1stHold", "pops", "pop", "feet", "accP95", "accMax", "snaps", "handAcc", "handP95", "slide", "slideMv", "skate", "skMax", "warp", "warpMv", "warpSlow", "plant", "plantMv", "plant%"]
w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
print("  ".join(h.ljust(w[i]) for i, h in enumerate(hdr)))
for r in rows: print("  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)))
