#!/usr/bin/env bash
# Probe all 30 official java-tron mainnet seed nodes (TCP 18888).
#
# Usage (run on your server):
#   bash scripts/test-mainnet-seeds.sh
#   TOP_N=10 bash scripts/test-mainnet-seeds.sh
#
# Output: alive seeds sorted fastest-first (line 1 = best).
# Paste full output to refresh configs/mainnet.conf seed.node.ip.list.

set -uo pipefail

TIMEOUT="${TIMEOUT:-3}"
TOP_N="${TOP_N:-10}"

echo "=== TRON mainnet seed probe ==="
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

# All 30 official java-tron mainnet seeds (upstream config.conf)
OFFICIAL_SEEDS = [
    "3.225.171.164:18888",
    "52.8.46.215:18888",
    "3.79.71.167:18888",
    "108.128.110.16:18888",
    "18.133.82.227:18888",
    "35.180.81.133:18888",
    "13.210.151.5:18888",
    "18.231.27.82:18888",
    "3.12.212.122:18888",
    "52.24.128.7:18888",
    "15.207.144.3:18888",
    "3.39.38.55:18888",
    "54.151.226.240:18888",
    "35.174.93.198:18888",
    "18.210.241.149:18888",
    "54.177.115.127:18888",
    "54.254.131.82:18888",
    "18.167.171.167:18888",
    "54.167.11.177:18888",
    "35.74.7.196:18888",
    "52.196.244.176:18888",
    "54.248.129.19:18888",
    "43.198.142.160:18888",
    "3.0.214.7:18888",
    "54.153.59.116:18888",
    "54.153.94.160:18888",
    "54.82.161.39:18888",
    "54.179.207.68:18888",
    "18.142.82.44:18888",
    "18.163.230.203:18888",
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

with ThreadPoolExecutor(max_workers=30) as pool:
    results = list(pool.map(probe, OFFICIAL_SEEDS))

alive = sorted((r for r in results if r[1]), key=lambda r: r[2])
dead = sorted((r for r in results if not r[1]), key=lambda r: r[0])
top = alive[:top_n]

print(f"SUMMARY: {len(alive)}/{len(OFFICIAL_SEEDS)} reachable, {len(dead)} failed")
print()
print(f"TOP {top_n} (fastest first — best seed is line 1):")
if top:
    for i, (addr, _, ms, _) in enumerate(top, 1):
        print(f"  {i:2d}. {ms:7.1f}ms  {addr}")
else:
    print("  (none reachable)")

print()
print("ALL ALIVE (fastest first):")
if alive:
    for i, (addr, _, ms, _) in enumerate(alive, 1):
        mark = " *" if i <= top_n else ""
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
print(f"--- paste into configs/mainnet.conf (top {top_n}, fastest first) ---")
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
