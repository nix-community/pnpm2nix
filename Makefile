.PHONY: all test

test:
	nix-shell -p nixUnstable --run "nix-build --no-out-link ./tests/default.nix --show-trace"

all: test
