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
# registry.yaml is the single AUTHOR of package kind. check-specs verifies the
# installer's synced spec kinds directly against it (not only byte-identity to the
# intermediate source specs) — see services repo docs/design/package-classification-single-source.md.
REGISTRY ?= $(CURDIR)/../packages/registry.yaml

.PHONY: all build test fmt tidy clean ensure-cache bin bundle bundle-stage sync-specs check-specs check-spec-kinds

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

# check-spec-kinds verifies the installer's embedded spec kinds directly against
# registry.yaml — the single AUTHOR of package kind (services repo
# docs/design/package-classification-single-source.md). This is a direct author check,
# independent of check-specs' byte-identity-to-source check, so a wrong kind can't ride
# in even if the intermediate source spec drifted. SKIPs when registry.yaml is absent
# (sibling packages repo not checked out).
check-spec-kinds:
	@if [ -f "$(REGISTRY)" ]; then \
		kdrift=0; \
		for dest in "$(SPEC_DEST_DIR)"/*_service.yaml; do \
			[ -f "$$dest" ] || continue; \
			n=$$(basename "$$dest" | sed 's/_service\.yaml$$//' | tr '_' '-'); \
			ik=$$(grep -E '^[[:space:]]{2}kind:' "$$dest" | head -1 | sed 's/.*kind:[[:space:]]*//' | tr -d '[:space:]'); \
			[ -z "$$ik" ] && continue; \
			rk=$$(python3 -c "import yaml; d=yaml.safe_load(open('$(REGISTRY)')); ps=d.get('packages',d) if isinstance(d,dict) else d; m=[p for p in ps if isinstance(p,dict) and p.get('name')=='$$n']; print(m[0].get('kind','') if m else '')" 2>/dev/null); \
			if [ -n "$$rk" ] && [ "$$ik" != "$$rk" ]; then echo "KIND-DRIFT: $$n installer=$$ik registry=$$rk" >&2; kdrift=$$(( $$kdrift + 1 )); fi; \
		done; \
		if [ $$kdrift -gt 0 ]; then echo "ERROR: $$kdrift installer spec kind(s) disagree with registry.yaml (the single author)." >&2; exit 1; fi; \
		echo "check-spec-kinds: installer spec kinds agree with registry.yaml"; \
	else \
		echo "check-spec-kinds: SKIP (registry.yaml not at $(REGISTRY))"; \
	fi
