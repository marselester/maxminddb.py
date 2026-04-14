# Zig-backed Python MaxMind DB Reader

This is an unofficial [Zig-backed](https://github.com/marselester/maxminddb.zig)
Python library to read MaxMind DB files.
See also [Rust](https://github.com/oschwald/maxminddb-rust-python),
[C, and pure Python](https://github.com/maxmind/MaxMind-DB-Reader-python) implementations.

## Quick start

```sh
pip install maxminddb-zig
```

```python
import maxminddb_zig

with maxminddb_zig.Reader('GeoLite2-City.mmdb') as db:
    r, net = db.lookup('89.160.20.128')
    print(net, r['city']['names']['en'])

89.160.20.128/25 Linköping
```

FastAPI middleware example:

```python
from fastapi import FastAPI, Request
import maxminddb_zig

app = FastAPI()
db = maxminddb_zig.Reader("GeoLite2-City.mmdb")
geo = db.query("country")


@app.middleware("http")
async def add_country(request: Request, call_next):
    r, _ = geo.lookup(request.client.host)
    request.state.country = r["country"]["iso_code"] if r else None
    return await call_next(request)
```

## Usage

The `Reader` opens a MaxMind DB file for reading.
Make sure to close it unless you're using a context manager.

```python
import maxminddb_zig

db = maxminddb_zig.Reader('GeoLite2-City.mmdb')
db.lookup('89.160.20.128')
db.close()

with maxminddb_zig.Reader('GeoLite2-City.mmdb') as db:
    db.lookup('89.160.20.128')
```

You can scan the whole db or networks within a given IP range.

```python
for r, net in db:
    print(net, r)

for r, net in db.scan("89.160.20.0/24"):
    print(net, r)
```

The `lookup()` and `scan()` methods support an optional `fields` argument.
It is a comma-separated list of record fields to decode.
You should decode only the fields you need to improve performance.

```python
db.lookup("89.160.20.128", "city,continent")

db.scan(fields="city,country")
```

Use `query()` for repeated lookups or scans, e.g., in web services.
Results are cached for faster access.
Pass field names to decode only specific fields.

```python
q = db.query("city,country")
r, net = q.lookup("89.160.20.128")

for r, net in q.scan():
    print(net, r)
```

Use `json()` for the fastest lookups.

```python
j = db.json("city,country")
r, net = j.lookup("89.160.20.128")
```

You can check if an IP address is in the database without decoding the record.

```python
"89.160.20.128" in db
True
```

You can access the database metadata.

```python
db.metadata()["ip_version"]
```

The `Reader` could raise the following exceptions:

- `ValueError` when `lookup()` and `scan()` arguments are invalid, e.g., invalid IP address
- `ReaderException` when db reading fails, e.g., a file is corrupted

## Thread safety

With the GIL, all methods are thread safe.

For free-threaded Python, use per-thread `query()` instances
because each `query()` owns its caches.
Don't share the same `query()` instance between threads.

```python
db = maxminddb_zig.Reader('GeoLite2-City.mmdb')

def worker():
    q = db.query()
    for ip in ips:
        r, net = q.lookup(ip)
```

Free-threaded `query().lookup()` numbers on Apple M2 Pro (GeoLite2-City)
show difference between GIL and no GIL concurrency.

| Threads | GIL     | Free-threading |
|---      |---      |---             |
| 1       | ~316K/s | ~321K/s        |
| 2       | ~312K/s | ~627K/s        |
| 4       | ~307K/s | ~1,226K/s      |
| 8       | ~303K/s | ~1,850K/s      |

With the GIL, throughput stays flat.

<details>

<summary>GIL vs Free-threading</summary>

```sh
$ for t in 1 2 4 8; do
      PYTHON_GIL=1 python benchmarks/threads_lookup.py \
          --file=GeoLite2-City.mmdb --threads=$t
  done

  echo '---'

  for t in 1 2 4 8; do
      PYTHON_GIL=0 python benchmarks/threads_lookup.py \
          --file=GeoLite2-City.mmdb --threads=$t
  done

1 threads: 316,004 lookups/s (3.16s)
2 threads: 311,858 lookups/s (6.41s)
4 threads: 306,872 lookups/s (13.03s)
8 threads: 303,335 lookups/s (26.37s)
---
1 threads: 320,845 lookups/s (3.12s)
2 threads: 627,379 lookups/s (3.19s)
4 threads: 1,225,835 lookups/s (3.26s)
8 threads: 1,849,511 lookups/s (4.33s)
```

</details>

## Development

Clone the repository and its submodule.

```sh
$ git clone https://github.com/marselester/maxminddb.py.git
$ cd ./maxminddb.py/
$ git submodule update --init --recursive
```

Build the extension, run tests, and linters.

```sh
$ pyenv local 3.13.8t
$ python -m venv .venv
$ source .venv/bin/activate
$ pip install pytest ruff
$ make test
$ make lint
```

## Benchmarks

The impact depends on the database:

- `fields` helps most on databases with large records because there are fewer Python objects to build.
  On databases with tiny records it can be slower due to filtering overhead.
- `query()` helps lookups by caching decoded records and interning map key strings.
  The benefit is highest on databases with few unique records, e.g., GeoLite2-Country.
  For scans, `query()` doesn't add meaningful benefit over `scan(fields=...)`
  because both use caching internally.
- `json()` is the fastest path because it skips building Python objects and
  formats JSON directly from decoded data.

Here are reference results on Apple M2 Pro against GeoLite2-City.

### Lookup

1M random IPv4 lookups in GeoLite2-City.

| Benchmark                  | lookups per second |
|---                         |---                 |
| `lookup(ip)`               | ~170K              |
| `query().lookup(ip)`       | ~277K              |
| `json().lookup(ip)`        | ~511K              |
| `lookup(ip, "city")`       | ~559K              |
| `query("city").lookup(ip)` | ~696K              |
| `json("city").lookup(ip)`  | ~805K              |

<details>

<summary>lookup(ip) vs lookup(ip, "city")</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/lookup.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python benchmarks/lookup.py --file=GeoLite2-City.mmdb --fields=city
  done

1,000,000 records in 5.9s (169,552 lookups per second)
1,000,000 records in 5.9s (169,227 lookups per second)
1,000,000 records in 5.9s (168,292 lookups per second)
1,000,000 records in 5.9s (169,891 lookups per second)
1,000,000 records in 5.9s (170,920 lookups per second)
1,000,000 records in 5.9s (170,487 lookups per second)
1,000,000 records in 5.9s (170,208 lookups per second)
1,000,000 records in 5.9s (169,469 lookups per second)
1,000,000 records in 6.0s (167,375 lookups per second)
1,000,000 records in 5.9s (170,594 lookups per second)
---
1,000,000 records in 1.8s (544,006 lookups per second)
1,000,000 records in 1.8s (555,160 lookups per second)
1,000,000 records in 1.8s (561,005 lookups per second)
1,000,000 records in 1.8s (564,637 lookups per second)
1,000,000 records in 1.8s (555,541 lookups per second)
1,000,000 records in 1.8s (557,924 lookups per second)
1,000,000 records in 1.8s (565,643 lookups per second)
1,000,000 records in 1.8s (568,964 lookups per second)
1,000,000 records in 1.8s (566,015 lookups per second)
1,000,000 records in 1.8s (556,172 lookups per second)
```

</details>

<details>

<summary>query().lookup(ip) vs query("city").lookup(ip)</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/query_lookup.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python benchmarks/query_lookup.py --file=GeoLite2-City.mmdb --fields=city
  done

1,000,000 records in 3.6s (280,790 lookups per second)
1,000,000 records in 3.6s (276,033 lookups per second)
1,000,000 records in 3.6s (277,486 lookups per second)
1,000,000 records in 3.6s (277,271 lookups per second)
1,000,000 records in 3.6s (276,642 lookups per second)
1,000,000 records in 3.6s (277,696 lookups per second)
1,000,000 records in 3.6s (280,458 lookups per second)
1,000,000 records in 3.6s (278,194 lookups per second)
1,000,000 records in 3.6s (275,151 lookups per second)
1,000,000 records in 3.7s (272,327 lookups per second)
---
1,000,000 records in 1.4s (698,274 lookups per second)
1,000,000 records in 1.4s (695,933 lookups per second)
1,000,000 records in 1.5s (687,627 lookups per second)
1,000,000 records in 1.4s (695,669 lookups per second)
1,000,000 records in 1.4s (698,477 lookups per second)
1,000,000 records in 1.4s (695,712 lookups per second)
1,000,000 records in 1.4s (695,234 lookups per second)
1,000,000 records in 1.4s (707,865 lookups per second)
1,000,000 records in 1.5s (677,752 lookups per second)
1,000,000 records in 1.4s (704,295 lookups per second)
```

</details>

<details>

<summary>json().lookup(ip) vs json("city").lookup(ip)</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/json_lookup.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python benchmarks/json_lookup.py --file=GeoLite2-City.mmdb --fields=city
  done

1,000,000 records in 2.0s (508,853 lookups per second)
1,000,000 records in 1.9s (513,942 lookups per second)
1,000,000 records in 1.9s (512,896 lookups per second)
1,000,000 records in 2.0s (505,046 lookups per second)
1,000,000 records in 2.0s (506,953 lookups per second)
1,000,000 records in 2.0s (512,477 lookups per second)
1,000,000 records in 2.0s (510,976 lookups per second)
1,000,000 records in 2.0s (510,270 lookups per second)
1,000,000 records in 2.0s (497,465 lookups per second)
1,000,000 records in 1.9s (513,094 lookups per second)
---
1,000,000 records in 1.2s (809,060 lookups per second)
1,000,000 records in 1.2s (803,894 lookups per second)
1,000,000 records in 1.3s (774,636 lookups per second)
1,000,000 records in 1.2s (811,619 lookups per second)
1,000,000 records in 1.2s (801,847 lookups per second)
1,000,000 records in 1.3s (798,536 lookups per second)
1,000,000 records in 1.2s (807,078 lookups per second)
1,000,000 records in 1.2s (807,707 lookups per second)
1,000,000 records in 1.2s (812,466 lookups per second)
1,000,000 records in 1.2s (801,383 lookups per second)
```

</details>

### Scan

Full GeoLite2-City scan (5.5M records).

| Benchmark              | records per second |
|---                     |---                 |
| `scan()`               | ~531K              |
| `query().scan()`       | ~526K              |
| `scan(fields="city")`  | ~1,794K            |
| `query("city").scan()` | ~1,785K            |

<details>

<summary>scan() vs scan(fields="city")</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/scan.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python benchmarks/scan.py --file=GeoLite2-City.mmdb --fields=city
  done

5,502,351 records in 10.3s (533,336 records per second)
5,502,351 records in 10.2s (541,393 records per second)
5,502,351 records in 10.3s (532,846 records per second)
5,502,351 records in 10.4s (530,385 records per second)
5,502,351 records in 10.3s (532,073 records per second)
5,502,351 records in 10.4s (530,863 records per second)
5,502,351 records in 10.4s (529,987 records per second)
5,502,351 records in 10.5s (524,235 records per second)
5,502,351 records in 10.4s (527,442 records per second)
5,502,351 records in 10.6s (521,197 records per second)
---
5,502,351 records in 3.1s (1,795,802 records per second)
5,502,351 records in 3.1s (1,798,097 records per second)
5,502,351 records in 3.1s (1,788,232 records per second)
5,502,351 records in 3.1s (1,794,434 records per second)
5,502,351 records in 3.0s (1,804,452 records per second)
5,502,351 records in 3.1s (1,787,658 records per second)
5,502,351 records in 3.1s (1,786,531 records per second)
5,502,351 records in 3.1s (1,796,017 records per second)
5,502,351 records in 3.1s (1,789,501 records per second)
5,502,351 records in 3.1s (1,793,517 records per second)
```

</details>

<details>

<summary>query().scan() vs query("city").scan()</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/query_scan.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python benchmarks/query_scan.py --file=GeoLite2-City.mmdb --fields=city
  done

5,502,351 records in 10.4s (527,939 records per second)
5,502,351 records in 10.4s (529,239 records per second)
5,502,351 records in 10.5s (523,321 records per second)
5,502,351 records in 10.4s (531,603 records per second)
5,502,351 records in 10.5s (526,033 records per second)
5,502,351 records in 10.5s (522,252 records per second)
5,502,351 records in 10.4s (528,354 records per second)
5,502,351 records in 10.5s (522,438 records per second)
5,502,351 records in 10.5s (525,263 records per second)
5,502,351 records in 10.5s (524,663 records per second)
---
5,502,351 records in 3.1s (1,788,935 records per second)
5,502,351 records in 3.1s (1,782,188 records per second)
5,502,351 records in 3.1s (1,786,643 records per second)
5,502,351 records in 3.1s (1,781,621 records per second)
5,502,351 records in 3.1s (1,786,342 records per second)
5,502,351 records in 3.1s (1,791,478 records per second)
5,502,351 records in 3.1s (1,783,888 records per second)
5,502,351 records in 3.1s (1,781,067 records per second)
5,502,351 records in 3.1s (1,780,360 records per second)
5,502,351 records in 3.1s (1,786,614 records per second)
```

</details>
