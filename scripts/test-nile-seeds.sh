#!/usr/bin/env bash
# Probe all official Nile testnet seed nodes (TCP 18888).
#
# Usage (run on your server):
#   bash scripts/test-nile-seeds.sh
#   TOP_N=5 bash scripts/test-nile-seeds.sh
#
# Output: alive seeds sorted fastest-first (line 1 = best).
# Paste full output to refresh configs/nile.conf seed.node.ip.list.

set -uo pipefail

TIMEOUT="${TIMEOUT:-3}"
TOP_N="${TOP_N:-5}"

echo "=== TRON Nile testnet seed probe ==="
echo "host: $(hostname -f 2>/dev/null || hostname)"
echo "time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "timeout: ${TIMEOUT}s per seed | top_n: ${TOP_N}"
echo

python3 - "$TIMEOUT" "$TOP_N" << 'PY'
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor

timeout = float(sys.argv[1])
top_n = int(sys.argv[2])

# All 5 official Nile testnet seeds (nile-testnet config-nile.conf)
OFFICIAL_SEEDS = [
    "44.236.192.97:18888",
    "44.236.125.107:18888",
    "44.232.119.174:18888",
    "52.39.105.180:18888",
    "54.70.52.47:18888",
]

def probe(addr: str):
    host, port_s = addr.rsplit(":", 1)
    port = int(port_s)
    t0 = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            ms = (time.perf_counter() - t0) * 1000
            return addr, True, ms, None
    except OSError as e:
        ms = (time.perf_counter() - t0) * 1000
        return addr, False, ms, e.__class__.__name__

workers = max(len(OFFICIAL_SEEDS), 1)
with ThreadPoolExecutor(max_workers=workers) as pool:
    results = list(pool.map(probe, OFFICIAL_SEEDS))

alive = sorted((r for r in results if r[1]), key=lambda r: r[2])
dead = sorted((r for r in results if not r[1]), key=lambda r: r[0])
keep = min(top_n, len(alive))
top = alive[:keep]

print(f"SUMMARY: {len(alive)}/{len(OFFICIAL_SEEDS)} reachable, {len(dead)} failed")
print()
print(f"TOP {keep} (fastest first — best seed is line 1):")
if top:
    for i, (addr, _, ms, _) in enumerate(top, 1):
        print(f"  {i:2d}. {ms:7.1f}ms  {addr}")
else:
    print("  (none reachable)")

print()
print("ALL ALIVE (fastest first):")
if alive:
    for i, (addr, _, ms, _) in enumerate(alive, 1):
        mark = " *" if i <= keep else ""
        print(f"  {i:2d}. {ms:7.1f}ms  {addr}{mark}")
else:
    print("  (none)")

print()
print("FAILED:")
if dead:
    for addr, _, ms, err in dead:
        print(f"  {err:16}  {ms:7.1f}ms  {addr}")
else:
    print("  (none)")

print()
print(f"--- paste into configs/nile.conf (top {keep}, fastest first) ---")
print("seed.node = {")
print("  ip.list = [")
for addr, _, ms, _ in top:
    print(f'    "{addr}",  # {ms:.0f}ms')
print("  ]")
print("}")

print()
print("TOP 3 for node.active (optional fallback):")
for addr, _, ms, _ in alive[:3]:
    print(f'  "{addr}",  # {ms:.0f}ms')
PY
