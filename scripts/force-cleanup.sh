#!/usr/bin/env bash
set -euo pipefail

# Force cleanup script - stops all services and removes Globular completely
# Use this when uninstall-day0.sh hangs

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          GLOBULAR FORCE CLEANUP                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)" >&2
  exit 1
fi

log_info() { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_step() { echo ""; echo "━━━ $* ━━━"; }

log_step "Stopping All Globular Services"

# Get all globular services
SERVICES=$(systemctl list-units --all --no-pager --no-legend 'globular-*.service' 2>/dev/null | awk '{print $1}' | sed 's/^●//' || true)

if [[ -n "$SERVICES" ]]; then
  for svc in $SERVICES; do
    log_info "Stopping $svc..."
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done
  log_success "All services stopped"
else
  log_info "No services found"
fi

log_step "Removing Systemd Units"

# Remove all unit files
for unit_file in /etc/systemd/system/globular-*.service; do
  if [[ -f "$unit_file" ]]; then
    log_info "Removing $(basename "$unit_file")..."
    rm -f "$unit_file"
  fi
done

systemctl daemon-reload
log_success "Unit files removed"

log_step "Removing Binaries"

if [[ -d /usr/lib/globular ]]; then
  log_info "Removing /usr/lib/globular..."
  rm -rf /usr/lib/globular
  log_success "Binaries removed"
fi

if [[ -f /usr/local/bin/globular ]]; then
  log_info "Removing /usr/local/bin/globular..."
  rm -f /usr/local/bin/globular
  log_success "CLI removed"
fi

log_step "Removing State and Config"

if [[ -d /var/lib/globular ]]; then
  log_info "Removing /var/lib/globular..."
  rm -rf /var/lib/globular
  log_success "State directory removed"
fi

if [[ -d /etc/globular ]]; then
  log_info "Removing /etc/globular..."
  rm -rf /etc/globular
  log_success "Config directory removed"
fi

log_step "Removing User and Group"

if id globular >/dev/null 2>&1; then
  # Kill any processes owned by globular user
  pkill -u globular 2>/dev/null || true
  sleep 2

  log_info "Removing globular user..."
  userdel -r globular 2>/dev/null || userdel globular 2>/dev/null || true
  log_success "User removed"
fi

if getent group globular >/dev/null 2>&1; then
  log_info "Removing globular group..."
  groupdel globular 2>/dev/null || true
  log_success "Group removed"
fi

log_step "Removing DNS Configuration"

# Remove systemd-resolved stub configuration
if [[ -f /etc/systemd/resolved.conf.d/globular.conf ]]; then
  log_info "Removing DNS stub configuration..."
  rm -f /etc/systemd/resolved.conf.d/globular.conf
  systemctl restart systemd-resolved 2>/dev/null || true
  log_success "DNS configuration removed"
fi

log_step "Final Cleanup"

# Remove any remaining globular-related files
rm -f /tmp/globular-* 2>/dev/null || true
rm -f /tmp/client-cert-* 2>/dev/null || true

log_success "Cleanup complete"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     ✓ FORCE CLEANUP COMPLETE                                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "All Globular components have been forcefully removed."
echo "You can now run: sudo ./scripts/install-day0.sh"
echo ""
