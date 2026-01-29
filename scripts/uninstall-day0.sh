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
log() { echo "[uninstall] $*"; }

[[ -d "$PKG_DIR" ]] || die "Package directory not found: $PKG_DIR"
[[ -n "$INSTALLER_BIN" ]] && [[ -x "$INSTALLER_BIN" ]] || die "globular-installer not found; set INSTALLER_BIN or build ./bin/globular-installer"

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
log "timeout command: ${TIMEOUT_BIN:-<none>}"
if [[ -z "$TIMEOUT_BIN" ]]; then
  die "timeout command not found; install coreutils (timeout) or set TIMEOUT_BIN"
fi
FAILED=0

log "Using installer: $INSTALLER_BIN"
log "Detected uninstall mode: $UNINSTALL_MODE"
log "Package dir: $PKG_DIR"

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
  local out rc
  local units
  units="$(units_for_pkg "$pkgname")"

  if [[ -n "$units" ]]; then
    for u in $units; do
      systemctl stop "$u" >/dev/null 2>&1 || true
      systemctl disable "$u" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if ! is_installed "$pkgname"; then
    log "Not detected as installed (will still attempt): $pkgname"
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
    log "Uninstalled: $(basename "$pkgfile")"
    return 0
  fi

  if [[ "$TOLERATE_NOT_INSTALLED" == "1" ]] && echo "$out" | grep -qiE "not installed|no such|does not exist"; then
    log "Not installed (tolerated): $(basename "$pkgfile")"
    return 0
  fi

  if echo "$out" | grep -qiE 'plan "uninstall" has no steps|has no steps'; then
    log "Installer produced no uninstall steps for tgz; retrying by name: $pkgname"
    set +e
    out="$("$INSTALLER_BIN" uninstall "$pkgname" 2>&1)"; rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      log "Uninstalled (by name): $pkgname"
      return 0
    fi
    if echo "$out" | grep -qiE 'plan "uninstall" has no steps|has no steps'; then
      log "No uninstall steps for $pkgname; skipping."
      return 0
    fi
  fi

  echo "$out" >&2
  log "WARNING: Failed uninstall for $pkgname: $out"
  FAILED=1
  return 0
}

REMOVE_ORDER=(
  "service.file_0.0.1_linux_amd64.tgz"
  "service.log_0.0.1_linux_amd64.tgz"
  "service.event_0.0.1_linux_amd64.tgz"

  "service.blog_0.0.1_linux_amd64.tgz"
  "service.catalog_0.0.1_linux_amd64.tgz"
  "service.conversation_0.0.1_linux_amd64.tgz"
  "service.echo_0.0.1_linux_amd64.tgz"
  "service.media_0.0.1_linux_amd64.tgz"
  "service.monitoring_0.0.1_linux_amd64.tgz"
  "service.persistence_0.0.1_linux_amd64.tgz"
  "service.search_0.0.1_linux_amd64.tgz"
  "service.sql_0.0.1_linux_amd64.tgz"
  "service.storage_0.0.1_linux_amd64.tgz"
  "service.title_0.0.1_linux_amd64.tgz"
  "service.torrent_0.0.1_linux_amd64.tgz"

  "service.dns_0.0.1_linux_amd64.tgz"
  "service.repository_0.0.1_linux_amd64.tgz"
  "service.discovery_0.0.1_linux_amd64.tgz"
  "service.authentication_0.0.1_linux_amd64.tgz"
  "service.rbac_0.0.1_linux_amd64.tgz"
  "service.resource_0.0.1_linux_amd64.tgz"

  "service.globular-cli-cmd_0.0.1_linux_amd64.tgz"
  "service.mc-cmd_0.0.1_linux_amd64.tgz"

  "service.cluster-controller_0.0.1_linux_amd64.tgz"
  "service.node-agent_0.0.1_linux_amd64.tgz"
  "service.gateway_0.0.1_linux_amd64.tgz"
  "service.xds_0.0.1_linux_amd64.tgz"
  "service.envoy_1.35.3_linux_amd64.tgz"
  "service.minio_0.0.1_linux_amd64.tgz"
  "service.etcd_3.5.14_linux_amd64.tgz"
)

for f in "${REMOVE_ORDER[@]}"; do
  pkg_path="$PKG_DIR/$f"
  if [[ ! -f "$pkg_path" ]]; then
    log "Skipping (not found): $f"
    continue
  fi
  log "Uninstalling package: $f"
  run_uninstall "$pkg_path"
done

if [[ "$FAILED" -ne 0 ]]; then
  die "Uninstall completed with errors (some services could not be removed). See warnings above."
fi

log "Done."
