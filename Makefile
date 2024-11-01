.PHONY: all test

test:
	nix-build --no-out-link ./tests/default.nix --show-trace

all: test
