CACHE_DIR ?= $(CURDIR)/.cache/go-build
export GOCACHE := $(CACHE_DIR)

BINDIR ?= $(CURDIR)/bin
BIN ?= $(BINDIR)/globular-installer
CMD_PKG := ./cmd/globular-installer

ASSET_BIN_DIR ?= $(CURDIR)/internal/assets/bin
BUNDLE_SRC_BIN ?= $(CURDIR)/../globular/bin
BUNDLE_BINS ?= gateway xds

# Spec sources: infrastructure from packages, services from generated specs.
INFRA_SPEC_DIR ?= $(CURDIR)/../packages/specs
SERVICE_SPEC_DIR ?= $(CURDIR)/../services/generated/specs
SPEC_DEST_DIR ?= $(CURDIR)/internal/specs

.PHONY: all build test fmt tidy clean ensure-cache bin bundle bundle-stage sync-specs check-specs

all: build

bin:
	mkdir -p $(BINDIR)

ensure-cache:
	mkdir -p $(CACHE_DIR)

# Build the installer binary (the main package lives under cmd/globular-installer)
build: ensure-cache bin sync-specs
	go build -buildvcs=false -o $(BIN) $(CMD_PKG)

# Optional: build all packages (useful for catching compile errors across the repo)
build-all: ensure-cache
	go build -buildvcs=false ./...

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

# sync-specs copies specs from both source repos into the installer.
# Infrastructure specs come from packages/specs/, service specs from
# services/generated/specs/. Command specs (*_cmd.yaml) are skipped
# since the installer doesn't install standalone CLI tools.
sync-specs:
	mkdir -p "$(SPEC_DEST_DIR)"
	@found=0; \
	if [ -d "$(INFRA_SPEC_DIR)" ]; then \
		cp -f $(INFRA_SPEC_DIR)/*_service.yaml "$(SPEC_DEST_DIR)"/ 2>/dev/null && \
		found=$$(( $$found + $$(ls -1 $(INFRA_SPEC_DIR)/*_service.yaml 2>/dev/null | wc -l) )); \
	else \
		echo "WARN: infrastructure spec source $(INFRA_SPEC_DIR) not found" >&2; \
	fi; \
	if [ -d "$(SERVICE_SPEC_DIR)" ]; then \
		cp -f $(SERVICE_SPEC_DIR)/*_service.yaml "$(SPEC_DEST_DIR)"/ 2>/dev/null && \
		found=$$(( $$found + $$(ls -1 $(SERVICE_SPEC_DIR)/*_service.yaml 2>/dev/null | wc -l) )); \
	else \
		echo "WARN: service spec source $(SERVICE_SPEC_DIR) not found" >&2; \
	fi; \
	echo "sync-specs: $$found specs synced to $(SPEC_DEST_DIR)"

# check-specs verifies that installer specs match their sources.
# Use in CI to catch stale specs before release.
check-specs:
	@stale=0; missing=0; \
	for src_dir in "$(INFRA_SPEC_DIR)" "$(SERVICE_SPEC_DIR)"; do \
		[ -d "$$src_dir" ] || continue; \
		for src in "$$src_dir"/*_service.yaml; do \
			[ -f "$$src" ] || continue; \
			base=$$(basename "$$src"); \
			dest="$(SPEC_DEST_DIR)/$$base"; \
			if [ ! -f "$$dest" ]; then \
				echo "MISSING: $$base (in source but not in installer)"; \
				missing=$$(( $$missing + 1 )); \
			elif ! diff -q "$$src" "$$dest" >/dev/null 2>&1; then \
				echo "STALE: $$base (differs from source)"; \
				stale=$$(( $$stale + 1 )); \
			fi; \
		done; \
	done; \
	if [ $$stale -gt 0 ] || [ $$missing -gt 0 ]; then \
		echo "ERROR: $$stale stale + $$missing missing specs. Run 'make sync-specs' to fix." >&2; \
		exit 1; \
	fi; \
	echo "check-specs: all installer specs are up to date"
