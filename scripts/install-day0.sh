#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="${PKG_DIR:-"$INSTALLER_ROOT/internal/assets/packages"}"

INSTALLER_BIN="$INSTALLER_ROOT/bin/globular-installer"
if [[ ! -x "$INSTALLER_BIN" ]]; then
  INSTALLER_BIN="$(command -v globular-installer || true)"
fi

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[install] $*"; }

[[ -d "$PKG_DIR" ]] || die "Package directory not found: $PKG_DIR"
[[ -n "$INSTALLER_BIN" ]] && [[ -x "$INSTALLER_BIN" ]] || die "globular-installer not found; set INSTALLER_BIN or build ./bin/globular-installer"

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

log "Using installer: $INSTALLER_BIN"
log "Detected install mode: $INSTALL_MODE"
log "Detected uninstall mode: $UNINSTALL_MODE"
log "Package dir: $PKG_DIR"

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
    echo "could not locate embedded spec in package: $pkgfile" >&2
    return 2
  fi

  log "Fallback picked spec: $spec"

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
  local out rc
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
    log "Installer fell back to default spec for $(basename "$pkgfile"); retrying via extract+spec..."
    set +e
    out="$(install_from_extracted_spec "$pkgfile" 2>&1)"; rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      echo "$out" >&2
      die "Install failed for $(basename "$pkgfile") (rc=$rc)"
    fi
    return 0
  fi

  if [[ $rc -ne 0 ]]; then
    if [[ "$TOLERATE_ALREADY_INSTALLED" == "1" ]] && echo "$out" | grep -qiE "already installed|exists|is installed"; then
      log "Already installed (tolerated): $(basename "$pkgfile")"
      return 0
    fi
    echo "$out" >&2
    die "Install failed for $(basename "$pkgfile") (rc=$rc)"
  fi

  log "Installed: $(basename "$pkgfile")"
}

install_list() {
  local pkg_array=("$@")
  for f in "${pkg_array[@]}"; do
    local path="$PKG_DIR/$f"
    if [[ ! -f "$path" ]]; then
      log "Skipping (not found): $f"
      continue
    fi
    run_install "$path"
  done
}

BOOTSTRAP_MINIO_PKGS=(
  "service.etcd_3.5.14_linux_amd64.tgz"
  "service.minio_0.0.1_linux_amd64.tgz"
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

log "Installing bootstrap layer (etcd + minio)..."
install_list "${BOOTSTRAP_MINIO_PKGS[@]}"

log "Setting up MinIO contract file..."
if [[ -x "$SCRIPT_DIR/setup-minio-contract.sh" ]]; then
  "$SCRIPT_DIR/setup-minio-contract.sh"
else
  die "setup-minio-contract.sh not found or not executable"
fi

MINIO_UNIT="/etc/systemd/system/globular-minio.service"
if [[ ! -f "$MINIO_UNIT" ]]; then
  die "MinIO unit not installed at $MINIO_UNIT"
fi
if grep -q "{{" "$MINIO_UNIT"; then
  die "MinIO unit contains unrendered template placeholders: $MINIO_UNIT"
fi
if ! systemd-analyze verify "$MINIO_UNIT"; then
  die "MinIO unit failed systemd verification: $MINIO_UNIT"
fi
systemctl daemon-reload
systemctl show -p FragmentPath globular-minio.service || true
if ! systemctl is-active --quiet globular-minio.service; then
  systemctl start globular-minio.service || die "Failed to start globular-minio.service"
fi

log "Setting up MinIO buckets and webroot..."
if [[ -x "$SCRIPT_DIR/setup-minio.sh" ]]; then
  "$SCRIPT_DIR/setup-minio.sh"
else
  die "setup-minio.sh not found or not executable"
fi

log "Installing remaining bootstrap services..."
install_list "${BOOTSTRAP_REST_PKGS[@]}"

log "Installing Day-0 control plane..."
install_list "${CONTROL_PLANE_PKGS[@]}"

log "Installing ops services..."
install_list "${OPS_PKGS[@]}"

log "Installing optional workload packages..."
install_list "${OPTIONAL_WORKLOAD_PKGS[@]}"

log "Done."
