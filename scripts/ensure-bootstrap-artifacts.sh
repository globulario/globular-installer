#!/usr/bin/env bash
# ensure-bootstrap-artifacts.sh
#
# Day-0 Artifact Publishing — Operational Scope
#
# Publishes the installer-bundled package set to the Repository catalog
# as a post-install step. This populates Layer 1 (Artifact) of the
# 4-layer state model so the cluster can manage upgrades, new-node
# joins, and desired-state resolution after Day-0.
#
# Scope boundary:
#   - This script publishes ONLY the CORE_PACKAGES[] list below
#   - The repository does NOT enforce a Day-0 package list
#   - Scope bounding is this script's responsibility, not the repository's
#   - sa retains full superuser authority at all times — this is by design
#
# Trust model (v1):
#   - Checksum immutability (SHA-256, content-addressable)
#   - RBAC authority (namespace ownership, sa superuser bypass)
#   - Provenance (immutable record: subject, source_ip, auth_method)
#   - Publish-state gating (STAGING → VERIFIED → PUBLISHED)
#   - Publisher signing (cosign/GPG) is intentionally out of scope for v1
#
# Day-0 publishes use the NORMAL authenticated publish flow via the sa
# account. No repository-specific bootstrap bypass exists. Day-0
# provenance records are marked with build_source="day0-bootstrap"
# for audit visibility.
#
# Idempotent: skips packages that are already published.
#
# Environment variables:
#   PKG_DIR            - Directory containing .tgz packages (required)
#   GLOBULAR_CLI       - Path to globularcli binary (default: /usr/lib/globular/bin/globularcli)
#   REPO_ADDR          - Repository gRPC endpoint override (default: auto-discover via gateway)
#   GLOBULAR_TOKEN     - Auth token override (default: login as sa)
#   GLOBULAR_PASSWORD  - sa password (default: read from bootstrap credential file or prompt)
#
# Exit codes:
#   0 - All core packages published (or already present)
#   1 - At least one core package failed (non-fatal: Day-0 continues)

set -uo pipefail
# NOTE: no set -e — we handle errors per-package and return a summary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

log_info()    { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_warn()    { echo "  ⚠ $*"; }
log_fail()    { echo "  ✗ $*" >&2; }

# ── Configuration ────────────────────────────────────────────────────────────

PKG_DIR="${PKG_DIR:-}"
if [[ -z "$PKG_DIR" || ! -d "$PKG_DIR" ]]; then
  log_fail "PKG_DIR is not set or does not exist: ${PKG_DIR:-<unset>}"
  exit 1
fi

GLOBULAR_CLI="${GLOBULAR_CLI:-/usr/lib/globular/bin/globularcli}"
if [[ ! -x "$GLOBULAR_CLI" ]]; then
  log_warn "globularcli not found at $GLOBULAR_CLI — cannot publish artifacts"
  exit 1
fi

# All packages that MUST be in the repository after Day-0.
# This includes every service, infrastructure component, and CLI tool
# so the full catalog is available for cluster management from the start.
CORE_PACKAGES=(
  # ── Infrastructure ──────────────────────────────────────────────────
  "service.etcd_*_linux_amd64.tgz"
  "service.minio_*_linux_amd64.tgz"
  "service.keepalived_*_linux_amd64.tgz"
  "service.scylladb_*_linux_amd64.tgz"
  # Data layer
  "service.persistence_*_linux_amd64.tgz"
  # ── Bootstrap services ─────────────────────────────────────────────
  "service.xds_*_linux_amd64.tgz"
  "service.envoy_*_linux_amd64.tgz"
  "service.gateway_*_linux_amd64.tgz"
  "service.node-agent_*_linux_amd64.tgz"
  "service.cluster-controller_*_linux_amd64.tgz"
  "service.cluster-doctor_*_linux_amd64.tgz"
  # ── Control plane ──────────────────────────────────────────────────
  "service.resource_*_linux_amd64.tgz"
  "service.rbac_*_linux_amd64.tgz"
  "service.authentication_*_linux_amd64.tgz"
  "service.discovery_*_linux_amd64.tgz"
  "service.dns_*_linux_amd64.tgz"
  "service.repository_*_linux_amd64.tgz"
  # ── Operations ─────────────────────────────────────────────────────
  "service.sidekick_*_linux_amd64.tgz"
  "service.node-exporter_*_linux_amd64.tgz"
  "service.prometheus_*_linux_amd64.tgz"
  "service.monitoring_*_linux_amd64.tgz"
  "service.event_*_linux_amd64.tgz"
  "service.log_*_linux_amd64.tgz"
  "service.backup-manager_*_linux_amd64.tgz"
  "service.mcp_*_linux_amd64.tgz"
  "service.ai-memory_*_linux_amd64.tgz"
  "service.ai-watcher_*_linux_amd64.tgz"
  "service.ai-executor_*_linux_amd64.tgz"
  "service.ai-router_*_linux_amd64.tgz"
  "service.scylla-manager-agent_*_linux_amd64.tgz"
  "service.scylla-manager_*_linux_amd64.tgz"
  # ── Workload services ──────────────────────────────────────────────
  "service.file_*_linux_amd64.tgz"
  "service.blog_*_linux_amd64.tgz"
  "service.catalog_*_linux_amd64.tgz"
  "service.conversation_*_linux_amd64.tgz"
  "service.echo_*_linux_amd64.tgz"
  "service.ldap_*_linux_amd64.tgz"
  "service.mail_*_linux_amd64.tgz"
  "service.media_*_linux_amd64.tgz"
  "service.search_*_linux_amd64.tgz"
  "service.sql_*_linux_amd64.tgz"
  "service.storage_*_linux_amd64.tgz"
  "service.title_*_linux_amd64.tgz"
  "service.torrent_*_linux_amd64.tgz"
  # ── CLI tools ──────────────────────────────────────────────────────
  "service.globular-cli-cmd_*_linux_amd64.tgz"
  "service.etcdctl-cmd_*_linux_amd64.tgz"
  "service.mc-cmd_*_linux_amd64.tgz"
  "service.sctool-cmd_*_linux_amd64.tgz"
  "service.ffmpeg-cmd_*_linux_amd64.tgz"
  "service.yt-dlp-cmd_*_linux_amd64.tgz"
  "service.sha256sum-cmd_*_linux_amd64.tgz"
  "service.restic-cmd_*_linux_amd64.tgz"
  "service.rclone-cmd_*_linux_amd64.tgz"
)

# ── Resolve real user home (handles sudo) ────────────────────────────────────
# When running as root via sudo, $HOME is /root but certs live under the
# invoking user's home (e.g. /home/dave/.config/globular/).
REAL_HOME="$HOME"
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  REAL_HOME=$(eval echo "~${SUDO_USER}")
fi

# ── Step 1: Discover repository endpoint ─────────────────────────────────────

REPO_ADDR="${REPO_ADDR:-}"

if [[ -z "$REPO_ADDR" ]]; then
  log_info "Discovering repository service endpoint..."

  # Find a CA cert for the gateway HTTPS call.
  # Search the real user's home first, then root, then system-wide.
  CA_CERT=""
  for _ca in \
      "$REAL_HOME/.config/globular/pki/ca.crt" \
      "$REAL_HOME/.config/globular/tls/localhost/ca.crt" \
      "$REAL_HOME/.config/globular/tls/globular.internal/ca.crt" \
      /root/.config/globular/pki/ca.crt \
      /root/.config/globular/tls/localhost/ca.crt \
      /var/lib/globular/pki/ca.crt; do
    if [[ -f "$_ca" && -r "$_ca" ]]; then
      CA_CERT="$_ca"
      break
    fi
  done

  if [[ -z "$CA_CERT" ]]; then
    log_warn "No CA cert found — cannot discover repository endpoint"
    exit 1
  fi

  # Query gateway /config for the repository service port.
  # Retry up to 5 times — the repository may still be registering with the gateway.
  REPO_ADDR=""
  for _repo_attempt in $(seq 1 5); do
    REPO_ADDR=$(curl -sf --max-time 5 \
        --cacert "$CA_CERT" \
        "https://localhost:8443/config" 2>/dev/null \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
for svc in data.get('Services', {}).values():
    name = svc.get('Name', '')
    if 'repository' in name.lower() and 'PackageRepository' in name:
        addr = svc.get('Address', '')
        host = addr.split(':')[0] if addr else '127.0.0.1'
        port = int(svc.get('Port', 0))
        if port:
            print(f'{host}:{port}')
            break
" 2>/dev/null || true)
    [[ -n "$REPO_ADDR" ]] && break
    log_info "Repository not yet available (attempt $_repo_attempt/5), retrying..."
    sleep 3
  done

  if [[ -z "$REPO_ADDR" ]]; then
    log_warn "Repository service not found via gateway /config after 5 attempts"
    exit 1
  fi
fi

log_success "Repository endpoint: $REPO_ADDR"

# ── Step 2: Acquire auth token ───────────────────────────────────────────────

if [[ -z "${GLOBULAR_TOKEN:-}" ]]; then
  GLOBULAR_USER="${GLOBULAR_USER:-sa}"

  # Resolve password: env var → bootstrap credential file → interactive prompt.
  if [[ -z "${GLOBULAR_PASSWORD:-}" ]]; then
    BOOTSTRAP_CRED="/var/lib/globular/.bootstrap-sa-password"
    if [[ -f "$BOOTSTRAP_CRED" && -r "$BOOTSTRAP_CRED" ]]; then
      GLOBULAR_PASSWORD=$(cat "$BOOTSTRAP_CRED")
    fi
  fi
  if [[ -z "${GLOBULAR_PASSWORD:-}" ]]; then
    read -rsp "Password for $GLOBULAR_USER: " GLOBULAR_PASSWORD
    echo
  fi

  # Fix ownership of the config dir so the CLI can write the token file.
  # Previous sudo runs may have created it as root-owned.
  CONFIG_DIR="${REAL_HOME}/.config/globular"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && -d "$CONFIG_DIR" ]]; then
    chown -R "${SUDO_USER}":"${SUDO_USER}" "$CONFIG_DIR" 2>/dev/null || true
  fi

  # When running as root via sudo, run the CLI login as the real user so
  # it writes the token and reads client certs from the right home dir.
  # Retry up to 3 times — auth service may still be starting.
  log_info "Logging in as $GLOBULAR_USER..."
  TOKEN_FILE="${REAL_HOME}/.config/globular/token"
  for _auth_attempt in $(seq 1 3); do
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
      LOGIN_OUT=$(sudo -u "$SUDO_USER" "$GLOBULAR_CLI" auth login \
        --user "$GLOBULAR_USER" \
        --password "$GLOBULAR_PASSWORD" 2>&1) || true
    else
      LOGIN_OUT=$("$GLOBULAR_CLI" auth login \
        --user "$GLOBULAR_USER" \
        --password "$GLOBULAR_PASSWORD" 2>&1) || true
    fi

    # Check for token in file.
    if [[ -f "$TOKEN_FILE" ]]; then
      GLOBULAR_TOKEN=$(cat "$TOKEN_FILE")
      [[ -n "$GLOBULAR_TOKEN" ]] && break
    fi

    # Fallback: also check /root in case CLI wrote it there.
    if [[ -z "${GLOBULAR_TOKEN:-}" && -f "/root/.config/globular/token" ]]; then
      GLOBULAR_TOKEN=$(cat "/root/.config/globular/token")
      [[ -n "$GLOBULAR_TOKEN" ]] && break
    fi

    # Fallback: parse the token directly from CLI output.
    if [[ -z "${GLOBULAR_TOKEN:-}" ]]; then
      PARSED_TOKEN=$(echo "$LOGIN_OUT" | grep -oP '^Token: \K\S+' || true)
      if [[ -n "$PARSED_TOKEN" ]]; then
        GLOBULAR_TOKEN="$PARSED_TOKEN"
        break
      fi
    fi

    log_info "Auth not ready (attempt $_auth_attempt/3), retrying..."
    sleep 3
  done

  if [[ -z "${GLOBULAR_TOKEN:-}" ]]; then
    log_warn "Failed to acquire auth token after 3 attempts: $LOGIN_OUT"
    log_warn "Publish requires authentication — skipping artifact publish"
    exit 1
  fi

  log_success "Auth token acquired"
fi

export GLOBULAR_TOKEN

# ── Step 3: Publish each core package ────────────────────────────────────────

# Extract a human-readable name and version from the .tgz filename.
# e.g. "service.etcd_3.5.14_linux_amd64.tgz" → name="etcd" version="3.5.14"
parse_pkg_label() {
  local base="$1"
  base="${base%.tgz}"                         # strip .tgz
  base="${base#service.}"                     # strip service. prefix
  local name="${base%%_*}"                    # everything before first _
  local rest="${base#*_}"                     # everything after first _
  local version="${rest%%_*}"                 # version = next segment before _
  echo "${name} ${version}"
}

PUBLISHED=0
SKIPPED=0
FAILED=0
TOTAL=0
FAILED_LIST=""

for pattern in "${CORE_PACKAGES[@]}"; do
  # Resolve glob pattern to actual file
  # shellcheck disable=SC2206
  matches=( $PKG_DIR/$pattern )
  if [[ ${#matches[@]} -eq 0 || ! -f "${matches[0]}" ]]; then
    continue
  fi

  PACKAGE="${matches[0]}"
  PKG_NAME="$(basename "$PACKAGE")"
  read -r SVC_NAME SVC_VER <<< "$(parse_pkg_label "$PKG_NAME")"
  TOTAL=$((TOTAL + 1))

  # Publish the package.  Capture stdout (JSON) and stderr separately
  # so the JSON parser doesn't choke on progress output.
  # Run as the real user (not root) so the CLI finds client certs.
  PUBLISH_ERR_FILE="/tmp/publish-err-$$.log"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    PUBLISH_JSON=$(sudo -u "$SUDO_USER" \
      "$GLOBULAR_CLI" --timeout 60s --token "$GLOBULAR_TOKEN" pkg publish \
        --file "$PACKAGE" \
        --repository "$REPO_ADDR" \
        --force \
        --output json 2>"$PUBLISH_ERR_FILE") || true
  else
    PUBLISH_JSON=$("$GLOBULAR_CLI" --timeout 60s --token "$GLOBULAR_TOKEN" pkg publish \
      --file "$PACKAGE" \
      --repository "$REPO_ADDR" \
      --force \
      --output json 2>"$PUBLISH_ERR_FILE") || true
  fi

  # Parse the JSON result.
  STATUS=$(echo "$PUBLISH_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('status', ''))
except:
    print('')
" 2>/dev/null || true)

  DESC_ACTION=$(echo "$PUBLISH_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('descriptor_action', ''))
except:
    print('')
" 2>/dev/null || true)

  if [[ "$STATUS" == "success" ]]; then
    if [[ "$DESC_ACTION" == "unchanged" || "$DESC_ACTION" == "skipped" ]]; then
      log_success "$(printf '%-28s %s (already present)' "$SVC_NAME" "$SVC_VER")"
      SKIPPED=$((SKIPPED + 1))
    else
      log_success "$(printf '%-28s %s (published)' "$SVC_NAME" "$SVC_VER")"
      PUBLISHED=$((PUBLISHED + 1))
    fi
  else
    # Check for "already exists" style errors in the raw output
    if echo "$PUBLISH_JSON" | grep -qiE "already exists|duplicate|conflict"; then
      log_success "$(printf '%-28s %s (already present)' "$SVC_NAME" "$SVC_VER")"
      SKIPPED=$((SKIPPED + 1))
    else
      log_fail "$(printf '%-28s %s — publish failed' "$SVC_NAME" "$SVC_VER")"
      # Log the actual error for diagnostics.
      if [[ -n "$PUBLISH_JSON" ]]; then
        ERR_MSG=$(echo "$PUBLISH_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    e = data.get('error', {})
    print(e.get('message', '') or e.get('code', ''))
except:
    print('')
" 2>/dev/null || true)
        [[ -n "$ERR_MSG" ]] && log_info "    error: $ERR_MSG"
      fi
      if [[ -s "$PUBLISH_ERR_FILE" ]]; then
        log_info "    stderr: $(head -1 "$PUBLISH_ERR_FILE")"
      fi
      FAILED=$((FAILED + 1))
      FAILED_LIST="$FAILED_LIST $SVC_NAME@$SVC_VER"
    fi
  fi
  rm -f "$PUBLISH_ERR_FILE" 2>/dev/null || true
done

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
log_info "Artifact publish: $TOTAL total, $PUBLISHED new, $SKIPPED existing, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
  log_warn "Failed:$FAILED_LIST"
  exit 1
fi

exit 0
