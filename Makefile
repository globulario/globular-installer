CACHE_DIR ?= $(CURDIR)/.cache/go-build
export GOCACHE := $(CACHE_DIR)

BINDIR ?= $(CURDIR)/bin
BIN ?= $(BINDIR)/globular-installer
CMD_PKG := ./cmd/globular-installer

.PHONY: all build test fmt tidy clean ensure-cache bin

all: build

bin:
	mkdir -p $(BINDIR)

ensure-cache:
	mkdir -p $(CACHE_DIR)

# Build the installer binary (the main package lives under cmd/globular-installer)
build: ensure-cache bin
	go build -o $(BIN) $(CMD_PKG)

# Optional: build all packages (useful for catching compile errors across the repo)
build-all: ensure-cache
	go build ./...

test: ensure-cache
	go test ./...

fmt:
	go fmt ./...

tidy:
	go mod tidy

clean:
	go clean -cache
	rm -rf $(CACHE_DIR) $(BINDIR)
