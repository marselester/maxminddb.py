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

Use `only()` for repeated lookups or scans with the same fields, e.g., in web services.
Fields are parsed once and the results are cached for faster access.

```python
q = db.only("city,country")
q.lookup("89.160.20.128")

for r, net in q.scan():
    print(net, r)
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
For free-threaded Python, use per-thread `only()` instances
because each `only()` owns its caches.

```python
db = maxmind.Reader('GeoLite2-City.mmdb')

def handle_request(ip):
    q = db.only("city,country")
    r, net = q.lookup(ip)
```

⚠️ `db.lookup()` and `db.scan()` use shared caches on the `Reader` and are not safe
for concurrent use from multiple threads without the GIL.
Don't share the same `only()` instance between threads.

Free-threaded `only().lookup()` numbers on Apple M2 Pro (GeoLite2-City)
show difference between GIL and no GIL concurrency.

| Threads | GIL        | Free-threading |
|---      |---         |---             |
| 1       | ~1,024K/s  | ~1,005K/s      |
| 2       | ~1,034K/s  | ~1,952K/s      |
| 4       | ~1,035K/s  | ~3,590K/s      |
| 8       | ~1,036K/s  | ~5,269K/s      |

With the GIL, throughput stays flat.

<details>

<summary>GIL vs Free-threading</summary>

```sh
$ for t in 1 2 4 8; do
    PYTHON_GIL=1 python benchmarks/threads_lookup.py --file=GeoLite2-City.mmdb --threads=$t
  done

  echo '---'

  for t in 1 2 4 8; do
    PYTHON_GIL=0 python benchmarks/threads_lookup.py --file=GeoLite2-City.mmdb --threads=$t
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

- `fields` helps most on databases with large records
  because there are fewer Python objects to build.
  On databases with tiny records it can be slower due to filtering overhead.
- `only()` helps lookups on databases with few unique records due to higher cache hit rate.
  For scans, `only()` doesn't add meaningful benefit over `scan(fields=...)`
  because both use caching internally.

Here are reference results on Apple M2 Pro against GeoLite2-City.

### Lookup

1M random IPv4 lookups in GeoLite2-City.

| Benchmark                 | lookups per second |
|---                        |---                 |
| `lookup(ip)`              | ~265K              |
| `lookup(ip, "city")`      | ~613K              |
| `only("city").lookup(ip)` | ~690K              |

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

1,000,000 records in 3.8s (260,401 lookups per second)
1,000,000 records in 3.8s (263,845 lookups per second)
1,000,000 records in 3.8s (265,037 lookups per second)
1,000,000 records in 3.8s (266,626 lookups per second)
1,000,000 records in 3.8s (265,949 lookups per second)
1,000,000 records in 3.8s (262,967 lookups per second)
1,000,000 records in 3.8s (266,238 lookups per second)
1,000,000 records in 3.8s (262,205 lookups per second)
1,000,000 records in 3.8s (265,644 lookups per second)
1,000,000 records in 3.7s (266,764 lookups per second)
---
1,000,000 records in 1.6s (613,136 lookups per second)
1,000,000 records in 1.6s (615,281 lookups per second)
1,000,000 records in 1.6s (613,697 lookups per second)
1,000,000 records in 1.6s (614,381 lookups per second)
1,000,000 records in 1.6s (610,796 lookups per second)
1,000,000 records in 1.6s (614,702 lookups per second)
1,000,000 records in 1.6s (608,786 lookups per second)
1,000,000 records in 1.6s (613,795 lookups per second)
1,000,000 records in 1.6s (615,612 lookups per second)
1,000,000 records in 1.6s (609,189 lookups per second)
```

</details>

<details>

<summary>only("city").lookup(ip)</summary>

```sh
$ for i in $(seq 1 10); do
    python3 benchmarks/only_lookup.py --file=GeoLite2-City.mmdb
  done

1,000,000 records in 1.5s (646,651 lookups per second)
1,000,000 records in 1.4s (705,755 lookups per second)
1,000,000 records in 1.5s (687,529 lookups per second)
1,000,000 records in 1.5s (688,474 lookups per second)
1,000,000 records in 1.5s (689,349 lookups per second)
1,000,000 records in 1.4s (694,513 lookups per second)
1,000,000 records in 1.4s (694,757 lookups per second)
1,000,000 records in 1.4s (691,701 lookups per second)
1,000,000 records in 1.5s (687,446 lookups per second)
1,000,000 records in 1.4s (695,486 lookups per second)
```

</details>

### Scan

Full GeoLite2-City scan (5.5M records).

| Benchmark             | records per second |
|---                    |---                 |
| `scan()`              | ~516K              |
| `scan(fields="city")` | ~1,769K            |
| `only("city").scan()` | ~1,765K            |

<details>

<summary>scan() vs scan(fields="city")</summary>

```sh
$ for i in $(seq 1 10); do
    python3 benchmarks/scan.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python3 benchmarks/scan.py --file=GeoLite2-City.mmdb --fields=city
  done

5,502,351 records in 10.6s (517,073 records per second)
5,502,351 records in 10.6s (520,035 records per second)
5,502,351 records in 10.7s (514,611 records per second)
5,502,351 records in 10.7s (513,001 records per second)
5,502,351 records in 10.6s (517,634 records per second)
5,502,351 records in 10.7s (514,480 records per second)
5,502,351 records in 10.6s (517,013 records per second)
5,502,351 records in 10.7s (512,102 records per second)
5,502,351 records in 10.7s (516,537 records per second)
5,502,351 records in 10.6s (517,771 records per second)
---
5,502,351 records in 3.1s (1,760,571 records per second)
5,502,351 records in 3.1s (1,775,104 records per second)
5,502,351 records in 3.1s (1,776,625 records per second)
5,502,351 records in 3.1s (1,766,162 records per second)
5,502,351 records in 3.1s (1,765,702 records per second)
5,502,351 records in 3.1s (1,775,493 records per second)
5,502,351 records in 3.1s (1,766,543 records per second)
5,502,351 records in 3.1s (1,768,793 records per second)
5,502,351 records in 3.1s (1,767,081 records per second)
5,502,351 records in 3.1s (1,770,212 records per second)
```

</details>

<details>

<summary>only("city").scan()</summary>

```sh
$ for i in $(seq 1 10); do
    python3 benchmarks/only_scan.py --file=GeoLite2-City.mmdb
  done

5,502,351 records in 3.1s (1,763,589 records per second)
5,502,351 records in 3.1s (1,769,234 records per second)
5,502,351 records in 3.1s (1,766,115 records per second)
5,502,351 records in 3.1s (1,771,872 records per second)
5,502,351 records in 3.1s (1,757,403 records per second)
5,502,351 records in 3.1s (1,768,186 records per second)
5,502,351 records in 3.1s (1,759,477 records per second)
5,502,351 records in 3.1s (1,767,438 records per second)
5,502,351 records in 3.1s (1,763,774 records per second)
5,502,351 records in 3.1s (1,764,091 records per second)
```

</details>
