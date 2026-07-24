#!/usr/bin/env python3
# test/benchmark_xlib.py
# Python json benchmark (cross-language reference)

import json
import time

sample = {"a": 1, "b": "hello world", "c": [1, 2, 3, 4, 5], "d": True, "e": 3.14}
json_str = json.dumps(sample)

def bench(name, fn, n):
    # warmup
    for _ in range(min(n, 1000)):
        fn()
    # measure
    start = time.perf_counter()
    for _ in range(n):
        fn()
    elapsed = time.perf_counter() - start
    ops = n / elapsed
    print(f"  {name:42s} {n:8d} ops in {elapsed:6.3f}s  ->  {ops:10.0f} ops/s")
    return ops

print("=== Python json benchmark ===")
print(f"Python version: {__import__('sys').version}")
print()

print("[JSON encode]")
bench("  python json.dumps", lambda: json.dumps(sample), 100000)
print()

print("[JSON decode]")
bench("  python json.loads", lambda: json.loads(json_str), 100000)
print()

try:
    import msgpack
    mp_str = msgpack.packb(sample)
    print("[Msgpack encode]")
    bench("  python msgpack.packb", lambda: msgpack.packb(sample), 100000)
    print()
    print("[Msgpack decode]")
    bench("  python msgpack.unpackb", lambda: msgpack.unpackb(mp_str), 100000)
    print()
except ImportError:
    print("msgpack: NOT INSTALLED")
    print()

print("=== done ===")
