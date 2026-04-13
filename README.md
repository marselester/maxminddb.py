# Zig-backed Python MaxMind DB Reader

This is an unofficial [Zig-backed](https://github.com/marselester/maxminddb.zig)
Python library to read MaxMind DB files.
See also [Rust](https://github.com/oschwald/maxminddb-rust-python),
[C, and pure Python](https://github.com/maxmind/MaxMind-DB-Reader-python) implementations.

## Quick start

```python
import maxmind

with maxmind.Reader('GeoLite2-City.mmdb') as db:
    r, net = db.lookup('89.160.20.128')
    print(net, r['city']['names']['en'])

89.160.20.128/25 Linköping
```

FastAPI middleware example:

```python
from fastapi import FastAPI, Request
import maxmind

app = FastAPI()
db = maxmind.Reader("GeoLite2-City.mmdb")
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
import maxmind

db = maxmind.Reader('GeoLite2-City.mmdb')
db.lookup('89.160.20.128')
db.close()

with maxmind.Reader('GeoLite2-City.mmdb') as db:
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
q.lookup("89.160.20.128")

for r, net in q.scan():
    print(net, r)
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
db = maxmind.Reader('GeoLite2-City.mmdb')

def worker():
    q = db.query()
    for ip in ips:
        r, net = q.lookup(ip)
```

Free-threaded `query().lookup()` numbers on Apple M2 Pro (GeoLite2-City)
show difference between GIL and no GIL concurrency.

| Threads | GIL       | Free-threading |
|---      |---        |---             |
| 1       | ~1,024K/s | ~1,005K/s      |
| 2       | ~1,034K/s | ~1,952K/s      |
| 4       | ~1,035K/s | ~3,590K/s      |
| 8       | ~1,036K/s | ~5,269K/s      |

With the GIL, throughput stays flat.

<details>

<summary>GIL vs Free-threading</summary>

```sh
$ for t in 1 2 4 8; do
      PYTHON_GIL=1 python benchmarks/threads_lookup.py \
          --file=GeoLite2-City.mmdb --fields=city --threads=$t
  done

  echo '---'

  for t in 1 2 4 8; do
      PYTHON_GIL=0 python benchmarks/threads_lookup.py \
          --file=GeoLite2-City.mmdb --fields=city --threads=$t
  done

1 threads: 1,024,475 lookups/s (0.98s)
2 threads: 1,034,136 lookups/s (1.93s)
4 threads: 1,035,279 lookups/s (3.86s)
8 threads: 1,035,886 lookups/s (7.72s)
---
1 threads: 1,004,677 lookups/s (1.00s)
2 threads: 1,951,560 lookups/s (1.02s)
4 threads: 3,590,088 lookups/s (1.11s)
8 threads: 5,268,850 lookups/s (1.52s)
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

Here are reference results on Apple M2 Pro against GeoLite2-City.

### Lookup

1M random IPv4 lookups in GeoLite2-City.

| Benchmark                  | lookups per second |
|---                         |---                 |
| `lookup(ip)`               | ~165K              |
| `query().lookup(ip)`       | ~268K              |
| `lookup(ip, "city")`       | ~546K              |
| `query("city").lookup(ip)` | ~681K              |

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

1,000,000 records in 6.1s (164,487 lookups per second)
1,000,000 records in 6.1s (165,099 lookups per second)
1,000,000 records in 6.1s (165,114 lookups per second)
1,000,000 records in 6.1s (164,612 lookups per second)
1,000,000 records in 6.1s (165,271 lookups per second)
1,000,000 records in 6.1s (164,997 lookups per second)
1,000,000 records in 6.1s (164,506 lookups per second)
1,000,000 records in 6.1s (163,500 lookups per second)
1,000,000 records in 6.1s (164,408 lookups per second)
1,000,000 records in 6.1s (164,348 lookups per second)
---
1,000,000 records in 1.8s (549,131 lookups per second)
1,000,000 records in 1.8s (545,391 lookups per second)
1,000,000 records in 1.8s (543,610 lookups per second)
1,000,000 records in 1.9s (539,345 lookups per second)
1,000,000 records in 1.8s (545,578 lookups per second)
1,000,000 records in 1.8s (542,915 lookups per second)
1,000,000 records in 1.8s (548,688 lookups per second)
1,000,000 records in 1.8s (546,562 lookups per second)
1,000,000 records in 1.8s (548,143 lookups per second)
1,000,000 records in 1.8s (554,557 lookups per second)
```

</details>

<details>

<summary>query().lookup(ip)</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/query_lookup.py --file=GeoLite2-City.mmdb
  done

1,000,000 records in 3.7s (269,236 lookups per second)
1,000,000 records in 3.7s (269,311 lookups per second)
1,000,000 records in 3.7s (269,805 lookups per second)
1,000,000 records in 3.8s (266,481 lookups per second)
1,000,000 records in 3.7s (267,394 lookups per second)
1,000,000 records in 3.7s (266,885 lookups per second)
1,000,000 records in 3.7s (269,322 lookups per second)
1,000,000 records in 3.7s (266,788 lookups per second)
1,000,000 records in 3.8s (266,524 lookups per second)
1,000,000 records in 3.8s (262,976 lookups per second)
```

</details>

<details>

<summary>query("city").lookup(ip)</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/query_lookup.py --file=GeoLite2-City.mmdb --fields=city
  done

1,000,000 records in 1.5s (649,478 lookups per second)
1,000,000 records in 1.5s (685,977 lookups per second)
1,000,000 records in 1.5s (684,136 lookups per second)
1,000,000 records in 1.5s (684,740 lookups per second)
1,000,000 records in 1.5s (682,131 lookups per second)
1,000,000 records in 1.5s (678,160 lookups per second)
1,000,000 records in 1.5s (674,532 lookups per second)
1,000,000 records in 1.5s (681,709 lookups per second)
1,000,000 records in 1.5s (681,175 lookups per second)
1,000,000 records in 1.5s (674,909 lookups per second)
```

</details>

### Scan

Full GeoLite2-City scan (5.5M records).

| Benchmark              | records per second |
|---                     |---                 |
| `scan()`               | ~520K              |
| `query().scan()`       | ~519K              |
| `scan(fields="city")`  | ~1,773K            |
| `query("city").scan()` | ~1,773K            |

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

5,502,351 records in 10.5s (522,246 records per second)
5,502,351 records in 10.6s (521,530 records per second)
5,502,351 records in 10.5s (522,559 records per second)
5,502,351 records in 10.5s (521,937 records per second)
5,502,351 records in 10.6s (519,105 records per second)
5,502,351 records in 10.6s (518,975 records per second)
5,502,351 records in 10.7s (513,727 records per second)
5,502,351 records in 10.7s (515,389 records per second)
5,502,351 records in 10.6s (517,501 records per second)
5,502,351 records in 10.6s (520,533 records per second)
---
5,502,351 records in 3.1s (1,784,713 records per second)
5,502,351 records in 3.1s (1,793,877 records per second)
5,502,351 records in 3.1s (1,780,723 records per second)
5,502,351 records in 3.1s (1,775,474 records per second)
5,502,351 records in 3.1s (1,758,084 records per second)
5,502,351 records in 3.1s (1,760,736 records per second)
5,502,351 records in 3.1s (1,776,621 records per second)
5,502,351 records in 3.1s (1,757,925 records per second)
5,502,351 records in 3.1s (1,768,053 records per second)
5,502,351 records in 3.1s (1,770,746 records per second)
```

</details>

<details>

<summary>query().scan()</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/query_scan.py --file=GeoLite2-City.mmdb
  done

5,502,351 records in 10.6s (518,620 records per second)
5,502,351 records in 10.6s (520,308 records per second)
5,502,351 records in 10.6s (518,037 records per second)
5,502,351 records in 10.6s (520,462 records per second)
5,502,351 records in 10.6s (519,904 records per second)
5,502,351 records in 10.7s (515,143 records per second)
5,502,351 records in 10.5s (521,716 records per second)
5,502,351 records in 10.6s (520,407 records per second)
5,502,351 records in 10.6s (518,381 records per second)
5,502,351 records in 10.7s (516,606 records per second)
```

</details>

<details>

<summary>query("city").scan()</summary>

```sh
$ for i in $(seq 1 10); do
    python benchmarks/query_scan.py --file=GeoLite2-City.mmdb --fields=city
  done

5,502,351 records in 3.1s (1,747,328 records per second)
5,502,351 records in 3.1s (1,788,840 records per second)
5,502,351 records in 3.1s (1,779,631 records per second)
5,502,351 records in 3.1s (1,780,345 records per second)
5,502,351 records in 3.1s (1,773,505 records per second)
5,502,351 records in 3.1s (1,772,941 records per second)
5,502,351 records in 3.1s (1,771,069 records per second)
5,502,351 records in 3.1s (1,770,072 records per second)
5,502,351 records in 3.1s (1,756,750 records per second)
5,502,351 records in 3.1s (1,772,070 records per second)
```

</details>
