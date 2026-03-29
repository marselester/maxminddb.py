# Python MaxMind DB Reader

This is an unofficial Python library to read MaxMind DB files.
How is it different from others? It's written in Zig!

## Development

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

Make sure the library works.

```python
import maxmind

with maxmind.Reader('GeoLite2-City.mmdb') as db:
    db.lookup('0.0.0.0') is None
    db.lookup('89.160.20.128')['city']['names']['en']

True
'Karlstad'
```
