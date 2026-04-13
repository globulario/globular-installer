#!/usr/bin/env bash
set -euo pipefail

# ── Globular Day-0 Uninstaller ──────────────────────────────────────────────
#
# Discovers what is installed from systemd unit state and known binary paths,
# then stops, disables, and removes everything. Does NOT require .tgz package
# files to be present.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${PREFIX:-/usr/lib/globular}"
STATE_DIR="${STATE_DIR:-/var/lib/globular}"
CONFIG_DIR="${CONFIG_DIR:-/etc/globular}"
SYSTEMD_DIR="/etc/systemd/system"
BIN_DIR="$PREFIX/bin"
SPEC_DIR="$STATE_DIR/specs"

# Visual helper functions
die() { echo "  ✗ ERROR: $*" >&2; exit 1; }
log_info() { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_warn() { echo "  ⚠ $*"; }
log_step() { echo ""; echo "━━━ $* ━━━"; echo ""; }
log_substep() { echo "  • $*"; }

# ── Service registry ─────────────────────────────────────────────────────────
# Each entry: "display_name|unit1 unit2|binary1 binary2"
# Units and binaries that don't exist on disk are silently skipped.
# Order: reverse dependency (leaf services first, infrastructure last).
SERVICES=(
  # AI services
  "ai-watcher|globular-ai-watcher.service|ai_watcher_server"
  "ai-executor|globular-ai-executor.service|ai_executor_server"
  "ai-router|globular-ai-router.service|ai_router_server"
  "ai-memory|globular-ai-memory.service|ai_memory_server"

  # Application services
  "scylla-manager|globular-scylla-manager.service|"
  "scylla-manager-agent|globular-scylla-manager-agent.service|"
  "backup-manager|globular-backup-manager.service|backup_manager_server"
  "file|globular-file.service|file_server"
  "log|globular-log.service|log_server"
  "monitoring|globular-monitoring.service|monitoring_server"
  "prometheus|globular-prometheus.service|prometheus"
  "sidekick|globular-sidekick.service|sidekick"
  "node-exporter|globular-node-exporter.service|node_exporter"

  # Optional services
  "blog|globular-blog.service|blog_server"
  "catalog|globular-catalog.service|catalog_server"
  "conversation|globular-conversation.service|conversation_server"
  "echo|globular-echo.service|echo_server"
  "ldap|globular-ldap.service|ldap_server"
  "media|globular-media.service|media_server"
  "persistence|globular-persistence.service|persistence_server"
  "search|globular-search.service|search_server"
  "sql|globular-sql.service|sql_server"
  "storage|globular-storage.service|storage_server"
  "title|globular-title.service|title_server"
  "torrent|globular-torrent.service|torrent_server"

  # Core services
  "event|globular-event.service|event_server"
  "dns|globular-dns.service|dns_server"
  "repository|globular-repository.service|repository_server"
  "discovery|globular-discovery.service|discovery_server"
  "authentication|globular-authentication.service|authentication_server"
  "rbac|globular-rbac.service|rbac_server"
  "resource|globular-resource.service|resource_server"
  "mcp|globular-mcp.service|mcp"

  # CLI tools (no units, just binaries)
  "yt-dlp||yt-dlp"
  "ffmpeg||ffmpeg ffprobe"
  "sha256sum||sha256sum"
  "sctool||sctool"
  "restic||restic"
  "rclone||rclone"
  "etcdctl||etcdctl"
  "globular-cli||globularcli"
  "mc||mc"

  # Control plane
  "cluster-doctor|globular-cluster-doctor.service|cluster_doctor_server"
  "cluster-controller|globular-cluster-controller.service|cluster_controller_server"
  "node-agent|globular-node-agent.service|node_agent_server"
  "gateway|globular-gateway.service|gateway"

  # Data plane
  "xds|globular-xds.service|xds_server"
  "envoy|globular-envoy.service envoy.service|envoy"

  # Infrastructure
  "minio|globular-minio.service|minio"
  "etcd|globular-etcd.service|etcd"
  "scylladb|scylla-server.service|"
)

FAILED=0
STOPPED=0
REMOVED=0
SKIPPED=0

# ── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          GLOBULAR DAY-0 UNINSTALLATION                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

log_step "Configuration"
log_info "Prefix:     $PREFIX"
log_info "State dir:  $STATE_DIR"
log_info "Systemd:    $SYSTEMD_DIR"

# ── External domain warning ──────────────────────────────────────────────────

log_step "External Domain Warning"
echo ""
echo "  This script removes local services and data, but does NOT clean up"
echo "  external DNS records published to DNS providers (CloudFlare, etc.)."
echo ""

if command -v globular >/dev/null 2>&1; then
  DOMAIN_COUNT=0
  if systemctl is-active --quiet globular-etcd 2>/dev/null; then
    DOMAIN_COUNT=$(globular domain status 2>&1 \
      | grep -cE "globular\\.app|globular\\.cloud" || true)
    DOMAIN_COUNT="${DOMAIN_COUNT:-0}"
  fi

  if [[ "$DOMAIN_COUNT" -gt 0 ]] 2>/dev/null; then
    echo "  ⚠️  Detected $DOMAIN_COUNT external domain registration(s)!"
    echo ""
    echo "  Run BEFORE uninstalling:"
    echo "    globular domain status"
    echo "    globular domain remove --fqdn <domain> --cleanup-dns"
    echo ""
  fi
fi

echo "  If you registered external domains, manually remove DNS records after uninstall."
echo ""

# Give user a chance to abort
if [[ -t 0 ]]; then
  echo "Press Enter to continue with uninstall, or Ctrl+C to abort..."
  read -r
else
  echo "Non-interactive mode - continuing in 5 seconds... (Ctrl+C to abort)"
  sleep 5
fi

# ── Helper: check if a unit is known to systemd ─────────────────────────────

unit_exists() {
  systemctl list-unit-files "$1" --no-pager --no-legend 2>/dev/null | grep -q "$1" \
    || systemctl list-units --all --no-pager --no-legend --plain 2>/dev/null | grep -q "$1"
}

# ── Phase 1: Stop and disable services ───────────────────────────────────────

log_step "Stopping Services"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name units bins <<< "$entry"
  [[ -z "$units" ]] && continue

  for u in $units; do
    if unit_exists "$u"; then
      log_info "Stopping $u"
      systemctl stop "$u" 2>/dev/null || log_warn "Could not stop $u"
      systemctl disable "$u" 2>/dev/null || log_warn "Could not disable $u"
      STOPPED=$((STOPPED + 1))
    fi
  done
done

# Catch any globular-* units not in our registry
while IFS= read -r extra_unit; do
  [[ -z "$extra_unit" ]] && continue
  # Check if already handled
  already=0
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r _ units _ <<< "$entry"
    for u in $units; do
      [[ "$u" == "$extra_unit" ]] && already=1
    done
  done
  if [[ $already -eq 0 ]]; then
    log_info "Stopping extra unit: $extra_unit"
    systemctl stop "$extra_unit" 2>/dev/null || true
    systemctl disable "$extra_unit" 2>/dev/null || true
    STOPPED=$((STOPPED + 1))
  fi
done < <(systemctl list-unit-files 'globular-*' --no-pager --no-legend 2>/dev/null | awk '{print $1}')

systemctl daemon-reload 2>/dev/null || true

# ── Phase 1b: Force-kill any surviving processes ─────────────────────────────
# Some services hold listeners open and don't exit on SIGTERM. Kill them.

log_step "Force-Killing Surviving Processes"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name units bins <<< "$entry"
  [[ -z "$bins" ]] && continue

  for b in $bins; do
    if pgrep -x "$b" >/dev/null 2>&1; then
      log_warn "Process $b still running — sending SIGKILL"
      pkill -9 -x "$b" 2>/dev/null || true
    fi
  done
done

# Catch any remaining globular processes not in registry
remaining_procs=$(pgrep -a '_server$' 2>/dev/null | grep -v grep || true)
if [[ -n "$remaining_procs" ]]; then
  log_warn "Killing remaining *_server processes:"
  echo "$remaining_procs" | while read -r pid cmd; do
    log_substep "PID $pid: $cmd"
    kill -9 "$pid" 2>/dev/null || true
  done
fi

# Wait briefly for processes to die
sleep 1

# ── Phase 2: Remove unit files ───────────────────────────────────────────────

log_step "Removing Unit Files"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name units bins <<< "$entry"
  [[ -z "$units" ]] && continue

  for u in $units; do
    unit_path="$SYSTEMD_DIR/$u"
    if [[ -f "$unit_path" ]]; then
      rm -f "$unit_path"
      log_success "Removed $u"
      REMOVED=$((REMOVED + 1))
    fi
  done
done

# Catch any remaining globular-* unit files
for unit_file in "$SYSTEMD_DIR"/globular-*.service; do
  [[ -f "$unit_file" ]] || continue
  rm -f "$unit_file"
  log_success "Removed extra: $(basename "$unit_file")"
  REMOVED=$((REMOVED + 1))
done

systemctl daemon-reload 2>/dev/null || true

# ── Phase 3: Remove binaries ─────────────────────────────────────────────────

log_step "Removing Binaries"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name units bins <<< "$entry"
  [[ -z "$bins" ]] && continue

  for b in $bins; do
    bin_path="$BIN_DIR/$b"
    if [[ -f "$bin_path" ]]; then
      rm -f "$bin_path"
      log_success "Removed $b"
      REMOVED=$((REMOVED + 1))
    fi
  done
done

# Remove any remaining binaries in the bin directory
if [[ -d "$BIN_DIR" ]]; then
  remaining=$(find "$BIN_DIR" -type f 2>/dev/null | wc -l)
  if [[ "$remaining" -gt 0 ]]; then
    log_info "Removing $remaining remaining file(s) in $BIN_DIR"
    rm -rf "$BIN_DIR"
    REMOVED=$((REMOVED + remaining))
  fi
fi

# ── Phase 4: Remove installed specs ──────────────────────────────────────────

if [[ -d "$SPEC_DIR" ]]; then
  log_step "Removing Installed Specs"
  spec_count=$(find "$SPEC_DIR" -type f 2>/dev/null | wc -l)
  if [[ "$spec_count" -gt 0 ]]; then
    rm -rf "$SPEC_DIR"
    log_success "Removed $spec_count spec file(s)"
  fi
fi

# ── Phase 5: Cleanup ─────────────────────────────────────────────────────────

log_step "Cleanup"

# Remove state directory
if [[ -d "$STATE_DIR" ]]; then
  log_info "Removing $STATE_DIR..."
  rm -rf "$STATE_DIR" || log_warn "Could not remove $STATE_DIR"
  log_success "State directory removed"
else
  log_substep "State directory already removed"
fi

# Remove config directory
if [[ -d "$CONFIG_DIR" ]]; then
  log_info "Removing $CONFIG_DIR..."
  rm -rf "$CONFIG_DIR" || log_warn "Could not remove $CONFIG_DIR"
  log_success "Config directory removed"
else
  log_substep "Config directory already removed"
fi

# Remove prefix directory if empty
if [[ -d "$PREFIX" ]]; then
  rmdir "$PREFIX" 2>/dev/null && log_success "Removed empty $PREFIX" || true
fi

# Remove user client certificates
log_info "Removing user client certificates..."
CERT_CLEANUP_COUNT=0
for user_home in /home/*; do
  if [[ -d "$user_home/.config/globular" ]]; then
    user_name="$(basename "$user_home")"
    log_substep "Cleaning certificates for user: $user_name"
    rm -rf "$user_home/.config/globular" || log_warn "Could not remove $user_home/.config/globular"
    CERT_CLEANUP_COUNT=$((CERT_CLEANUP_COUNT + 1))
  fi
done

if [[ -d /root/.config/globular ]]; then
  log_substep "Cleaning certificates for root"
  rm -rf /root/.config/globular || log_warn "Could not remove /root/.config/globular"
  CERT_CLEANUP_COUNT=$((CERT_CLEANUP_COUNT + 1))
fi

if [[ $CERT_CLEANUP_COUNT -gt 0 ]]; then
  log_success "Cleaned client certificates for $CERT_CLEANUP_COUNT user(s)"
else
  log_substep "No user certificates found"
fi

# Remove globular user/group
if id globular >/dev/null 2>&1; then
  log_info "Removing globular user..."
  userdel globular 2>/dev/null || log_warn "Could not remove globular user"
  log_success "User removed"
else
  log_substep "User already removed"
fi

if getent group globular >/dev/null 2>&1; then
  log_info "Removing globular group..."
  groupdel globular 2>/dev/null || log_warn "Could not remove globular group"
  log_success "Group removed"
else
  log_substep "Group already removed"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     ✓ UNINSTALL COMPLETE                                     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Summary:"
echo "  Stopped:  $STOPPED unit(s)"
echo "  Removed:  $REMOVED file(s)"
echo ""
