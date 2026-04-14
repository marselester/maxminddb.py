#!/usr/bin/python
import argparse
import timeit

import maxminddb_zig

parser = argparse.ArgumentParser(description="Benchmark db.query() scans.")
parser.add_argument("--file", default="GeoLite2-City.mmdb", help="path to mmdb file")
parser.add_argument("--fields", default="", type=str, help="fields to decode")

args = parser.parse_args()

db = maxminddb_zig.Reader(args.file)
q = db.query(args.fields)

start = timeit.default_timer()
n = sum(1 for _ in q.scan())
elapsed = timeit.default_timer() - start

print(f"{n:,} records in {elapsed:.1f}s ({int(n / elapsed):,} records per second)")
