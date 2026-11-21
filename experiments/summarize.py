#!/usr/bin/env python3
"""Summarize a run-matrix results file into a markdown table you can paste into the README."""
import json
import sys
from collections import Counter, defaultdict
from statistics import median

ORDER = ["control-runc", "control-gvisor", "host-runc", "host-gvisor", "nft-runc", "nft-gvisor"]


def pct(n, d):
    return f"{100 * n / d:.0f}%" if d else "—"


rows = defaultdict(list)
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("{"):
        r = json.loads(line)
        rows[r.get("cell")].append(r)

print("| cell | n | errors | I2 open on 1st attempt | I2 open window ms (median / max) | "
      "I3a direct DNS blocked | I3b cluster DNS forwards | nft | kernel |")
print("|---|---|---|---|---|---|---|---|---|")
for cell in sorted(rows, key=lambda c: ORDER.index(c) if c in ORDER else 99):
    rs = rows[cell]
    ok = [r for r in rs if "error" not in r]
    errs = len(rs) - len(ok)
    first_open = sum(1 for r in ok if r["i2"]["first_attempt_open"])
    windows = [r["i2"]["open_until_ms"] for r in ok if r["i2"]["open_until_ms"] is not None]
    always = sum(1 for r in ok if r["i2"]["open_until_ms"] is not None
                 and r["i2"]["open_until_ms"] >= r.get("race_seconds", 8) * 1000 - 500)
    if not ok:
        win = "—"
    elif not windows:
        win = "never open"
    else:
        win = f"{median(windows):.0f} / {max(windows)}" + (f" ({always} never closed)" if always else "")
    i3a = sum(1 for r in ok if r["i3a_direct_dns_blocked"])
    i3b = sum(1 for r in ok if r["i3b_cluster_dns_forwards"])
    nft = Counter((r["nft"] or "-")[:40] for r in ok)
    kern = Counter(r["kernel"] for r in ok).most_common(1)
    print(f"| {cell} | {len(rs)} | {errs} | {pct(first_open, len(ok))} | {win} | {pct(i3a, len(ok))} | "
          f"{pct(i3b, len(ok))} | {'; '.join(f'{k} ×{v}' for k, v in nft.items())} | "
          f"{kern[0][0] if kern else '—'} |")

print("\nReading it:")
print("- control rows must be OPEN everywhere (1st attempt open 100%, DNS not blocked, forwards 100%).")
print("  If a control is blocked, that target can't prove anything in this environment (Finding 3).")
print("- 'open window' for an enforced cell = how long the agent could reach the internet after start (I2).")
print("- I3b forwards > 0% in an enforced cell = DNS is a working exfil channel despite default-deny.")
print("- nft-gvisor: if nft says FAILED and the window says open, the in-pod firewall failed OPEN under gVisor (I9).")
