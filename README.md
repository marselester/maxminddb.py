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

89.160.20.0/24 Karlstad
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
    print(r, net)

for r, net in db.scan("89.160.20.0/24"):
    print(r, net)
```

The `lookup` and `scan` methods support an optional `fields` argument.
It is a comma-separated list of record fields to decode.
You should decode only the fields you need to improve performance.

```python
db.lookup("89.160.20.128", "city,continent")

db.scan(fields="city,country")
```

You can access the database metadata.

```python
db.metadata()["ip_version"]
```

The `Reader` could raise the following exceptions:

- `ValueError` when `lookup` and `scan` arguments are invalid, e.g., invalid IP address
- `ReaderException` when db reading fails, e.g., a file is corrupted

## Development

Clone the repository and its submodule.

```sh
$ git clone https://github.com/marselester/maxminddb.py.git
$ cd ./maxminddb.py/
$ git submodule update --init --recursive
```

Install the dependencies.

```sh
$ pyenv install 3.13.12
$ pyenv local 3.13.12
$ pip install virtualenv
$ virtualenv venv
$ . venv/bin/activate
$ pip install pyoz
$ pyoz develop
```

Run the tests and linters.

```sh
$ pip install pytest ruff
$ pytest -vs
$ ruff check
$ ruff format
```

Run benchmarks to catch regressions.
Here are reference results on Apple M2 Pro against GeoLite2-City:

| Benchmark                | All fields | `city` only |
|---                       |---         |---          |
| lookup (1M random IPs)   | ~268K/s    | ~695K/s     |
| scan (full db)           | ~262K/s    | ~1,228K/s   |

<details>

<summary>lookup all vs filtered</summary>

```sh
$ for i in $(seq 1 10); do
    python3 benchmarks/lookup.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python3 benchmarks/lookup.py --file=GeoLite2-City.mmdb --fields=city
  done

1,000,000 records in 3.7s (271,037 lookups per second)
1,000,000 records in 3.7s (267,561 lookups per second)
1,000,000 records in 3.7s (271,391 lookups per second)
1,000,000 records in 3.7s (268,023 lookups per second)
1,000,000 records in 3.7s (270,993 lookups per second)
1,000,000 records in 3.7s (269,406 lookups per second)
1,000,000 records in 3.7s (267,809 lookups per second)
1,000,000 records in 3.8s (264,635 lookups per second)
1,000,000 records in 3.8s (264,429 lookups per second)
1,000,000 records in 3.8s (263,863 lookups per second)
---
1,000,000 records in 1.5s (683,086 lookups per second)
1,000,000 records in 1.4s (695,187 lookups per second)
1,000,000 records in 1.4s (702,726 lookups per second)
1,000,000 records in 1.4s (697,347 lookups per second)
1,000,000 records in 1.4s (699,832 lookups per second)
1,000,000 records in 1.4s (693,495 lookups per second)
1,000,000 records in 1.4s (693,735 lookups per second)
1,000,000 records in 1.4s (696,207 lookups per second)
1,000,000 records in 1.4s (696,179 lookups per second)
1,000,000 records in 1.4s (690,049 lookups per second)
```

</details>

<details>

<summary>scan all vs filtered</summary>

```sh
$ for i in $(seq 1 10); do
    python3 benchmarks/scan.py --file=GeoLite2-City.mmdb
  done

  echo '---'

  for i in $(seq 1 10); do
    python3 benchmarks/scan.py --file=GeoLite2-City.mmdb --fields=city
  done

5,502,351 records in 21.2s (259,730 records per second)
5,502,351 records in 21.2s (259,674 records per second)
5,502,351 records in 21.0s (262,636 records per second)
5,502,351 records in 21.1s (261,077 records per second)
5,502,351 records in 21.3s (257,977 records per second)
5,502,351 records in 21.2s (259,935 records per second)
5,502,351 records in 21.0s (261,668 records per second)
5,502,351 records in 20.9s (263,869 records per second)
5,502,351 records in 21.1s (260,449 records per second)
5,502,351 records in 21.2s (259,491 records per second)
---
5,502,351 records in 4.5s (1,226,793 records per second)
5,502,351 records in 4.5s (1,236,313 records per second)
5,502,351 records in 4.5s (1,220,429 records per second)
5,502,351 records in 4.5s (1,225,400 records per second)
5,502,351 records in 4.5s (1,217,991 records per second)
5,502,351 records in 4.5s (1,231,626 records per second)
5,502,351 records in 4.5s (1,228,671 records per second)
5,502,351 records in 4.5s (1,229,389 records per second)
5,502,351 records in 4.4s (1,239,842 records per second)
5,502,351 records in 4.5s (1,224,617 records per second)
```

</details>
