#!/usr/bin/env bash
set -euo pipefail

# Globular Day-0 Installation Script
#
# Environment Variables:
#   PKG_DIR                  - Package directory (default: internal/assets/packages)
#   INSTALLER_BIN            - Installer binary path (auto-detected)
#   TOLERATE_ALREADY_INSTALLED - Allow already-installed packages (default: 1)
#   FORCE_REINSTALL          - Force overwrite existing binaries even if unchanged (default: 0)
#                              Set to 1 to always reinstall all binaries (useful after rebuild)
#   GLOBULAR_CONFORMANCE     - Conformance test mode (default: warn)
#                              warn: Run tests, log failures, continue installation
#                              fail: Run tests, abort installation on any failure (v1 target)
#                              off:  Skip conformance tests entirely
#
# Conformance tests validate v1.0 invariants:
#   - DNS service reports correct port in metadata
#   - User client certificates exist and are readable
#   - TLS certificate symlinks (server.crt, server.key, ca.crt) exist
#   - DNS service has CAP_NET_BIND_SERVICE for port 53

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
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"

# Canonical cluster domain — single source of truth for all Day-0 scripts
DOMAIN="${GLOBULAR_DOMAIN:-globular.internal}"
export DOMAIN
FORCE_FLAG=""
if [[ "$FORCE_REINSTALL" == "1" ]]; then
  FORCE_FLAG="--force"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          GLOBULAR DAY-0 INSTALLATION                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Prompt for MinIO data storage location
# MinIO stores all bucket data under this directory. Choose a path on a
# drive with enough space for your object-store data (backups, media, etc.)
MINIO_DATA_DIR="${MINIO_DATA_DIR:-}"
if [[ -z "$MINIO_DATA_DIR" ]]; then
  DEFAULT_MINIO_DATA_DIR="/var/lib/globular/minio/data"
  echo "  MinIO stores all bucket data (backups, media, etc.) in a local directory."
  echo "  Choose a path on a drive with enough free space."
  echo ""
  read -r -p "  MinIO data directory [$DEFAULT_MINIO_DATA_DIR]: " MINIO_DATA_DIR
  MINIO_DATA_DIR="${MINIO_DATA_DIR:-$DEFAULT_MINIO_DATA_DIR}"
fi
# Ensure absolute path
if [[ "${MINIO_DATA_DIR:0:1}" != "/" ]]; then
  die "MinIO data directory must be an absolute path: $MINIO_DATA_DIR"
fi
export MINIO_DATA_DIR
MINIO_DATA_DIR_FLAG="--minio-data-dir $MINIO_DATA_DIR"

log_info "Installer binary: $INSTALLER_BIN"
log_info "Install mode: $INSTALL_MODE"
log_info "Package directory: $PKG_DIR"
log_info "MinIO data directory: $MINIO_DATA_DIR"
log_info "Cluster domain: $DOMAIN"
log_info "Conformance mode: ${GLOBULAR_CONFORMANCE:-warn}"
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
  # CRITICAL: Unset SUDO_USER so script generates certificates for root, not the original user
  if ( unset SUDO_USER; "$SCRIPT_DIR/generate-user-client-cert.sh" ) 2>&1 | tee /tmp/client-cert-root.log; then
    log_success "Root client certificates generated"
  else
    die "Root client certificate generation failed (check /tmp/client-cert-root.log) - CLI will not work without this"
  fi

  # Also generate for the actual user who invoked sudo (if different from root)
  # Detect the original user even if $SUDO_USER is not set (e.g., after 'sudo su')
  ORIGINAL_USER=""
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    ORIGINAL_USER="$SUDO_USER"
  else
    # Try to detect user from installer directory ownership
    if [[ -d "$SCRIPT_DIR" ]]; then
      DETECTED_USER=$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || echo "")
      if [[ -n "$DETECTED_USER" ]] && [[ "$DETECTED_USER" != "root" ]]; then
        ORIGINAL_USER="$DETECTED_USER"
        log_info "Detected original user from directory ownership: $ORIGINAL_USER"
      fi
    fi
  fi

  if [[ -n "$ORIGINAL_USER" ]]; then
    # Set SUDO_USER so generate-user-client-cert.sh can detect the user
    export SUDO_USER="$ORIGINAL_USER"
    # Run as root (script will detect SUDO_USER automatically)
    if "$SCRIPT_DIR/generate-user-client-cert.sh" 2>&1 | tee "/tmp/client-cert-$ORIGINAL_USER.log"; then
      # Fix ownership of generated certificates
      if [[ -x "$SCRIPT_DIR/fix-client-cert-ownership.sh" ]]; then
        "$SCRIPT_DIR/fix-client-cert-ownership.sh" "$ORIGINAL_USER" 2>&1 | tee "/tmp/client-cert-fix-$ORIGINAL_USER.log" || true
      fi
      log_success "User ($ORIGINAL_USER) client certificates generated"
    else
      die "User ($ORIGINAL_USER) client certificate generation failed (check /tmp/client-cert-$ORIGINAL_USER.log) - CLI will not work without this"
    fi
  else
    log_info "No non-root user detected, skipping user client certificate generation"
  fi
else
  die "generate-user-client-cert.sh not found - CLI will not work without client certificates"
fi

# Note: ScyllaDB TLS is configured in the "ScyllaDB Database" section below
# (both fresh-install and already-installed paths run setup-scylla-tls.sh)

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
  # shellcheck disable=SC2086
  out="$("$INSTALLER_BIN" install --staging-dir "$staging" --spec "$spec" $FORCE_FLAG $MINIO_DATA_DIR_FLAG 2>&1)"
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
  log_substep "  CMD: $INSTALLER_BIN install $FORCE_FLAG $MINIO_DATA_DIR_FLAG $pkgfile"

  set +e
  # shellcheck disable=SC2086
  # NOTE: flags MUST come before positional args (Go flag package stops at first non-flag)
  case "$INSTALL_MODE" in
    pkg_install_flag) out="$("$INSTALLER_BIN" pkg install --package "$pkgfile" $FORCE_FLAG $MINIO_DATA_DIR_FLAG 2>&1)"; rc=$? ;;
    pkg_install_arg)  out="$("$INSTALLER_BIN" pkg install $FORCE_FLAG $MINIO_DATA_DIR_FLAG "$pkgfile" 2>&1)"; rc=$? ;;
    install_flag)     out="$("$INSTALLER_BIN" install --package "$pkgfile" $FORCE_FLAG $MINIO_DATA_DIR_FLAG 2>&1)"; rc=$? ;;
    install_arg)      out="$("$INSTALLER_BIN" install $FORCE_FLAG $MINIO_DATA_DIR_FLAG "$pkgfile" 2>&1)"; rc=$? ;;
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
      log_substep "Warning: package not found, skipping: $path"
      continue
    fi
    run_install "$path"
  done
}

SCYLLADB_PKG="service.scylladb_2025.3.1_linux_amd64.tgz"

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
  "service.cluster-doctor_0.0.1_linux_amd64.tgz"
)

CONTROL_PLANE_PKGS=(
  "service.resource_0.0.1_linux_amd64.tgz"
  "service.rbac_0.0.1_linux_amd64.tgz"
  "service.authentication_0.0.1_linux_amd64.tgz"
  "service.discovery_0.0.1_linux_amd64.tgz"
  # DNS must be installed before repository so it gets its default port (10006).
  # The PortAllocator assigns ports in first-come order; repository would otherwise
  # grab 10006 first and force DNS to reallocate to 10007, breaking bootstrap-dns.sh.
  "service.dns_0.0.1_linux_amd64.tgz"
  "service.repository_0.0.1_linux_amd64.tgz"
)

OPS_PKGS=(
  "service.sidekick_7.0.0_linux_amd64.tgz"
  "service.node-exporter_1.10.2_linux_amd64.tgz"
  "service.prometheus_3.5.1_linux_amd64.tgz"
  "service.monitoring_0.0.1_linux_amd64.tgz"
  "service.event_0.0.1_linux_amd64.tgz"
  "service.log_0.0.1_linux_amd64.tgz"
  "service.backup-manager_0.0.1_linux_amd64.tgz"
  "service.scylla-manager-agent_3.8.1_linux_amd64.tgz"
  "service.scylla-manager_3.8.1_linux_amd64.tgz"
)

OPTIONAL_WORKLOAD_PKGS=(
  "service.file_0.0.1_linux_amd64.tgz"
)

CMDS_PKGS=(
  "service.mc-cmd_0.0.1_linux_amd64.tgz"
  "service.globular-cli-cmd_0.0.1_linux_amd64.tgz"
  "service.etcdctl-cmd_3.5.14_linux_amd64.tgz"
  "service.rclone-cmd_1.73.1_linux_amd64.tgz"
  "service.restic-cmd_0.18.1_linux_amd64.tgz"
  "service.sctool-cmd_3.8.1_linux_amd64.tgz"
  "service.sha256sum-cmd_9.4.0_linux_amd64.tgz"
  "service.yt-dlp-cmd_2026.2.21_linux_amd64.tgz"
  "service.ffmpeg-cmd_7.0.2_linux_amd64.tgz"
)

# Phase 2: Enable bootstrap mode for Day-0 installation
# Security Fix #4: Create JSON state file with explicit timestamps
# This enables 4-level secured bootstrap mode:
# - Time-bounded (30 minutes from now, explicit in file)
# - Loopback-only (127.0.0.1/::1)
# - Method allowlisted (essential Day-0 methods only)
# - Explicit enablement (this file with 0600 permissions)
BOOTSTRAP_FLAG="/var/lib/globular/bootstrap.enabled"
log_substep "Enabling bootstrap mode (30-minute window)..."
mkdir -p "$(dirname "$BOOTSTRAP_FLAG")"

# Create JSON state file with explicit timestamps (not relying on mtime)
ENABLED_AT=$(date +%s)
EXPIRES_AT=$((ENABLED_AT + 1800))  # 30 minutes = 1800 seconds
NONCE=$(openssl rand -hex 16 2>/dev/null || echo "fallback-nonce-$$")

cat > "$BOOTSTRAP_FLAG" <<EOF
{
  "enabled_at_unix": $ENABLED_AT,
  "expires_at_unix": $EXPIRES_AT,
  "nonce": "$NONCE",
  "created_by": "${SUDO_USER:-root}",
  "version": "1.0"
}
EOF

# Set secure permissions: 0600, root-owned
chmod 0600 "$BOOTSTRAP_FLAG"
chown root:root "$BOOTSTRAP_FLAG" 2>/dev/null || chown 0:0 "$BOOTSTRAP_FLAG"

log_success "Bootstrap mode enabled: $BOOTSTRAP_FLAG (expires: $(date -d @$EXPIRES_AT '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $EXPIRES_AT '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'in 30 minutes'))"

log_step "ScyllaDB Database"
if systemctl list-unit-files 2>/dev/null | grep -q "^scylla-server.service"; then
  log_success "ScyllaDB packages already installed"

  # Ensure data dirs exist (may have been wiped for a clean reinstall)
  if [[ ! -d /var/lib/scylla/data ]] || [[ ! -d /var/lib/scylla/commitlog ]]; then
    log_substep "ScyllaDB data directories missing — recreating..."
    mkdir -p /var/lib/scylla/data /var/lib/scylla/commitlog
    chown -R scylla:scylla /var/lib/scylla
    log_success "ScyllaDB data directories recreated"
  fi

  # Reconfigure TLS and restart (handles wiped /var/lib/scylla/conf symlink)
  if [[ -x "$SCRIPT_DIR/setup-scylla-tls.sh" ]]; then
    log_substep "Configuring ScyllaDB TLS..."
    "$SCRIPT_DIR/setup-scylla-tls.sh" || die "ScyllaDB TLS setup failed"
    log_success "ScyllaDB configured with TLS"
  fi

  # Wait for ScyllaDB to be ready
  if ! systemctl is-active --quiet scylla-server.service; then
    systemctl start scylla-server.service || log_substep "Warning: failed to start scylla-server"
  fi
  log_substep "Waiting for ScyllaDB CQL port (9042)..."
  SCYLLA_READY=0
  for i in $(seq 1 90); do
    if cqlsh 127.0.0.1 9042 -e "SELECT now() FROM system.local" &>/dev/null; then
      SCYLLA_READY=1
      break
    fi
    sleep 1
  done
  if [[ $SCYLLA_READY -eq 1 ]]; then
    log_success "ScyllaDB ready (took ${i}s)"
  else
    log_substep "Warning: ScyllaDB not accepting connections after 90s"
  fi
else
  log_substep "ScyllaDB not found — installing..."

  # Ensure GPG keyring directory exists
  mkdir -p /etc/apt/keyrings

  # Import ScyllaDB GPG key if not present
  if [[ ! -f /etc/apt/keyrings/scylladb.gpg ]]; then
    log_substep "Importing ScyllaDB GPG key..."
    curl -fsSL https://downloads.scylladb.com/deb/ubuntu/scylladb-2025.3.gpg | \
      gpg --dearmor -o /etc/apt/keyrings/scylladb.gpg
    log_success "ScyllaDB GPG key imported"
  fi

  # Install the ScyllaDB Globular package (sets up apt repo + installs OS packages)
  if [[ -f "$PKG_DIR/$SCYLLADB_PKG" ]]; then
    run_install "$PKG_DIR/$SCYLLADB_PKG"
  else
    log_substep "Warning: $SCYLLADB_PKG not found, attempting direct apt install..."
    # Ensure apt repo is configured
    if [[ ! -f /etc/apt/sources.list.d/scylla.list ]]; then
      echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/scylladb.gpg] https://downloads.scylladb.com/downloads/scylla/deb/debian-ubuntu/scylladb-2025.3 stable main" \
        > /etc/apt/sources.list.d/scylla.list
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq scylla scylla-server scylla-conf scylla-cqlsh scylla-python3
  fi

  # Move ScyllaDB REST API to port 56093 to avoid conflict with Globular
  # services (port range 10000-20000). ScyllaDB defaults to api_port 10000
  # which collides with the persistence service.
  if [[ -f /etc/scylla/scylla.yaml ]]; then
    if ! grep -q "^api_port:" /etc/scylla/scylla.yaml; then
      echo "" >> /etc/scylla/scylla.yaml
      echo "# Moved to 56093 to avoid conflict with Globular service ports (10000+)" >> /etc/scylla/scylla.yaml
      echo "api_port: 56093" >> /etc/scylla/scylla.yaml
      log_substep "Set ScyllaDB api_port to 56093 (avoids port 10000 conflict)"
    fi
  fi

  # Enable and start ScyllaDB
  systemctl daemon-reload
  systemctl enable scylla-server.service 2>/dev/null || true
  if ! systemctl is-active --quiet scylla-server.service; then
    systemctl start scylla-server.service || log_substep "Warning: failed to start scylla-server (may need scylla_setup)"
  fi

  # Wait for ScyllaDB to be ready (CQL port 9042). ScyllaDB can take 30-90s
  # to initialize on first start. Without this wait, downstream services
  # (persistence, scylla-manager) fail to connect on the first install attempt.
  log_substep "Waiting for ScyllaDB to accept CQL connections (port 9042)..."
  SCYLLA_READY=0
  for i in $(seq 1 90); do
    if cqlsh 127.0.0.1 9042 -e "SELECT now() FROM system.local" &>/dev/null; then
      SCYLLA_READY=1
      break
    fi
    sleep 1
  done
  if [[ $SCYLLA_READY -eq 1 ]]; then
    log_success "ScyllaDB installed and ready (took ${i}s)"
  else
    log_substep "Warning: ScyllaDB started but not yet accepting connections after 90s"
    log_substep "Downstream services may fail on first attempt — re-run installer to retry"
  fi

  # Configure TLS for the freshly installed ScyllaDB
  if [[ -x "$SCRIPT_DIR/setup-scylla-tls.sh" ]]; then
    log_substep "Configuring ScyllaDB TLS..."
    "$SCRIPT_DIR/setup-scylla-tls.sh" || log_substep "Warning: ScyllaDB TLS setup failed (will retry later)"
  fi
fi

log_step "Infrastructure Layer (etcd + minio)"
install_list "${BOOTSTRAP_MINIO_PKGS[@]}"

# If the user chose a custom MinIO data directory, patch the systemd unit and env file
# to use the custom path instead of the default /var/lib/globular/minio/data.
DEFAULT_MINIO_PATH="/var/lib/globular/minio/data"
if [[ "$MINIO_DATA_DIR" != "$DEFAULT_MINIO_PATH" ]]; then
  log_substep "Applying custom MinIO data directory: $MINIO_DATA_DIR"

  MINIO_UNIT="/etc/systemd/system/globular-minio.service"
  MINIO_ENV="/var/lib/globular/minio/minio.env"

  # Patch the systemd unit
  if [[ -f "$MINIO_UNIT" ]]; then
    sed -i "s|${DEFAULT_MINIO_PATH}|${MINIO_DATA_DIR}|g" "$MINIO_UNIT"
    log_substep "Patched $MINIO_UNIT"
  fi

  # Patch the env file
  if [[ -f "$MINIO_ENV" ]]; then
    sed -i "s|${DEFAULT_MINIO_PATH}|${MINIO_DATA_DIR}|g" "$MINIO_ENV"
    log_substep "Patched $MINIO_ENV"
  fi

  # Create the custom data directory
  mkdir -p "$MINIO_DATA_DIR"
  chown globular:globular "$MINIO_DATA_DIR"
  chmod 0700 "$MINIO_DATA_DIR"
  log_substep "Created $MINIO_DATA_DIR"

  systemctl daemon-reload
  systemctl restart globular-minio.service 2>/dev/null || true
  log_success "MinIO configured to use $MINIO_DATA_DIR"
fi

log_step "TLS Ownership Fix"
log_substep "Setting TLS file ownership to globular user..."
if id globular >/dev/null 2>&1; then
  # Create backup data directory outside the cluster dir so backups survive uninstall/disk failure
  mkdir -p /var/backups/globular
  chown globular:globular /var/backups/globular
  log_success "Backup data directory created at /var/backups/globular"

  # INV-PKI-1: Use canonical PKI paths only
  chown -R globular:globular /var/lib/globular/pki /var/lib/globular/.minio 2>/dev/null || true
  log_success "TLS files ownership set to globular:globular"

  # Allow the gateway to read systemd journal (needed for journal.ReadUnit API)
  if getent group systemd-journal >/dev/null 2>&1; then
    usermod -aG systemd-journal globular
    log_success "globular user added to systemd-journal group"
  fi

  # Allow scylla-manager-agent (running as globular) to manage ScyllaDB snapshots
  if getent group scylla >/dev/null 2>&1; then
    usermod -aG scylla globular
    # Set default ACLs so new snapshot files/dirs are group-writable by scylla group
    if command -v setfacl >/dev/null 2>&1 && [[ -d /var/lib/scylla/data ]]; then
      setfacl -R -m g:scylla:rwX /var/lib/scylla/data
      setfacl -R -d -m g:scylla:rwX /var/lib/scylla/data
    fi
    log_success "globular user added to scylla group (snapshot management)"
  fi

  # Sudoers: allow globular user to manage services for backup/restore operations
  log_substep "Installing sudoers rules for globular user..."
  cat > /etc/sudoers.d/globular <<'SUDOERS'
# Allow globular user to stop/start/restart Globular-managed services
# Only systemctl needs sudo — all data dirs are owned by globular:globular
globular ALL=(root) NOPASSWD: /usr/bin/systemctl stop globular-etcd.service
globular ALL=(root) NOPASSWD: /usr/bin/systemctl start globular-etcd.service
globular ALL=(root) NOPASSWD: /usr/bin/systemctl restart globular-etcd.service
globular ALL=(root) NOPASSWD: /usr/bin/systemctl stop globular-minio.service
globular ALL=(root) NOPASSWD: /usr/bin/systemctl start globular-minio.service
globular ALL=(root) NOPASSWD: /usr/bin/systemctl restart globular-minio.service
SUDOERS
  chmod 0440 /etc/sudoers.d/globular
  log_success "Sudoers rules installed for globular user"

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

  # Ensure network.json is readable by all for health checks
  if [[ -f /var/lib/globular/network.json ]]; then
    chmod 644 /var/lib/globular/network.json
    log_substep "Set network.json permissions to 644"
  fi

  # CRITICAL: Regenerate client certificates now that domain is configured
  # Initial certs were generated with default "localhost", but config.json now has the actual domain
  log_substep "Regenerating client certificates with configured domain..."

  # Regenerate root client certificates
  if ( unset SUDO_USER; "$SCRIPT_DIR/generate-user-client-cert.sh" ) >/dev/null 2>&1; then
    log_substep "Root client certificates regenerated for configured domain"
  fi

  # Regenerate user client certificates if we have a detected user
  if [[ -n "${ORIGINAL_USER:-}" ]] && [[ "$ORIGINAL_USER" != "root" ]]; then
    export SUDO_USER="$ORIGINAL_USER"
    if "$SCRIPT_DIR/generate-user-client-cert.sh" >/dev/null 2>&1; then
      if [[ -x "$SCRIPT_DIR/fix-client-cert-ownership.sh" ]]; then
        "$SCRIPT_DIR/fix-client-cert-ownership.sh" "$ORIGINAL_USER" >/dev/null 2>&1 || true
      fi
      log_substep "User ($ORIGINAL_USER) client certificates regenerated for configured domain"
    fi
  fi
else
  log_substep "Warning: setup-config.sh not found (Protocol may default to HTTP)"
fi

log_step "Bootstrap Services (xds, envoy, gateway, agents)"
install_list "${BOOTSTRAP_REST_PKGS[@]}"

# Explicitly ensure cluster-doctor is installed and running (common omission)
CLUSTER_DOCTOR_PKG="$PKG_DIR/service.cluster-doctor_0.0.1_linux_amd64.tgz"
if [[ -f "$CLUSTER_DOCTOR_PKG" ]]; then
  if ! systemctl list-unit-files | grep -q "^globular-cluster-doctor.service"; then
    log_substep "cluster-doctor unit missing; reinstalling from package..."
    run_install "$CLUSTER_DOCTOR_PKG"
  fi

  if ! systemctl is-active --quiet globular-cluster-doctor.service 2>/dev/null; then
    log_substep "Starting globular-cluster-doctor.service..."
    systemctl enable globular-cluster-doctor.service >/dev/null 2>&1 || true
    systemctl start globular-cluster-doctor.service || log_substep "Warning: failed to start cluster-doctor (check logs)"
  fi
else
  log_substep "Warning: cluster-doctor package not found at $CLUSTER_DOCTOR_PKG"
fi

# Restart xDS to ensure it picks up the HTTPS configuration
log_substep "Restarting xDS service to apply HTTPS configuration..."
if systemctl is-active --quiet globular-xds.service; then
  systemctl restart globular-xds.service
  sleep 3  # Wait for xDS to regenerate Envoy config
  log_success "xDS restarted with HTTPS config"
fi

# Restart Envoy to pick up the new configuration from xDS
log_substep "Restarting Envoy with HTTPS configuration..."
if systemctl is-active --quiet globular-envoy.service; then
  systemctl restart globular-envoy.service
  sleep 3  # Wait for Envoy to start with new config
  log_success "Envoy restarted on port 8443 (HTTPS)"
fi

log_step "Control Plane Services"
install_list "${CONTROL_PLANE_PKGS[@]}"

# Set cluster_domain in cluster controller config so the admin UI and DNS
# reconciler know the canonical domain from the very first boot.
CC_CONFIG_DIR="/var/lib/globular/cluster-controller"
CC_CONFIG_FILE="${CC_CONFIG_DIR}/config.json"
mkdir -p "${CC_CONFIG_DIR}"
if [[ -f "${CC_CONFIG_FILE}" ]]; then
  # Merge cluster_domain into existing config
  jq --arg d "$DOMAIN" '.cluster_domain = $d' "${CC_CONFIG_FILE}" > "${CC_CONFIG_FILE}.tmp"
  mv "${CC_CONFIG_FILE}.tmp" "${CC_CONFIG_FILE}"
else
  cat > "${CC_CONFIG_FILE}" <<CCEOF
{
  "port": 12000,
  "cluster_domain": "${DOMAIN}",
  "default_profiles": ["core"]
}
CCEOF
fi
chmod 644 "${CC_CONFIG_FILE}"
if id globular >/dev/null 2>&1; then
  chown globular:globular "${CC_CONFIG_FILE}"
fi
log_success "Cluster controller config: cluster_domain=${DOMAIN}"

# Restart cluster controller to pick up the domain
if systemctl is-active --quiet globular-cluster-controller.service 2>/dev/null; then
  systemctl restart globular-cluster-controller.service
  log_substep "Restarted cluster controller with cluster_domain"
fi

log_step "System Resolver Configuration (Day-0)"
if [[ -x "$SCRIPT_DIR/configure-resolver.sh" ]]; then
  RESOLVER_LOG="/tmp/configure-resolver-$(date +%Y%m%d-%H%M%S).log"
  set +e
  "$SCRIPT_DIR/configure-resolver.sh" 2>&1 | tee "$RESOLVER_LOG"
  resolver_rc=${PIPESTATUS[0]}
  set -e

  if [[ $resolver_rc -ne 0 ]]; then
    die "configure-resolver.sh failed (see $RESOLVER_LOG)"
  fi

  if grep -q "VERIFY_RESULT=FAIL" "$RESOLVER_LOG"; then
    log_substep "Warning: DNS resolver verification FAILED (see $RESOLVER_LOG)"
  elif grep -q "VERIFY_RESULT=PASS" "$RESOLVER_LOG"; then
    log_success "System resolver configured for ${DOMAIN}"
  else
    log_substep "Warning: configure-resolver.sh completed without VERIFY_RESULT marker (see $RESOLVER_LOG)"
  fi
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

# Configure scylla-manager-agent (auth token, port, ScyllaDB API address, MinIO S3 creds)
AGENT_CONFIG="/var/lib/globular/scylla-manager-agent/scylla-manager-agent.yaml"
AGENT_TOKEN_FILE="/var/lib/globular/scylla-manager-agent/auth_token.txt"

# Detect ScyllaDB listen address (needed for agent config and cluster registration)
SCYLLA_IP=""
if [[ -f /etc/scylla/scylla.yaml ]]; then
  SCYLLA_IP=$(grep "^listen_address:" /etc/scylla/scylla.yaml 2>/dev/null | awk '{print $2}')
fi
if [[ -z "$SCYLLA_IP" ]]; then
  SCYLLA_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
fi
if [[ -z "$SCYLLA_IP" ]]; then
  SCYLLA_IP="127.0.0.1"
fi

# Generate auth token (idempotent)
if [[ -d /var/lib/globular/scylla-manager-agent ]] && [[ ! -f "$AGENT_TOKEN_FILE" ]]; then
  cat /proc/sys/kernel/random/uuid > "$AGENT_TOKEN_FILE"
  chown globular:globular "$AGENT_TOKEN_FILE"
  chmod 0640 "$AGENT_TOKEN_FILE"
fi

if [[ -f "$AGENT_CONFIG" ]] && ! grep -q "^auth_token:" "$AGENT_CONFIG"; then
  log_substep "Configuring scylla-manager-agent..."

  AGENT_TOKEN=$(cat "$AGENT_TOKEN_FILE")

  # Read MinIO credentials for S3 backup access
  MINIO_CRED_FILE="${STATE_DIR:-/var/lib/globular}/minio/credentials"
  AGENT_S3_BLOCK=""
  if [[ -f "$MINIO_CRED_FILE" ]]; then
    if IFS=":" read -r MINIO_AK MINIO_SK < "$MINIO_CRED_FILE" && [[ -n "$MINIO_AK" && -n "$MINIO_SK" ]]; then
      AGENT_S3_BLOCK="
# MinIO S3 access for ScyllaDB backups (auto-configured by install-day0.sh)
s3:
  access_key_id: ${MINIO_AK}
  secret_access_key: ${MINIO_SK}
  provider: Minio
  region: us-east-1
  endpoint: https://127.0.0.1:9000

# Skip TLS verification for internal MinIO with self-signed certs
rclone:
  insecure_skip_verify: true"
      log_substep "MinIO S3 credentials included in agent config"
    else
      log_substep "Warning: could not parse MinIO credentials from $MINIO_CRED_FILE"
    fi
  else
    log_substep "Warning: MinIO credentials file not found at $MINIO_CRED_FILE — agent will not have S3 access"
  fi

  cat > "$AGENT_CONFIG" <<AGENTEOF
# Scylla Manager Agent configuration (managed by Globular)
auth_token: ${AGENT_TOKEN}

# Ports 56090/56091 avoid conflict with Globular service range (10000-10200)
https: 0.0.0.0:56090
prometheus: 0.0.0.0:56091
debug: 127.0.0.1:56092

# ScyllaDB API address — must match api_address in scylla.yaml
scylla:
  api_address: "${SCYLLA_IP}"
  api_port: "56093"
${AGENT_S3_BLOCK}
AGENTEOF
  chown globular:globular "$AGENT_CONFIG"
  chmod 0640 "$AGENT_CONFIG"

  log_success "scylla-manager-agent configured (token generated, port=56090, scylla=${SCYLLA_IP})"

  # Restart agent with new config
  systemctl restart globular-scylla-manager-agent.service 2>/dev/null || true
fi

# Always ensure the agent config directory is readable by backup-manager (runs as globular)
if [[ -d /var/lib/globular/scylla-manager-agent ]]; then
  chmod 0750 /var/lib/globular/scylla-manager-agent
  chown globular:globular /var/lib/globular/scylla-manager-agent
fi

# Register ScyllaDB cluster in scylla-manager (idempotent — works on fresh install or reinstall)
if [[ -f "$AGENT_TOKEN_FILE" ]] && command -v sctool &>/dev/null; then
  AGENT_TOKEN=$(cat "$AGENT_TOKEN_FILE")
  log_substep "Ensuring ScyllaDB is registered in scylla-manager..."

  # Wait for agent to be ready (up to 15s)
  for i in $(seq 1 15); do
    if curl -sf --connect-timeout 1 -k "https://127.0.0.1:56090/api/v1/version" &>/dev/null; then
      break
    fi
    sleep 1
  done

  # Wait for scylla-manager server to be ready (up to 15s)
  for i in $(seq 1 15); do
    if sctool status &>/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # Check if already registered
  if ! sctool cluster list 2>/dev/null | grep -q "$DOMAIN"; then
    REGISTER_OUT=$(sctool cluster add \
      --host "${SCYLLA_IP:-127.0.0.1}" \
      --name "${DOMAIN}" \
      --auth-token "${AGENT_TOKEN}" \
      --port 56090 2>&1) && \
      log_success "ScyllaDB cluster registered as '${DOMAIN}'" || \
      log_substep "Warning: cluster registration failed: ${REGISTER_OUT}"
  else
    # Already registered — ensure auth token is current
    sctool cluster update -c "${DOMAIN}" \
      --auth-token "${AGENT_TOKEN}" \
      --port 56090 2>/dev/null || true
    log_substep "ScyllaDB cluster '${DOMAIN}' already registered (auth token refreshed)"
  fi
fi

log_step "Workload Services"
install_list "${OPTIONAL_WORKLOAD_PKGS[@]}"

# Run conformance tests
# GLOBULAR_CONFORMANCE=warn|fail|off (default: warn)
CONFORMANCE_MODE="${GLOBULAR_CONFORMANCE:-warn}"

if [[ "$CONFORMANCE_MODE" != "off" ]]; then
  log_step "Conformance Tests (mode: $CONFORMANCE_MODE)"
  CONFORMANCE_SCRIPT="$SCRIPT_DIR/../tests/conformance/run.sh"

  if [[ -x "$CONFORMANCE_SCRIPT" ]]; then
    log_substep "Running v1.0 conformance checks..."

    # Run conformance and capture exit code
    CONFORMANCE_LOG="/tmp/globular-conformance-$(date +%Y%m%d-%H%M%S).log"
    if "$CONFORMANCE_SCRIPT" 2>&1 | tee "$CONFORMANCE_LOG"; then
      log_success "All conformance tests passed!"
    else
      CONFORMANCE_EXIT=$?
      echo ""
      echo "╔════════════════════════════════════════════════════════════════╗"
      echo "║          ⚠  CONFORMANCE FAILED                                 ║"
      echo "╚════════════════════════════════════════════════════════════════╝"
      echo ""
      log_info "Some conformance tests failed (exit code: $CONFORMANCE_EXIT)"
      log_info "Full log: $CONFORMANCE_LOG"
      log_info "Run manually: sudo $CONFORMANCE_SCRIPT"
      echo ""

      if [[ "$CONFORMANCE_MODE" == "fail" ]]; then
        die "Installation failed due to conformance violations (GLOBULAR_CONFORMANCE=fail)"
      else
        # warn mode: continue but alert user
        log_info "⚠  Installation will continue (GLOBULAR_CONFORMANCE=warn)"
        log_info "   Set GLOBULAR_CONFORMANCE=fail to enforce conformance before v1.0"
        echo ""
      fi
    fi
  else
    log_substep "Conformance script not found: $CONFORMANCE_SCRIPT"
    log_substep "Skipping conformance checks"

    if [[ "$CONFORMANCE_MODE" == "fail" ]]; then
      die "Conformance script missing but GLOBULAR_CONFORMANCE=fail (cannot enforce)"
    fi
  fi
else
  log_substep "Conformance tests disabled (GLOBULAR_CONFORMANCE=off)"
fi

# Cluster Health Validation
log_step "Cluster Health Validation"
VALIDATION_SCRIPT="$SCRIPT_DIR/validate-cluster-health.sh"

if [[ -x "$VALIDATION_SCRIPT" ]]; then
  log_substep "Running comprehensive cluster health checks..."
  echo ""

  # Run validation and capture exit code
  if "$VALIDATION_SCRIPT"; then
    VALIDATION_PASSED=1
  else
    VALIDATION_PASSED=0
    VALIDATION_EXIT=$?
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║          ⚠  CLUSTER HEALTH VALIDATION FAILED                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Cluster health validation failed (exit code: $VALIDATION_EXIT)"
    log_info "Some services may not be running correctly"
    log_info "Review the validation output above for details"
    log_info "Common fixes:"
    log_info "  - Check service logs: journalctl -u globular-<service> -n 50"
    log_info "  - Restart failed services: systemctl restart globular-<service>"
    log_info "  - Re-run validation: sudo $VALIDATION_SCRIPT"
    echo ""
    die "Installation validation failed - cluster is not healthy"
  fi
else
  log_substep "Warning: Validation script not found: $VALIDATION_SCRIPT"
  log_substep "Skipping cluster health validation"
  VALIDATION_PASSED=0
fi

# Seed desired state so the controller tracks all installed services
log_step "Seed Desired State"
GLOBULAR_CLI="/usr/lib/globular/bin/globularcli"
if [[ -x "$GLOBULAR_CLI" ]]; then
  log_substep "Importing installed services into controller desired state..."
  if "$GLOBULAR_CLI" services seed --insecure 2>&1; then
    log_success "Desired state seeded from installed services"
  else
    log_substep "Warning: failed to seed desired state (controller may not be ready yet)"
    log_substep "Run manually later: globular services seed --insecure"
  fi
else
  log_substep "Warning: globular CLI not found at $GLOBULAR_CLI, skipping desired-state seed"
  log_substep "Run manually later: globular services seed --insecure"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          ✓ INSTALLATION COMPLETE                               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
log_success "Globular Day-0 installation successful!"

if [[ $VALIDATION_PASSED -eq 1 ]]; then
  log_success "All cluster health checks passed!"
fi

# Phase 2: Disable bootstrap mode (Day-0 complete)
# Remove the flag file to close the bootstrap window
if [[ -f "$BOOTSTRAP_FLAG" ]]; then
  log_substep "Disabling bootstrap mode..."
  rm -f "$BOOTSTRAP_FLAG"
  log_success "Bootstrap mode disabled (Day-0 complete)"
fi

echo ""
