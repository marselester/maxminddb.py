#!/usr/bin/python
# This benchmark is based on https://github.com/oschwald/maxminddb-rust-python.
import argparse
import random
import socket
import struct
import timeit

import maxminddb_zig

parser = argparse.ArgumentParser(description="Benchmark lookups.")
parser.add_argument("--file", default="GeoLite2-City.mmdb", help="path to mmdb file")
parser.add_argument("--fields", default=None, type=str, help="fields to decode")
parser.add_argument("--count", default=1_000_000, type=int, help="number of lookups")

args = parser.parse_args()

random.seed(0)
db = maxminddb_zig.Reader(args.file)


def lookup_ip_address() -> None:
    ip = socket.inet_ntoa(struct.pack("!L", random.getrandbits(32)))
    db.lookup(ip, args.fields)


elapsed = timeit.timeit(
    "lookup_ip_address()",
    setup="from __main__ import lookup_ip_address",
    number=args.count,
)

print(
    f"{args.count:,} records in {elapsed:.1f}s ({int(args.count / elapsed):,} lookups per second)"
)
