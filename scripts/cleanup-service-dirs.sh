#!/usr/bin/env bash
set -euo pipefail

# Cleanup script for empty service directories created by old specs
# These directories should NOT exist as all service configs go in /var/lib/globular/services

STATE_DIR="${GLOBULAR_STATE_DIR:-/var/lib/globular}"

log() { echo "[cleanup] $*"; }
die() { echo "[cleanup] ERROR: $*" >&2; exit 1; }

# Services that should NOT have individual directories in STATE_DIR
# (their configs belong in STATE_DIR/services/)
SERVICES_TO_CLEAN=(
  "authentication"
  "blog"
  "catalog"
  "conversation"
  "discovery"
  "dns"
  "echo"
  "event"
  "file"
  "log"
  "media"
  "monitoring"
  "persistence"
  "rbac"
  "repository"
  "resource"
  "search"
  "sql"
  "storage"
  "title"
  "torrent"
  "gateway"
  "node-agent"
  "envoy"
  # Also check for underscore variants
  "cluster_controller"
  "clustercontroller"
  "node_agent"
)

# Services that SHOULD keep their directories (infrastructure services with data)
KEEP_DIRS=(
  "services"           # All service configs
  "cluster-controller" # State and config
  "etcd"              # Data and config
  "minio"             # Object storage data
  "xds"               # Config
)

if [[ ! -d "$STATE_DIR" ]]; then
  log "State directory does not exist: $STATE_DIR"
  exit 0
fi

log "Checking for empty service directories in $STATE_DIR..."
log "Directories to keep: ${KEEP_DIRS[*]}"
log ""

REMOVED_COUNT=0
SKIPPED_COUNT=0

for svc in "${SERVICES_TO_CLEAN[@]}"; do
  dir="$STATE_DIR/$svc"

  if [[ ! -d "$dir" ]]; then
    continue
  fi

  # Check if directory is empty or only contains hidden files
  if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
    log "Removing empty directory: $dir"
    rmdir "$dir" 2>/dev/null || log "Warning: Could not remove $dir"
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
  else
    log "Skipping non-empty directory: $dir (contains: $(ls -A "$dir" | head -3 | tr '\n' ' ')...)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
  fi
done

log ""
log "Cleanup complete:"
log "  - Removed: $REMOVED_COUNT empty directories"
log "  - Skipped: $SKIPPED_COUNT non-empty directories"
log ""

if [[ $SKIPPED_COUNT -gt 0 ]]; then
  log "Note: Non-empty directories were preserved. If they should be removed,"
  log "      please backup their contents and remove them manually."
fi

# Show current state
log "Current directory structure in $STATE_DIR:"
log "$(ls -la "$STATE_DIR" 2>/dev/null | grep ^d || echo '  (no directories found)')"
