# Build the library and create a symlink so venv can find maxmind.so.
build:
	zig build -Doptimize=ReleaseFast
	ln -sf $(shell pwd)/zig-out/lib/maxmind.so \
		$(shell python -c "import site; print(site.getsitepackages()[0])")/maxmind.so

test: build
	pytest -vs

lint:
	ruff check
	ruff format
