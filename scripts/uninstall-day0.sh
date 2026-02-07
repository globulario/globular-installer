#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="${PKG_DIR:-"$INSTALLER_ROOT/internal/assets/packages"}"

INSTALLER_BIN="$INSTALLER_ROOT/bin/globular-installer"
if [[ ! -x "$INSTALLER_BIN" ]]; then
  INSTALLER_BIN="$(command -v globular-installer || true)"
fi

# Visual helper functions
die() { echo "  ✗ ERROR: $*" >&2; exit 1; }
log_info() { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_warn() { echo "  ⚠ $*"; }
log_step() { echo ""; echo "━━━ $* ━━━"; echo ""; }
log_substep() { echo "  • $*"; }

[[ -d "$PKG_DIR" ]] || die "Package directory not found: $PKG_DIR"
[[ -n "$INSTALLER_BIN" ]] && [[ -x "$INSTALLER_BIN" ]] || die "globular-installer not found; set INSTALLER_BIN or build ./bin/globular-installer"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          GLOBULAR DAY-0 UNINSTALLATION                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

detect_uninstall_cmd() {
  if "$INSTALLER_BIN" uninstall --help >/dev/null 2>&1; then
    if "$INSTALLER_BIN" uninstall --help 2>&1 | grep -q -- "--package"; then
      echo "uninstall_flag"; return 0
    fi
    echo "uninstall_arg"; return 0
  fi

  die "Could not detect uninstall command form for $INSTALLER_BIN"
}

UNINSTALL_MODE="$(detect_uninstall_cmd)"
TOLERATE_NOT_INSTALLED="${TOLERATE_NOT_INSTALLED:-1}"
UNINSTALL_TIMEOUT="${UNINSTALL_TIMEOUT:-120}"
TIMEOUT_BIN="${TIMEOUT_BIN:-$(command -v timeout || true)}"

if [[ -z "$TIMEOUT_BIN" ]]; then
  die "timeout command not found; install coreutils (timeout) or set TIMEOUT_BIN"
fi

FAILED=0
UNINSTALLED=0
SKIPPED=0

log_step "Configuration"
log_info "Installer: $(basename "$INSTALLER_BIN")"
log_info "Uninstall mode: $UNINSTALL_MODE"
log_info "Package directory: $PKG_DIR"
log_info "Timeout: ${UNINSTALL_TIMEOUT}s"

pkg_base_from_filename() {
  local base
  base="$(basename "$1")"
  echo "$base" | awk -F'_' '{print $1}'
}

units_for_pkg() {
  case "$1" in
    service.etcd)               echo "globular-etcd.service" ;;
    service.minio)              echo "globular-minio.service" ;;
    service.envoy)              echo "globular-envoy.service envoy.service" ;;
    service.xds)                echo "globular-xds.service" ;;
    service.gateway)            echo "globular-gateway.service" ;;
    service.node-agent)         echo "globular-node-agent.service" ;;
    service.cluster-controller) echo "globular-cluster-controller.service" ;;
    service.discovery)          echo "globular-discovery.service" ;;
    service.repository)         echo "globular-repository.service" ;;
    service.dns)                echo "globular-dns.service" ;;
    service.authentication)     echo "globular-authentication.service" ;;
    service.rbac)               echo "globular-rbac.service" ;;
    service.resource)           echo "globular-resource.service" ;;
    service.event)              echo "globular-event.service" ;;
    service.log)                echo "globular-log.service" ;;
    service.file)               echo "globular-file.service" ;;
    service.persistence)        echo "globular-persistence.service" ;;
    service.ldap)               echo "globular-ldap.service" ;;
    service.blog)               echo "globular-blog.service" ;;
    service.catalog)            echo "globular-catalog.service" ;;
    service.conversation)       echo "globular-conversation.service" ;;
    service.echo)               echo "globular-echo.service" ;;
    service.media)              echo "globular-media.service" ;;
    service.monitoring)         echo "globular-monitoring.service" ;;
    service.search)             echo "globular-search.service" ;;
    service.sql)                echo "globular-sql.service" ;;
    service.storage)            echo "globular-storage.service" ;;
    service.title)              echo "globular-title.service" ;;
    service.torrent)            echo "globular-torrent.service" ;;
    *)                          echo "" ;;
  esac
}

is_installed() {
  local name="$1"
  local units
  units="$(units_for_pkg "$name")"

  local unit_files units_all
  unit_files="$(LC_ALL=C systemctl list-unit-files --no-pager --no-legend 2>/dev/null | awk '{print $1}')"
  units_all="$(LC_ALL=C systemctl list-units --all --no-pager --no-legend --plain 2>/dev/null \
    | awk '{print $1}' \
    | sed 's/^●//')"

  if [[ -n "$units" ]]; then
    for u in $units; do
      if echo "$unit_files" | grep -qx "$u"; then
        return 0
      fi
      if echo "$units_all" | grep -qx "$u"; then
        return 0
      fi
    done
    return 1
  fi
  local st
  st="$("$INSTALLER_BIN" status 2>&1 || true)"
  echo "$st" | grep -qF "$name"
}

run_uninstall() {
  local pkgfile="$1"
  local pkgname
  pkgname="$(pkg_base_from_filename "$pkgfile")"
  local display_name
  display_name="$(basename "$pkgfile" .tgz | sed 's/_0\.0\.1_linux_amd64$//' | sed 's/_[0-9.]*_linux_amd64$//' | sed 's/^service\.//')"

  local out rc
  local units
  units="$(units_for_pkg "$pkgname")"

  # Stop and disable systemd units first
  if [[ -n "$units" ]]; then
    for u in $units; do
      systemctl stop "$u" >/dev/null 2>&1 || true
      systemctl disable "$u" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if ! is_installed "$pkgname"; then
    log_substep "Not detected as installed, attempting anyway: $display_name"
  fi

  try_cmd() {
    out="$("$@" 2>&1)"
    rc=$?
    return 0
  }

  set +e
  case "$UNINSTALL_MODE" in
    uninstall_flag)
      if [[ -n "$TIMEOUT_BIN" ]]; then
        try_cmd "$TIMEOUT_BIN" "$UNINSTALL_TIMEOUT" "$INSTALLER_BIN" --non-interactive uninstall --package "$pkgfile"
      else
        try_cmd "$INSTALLER_BIN" --non-interactive uninstall --package "$pkgfile"
      fi
      ;;
    uninstall_arg)
      try_cmd "$TIMEOUT_BIN" "$UNINSTALL_TIMEOUT" "$INSTALLER_BIN" --non-interactive uninstall "$pkgfile"
      ;;
    *) out="Unknown uninstall mode: $UNINSTALL_MODE"; rc=2 ;;
  esac
  set -e

  if [[ $rc -eq 0 ]]; then
    log_success "$display_name"
    UNINSTALLED=$((UNINSTALLED + 1))
    return 0
  fi

  if [[ "$TOLERATE_NOT_INSTALLED" == "1" ]] && echo "$out" | grep -qiE "not installed|no such|does not exist"; then
    log_substep "Not installed (skipped): $display_name"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if echo "$out" | grep -qiE 'plan "uninstall" has no steps|has no steps'; then
    log_substep "No uninstall steps, retrying by name: $display_name"
    set +e
    out="$("$INSTALLER_BIN" uninstall "$pkgname" 2>&1)"; rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      log_success "$display_name (by name)"
      UNINSTALLED=$((UNINSTALLED + 1))
      return 0
    fi
    if echo "$out" | grep -qiE 'plan "uninstall" has no steps|has no steps'; then
      log_substep "No uninstall steps for $display_name, skipping"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
  fi

  echo "$out" >&2
  log_warn "Failed to uninstall $display_name"
  FAILED=1
  return 0
}

# Uninstall order: reverse dependency order (application services, then infrastructure)
REMOVE_ORDER=(
  # Application services (high-level)
  "service.file_0.0.1_linux_amd64.tgz"
  "service.log_0.0.1_linux_amd64.tgz"
  "service.event_0.0.1_linux_amd64.tgz"

  # Optional services
  "service.blog_0.0.1_linux_amd64.tgz"
  "service.catalog_0.0.1_linux_amd64.tgz"
  "service.conversation_0.0.1_linux_amd64.tgz"
  "service.echo_0.0.1_linux_amd64.tgz"
  "service.ldap_0.0.1_linux_amd64.tgz"
  "service.media_0.0.1_linux_amd64.tgz"
  "service.monitoring_0.0.1_linux_amd64.tgz"
  "service.persistence_0.0.1_linux_amd64.tgz"
  "service.search_0.0.1_linux_amd64.tgz"
  "service.sql_0.0.1_linux_amd64.tgz"
  "service.storage_0.0.1_linux_amd64.tgz"
  "service.title_0.0.1_linux_amd64.tgz"
  "service.torrent_0.0.1_linux_amd64.tgz"

  # Core services
  "service.dns_0.0.1_linux_amd64.tgz"
  "service.repository_0.0.1_linux_amd64.tgz"
  "service.discovery_0.0.1_linux_amd64.tgz"
  "service.authentication_0.0.1_linux_amd64.tgz"
  "service.rbac_0.0.1_linux_amd64.tgz"
  "service.resource_0.0.1_linux_amd64.tgz"

  # CLI tools
  "service.globular-cli-cmd_0.0.1_linux_amd64.tgz"
  "service.mc-cmd_0.0.1_linux_amd64.tgz"

  # Control plane
  "service.cluster-controller_0.0.1_linux_amd64.tgz"
  "service.node-agent_0.0.1_linux_amd64.tgz"
  "service.gateway_0.0.1_linux_amd64.tgz"

  # Data plane
  "service.xds_0.0.1_linux_amd64.tgz"
  "service.envoy_1.35.3_linux_amd64.tgz"

  # Infrastructure
  "service.minio_0.0.1_linux_amd64.tgz"
  "service.etcd_3.5.14_linux_amd64.tgz"
)

log_step "Uninstalling Services"

for f in "${REMOVE_ORDER[@]}"; do
  pkg_path="$PKG_DIR/$f"
  if [[ ! -f "$pkg_path" ]]; then
    log_substep "Package not found (skipped): $(basename "$f" .tgz | sed 's/_0\.0\.1_linux_amd64$//' | sed 's/_[0-9.]*_linux_amd64$//' | sed 's/^service\.//')"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  run_uninstall "$pkg_path"
done

echo ""
log_step "Cleanup"

# Remove state directories if they exist
if [[ -d /var/lib/globular ]]; then
  log_info "Removing /var/lib/globular..."
  rm -rf /var/lib/globular || log_warn "Could not remove /var/lib/globular"
  log_success "State directory removed"
else
  log_substep "State directory already removed"
fi

if [[ -d /etc/globular ]]; then
  log_info "Removing /etc/globular..."
  rm -rf /etc/globular || log_warn "Could not remove /etc/globular"
  log_success "Config directory removed"
else
  log_substep "Config directory already removed"
fi

# Remove globular user/group if they exist
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

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"

if [[ "$FAILED" -ne 0 ]]; then
  echo "║     ⚠ UNINSTALL COMPLETED WITH WARNINGS                       ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Summary:"
  echo "  Uninstalled: $UNINSTALLED packages"
  echo "  Skipped:     $SKIPPED packages"
  echo "  Warnings:    Some services could not be removed"
  echo ""
  echo "Check warnings above for details."
  exit 1
else
  echo "║     ✓ UNINSTALL COMPLETE                                       ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Summary:"
  echo "  Uninstalled: $UNINSTALLED packages"
  echo "  Skipped:     $SKIPPED packages"
  echo ""
  echo "  🎉 System cleaned successfully!"
fi

echo ""
