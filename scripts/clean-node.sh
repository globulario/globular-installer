#!/usr/bin/env bash
set -euo pipefail

# ── Globular Node Cleanup ─────────────────────────────────────────────────────
#
# Prepares a node for a fresh Day-1 join by stopping all Globular and ScyllaDB
# services and removing their state. Run this on any node that previously had
# Globular installed before joining it to a new cluster.
#
# Usage:
#   sudo bash clean-node.sh              # interactive (asks before wiping)
#   sudo bash clean-node.sh --force      # non-interactive (no prompts)
#
# Can be run remotely:
#   ssh user@node "sudo bash -s" < clean-node.sh

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

die() { echo "  ✗ ERROR: $*" >&2; exit 1; }
log_info() { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_warn() { echo "  ⚠ $*"; }
log_step() { echo ""; echo "━━━ $* ━━━"; echo ""; }

# Must be root
[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          GLOBULAR NODE CLEANUP                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Host: $(hostname)"
echo "  Date: $(date)"
echo ""

if [[ $FORCE -eq 0 ]] && [[ -t 0 ]]; then
  echo "  This will stop all Globular/ScyllaDB services and wipe their data."
  echo "  Press Enter to continue, or Ctrl+C to abort..."
  read -r
fi

# ── Phase 1: Stop services ────────────────────────────────────────────────────

log_step "Stopping Services"

# Stop all globular services
for unit in $(systemctl list-units 'globular-*' --no-pager --no-legend --plain 2>/dev/null | awk '{print $1}'); do
  log_info "Stopping $unit"
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
done

# Stop ScyllaDB
for unit in scylla-server.service scylla-node-exporter.service scylla-tune-sched.service; do
  if systemctl is-active --quiet "$unit" 2>/dev/null || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    log_info "Stopping $unit"
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
  fi
done

# Stop ScyllaDB timers
for timer in $(systemctl list-timers 'scylla-*' --no-pager --no-legend --plain 2>/dev/null | awk '{print $NF}'); do
  log_info "Stopping timer $timer"
  systemctl stop "$timer" 2>/dev/null || true
  systemctl disable "$timer" 2>/dev/null || true
done

# ── Phase 2: Force-kill survivors ─────────────────────────────────────────────

log_step "Force-Killing Surviving Processes"

# Kill all globular server processes
for proc in $(ps aux 2>/dev/null | grep -E '_server|globularcli|mcp|gateway|xds_server|envoy' | grep -v grep | awk '{print $2}'); do
  cmd=$(ps -p "$proc" -o comm= 2>/dev/null || true)
  log_warn "Killing PID $proc ($cmd)"
  kill -9 "$proc" 2>/dev/null || true
done

# Kill etcd if running
pkill -9 -x etcd 2>/dev/null && log_warn "Killed etcd" || true

sleep 1

# ── Phase 3: Remove unit files ───────────────────────────────────────────────

log_step "Removing Unit Files"

REMOVED=0
for unit_file in /etc/systemd/system/globular-*.service; do
  [[ -f "$unit_file" ]] || continue
  rm -f "$unit_file"
  log_success "Removed $(basename "$unit_file")"
  REMOVED=$((REMOVED + 1))
done

# Remove drop-in dirs
for dropin in /etc/systemd/system/globular-*.service.d; do
  [[ -d "$dropin" ]] || continue
  rm -rf "$dropin"
  log_success "Removed $(basename "$dropin")"
done

systemctl daemon-reload 2>/dev/null || true

# ── Phase 4: Wipe state ─────────────────────────────────────────────────────

log_step "Wiping State"

# Globular state — unconditional rm -rf (safe on missing dirs, avoids
# permission-race with the globular user that was just removed)
for dir in /var/lib/globular /etc/globular /usr/lib/globular; do
  rm -rf "$dir" && log_success "Removed $dir" || log_warn "Could not fully remove $dir (retrying with -f)"
  rm -rf "$dir" 2>/dev/null || true
done

# MinIO object data (mounted volume — not under /var/lib/globular)
for dir in /mnt/data/minio /var/lib/minio; do
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
    log_success "Removed $dir"
  fi
done

# ScyllaDB data (but NOT the scylla package itself)
for dir in /var/lib/scylla/data /var/lib/scylla/commitlog /var/lib/scylla/hints /var/lib/scylla/view_hints; do
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
    log_success "Removed $dir"
  fi
done

# etcd data
if [[ -d /var/lib/etcd ]]; then
  rm -rf /var/lib/etcd
  log_success "Removed /var/lib/etcd"
fi


# Remove Globular CA from system trust store
if [[ -f /usr/local/share/ca-certificates/globular-ca.crt ]]; then
  rm -f /usr/local/share/ca-certificates/globular-ca.crt
  update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates >/dev/null 2>&1 || true
  log_success "Removed globular CA from system trust store"
fi

# User client certificates
for user_home in /home/*; do
  if [[ -d "$user_home/.config/globular" ]]; then
    rm -rf "$user_home/.config/globular"
    log_success "Cleaned certs for $(basename "$user_home")"
  fi
done
[[ -d /root/.config/globular ]] && rm -rf /root/.config/globular && log_success "Cleaned certs for root"

# ── Phase 5: Remove globular user ───────────────────────────────────────────

log_step "Cleanup"

if id globular >/dev/null 2>&1; then
  userdel globular 2>/dev/null || log_warn "Could not remove globular user"
  log_success "Removed globular user"
fi

if getent group globular >/dev/null 2>&1; then
  groupdel globular 2>/dev/null || log_warn "Could not remove globular group"
  log_success "Removed globular group"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     ✓ NODE CLEANUP COMPLETE                                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Node $(hostname) is ready for Day-1 join."
echo "  Removed $REMOVED unit file(s)."
echo ""
