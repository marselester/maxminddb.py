#!/usr/bin/python
import argparse
import timeit

import maxmind

parser = argparse.ArgumentParser(description="Benchmark full db scan.")
parser.add_argument("--fields", default=None, type=str, help="fields to decode")
parser.add_argument("--file", default="GeoLite2-City.mmdb", help="path to mmdb file")

args = parser.parse_args()

db = maxmind.Reader(args.file)

start = timeit.default_timer()
n = sum(1 for _ in db.scan(fields=args.fields))
elapsed = timeit.default_timer() - start

print(f"{n:,} records in {elapsed:.1f}s ({int(n / elapsed):,} records per second)")
