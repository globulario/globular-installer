CACHE_DIR ?= $(CURDIR)/.cache/go-build
export GOCACHE := $(CACHE_DIR)

BINDIR ?= $(CURDIR)/bin
BIN ?= $(BINDIR)/globular-installer
CMD_PKG := ./cmd/globular-installer

ASSET_BIN_DIR ?= $(CURDIR)/internal/assets/bin
BUNDLE_SRC_BIN ?= $(CURDIR)/../globular/bin
BUNDLE_BINS ?= gateway xds

.PHONY: all build test fmt tidy clean ensure-cache bin bundle bundle-stage

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

bundle-stage:
	mkdir -p $(ASSET_BIN_DIR)
	@for b in $(BUNDLE_BINS); do \
		if [ ! -f "$(BUNDLE_SRC_BIN)/$$b" ]; then \
			echo "missing binary: $(BUNDLE_SRC_BIN)/$$b" >&2; exit 1; \
		fi; \
		cp -f "$(BUNDLE_SRC_BIN)/$$b" "$(ASSET_BIN_DIR)/$$b"; \
		chmod 0755 "$(ASSET_BIN_DIR)/$$b"; \
	done

bundle: bundle-stage build
