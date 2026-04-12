import argparse
import random
import socket
import struct
import time
from concurrent.futures import ThreadPoolExecutor

import maxmind

parser = argparse.ArgumentParser(description="Benchmark concurrent lookups.")
parser.add_argument("--file", default="GeoLite2-City.mmdb", help="path to mmdb file")
parser.add_argument("--fields", default="city", type=str, help="fields to decode")
parser.add_argument("--count", default=1_000_000, type=int, help="lookups per thread")
parser.add_argument("--threads", default=8, type=int, help="number of threads")

args = parser.parse_args()


def random_ips(seed, count):
    r = random.Random(seed)
    return [
        socket.inet_ntoa(struct.pack("!L", r.getrandbits(32))) for _ in range(count)
    ]


thread_ips = [random_ips(t, args.count) for t in range(args.threads)]

db = maxmind.Reader(args.file)


def lookup_only(thread_id):
    q = db.only(args.fields)
    for ip in thread_ips[thread_id]:
        q.lookup(ip)


start = time.perf_counter()
with ThreadPoolExecutor(max_workers=args.threads) as pool:
    list(pool.map(lookup_only, range(args.threads)))
elapsed = time.perf_counter() - start

total = args.count * args.threads
rate = total / elapsed
print(f"{args.threads} threads: {rate:,.0f} lookups/s ({elapsed:.2f}s)")
