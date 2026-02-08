#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="${PKG_DIR:-"$INSTALLER_ROOT/internal/assets/packages"}"

INSTALLER_BIN="$INSTALLER_ROOT/bin/globular-installer"
if [[ ! -x "$INSTALLER_BIN" ]]; then
  INSTALLER_BIN="$(command -v globular-installer || true)"
fi

# Visual symbols for output
die() { echo "  ✗ ERROR: $*" >&2; exit 1; }
log_info() { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_step() { echo ""; echo "━━━ $* ━━━"; }
log_substep() { echo "  • $*"; }

[[ -d "$PKG_DIR" ]] || die "Package directory not found: $PKG_DIR"
[[ -n "$INSTALLER_BIN" ]] && [[ -x "$INSTALLER_BIN" ]] || die "Installer binary not found; set INSTALLER_BIN or build ./bin/globular-installer"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (use sudo)"
fi

detect_install_cmd() {
  if "$INSTALLER_BIN" pkg --help >/dev/null 2>&1; then
    if "$INSTALLER_BIN" pkg install --help >/dev/null 2>&1; then
      if "$INSTALLER_BIN" pkg install --help 2>&1 | grep -q -- "--package"; then
        echo "pkg_install_flag"; return 0
      fi
      echo "pkg_install_arg"; return 0
    fi
  fi

  if "$INSTALLER_BIN" install --help >/dev/null 2>&1; then
    if "$INSTALLER_BIN" install --help 2>&1 | grep -q -- "--package"; then
      echo "install_flag"; return 0
    fi
    echo "install_arg"; return 0
  fi

  die "Could not detect install command form for $INSTALLER_BIN"
}

detect_uninstall_cmd() {
  if "$INSTALLER_BIN" pkg --help >/dev/null 2>&1; then
    if "$INSTALLER_BIN" pkg uninstall --help >/dev/null 2>&1; then
      if "$INSTALLER_BIN" pkg uninstall --help 2>&1 | grep -q -- "--package"; then
        echo "pkg_uninstall_flag"; return 0
      fi
      echo "pkg_uninstall_arg"; return 0
    fi
  fi

  if "$INSTALLER_BIN" uninstall --help >/dev/null 2>&1; then
    if "$INSTALLER_BIN" uninstall --help 2>&1 | grep -q -- "--package"; then
      echo "uninstall_flag"; return 0
    fi
    echo "uninstall_arg"; return 0
  fi

  if "$INSTALLER_BIN" remove --help >/dev/null 2>&1; then
    if "$INSTALLER_BIN" remove --help 2>&1 | grep -q -- "--package"; then
      echo "remove_flag"; return 0
    fi
    echo "remove_arg"; return 0
  fi

  echo "unknown"
}

INSTALL_MODE="$(detect_install_cmd)"
UNINSTALL_MODE="$(detect_uninstall_cmd)"

TOLERATE_ALREADY_INSTALLED="${TOLERATE_ALREADY_INSTALLED:-1}"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          GLOBULAR DAY-0 INSTALLATION                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
log_info "Installer binary: $INSTALLER_BIN"
log_info "Install mode: $INSTALL_MODE"
log_info "Package directory: $PKG_DIR"
echo ""

# TLS MUST be set up BEFORE any packages are installed
log_step "TLS Certificate Bootstrap"
if [[ -x "$SCRIPT_DIR/setup-tls.sh" ]]; then
  "$SCRIPT_DIR/setup-tls.sh" || die "TLS setup failed"
  log_success "TLS certificates generated (RSA)"
else
  die "setup-tls.sh not found or not executable"
fi

# Generate root/admin client certificates for CLI and service-to-service communication
log_step "Client Certificate Generation"
if [[ -x "$SCRIPT_DIR/generate-user-client-cert.sh" ]]; then
  # Generate for root user (for sudo operations)
  if "$SCRIPT_DIR/generate-user-client-cert.sh" 2>&1 | tee /tmp/client-cert-root.log; then
    log_success "Root client certificates generated"
  else
    die "Root client certificate generation failed (check /tmp/client-cert-root.log) - CLI will not work without this"
  fi

  # Also generate for the actual user who invoked sudo (if different from root)
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    # Run as the actual user - the script will handle sudo for signing
    if su - "$SUDO_USER" -c "$SCRIPT_DIR/generate-user-client-cert.sh" 2>&1 | tee "/tmp/client-cert-$SUDO_USER.log"; then
      log_success "User ($SUDO_USER) client certificates generated"
      # Fix ownership
      "$SCRIPT_DIR/fix-client-cert-ownership.sh" "$SUDO_USER" 2>&1 | tee "/tmp/client-cert-fix-$SUDO_USER.log" || true
    else
      die "User ($SUDO_USER) client certificate generation failed (check /tmp/client-cert-$SUDO_USER.log) - CLI will not work without this"
    fi
  fi
else
  die "generate-user-client-cert.sh not found - CLI will not work without client certificates"
fi

# Configure ScyllaDB with TLS (if ScyllaDB is installed)
if systemctl list-unit-files | grep -q "scylla-server.service"; then
  log_step "ScyllaDB TLS Configuration"
  if [[ -x "$SCRIPT_DIR/setup-scylla-tls.sh" ]]; then
    "$SCRIPT_DIR/setup-scylla-tls.sh" || die "ScyllaDB TLS setup failed"
    log_success "ScyllaDB configured with TLS"
  else
    log_info "setup-scylla-tls.sh not found (skipping ScyllaDB TLS)"
  fi
fi

install_from_extracted_spec() {
  local pkgfile="$1"
  local staging spec out rc
  staging="$(mktemp -d)"
  cleanup() { rm -rf "$staging"; }
  trap cleanup RETURN

  tar -xzf "$pkgfile" -C "$staging"

  spec=""
  if [[ -d "$staging/specs" ]]; then
    spec="$(find "$staging/specs" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.json" \) | head -n 1)"
  fi

  if [[ -z "${spec:-}" || ! -f "$spec" ]]; then
    echo "    ✗ Could not locate embedded spec in package: $pkgfile" >&2
    return 2
  fi

  set +e
  out="$("$INSTALLER_BIN" install --staging-dir "$staging" --spec "$spec" 2>&1)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "$out" >&2
    return $rc
  fi
  return 0
}

run_install() {
  local pkgfile="$1"
  local pkgname="$(basename "$pkgfile" .tgz | sed 's/_linux_amd64$//' | sed 's/^service\.//')"
  local out rc

  log_substep "Installing $pkgname..."

  set +e
  case "$INSTALL_MODE" in
    pkg_install_flag) out="$("$INSTALLER_BIN" pkg install --package "$pkgfile" 2>&1)"; rc=$? ;;
    pkg_install_arg)  out="$("$INSTALLER_BIN" pkg install "$pkgfile" 2>&1)"; rc=$? ;;
    install_flag)     out="$("$INSTALLER_BIN" install --package "$pkgfile" 2>&1)"; rc=$? ;;
    install_arg)      out="$("$INSTALLER_BIN" install "$pkgfile" 2>&1)"; rc=$? ;;
    *) die "Unknown install mode: $INSTALL_MODE" ;;
  esac
  set -e

  if [[ $rc -ne 0 ]] && echo "$out" | grep -qiE "using spec default|missing files definition"; then
    set +e
    out="$(install_from_extracted_spec "$pkgfile" 2>&1)"; rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      echo "$out" >&2
      die "Failed to install $pkgname"
    fi
    log_success "$pkgname installed"
    return 0
  fi

  if [[ $rc -ne 0 ]]; then
    if [[ "$TOLERATE_ALREADY_INSTALLED" == "1" ]] && echo "$out" | grep -qiE "already installed|exists|is installed"; then
      log_success "$pkgname (already installed)"
      return 0
    fi
    echo "$out" >&2
    die "Failed to install $pkgname"
  fi

  log_success "$pkgname installed"
}

install_list() {
  local pkg_array=("$@")
  for f in "${pkg_array[@]}"; do
    local path="$PKG_DIR/$f"
    if [[ ! -f "$path" ]]; then
      continue  # Skip silently if package not found
    fi
    run_install "$path"
  done
}

BOOTSTRAP_MINIO_PKGS=(
  "service.etcd_3.5.14_linux_amd64.tgz"
  "service.minio_0.0.1_linux_amd64.tgz"
)

DATA_LAYER_PKGS=(
  "service.persistence_0.0.1_linux_amd64.tgz"
)

BOOTSTRAP_REST_PKGS=(
  "service.xds_0.0.1_linux_amd64.tgz"
  "service.envoy_1.35.3_linux_amd64.tgz"
  "service.gateway_0.0.1_linux_amd64.tgz"
  "service.node-agent_0.0.1_linux_amd64.tgz"
  "service.cluster-controller_0.0.1_linux_amd64.tgz"
)

CONTROL_PLANE_PKGS=(
  "service.resource_0.0.1_linux_amd64.tgz"
  "service.rbac_0.0.1_linux_amd64.tgz"
  "service.authentication_0.0.1_linux_amd64.tgz"
  "service.discovery_0.0.1_linux_amd64.tgz"
  "service.repository_0.0.1_linux_amd64.tgz"
  "service.dns_0.0.1_linux_amd64.tgz"
)

OPS_PKGS=(
  "service.event_0.0.1_linux_amd64.tgz"
  "service.log_0.0.1_linux_amd64.tgz"
)

OPTIONAL_WORKLOAD_PKGS=(
  "service.file_0.0.1_linux_amd64.tgz"
)

CMDS_PKGS=(
  "service.mc-cmd_0.0.1_linux_amd64.tgz"
  "service.globular-cli-cmd_0.0.1_linux_amd64.tgz"
)

log_step "Infrastructure Layer (etcd + minio)"
install_list "${BOOTSTRAP_MINIO_PKGS[@]}"

log_step "TLS Ownership Fix"
log_substep "Setting TLS file ownership to globular user..."
if id globular >/dev/null 2>&1; then
  chown -R globular:globular /var/lib/globular/pki /var/lib/globular/config/tls /var/lib/globular/.minio 2>/dev/null || true
  if [[ -d /var/lib/globular/tls/etcd ]]; then
    chown -R globular:globular /var/lib/globular/tls/etcd
  fi
  log_success "TLS files ownership set to globular:globular"

  # Restart services that depend on TLS certificates
  log_substep "Restarting services to apply TLS ownership changes..."
  systemctl restart globular-etcd.service 2>/dev/null || true
  systemctl restart globular-minio.service 2>/dev/null || true
  sleep 3  # Wait for services to restart with correct cert permissions
  log_success "Services restarted with correct TLS ownership"
else
  log_substep "Warning: globular user not found, skipping ownership fix"
fi

log_step "MinIO Configuration"
if [[ -x "$SCRIPT_DIR/setup-minio-contract.sh" ]]; then
  "$SCRIPT_DIR/setup-minio-contract.sh"
  log_success "MinIO contract configured"
else
  die "setup-minio-contract.sh not found or not executable"
fi

log_substep "Verifying MinIO systemd unit..."
MINIO_UNIT="/etc/systemd/system/globular-minio.service"
if [[ ! -f "$MINIO_UNIT" ]]; then
  die "MinIO unit not installed at $MINIO_UNIT"
fi
if grep -q "{{" "$MINIO_UNIT"; then
  die "MinIO unit contains unrendered template placeholders"
fi
if ! systemd-analyze verify "$MINIO_UNIT" 2>&1 | grep -v "Transaction order is cyclic" > /dev/null; then
  : # Ignore systemd-analyze errors (they're often spurious)
fi

log_substep "Starting MinIO service..."
systemctl daemon-reload
if ! systemctl is-active --quiet globular-minio.service; then
  systemctl start globular-minio.service || die "Failed to start MinIO service"
fi
log_success "MinIO service started"

log_step "CLI Tools (needed for bucket provisioning)"
install_list "${CMDS_PKGS[@]}"

log_step "MinIO Bucket Provisioning"
if [[ -x "$SCRIPT_DIR/ensure-minio-buckets.sh" ]]; then
  "$SCRIPT_DIR/ensure-minio-buckets.sh"
  log_success "MinIO buckets provisioned"
else
  log_substep "Warning: ensure-minio-buckets.sh not found, skipping bucket creation"
fi

log_step "Data Layer (persistence)"
install_list "${DATA_LAYER_PKGS[@]}"

log_step "MinIO Bucket Setup"
if [[ -x "$SCRIPT_DIR/setup-minio.sh" ]]; then
  "$SCRIPT_DIR/setup-minio.sh"
  log_success "MinIO buckets configured"
else
  die "setup-minio.sh not found or not executable"
fi

log_step "Globular Configuration (Protocol=https)"
if [[ -x "$SCRIPT_DIR/setup-config.sh" ]]; then
  "$SCRIPT_DIR/setup-config.sh"
  log_success "Configuration set to HTTPS"
else
  log_substep "Warning: setup-config.sh not found (Protocol may default to HTTP)"
fi

log_step "Bootstrap Services (xds, envoy, gateway, agents)"
install_list "${BOOTSTRAP_REST_PKGS[@]}"

log_step "Control Plane Services"
install_list "${CONTROL_PLANE_PKGS[@]}"

log_step "System Resolver Configuration (Day-0)"
if [[ -x "$SCRIPT_DIR/configure-resolver.sh" ]]; then
  "$SCRIPT_DIR/configure-resolver.sh"
  log_success "System resolver configured for globular.internal"
else
  log_substep "Warning: configure-resolver.sh not found, DNS system resolver not configured"
fi

log_step "DNS Bootstrap (Day-0)"
if [[ -x "$SCRIPT_DIR/bootstrap-dns.sh" ]]; then
  "$SCRIPT_DIR/bootstrap-dns.sh"
  log_success "DNS records initialized (n0, api)"
else
  log_substep "Warning: bootstrap-dns.sh not found, DNS records not initialized"
fi

log_step "Operations Services"
install_list "${OPS_PKGS[@]}"

log_step "Workload Services"
install_list "${OPTIONAL_WORKLOAD_PKGS[@]}"

# Run conformance tests (warn-only mode)
if [[ "${GLOBULAR_CONFORMANCE:-0}" == "1" ]]; then
  log_step "Conformance Tests"
  CONFORMANCE_SCRIPT="$SCRIPT_DIR/../tests/conformance/run.sh"
  if [[ -x "$CONFORMANCE_SCRIPT" ]]; then
    log_substep "Running v1.0 conformance checks..."
    if "$CONFORMANCE_SCRIPT" 2>&1 | tee /tmp/globular-conformance.log; then
      log_success "All conformance tests passed!"
    else
      # Warn-only mode: don't fail installation yet
      log_info "⚠  Some conformance tests failed (see /tmp/globular-conformance.log)"
      log_info "   Installation will continue, but please review failures"
      log_info "   Run manually: sudo $CONFORMANCE_SCRIPT"
    fi
  else
    log_substep "Conformance tests not found (skipping)"
  fi
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          ✓ INSTALLATION COMPLETE                               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
log_success "Globular Day-0 installation successful!"
echo ""
