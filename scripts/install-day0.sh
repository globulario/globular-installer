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

# Respect INSTALLER_BIN if already set by a parent script (e.g. install.sh in the
# release tarball places globular-installer at the tarball root, not in bin/).
# Fall back to the dev/build layout, then PATH.
if [[ -z "${INSTALLER_BIN:-}" ]] || [[ ! -x "${INSTALLER_BIN}" ]]; then
  INSTALLER_BIN="$INSTALLER_ROOT/bin/globular-installer"
  if [[ ! -x "$INSTALLER_BIN" ]]; then
    INSTALLER_BIN="$(command -v globular-installer || true)"
  fi
fi

# Visual symbols for output
die() { echo "  ✗ ERROR: $*" >&2; trace_step "fatal" "die" "$*" 3; exit 1; }
log_info() { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_step() { echo ""; echo "━━━ $* ━━━"; }
log_substep() { echo "  • $*"; }

# ── Workflow trace log ─────────────────────────────────────────────────────
# Writes JSON-lines to DAY0_TRACE_LOG. The workflow service imports this on
# startup to create a proper workflow run visible in the admin UI.
DAY0_TRACE_LOG="/var/lib/globular/day0-install.jsonl"
DAY0_TRACE_SEQ=0
DAY0_TRACE_START=$(date +%s%3N)

trace_step() {
  local status="$1" step_key="$2" title="$3" phase="${4:-5}"
  DAY0_TRACE_SEQ=$((DAY0_TRACE_SEQ + 1))
  local now_ms=$(date +%s%3N)
  local dur=$((now_ms - DAY0_TRACE_START))
  printf '{"seq":%d,"key":"%s","title":"%s","status":"%s","phase":%d,"actor":4,"ts":%d,"dur":%d}\n' \
    "$DAY0_TRACE_SEQ" "$step_key" "$title" "$status" "$phase" "$now_ms" "$dur" \
    >> "$DAY0_TRACE_LOG" 2>/dev/null || true
  DAY0_TRACE_START=$now_ms
}

trace_start() {
  mkdir -p "$(dirname "$DAY0_TRACE_LOG")"
  printf '{"type":"run_start","ts":%d,"hostname":"%s"}\n' \
    "$(date +%s%3N)" "$(hostname)" > "$DAY0_TRACE_LOG" 2>/dev/null || true
}

trace_finish() {
  local status="$1" msg="$2"
  printf '{"type":"run_finish","status":"%s","msg":"%s","ts":%d}\n' \
    "$status" "$msg" "$(date +%s%3N)" >> "$DAY0_TRACE_LOG" 2>/dev/null || true
}

trace_start

[[ -d "$PKG_DIR" ]] || die "Package directory not found: $PKG_DIR"
[[ -n "$INSTALLER_BIN" ]] && [[ -x "$INSTALLER_BIN" ]] || die "Installer binary not found; set INSTALLER_BIN or build ./bin/globular-installer"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (use sudo)"
fi

# Ensure /bin/echo exists — apt post-invoke hooks reference it and fail on
# systems where /bin is not symlinked to /usr/bin (minimal installs, containers).
if [[ ! -x /bin/echo ]] && [[ -x /usr/bin/echo ]]; then
  ln -sf /usr/bin/echo /bin/echo
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
# ── Logo ──────────────────────────────────────────────────────────────────────
# Display logo in terminal if chafa is available; install it silently if missing.
LOGO_FILE="${SCRIPT_DIR}/../assets/logo.png"
if [[ ! -f "$LOGO_FILE" ]]; then
  # Fallback paths
  for p in "$HOME/Pictures/logo.png" "$HOME/pictures/logo.png" /usr/share/globular/logo.png; do
    [[ -f "$p" ]] && LOGO_FILE="$p" && break
  done
fi

if [[ -f "$LOGO_FILE" ]]; then
  if ! command -v chafa >/dev/null 2>&1; then
    apt-get install -y -qq chafa >/dev/null 2>&1 || true
  fi
  if command -v chafa >/dev/null 2>&1; then
    echo ""
    chafa --size=80x25 --symbols=all --colors=full "$LOGO_FILE" 2>/dev/null || true
    echo ""
  fi
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          GLOBULAR DAY-0 INSTALLATION                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Prompt for MinIO data storage location
# MinIO stores all bucket data under this directory. Choose a path on a
# drive with enough space for your object-store data (backups, media, etc.)
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/var/lib/globular/minio/data}"
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
trace_step "running" "phase.tls" "TLS Certificate Bootstrap" 6
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
  local pkgname="$(basename "$pkgfile" .tgz | sed 's/_linux_amd64$//')"
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
      trace_step "failed" "install.$pkgname" "Install $pkgname (spec fallback failed)"
      die "Failed to install $pkgname"
    fi
    log_success "$pkgname installed"
    trace_step "ok" "install.$pkgname" "Install $pkgname (spec fallback)"
    return 0
  fi

  if [[ $rc -ne 0 ]]; then
    if [[ "$TOLERATE_ALREADY_INSTALLED" == "1" ]] && echo "$out" | grep -qiE "already installed|exists|is installed"; then
      log_success "$pkgname (already installed)"
      trace_step "ok" "install.$pkgname" "Install $pkgname (already installed)"
      return 0
    fi
    echo "$out" >&2
    trace_step "failed" "install.$pkgname" "Install $pkgname failed"
    die "Failed to install $pkgname"
  fi

  log_success "$pkgname installed"
  trace_step "ok" "install.$pkgname" "Install $pkgname"
}

install_list() {
  local pkg_array=("$@")
  for f in "${pkg_array[@]}"; do
    local path="$PKG_DIR/$f"
    if [[ ! -f "$path" ]]; then
      # Exact name not found — try resolving by package name prefix (version-agnostic).
      # Packages in the release tarball are named <name>_<release-version>_linux_amd64.tgz
      # but install-day0.sh arrays use canonical names like <name>_0.0.1_linux_amd64.tgz.
      local prefix="${f%%_*}"
      local match
      # || match="" prevents set -euo pipefail from treating ls-no-match (exit 2) as fatal
      match=$(ls "$PKG_DIR/${prefix}_"*"_linux_amd64.tgz" 2>/dev/null | head -1) || match=""
      if [[ -n "$match" ]]; then
        log_substep "Resolved $f → $(basename "$match")"
        path="$match"
      else
        log_substep "Warning: package not found, skipping: $path"
        continue
      fi
    fi
    run_install "$path"
  done
}

SCYLLADB_PKG="scylladb_2025.3.8_linux_amd64.tgz"

BOOTSTRAP_MINIO_PKGS=(
  "etcd_3.5.14_linux_amd64.tgz"
  "minio_0.0.1_linux_amd64.tgz"
)

DATA_LAYER_PKGS=(
  "persistence_0.0.1_linux_amd64.tgz"
)

BOOTSTRAP_REST_PKGS=(
  "xds_0.0.1_linux_amd64.tgz"
  # gateway must come before envoy: envoy's ExecStartPre waits for
  # /run/globular/envoy/envoy-bootstrap.json which gateway writes on startup.
  "gateway_0.0.1_linux_amd64.tgz"
  "envoy_1.35.3_linux_amd64.tgz"
  "node-agent_0.0.1_linux_amd64.tgz"
  "cluster-controller_0.0.1_linux_amd64.tgz"
  "cluster-doctor_0.0.1_linux_amd64.tgz"
)

CONTROL_PLANE_PKGS=(
  "resource_0.0.1_linux_amd64.tgz"
  "rbac_0.0.1_linux_amd64.tgz"
  "authentication_0.0.1_linux_amd64.tgz"
  "discovery_0.0.1_linux_amd64.tgz"
  # DNS must be installed before repository so it gets its default port (10006).
  # The PortAllocator assigns ports in first-come order; repository would otherwise
  # grab 10006 first and force DNS to reallocate to 10007, breaking bootstrap-dns.sh.
  "dns_0.0.1_linux_amd64.tgz"
  "repository_0.0.1_linux_amd64.tgz"
)

OPS_PKGS=(
  "sidekick_7.0.0_linux_amd64.tgz"
  "node-exporter_1.10.2_linux_amd64.tgz"
  "prometheus_3.5.1_linux_amd64.tgz"
  "alertmanager_0.28.1_linux_amd64.tgz"
  "monitoring_0.0.1_linux_amd64.tgz"
  "event_0.0.1_linux_amd64.tgz"
  "log_0.0.1_linux_amd64.tgz"
  "backup-manager_0.0.1_linux_amd64.tgz"
  "mcp_0.0.2_linux_amd64.tgz"
  "ai-memory_0.0.1_linux_amd64.tgz"
  "ai-watcher_0.0.1_linux_amd64.tgz"
  "ai-executor_0.0.1_linux_amd64.tgz"
  "ai-router_0.0.1_linux_amd64.tgz"
  "workflow_0.0.1_linux_amd64.tgz"
  "scylla-manager-agent_3.8.1_linux_amd64.tgz"
  "scylla-manager_3.8.1_linux_amd64.tgz"
)

OPTIONAL_WORKLOAD_PKGS=(
  "file_0.0.1_linux_amd64.tgz"
  "search_0.0.1_linux_amd64.tgz"
  "media_0.0.1_linux_amd64.tgz"
  "title_0.0.1_linux_amd64.tgz"
  "torrent_0.0.1_linux_amd64.tgz"
)

CMDS_PKGS=(
  "mc_0.0.1_linux_amd64.tgz"
  "globular-cli_0.0.1_linux_amd64.tgz"
  "etcdctl_3.5.14_linux_amd64.tgz"
  "rclone_1.73.1_linux_amd64.tgz"
  "restic_0.18.1_linux_amd64.tgz"
  "sctool_3.8.1_linux_amd64.tgz"
  "sha256sum_9.4.0_linux_amd64.tgz"
  "yt-dlp_2026.2.21_linux_amd64.tgz"
  "ffmpeg_7.0.2_linux_amd64.tgz"
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

# Set secure permissions: 0600, globular-owned so services running as globular can read it.
# The bootstrap gate allows both root-owned and globular-owned files.
chmod 0600 "$BOOTSTRAP_FLAG"
if id globular >/dev/null 2>&1; then
  chown globular:globular "$BOOTSTRAP_FLAG" 2>/dev/null || true
else
  chown root:root "$BOOTSTRAP_FLAG" 2>/dev/null || chown 0:0 "$BOOTSTRAP_FLAG"
fi

log_success "Bootstrap mode enabled: $BOOTSTRAP_FLAG (expires: $(date -d @$EXPIRES_AT '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $EXPIRES_AT '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'in 30 minutes'))"

# Write bootstrap sa credential file for non-interactive artifact publishing.
# Permissions 0600, root-owned. Deleted in Phase 5 cleanup.
# On Day-0 the sa account always starts with the default password (adminadmin).
# No interactive prompt needed — it would block unattended installs for no benefit.
BOOTSTRAP_SA_CRED="/var/lib/globular/.bootstrap-sa-password"
GLOBULAR_PASSWORD="${GLOBULAR_PASSWORD:-adminadmin}"
if [[ -n "${GLOBULAR_PASSWORD:-}" ]]; then
  printf '%s' "$GLOBULAR_PASSWORD" > "$BOOTSTRAP_SA_CRED"
  chmod 0600 "$BOOTSTRAP_SA_CRED"
  chown root:root "$BOOTSTRAP_SA_CRED" 2>/dev/null || true
fi

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

  # TLS setup is handled by scylladb package post-install script when present.
  # Fallback to external script for packages built without embedded scripts.
  if [[ -f /etc/scylla/tls/server.crt ]]; then
    log_substep "ScyllaDB TLS already configured"
  elif [[ -x "$SCRIPT_DIR/setup-scylla-tls.sh" ]]; then
    log_substep "Configuring ScyllaDB TLS (fallback)..."
    "$SCRIPT_DIR/setup-scylla-tls.sh" || die "ScyllaDB TLS setup failed"
    log_success "ScyllaDB configured with TLS"
  fi

  # Wait for ScyllaDB to be ready
  if ! systemctl is-active --quiet scylla-server.service; then
    systemctl start scylla-server.service || log_substep "Warning: failed to start scylla-server"
  fi
  # ScyllaDB binds to the routable IP, not 127.0.0.1 — extract from scylla.yaml
  SCYLLA_CQL_HOST=$(grep "^listen_address:" /etc/scylla/scylla.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"" || true)
  SCYLLA_CQL_HOST="${SCYLLA_CQL_HOST:-$(hostname -I | awk '{print $1}')}"
  log_substep "Waiting for ScyllaDB CQL port (${SCYLLA_CQL_HOST}:9042)..."
  SCYLLA_READY=0
  for i in $(seq 1 90); do
    if cqlsh "$SCYLLA_CQL_HOST" 9042 -e "SELECT now() FROM system.local" &>/dev/null; then
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

  # Install the ScyllaDB Globular package (sets up apt repo + installs OS packages)
  if [[ -f "$PKG_DIR/$SCYLLADB_PKG" ]]; then
    run_install "$PKG_DIR/$SCYLLADB_PKG"
  else
    log_substep "Warning: $SCYLLADB_PKG not found, attempting direct apt install..."
    # Only import GPG key and configure apt repo when falling back to direct apt install
    mkdir -p /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/scylladb.gpg ]]; then
      log_substep "Importing ScyllaDB GPG key..."
      curl -fsSL https://downloads.scylladb.com/deb/ubuntu/scylladb-2025.3.gpg | \
        gpg --dearmor -o /etc/apt/keyrings/scylladb.gpg
      log_success "ScyllaDB GPG key imported"
    fi
    if [[ ! -f /etc/apt/sources.list.d/scylla.list ]]; then
      echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/scylladb.gpg] https://downloads.scylladb.com/downloads/scylla/deb/debian-ubuntu/scylladb-2025.3 stable main" \
        > /etc/apt/sources.list.d/scylla.list
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq scylla scylla-server scylla-conf scylla-cqlsh scylla-python3
  fi

  # TLS, data dirs, and scylla.yaml are configured by the scylladb package
  # post-install script when present. Fallback to external script for packages
  # built without embedded scripts.
  if [[ -f /etc/scylla/tls/server.crt ]] && [[ -f /etc/scylla/scylla.yaml ]]; then
    log_substep "ScyllaDB TLS/config already configured (by package post-install)"
  elif [[ -x "$SCRIPT_DIR/setup-scylla-tls.sh" ]]; then
    log_substep "Configuring ScyllaDB (TLS, data dirs, scylla.yaml)..."
    "$SCRIPT_DIR/setup-scylla-tls.sh" || die "ScyllaDB TLS setup failed"
    log_success "ScyllaDB configured and started"
  else
    die "ScyllaDB TLS not configured and setup-scylla-tls.sh not found"
  fi

  # Enable service for boot
  systemctl enable scylla-server.service 2>/dev/null || true

  # Ensure ScyllaDB is actually running. The TLS check above may pass from a
  # previous install's config files, but the service may not be started yet
  # (apt reinstall can stop it, or the post-install script may not have run).
  if ! systemctl is-active --quiet scylla-server.service; then
    log_substep "Starting ScyllaDB service..."
    systemctl start scylla-server.service || log_substep "Warning: failed to start scylla-server"
  fi

  # Wait for ScyllaDB to be ready (CQL port 9042). ScyllaDB can take 30-90s
  # to initialize on first start. Without this wait, downstream services
  # (persistence, scylla-manager) fail to connect on the first install attempt.
  # ScyllaDB binds to the routable IP, not 127.0.0.1 — extract from scylla.yaml
  SCYLLA_CQL_HOST=$(grep "^listen_address:" /etc/scylla/scylla.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"" || true)
  SCYLLA_CQL_HOST="${SCYLLA_CQL_HOST:-$(hostname -I | awk '{print $1}')}"
  log_substep "Waiting for ScyllaDB to accept CQL connections (${SCYLLA_CQL_HOST}:9042)..."
  SCYLLA_READY=0
  for i in $(seq 1 90); do
    if cqlsh "$SCYLLA_CQL_HOST" 9042 -e "SELECT now() FROM system.local" &>/dev/null; then
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
fi

# TLS ownership fix: certs were generated as root during TLS Bootstrap but
# infrastructure services (etcd, gateway, etc.) run as the globular user.
# Fix ownership NOW, before any globular-user service tries to read them.
if id globular >/dev/null 2>&1 && [[ -d /var/lib/globular/pki ]]; then
  chown -R globular:globular /var/lib/globular/pki
  log_substep "TLS files ownership set to globular:globular (pre-infra)"
fi

log_step "Infrastructure Layer (etcd + minio)"
trace_step "running" "phase.infra" "Infrastructure Layer" 5
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

  # Sudoers: allow globular user to manage Globular services and restore operations.
  # The backup-manager runs as globular and needs to:
  # - Restart all services after restore (re-register etcd ports, fix node reachability)
  # - Stop/start ScyllaDB workload services during schema restore
  # - Fix sstable upload dir ownership for ScyllaDB restore
  log_substep "Installing sudoers rules for globular user..."
  cat > /etc/sudoers.d/globular <<'SUDOERS'
# Manage any globular-* systemd service.
# Needed by: backup-manager (post-restore restarts), node-agent (stop/start
# workload services during ScyllaDB schema restore, etcd stop/start).
globular ALL=(root) NOPASSWD: /usr/bin/systemctl stop globular-*.service
globular ALL=(root) NOPASSWD: /usr/bin/systemctl start globular-*.service
globular ALL=(root) NOPASSWD: /usr/bin/systemctl restart globular-*.service

# ScyllaDB sstable upload dir ownership fix during restore (safety net).
# The scylla-manager-agent runs as scylla so this rarely fires, but guards
# against edge cases where files end up with wrong ownership.
globular ALL=(root) NOPASSWD: /usr/bin/find /var/lib/scylla/data *
globular ALL=(root) NOPASSWD: /usr/bin/bash -c find /var/lib/scylla/data *
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
# Contract, credentials, and TLS symlinks are handled by the minio package
# pre-start.sh script when present. Fallback to external script for packages
# built without embedded scripts.
if [[ -f /var/lib/globular/objectstore/minio.json ]]; then
  log_success "MinIO contract configured (by package pre-start script)"
elif [[ -x "$SCRIPT_DIR/setup-minio-contract.sh" ]]; then
  "$SCRIPT_DIR/setup-minio-contract.sh"
  log_success "MinIO contract configured (fallback)"
else
  die "MinIO contract not found and setup-minio-contract.sh not available"
fi

# Verify TLS symlinks exist (created by pre-start.sh or setup-tls.sh).
# Without these, MinIO runs in HTTP mode — which breaks the HTTPS-only cluster.
if [[ ! -L /var/lib/globular/.minio/certs/public.crt ]]; then
  log_substep "Warning: MinIO TLS cert symlink missing — MinIO may be running in HTTP mode"
  log_substep "Expected: /var/lib/globular/.minio/certs/public.crt → PKI service cert"
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

# Ensure MinIO is running. The installer's start_services step already started
# it if the package had a spec with that step, but handle the case where the
# installer didn't start it (old packages or install failures).
log_substep "Ensuring MinIO service is running..."
systemctl daemon-reload
if ! systemctl is-active --quiet globular-minio.service; then
  systemctl start globular-minio.service || die "Failed to start MinIO service"
  log_success "MinIO service started"
else
  log_success "MinIO service already running"
fi

log_step "CLI Tools (needed for bucket provisioning)"
install_list "${CMDS_PKGS[@]}"

# Seed etcd Tier-0 keys so services that cannot use DNS can find infrastructure.
# These keys must be written BEFORE the cluster controller starts, which reads
# them during initProjections and publishMinioConfigLocked.
log_step "Seed Tier-0 etcd keys (ScyllaDB hosts + MinIO config)"
_NODE_IP_LOCAL=$(hostname -I | awk '{print $1}')
_ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-https://${_NODE_IP_LOCAL}:2379}"
_CA_CERT="/var/lib/globular/pki/ca.crt"
_CERT="/var/lib/globular/pki/issued/services/service.crt"
_KEY="/var/lib/globular/pki/issued/services/service.key"

# --- ScyllaDB hosts ---
# Detect ScyllaDB listen IP from scylla.yaml (same logic as the readiness check above).
_SCYLLA_IP=$(grep "^listen_address:" /etc/scylla/scylla.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"" || true)
if [[ -z "$_SCYLLA_IP" ]]; then
  _SCYLLA_IP="$_NODE_IP_LOCAL"
fi
if [[ -n "$_SCYLLA_IP" ]] && [[ "$_SCYLLA_IP" != "127.0.0.1" ]]; then
  if etcdctl --endpoints="$_ETCD_ENDPOINTS" \
      --cacert="$_CA_CERT" --cert="$_CERT" --key="$_KEY" \
      put "/globular/cluster/scylla/hosts" "[\"$_SCYLLA_IP\"]" >/dev/null 2>&1; then
    log_success "ScyllaDB hosts seeded in etcd: [$_SCYLLA_IP]"
  else
    log_substep "Warning: could not seed ScyllaDB hosts in etcd (will retry at runtime)"
  fi
else
  log_substep "Warning: could not determine ScyllaDB listen IP, skipping scylla hosts seed"
fi

# --- MinIO config ---
# Read credentials from the credentials file (written by setup-minio-contract.sh).
# This ensures the cluster controller uses the same credentials MinIO was initialized with.
_MINIO_CRED_FILE="/var/lib/globular/minio/credentials"
if [[ -f "$_MINIO_CRED_FILE" ]]; then
  _MINIO_AK=$(cut -d: -f1 "$_MINIO_CRED_FILE")
  _MINIO_SK=$(cut -d: -f2- "$_MINIO_CRED_FILE")
  if [[ -n "$_MINIO_AK" && -n "$_MINIO_SK" ]]; then
    _MINIO_ETCD_VAL="{\"endpoint\":\"minio.${DOMAIN}:9000\",\"access_key\":\"$_MINIO_AK\",\"secret_key\":\"$_MINIO_SK\",\"secure\":true,\"bucket\":\"globular\",\"prefix\":\"${DOMAIN}\"}"
    if etcdctl --endpoints="$_ETCD_ENDPOINTS" \
        --cacert="$_CA_CERT" --cert="$_CERT" --key="$_KEY" \
        put "/globular/cluster/minio/config" "$_MINIO_ETCD_VAL" >/dev/null 2>&1; then
      log_success "MinIO config seeded in etcd (access_key=$_MINIO_AK endpoint=minio.${DOMAIN}:9000)"
    else
      log_substep "Warning: could not seed MinIO config in etcd (will be written by cluster controller)"
    fi
  fi
else
  log_substep "Warning: MinIO credentials file not found — MinIO config not seeded"
fi

log_step "MinIO Bucket Provisioning"
# On new packages, the post-install.sh script already created buckets during
# install_list above. The external scripts are idempotent — safe to re-run.
# On old packages (no embedded scripts), these are the primary bucket creators.
if [[ -x "$SCRIPT_DIR/ensure-minio-buckets.sh" ]]; then
  "$SCRIPT_DIR/ensure-minio-buckets.sh"
  log_success "MinIO buckets provisioned"
else
  log_substep "ensure-minio-buckets.sh not found — buckets handled by package post-install"
fi

log_step "Cluster Config (shared via MinIO)"
# Create the cluster config bucket and upload critical shared files.
# These are available to all nodes via MinIO — survives any single node loss.
MC_BIN="/usr/local/bin/mc"
MINIO_ALIAS="local"
if [[ -x "$MC_BIN" ]]; then
  # Read credentials from the canonical credentials file (written by setup-minio-contract.sh).
  # minio.json stores auth.mode=file — the AccessKey/SecretKey fields are NOT directly in it.
  # Fallback to default credentials only if the file is missing.
  MINIO_ENDPOINT="https://$(hostname -I | awk '{print $1}'):9000"
  _CRED_FILE="/var/lib/globular/minio/credentials"
  if [[ -f "$_CRED_FILE" ]]; then
    MINIO_ACCESS="$(cut -d: -f1 "$_CRED_FILE")"
    MINIO_SECRET="$(cut -d: -f2- "$_CRED_FILE")"
  else
    MINIO_ACCESS="globular"
    MINIO_SECRET="globularadmin"
  fi
  if "$MC_BIN" alias set "$MINIO_ALIAS" "$MINIO_ENDPOINT" "$MINIO_ACCESS" "$MINIO_SECRET" --insecure 2>/dev/null; then
    log_substep "mc alias configured (user=$MINIO_ACCESS)"
  else
    log_substep "Warning: mc alias set failed — cluster config upload skipped"
  fi

  # Create config bucket.
  "$MC_BIN" mb --ignore-existing "${MINIO_ALIAS}/globular-config" --insecure 2>/dev/null || true

  # Upload CA certificate and key (cluster-wide PKI).
  if [[ -f /var/lib/globular/pki/ca.pem ]]; then
    "$MC_BIN" cp /var/lib/globular/pki/ca.pem "${MINIO_ALIAS}/globular-config/pki/ca.pem" --insecure 2>/dev/null && \
      log_success "CA certificate uploaded to MinIO (cluster-shared)" || \
      log_substep "Warning: CA cert upload to MinIO failed (non-fatal)"
  fi
  if [[ -f /var/lib/globular/pki/ca.key ]]; then
    "$MC_BIN" cp /var/lib/globular/pki/ca.key "${MINIO_ALIAS}/globular-config/pki/ca.key" --insecure 2>/dev/null && \
      log_success "CA key uploaded to MinIO (cluster-shared)" || \
      log_substep "Warning: CA key upload to MinIO failed (non-fatal)"
  fi

  # Upload RBAC cluster roles if present.
  if [[ -f /var/lib/globular/policy/rbac/cluster-roles.json ]]; then
    "$MC_BIN" cp /var/lib/globular/policy/rbac/cluster-roles.json \
      "${MINIO_ALIAS}/globular-config/policy/rbac/cluster-roles.json" --insecure 2>/dev/null || true
    log_success "RBAC policies uploaded to MinIO"
  fi

  # Upload AI operational rules (CLUSTER_CLAUDE.md → ai/CLAUDE.md in MinIO).
  # The ai_executor reads this via config.GetClusterConfig("ai/CLAUDE.md").
  CLAUDE_MD="${SCRIPT_DIR}/CLUSTER_CLAUDE.md"
  if [[ -f "$CLAUDE_MD" ]]; then
    "$MC_BIN" cp "$CLAUDE_MD" "${MINIO_ALIAS}/globular-config/ai/CLAUDE.md" --insecure 2>/dev/null && \
      log_success "AI operational rules uploaded to MinIO (cluster-shared)" || \
      log_substep "Warning: CLAUDE.md upload to MinIO failed (non-fatal)"
  fi
else
  log_substep "Warning: mc not found — cluster config sharing deferred"
fi

log_step "Data Layer (persistence)"
install_list "${DATA_LAYER_PKGS[@]}"

log_step "MinIO Bucket Setup"
if [[ -x "$SCRIPT_DIR/setup-minio.sh" ]]; then
  # Resolve webroot: bundled assets (webroot/ next to scripts/) take priority
  # over an empty STATE_DIR/webroot. Pass inline to the subprocess — no export.
  _BUNDLED_WEBROOT="$(dirname "$SCRIPT_DIR")/webroot"
  if [[ -d "$_BUNDLED_WEBROOT" ]]; then
    log_substep "Using bundled welcome page assets: $_BUNDLED_WEBROOT"
    WEBROOT_DIR="$_BUNDLED_WEBROOT" "$SCRIPT_DIR/setup-minio.sh"
  else
    "$SCRIPT_DIR/setup-minio.sh"
  fi
  log_success "MinIO buckets configured"
else
  log_substep "setup-minio.sh not found — bucket setup handled by package post-install"
fi

# ── Workflow-driven installation ─────────────────────────────────────────
# If USE_WORKFLOW=1 (default), install the node-agent, copy workflow
# definitions, start the node-agent, and delegate all remaining package
# installation to the day0.bootstrap workflow. This replaces the manual
# install_list calls below with a single declarative workflow run.
USE_WORKFLOW="${USE_WORKFLOW:-0}"
if [[ "$USE_WORKFLOW" == "1" ]]; then
  log_step "Workflow-Driven Bootstrap"

  # Install node-agent (the workflow runner).
  NODE_AGENT_PKG="$PKG_DIR/node-agent_0.0.1_linux_amd64.tgz"
  if [[ -f "$NODE_AGENT_PKG" ]]; then
    run_install "$NODE_AGENT_PKG"
  else
    die "node-agent package not found at $NODE_AGENT_PKG"
  fi

  # Copy all .tgz packages to the local fallback directory so the workflow
  # can install them without needing the repository service (which isn't
  # running yet during Day-0).
  log_substep "Staging packages for local install..."
  mkdir -p /var/lib/globular/packages
  cp "$PKG_DIR"/*.tgz /var/lib/globular/packages/ 2>/dev/null || true
  chown -R globular:globular /var/lib/globular/packages 2>/dev/null || true
  PKG_COUNT=$(ls /var/lib/globular/packages/*.tgz 2>/dev/null | wc -l)
  log_success "$PKG_COUNT packages staged in /var/lib/globular/packages/"

  # Copy workflow definitions to disk so the controller can seed etcd at startup.
  # Primary: release tarball layout — workflows/ is a sibling of scripts/.
  # Fallback: dev environment source tree.
  WORKFLOW_DEFS_SRC="${SCRIPT_DIR}/../workflows"
  if [[ ! -d "$WORKFLOW_DEFS_SRC" ]]; then
    WORKFLOW_DEFS_SRC="${SCRIPT_DIR}/../../services/golang/workflow/definitions"
  fi
  if [[ ! -d "$WORKFLOW_DEFS_SRC" ]]; then
    WORKFLOW_DEFS_SRC="/home/dave/Documents/github.com/globulario/services/golang/workflow/definitions"
  fi
  if [[ -d "$WORKFLOW_DEFS_SRC" ]]; then
    mkdir -p /var/lib/globular/workflows
    cp "$WORKFLOW_DEFS_SRC"/*.yaml /var/lib/globular/workflows/
    chown -R globular:globular /var/lib/globular/workflows 2>/dev/null || true
    log_success "Workflow definitions deployed to /var/lib/globular/workflows/"
  else
    log_substep "Warning: workflow definitions source not found — controller cannot self-heal etcd"
  fi

  # Globular configuration (Protocol=https) — needed before node-agent starts.
  if [[ -x "$SCRIPT_DIR/setup-config.sh" ]]; then
    "$SCRIPT_DIR/setup-config.sh"
    log_success "Configuration set to HTTPS"
  fi

  # Start the node-agent.
  log_substep "Starting node-agent..."
  systemctl enable globular-node-agent.service 2>/dev/null || true
  systemctl start globular-node-agent.service || die "Failed to start node-agent"

  # Resolve the node-agent's actual port from the installed systemd unit.
  # Never hardcode 11000 — the port lives in the unit file, not in this script.
  _NA_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
  _NA_IP="${_NA_IP:-$(hostname -I | awk '{print $1}')}"
  _NA_PORT=$(grep -oP '(?<=--port[= ])\d+' /etc/systemd/system/globular-node-agent.service 2>/dev/null | head -1 || true)
  _NA_PORT="${_NA_PORT:-$(grep -oP '(?<=--port[= ])\d+' /etc/systemd/system/globular-node-agent.service.d/*.conf 2>/dev/null | head -1 || true)}"
  [[ -n "$_NA_PORT" ]] || die "Could not determine node-agent port from installed systemd unit"

  # Wait for node-agent to be ready on its routable IP.
  log_substep "Waiting for node-agent to be ready on ${_NA_IP}:${_NA_PORT}..."
  for i in $(seq 1 30); do
    if timeout 2 bash -c "echo >/dev/tcp/${_NA_IP}/${_NA_PORT}" 2>/dev/null; then
      log_success "Node-agent ready on ${_NA_IP}:${_NA_PORT}"
      break
    fi
    if [[ $i -eq 30 ]]; then
      die "Node-agent not ready after 60 seconds"
    fi
    sleep 2
  done

  # Detect local hostname and IP for workflow inputs.
  NODE_HOSTNAME="$(hostname)"
  NODE_IP="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
  NODE_IP="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

  # Trigger the day0.bootstrap workflow via gRPC to the local node-agent.
  # The node-agent uses TLS with the cluster CA.
  CA_CERT="/var/lib/globular/pki/ca.crt"
  SVC_CERT="/var/lib/globular/pki/issued/services/service.crt"
  SVC_KEY="/var/lib/globular/pki/issued/services/service.key"

  NODE_ID="$(cat /var/lib/globular/nodeagent/node_id 2>/dev/null || echo 'bootstrap')"

  GRPC_REQUEST="{\"workflow_name\":\"day0.bootstrap\",\"inputs\":{\"cluster_id\":\"$DOMAIN\",\"bootstrap_node_id\":\"$NODE_ID\",\"bootstrap_node_hostname\":\"$NODE_HOSTNAME\",\"domain\":\"$DOMAIN\"}}"

  log_substep "Triggering day0.bootstrap workflow..."
  log_substep "  Request: $GRPC_REQUEST"

  GRPCURL="$(command -v grpcurl 2>/dev/null || true)"
  if [[ -n "$GRPCURL" ]]; then
    "$GRPCURL" -insecure \
      -cert "$SVC_CERT" -key "$SVC_KEY" \
      -d "$GRPC_REQUEST" \
      -max-time 1800 \
      "${_NA_IP}:${_NA_PORT}" node_agent.NodeAgentService/RunWorkflow 2>&1 | while IFS= read -r line; do
        echo "  [workflow] $line"
      done
    WORKFLOW_RC=${PIPESTATUS[0]}
  else
    # No grpcurl — try the globular CLI with a RunWorkflow-equivalent command.
    GLOBULAR_CLI="/usr/lib/globular/bin/globularcli"
    if [[ ! -x "$GLOBULAR_CLI" ]]; then
      GLOBULAR_CLI="$(command -v globular 2>/dev/null || true)"
    fi
    if [[ -n "$GLOBULAR_CLI" ]] && [[ -x "$GLOBULAR_CLI" ]]; then
      "$GLOBULAR_CLI" --insecure --timeout 1800s workflow run day0.bootstrap \
        --node "${_NA_IP}:${_NA_PORT}" 2>&1 | while IFS= read -r line; do
          echo "  [workflow] $line"
        done
      WORKFLOW_RC=${PIPESTATUS[0]}
    else
      die "Neither grpcurl nor globular CLI available to trigger workflow"
    fi
  fi

  if [[ "${WORKFLOW_RC:-1}" -ne 0 ]]; then
    log_substep "Warning: Workflow returned non-zero exit code: ${WORKFLOW_RC}"
    log_substep "Falling back to manual installation..."
    USE_WORKFLOW=0
    # Fall through to manual installation below.
  else
    log_success "Day-0 bootstrap workflow completed successfully"
    trace_finish "ok" "Day-0 installation via workflow completed"
    exit 0
  fi
fi

# ── Manual Installation (legacy or workflow fallback) ────────────────────
# This path runs if USE_WORKFLOW=0 or if the workflow failed and fell back.

log_step "Globular Configuration (Protocol=https)"
if [[ -x "$SCRIPT_DIR/setup-config.sh" ]]; then
  "$SCRIPT_DIR/setup-config.sh"
  log_success "Configuration set to HTTPS"

  # Ensure network.json has https protocol and correct permissions.
  # network.json may exist from a previous run with Protocol=http.
  if [[ -f /var/lib/globular/network.json ]]; then
    CURRENT_NET_PROTO=$(jq -r '.Protocol // "http"' /var/lib/globular/network.json 2>/dev/null)
    if [[ "$CURRENT_NET_PROTO" != "https" ]]; then
      jq '.Protocol = "https"' /var/lib/globular/network.json > /var/lib/globular/network.json.tmp \
        && mv /var/lib/globular/network.json.tmp /var/lib/globular/network.json
      log_substep "Updated network.json Protocol to https"
    fi
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
CLUSTER_DOCTOR_PKG="$PKG_DIR/cluster-doctor_0.0.1_linux_amd64.tgz"
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
trace_step "running" "phase.control-plane" "Control Plane Services" 5

# Add /etc/hosts entry for <hostname>.globular.internal so the DNS service can
# resolve the etcd endpoint (globule-ryzen.globular.internal:2379) before the
# cluster DNS resolver is running. This is a Day-0 bootstrap necessity only —
# once DNS is bootstrapped the system resolver handles this.
_NODE_IP=$(hostname -I | awk '{print $1}')
_NODE_SHORT=$(hostname -s)
_NODE_FQDN="${_NODE_SHORT}.${DOMAIN}"
if [[ -n "$_NODE_IP" ]] && ! grep -qF "$_NODE_FQDN" /etc/hosts 2>/dev/null; then
  echo "$_NODE_IP  $_NODE_FQDN  $_NODE_SHORT" >> /etc/hosts
  log_substep "Added /etc/hosts: $_NODE_IP → $_NODE_FQDN (bootstrap DNS resolution)"
fi

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

# Ensure etcd is running — DNS depends on it and etcd may have been rate-limited
# by systemd if TLS certs were briefly unreadable during regeneration.
if ! systemctl is-active --quiet globular-etcd.service 2>/dev/null; then
  log_substep "etcd not running — resetting and restarting..."
  systemctl reset-failed globular-etcd.service 2>/dev/null || true
  chown -R globular:globular /var/lib/globular/pki 2>/dev/null || true
  systemctl start globular-etcd.service 2>/dev/null || true
  sleep 3
  if systemctl is-active --quiet globular-etcd.service 2>/dev/null; then
    log_success "etcd recovered"
  else
    log_substep "Warning: etcd still not running — DNS bootstrap may fail"
  fi
fi

# DNS zone/record registration is now handled by the dns package post-install script.
# On Day 0, the dns service package includes scripts/post-install.sh which runs
# after health_checks pass. Fallback to external script if post-install didn't run.
if [[ -x "$SCRIPT_DIR/bootstrap-dns.sh" ]]; then
  # Verify DNS records exist; if not, run the legacy bootstrap script.
  if command -v dig >/dev/null 2>&1 && dig @127.0.0.1 +short "api.${DOMAIN:-globular.internal}" 2>/dev/null | grep -q .; then
    log_success "DNS records already initialized (by package post-install)"
  else
    log_substep "DNS records missing — running bootstrap-dns.sh..."
    "$SCRIPT_DIR/bootstrap-dns.sh"
    log_success "DNS records initialized (n0, api)"
  fi
else
  log_substep "Warning: bootstrap-dns.sh not found, DNS records not initialized"
fi

# Remove bootstrap flag — DNS bootstrap is done, and the expired flag would
# cause every subsequent gRPC call to fail on first attempt (bootstrap_expired
# denial before falling through to normal auth), making publish very slow.
rm -f "${BOOTSTRAP_FLAG}" 2>/dev/null

log_step "Operations Services"
trace_step "running" "phase.ops" "Operations Services" 5
install_list "${OPS_PKGS[@]}"

# Ensure MCP server is running — it's required by ai-watcher/ai-executor/ai-router.
# The installer may not start it if the binary exits cleanly before deps are ready
# (Restart=on-failure doesn't recover clean exits). Force-start + patch to Restart=always.
if [[ -f /etc/systemd/system/globular-mcp.service ]]; then
  if ! grep -q 'Restart=always' /etc/systemd/system/globular-mcp.service; then
    sed -i 's/Restart=on-failure/Restart=always/' /etc/systemd/system/globular-mcp.service
    systemctl daemon-reload
  fi
  systemctl restart globular-mcp.service 2>/dev/null || true
  log_substep "MCP server started (Restart=always)"
fi

# Configure scylla-manager-agent (auth token, port, ScyllaDB API address, MinIO S3 creds)
AGENT_CONFIG="/var/lib/globular/scylla-manager-agent/scylla-manager-agent.yaml"
AGENT_TOKEN_FILE="/var/lib/globular/scylla-manager-agent/auth_token.txt"

# Detect ScyllaDB listen address (needed for agent config and cluster registration)
SCYLLA_IP=""
if [[ -f /etc/scylla/scylla.yaml ]]; then
  # Strip quotes and whitespace from value (YAML may wrap IPs in single/double quotes)
  SCYLLA_IP=$(grep "^listen_address:" /etc/scylla/scylla.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"" || true)
fi
if [[ -z "$SCYLLA_IP" ]]; then
  SCYLLA_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
fi
if [[ -z "$SCYLLA_IP" ]]; then
  SCYLLA_IP=$(hostname -I | awk '{print $1}')
fi

# Generate auth token (idempotent)
# Owned by scylla:globular so the agent (runs as scylla) can read it
# and backup-manager (runs as globular) can also read it via group.
if [[ -d /var/lib/globular/scylla-manager-agent ]] && [[ ! -f "$AGENT_TOKEN_FILE" ]]; then
  cat /proc/sys/kernel/random/uuid > "$AGENT_TOKEN_FILE"
  chown scylla:globular "$AGENT_TOKEN_FILE"
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
  endpoint: https://${SCYLLA_IP}:9000

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

# ScyllaDB API address — must match api_address/api_port in scylla.yaml
# Scylla's REST API listens on port 10000 by default (see /etc/scylla/scylla.yaml).
scylla:
  api_address: "${SCYLLA_IP}"
  api_port: "10000"
${AGENT_S3_BLOCK}
AGENTEOF
  chown scylla:globular "$AGENT_CONFIG"
  chmod 0640 "$AGENT_CONFIG"

  log_success "scylla-manager-agent configured (token generated, port=56090, scylla=${SCYLLA_IP})"

  # Restart agent with new config
  systemctl restart globular-scylla-manager-agent.service 2>/dev/null || true
fi

# Always ensure the agent config directory is owned by scylla (agent runs as scylla)
# with globular group so backup-manager can read auth tokens.
if [[ -d /var/lib/globular/scylla-manager-agent ]]; then
  chmod 0750 /var/lib/globular/scylla-manager-agent
  chown scylla:globular /var/lib/globular/scylla-manager-agent
  # Fix ownership of all files inside too (covers auth_token.txt, config, etc.)
  chown scylla:globular /var/lib/globular/scylla-manager-agent/* 2>/dev/null || true
fi

# Register ScyllaDB cluster in scylla-manager (idempotent — works on fresh install or reinstall)
if [[ -f "$AGENT_TOKEN_FILE" ]] && command -v sctool &>/dev/null; then
  AGENT_TOKEN=$(cat "$AGENT_TOKEN_FILE")
  log_substep "Ensuring ScyllaDB is registered in scylla-manager..."

  # Wait for agent to be ready (up to 15s).
  # The agent requires auth, so any HTTP response (even 401) means it's up.
  for i in $(seq 1 15); do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 -k "https://127.0.0.1:56090/api/v1/version" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" != "000" ]]; then
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
      --host "${SCYLLA_IP}" \
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
trace_step "running" "phase.workloads" "Workload Services" 5
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
trace_step "running" "phase.health" "Cluster Health Validation" 8
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

# Globular CLI path — used by artifact publish and desired-state import below.
GLOBULAR_CLI="/usr/lib/globular/bin/globularcli"

# ── Day-0 Join Token ─────────────────────────────────────────────────────────
# Generate a shared join token so the first node can self-register with
# the cluster controller during bootstrap. Both services must share the
# same token: controller stores it in state.JoinTokens, node-agent passes
# it in RequestJoin.
log_step "Day-0 Join Token provisioning"
DAY0_TOKEN=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

# Write token to controller config
CC_CONFIG="/var/lib/globular/cluster-controller/config.json"
if [[ -f "$CC_CONFIG" ]]; then
  jq --arg tok "$DAY0_TOKEN" '.join_token = $tok' "$CC_CONFIG" > "${CC_CONFIG}.tmp" \
    && mv "${CC_CONFIG}.tmp" "$CC_CONFIG"
  log_substep "Join token written to controller config"
else
  mkdir -p "$(dirname "$CC_CONFIG")"
  echo "{\"join_token\": \"$DAY0_TOKEN\", \"port\": 12000}" > "$CC_CONFIG"
  log_substep "Controller config created with join token"
fi

# Set token as env var for node-agent via systemd drop-in
NA_DROPIN_DIR="/etc/systemd/system/globular-node-agent.service.d"
mkdir -p "$NA_DROPIN_DIR"
cat > "${NA_DROPIN_DIR}/join-token.conf" <<DROPIN
[Service]
Environment="NODE_AGENT_JOIN_TOKEN=${DAY0_TOKEN}"
DROPIN
log_substep "Join token written to node-agent systemd drop-in"

# Fix controller state if it has stale protocol=http from a previous run.
CC_STATE="/var/lib/globular/clustercontroller/state.json"
if [[ -f "$CC_STATE" ]]; then
  STATE_PROTO=$(jq -r '.cluster_network_spec.protocol // "http"' "$CC_STATE" 2>/dev/null)
  if [[ "$STATE_PROTO" != "https" ]]; then
    jq '.cluster_network_spec.protocol = "https"' "$CC_STATE" > "${CC_STATE}.tmp" \
      && mv "${CC_STATE}.tmp" "$CC_STATE"
    log_substep "Fixed controller state protocol to https"
  fi
fi

# Reload systemd and restart only the controller so it picks up the join token.
# The node-agent is enabled but NOT started here — the operator starts it explicitly.
systemctl daemon-reload
systemctl restart globular-cluster-controller
log_substep "Restarted cluster controller with shared join token"
# Give controller time to re-initialize with the new token.
sleep 5
log_success "Day-0 join token provisioned"

# ── Final Service Stabilization ──────────────────────────────────────────────
# Restart the cluster controller so it picks up fresh gRPC connections to all
# services. During install, services are started/stopped/restarted in sequence
# which leaves the controller with stale cached connections. A final restart
# ensures clean connectivity now that everything is stable.
log_step "Final Service Stabilization"
systemctl restart globular-cluster-controller.service 2>/dev/null || true
systemctl restart globular-gateway.service 2>/dev/null || true
sleep 3
log_success "Controller and gateway restarted with fresh connections"

echo ""
# ── AI credential access ─────────────────────────────────────────────────────
# Allow the globular service user to read Claude Code credentials from the
# installer user's home directory. The ai_executor auto-discovers credentials
# from /home/* and seeds them to etcd for cluster-wide sharing.
# Must run AFTER package installation (which creates the globular user).
INSTALLER_USER="${SUDO_USER:-}"
if [[ -n "$INSTALLER_USER" ]] && id globular >/dev/null 2>&1; then
  INSTALLER_HOME=$(eval echo "~$INSTALLER_USER")
  CLAUDE_CREDS="$INSTALLER_HOME/.claude/.credentials.json"
  if [[ -f "$CLAUDE_CREDS" ]]; then
    log_substep "Enabling AI credential access for globular user..."
    usermod -aG "$INSTALLER_USER" globular 2>/dev/null || true
    chmod 750 "$INSTALLER_HOME/.claude" 2>/dev/null || true
    chmod 640 "$CLAUDE_CREDS" 2>/dev/null || true
    # Restart ai_executor so it picks up the new group membership.
    systemctl restart globular-ai-executor.service 2>/dev/null || true
    log_success "AI credentials accessible (ai_executor will auto-seed to etcd)"
  fi
fi

# ── Publish bootstrap artifacts to repository (Layer 1) ──────────────────────
# Populates the Repository catalog so the cluster can manage upgrades,
# new-node joins, and desired-state resolution. Idempotent — skips packages
# already present. Non-fatal: install completes even if some packages fail.
log_step "Publishing Bootstrap Artifacts to Repository"
if [[ -x "$SCRIPT_DIR/ensure-bootstrap-artifacts.sh" ]]; then
  PKG_DIR="$PKG_DIR" GLOBULAR_CLI="$GLOBULAR_CLI" \
    "$SCRIPT_DIR/ensure-bootstrap-artifacts.sh" || \
    log_warn "Some artifacts failed to publish — run ensure-bootstrap-artifacts.sh manually"
else
  log_warn "ensure-bootstrap-artifacts.sh not found — skipping artifact publish"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          ✓ INSTALLATION COMPLETE                               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
log_success "Infrastructure ready. Bootstrap mode is active — start the node agent and run bootstrap."
trace_finish "ok" "Day-0 installation complete"

# Resolve the actual node IP and node-agent port from the installed systemd unit.
# Never use localhost/127.0.0.1 — the bootstrap command must use the routable IP
# so the controller can reach back. Never hardcode the port — read it from the unit.
_BOOTSTRAP_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
_BOOTSTRAP_IP="${_BOOTSTRAP_IP:-$(hostname -I | awk '{print $1}')}"
_NA_UNIT_PORT=$(grep -oP '(?<=--port[= ])\d+' /etc/systemd/system/globular-node-agent.service 2>/dev/null | head -1 || true)
_NA_UNIT_PORT="${_NA_UNIT_PORT:-$(grep -oP '(?<=--port[= ])\d+' /etc/systemd/system/globular-node-agent.service.d/*.conf 2>/dev/null | head -1 || true)}"
_BOOTSTRAP_NODE="${_BOOTSTRAP_IP}:${_NA_UNIT_PORT}"

echo ""
echo "  Next steps:"
echo ""
echo "  1. Start the node agent:"
echo "       sudo systemctl start globular-node-agent"
echo ""
echo "     Verify it is running:"
echo "       sudo systemctl status globular-node-agent"
echo ""
echo "  2. Bootstrap this node (in another terminal):"
echo "       globular cluster bootstrap \\"
echo "         --node ${_BOOTSTRAP_NODE} \\"
echo "         --domain <your-domain> \\"
echo "         --profile core \\"
echo "         --profile gateway"
echo ""
echo "     Example for a single-node cluster:"
echo "       globular cluster bootstrap \\"
echo "         --node ${_BOOTSTRAP_NODE} \\"
echo "         --domain mycluster.local \\"
echo "         --profile core --profile gateway --profile storage"
echo ""
echo "  After bootstrap, add more nodes with:"
echo "       curl -sfL https://<gateway>:8443/join -k | sudo bash -s -- --token <token>"
echo ""
