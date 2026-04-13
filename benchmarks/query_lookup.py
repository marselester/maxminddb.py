#!/usr/bin/python
import argparse
import random
import socket
import struct
import timeit

import maxmind

parser = argparse.ArgumentParser(description="Benchmark db.query() lookups.")
parser.add_argument("--file", default="GeoLite2-City.mmdb", help="path to mmdb file")
parser.add_argument("--fields", default="", type=str, help="fields to decode")
parser.add_argument("--count", default=1_000_000, type=int, help="number of lookups")

args = parser.parse_args()

random.seed(0)
db = maxmind.Reader(args.file)
q = db.query(args.fields)


def lookup_ip_address() -> None:
    ip = socket.inet_ntoa(struct.pack("!L", random.getrandbits(32)))
    q.lookup(ip)


elapsed = timeit.timeit(
    "lookup_ip_address()",
    setup="from __main__ import lookup_ip_address",
    number=args.count,
)

print(
    f"{args.count:,} records in {elapsed:.1f}s ({int(args.count / elapsed):,} lookups per second)"
)
