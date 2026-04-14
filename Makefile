# Build the library and create a symlink so venv can find maxminddb_zig.so.
build:
	zig build -Doptimize=ReleaseFast
	ln -sf $(shell pwd)/zig-out/lib/maxminddb_zig.so \
		$(shell python -c "import site; print(site.getsitepackages()[0])")/maxminddb_zig.so

test: build
	pytest -vs

lint:
	ruff check
	ruff format
