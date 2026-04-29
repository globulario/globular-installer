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
# Arguments:
#   $1 - Directory containing .tgz packages (required)
#   $2 - Path to globularcli binary (optional, default: /usr/lib/globular/bin/globularcli)
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

PKG_DIR="${1:-}"
if [[ -z "$PKG_DIR" || ! -d "$PKG_DIR" ]]; then
  log_fail "PKG_DIR is not set or does not exist: ${PKG_DIR:-<unset>}"
  exit 1
fi

GLOBULAR_CLI="${2:-/usr/lib/globular/bin/globularcli}"
if [[ ! -x "$GLOBULAR_CLI" ]]; then
  log_warn "globularcli not found at $GLOBULAR_CLI — cannot publish artifacts"
  exit 1
fi

STATE_DIR="/var/lib/globular"
REAL_HOME="/root"
REPO_ADDR=""
GLOBULAR_TOKEN=""
GLOBULAR_USER="sa"
GLOBULAR_PASSWORD=""

# All packages that MUST be in the repository after Day-0.
# This includes every service, infrastructure component, and CLI tool
# so the full catalog is available for cluster management from the start.
CORE_PACKAGES=(
  # ── Infrastructure ──────────────────────────────────────────────────
  "etcd_*_linux_amd64.tgz"
  "minio_*_linux_amd64.tgz"
  "keepalived_*_linux_amd64.tgz"
  "scylladb_*_linux_amd64.tgz"
  # Data layer
  "persistence_*_linux_amd64.tgz"
  # ── Bootstrap services ─────────────────────────────────────────────
  "xds_*_linux_amd64.tgz"
  "envoy_*_linux_amd64.tgz"
  "gateway_*_linux_amd64.tgz"
  "node-agent_*_linux_amd64.tgz"
  "cluster-controller_*_linux_amd64.tgz"
  "cluster-doctor_*_linux_amd64.tgz"
  # ── Control plane ──────────────────────────────────────────────────
  "resource_*_linux_amd64.tgz"
  "rbac_*_linux_amd64.tgz"
  "authentication_*_linux_amd64.tgz"
  "discovery_*_linux_amd64.tgz"
  "dns_*_linux_amd64.tgz"
  "repository_*_linux_amd64.tgz"
  # ── Operations ─────────────────────────────────────────────────────
  "sidekick_*_linux_amd64.tgz"
  "node-exporter_*_linux_amd64.tgz"
  "prometheus_*_linux_amd64.tgz"
  "monitoring_*_linux_amd64.tgz"
  "event_*_linux_amd64.tgz"
  "log_*_linux_amd64.tgz"
  "backup-manager_*_linux_amd64.tgz"
  "mcp_*_linux_amd64.tgz"
  "ai-memory_*_linux_amd64.tgz"
  "ai-watcher_*_linux_amd64.tgz"
  "ai-executor_*_linux_amd64.tgz"
  "ai-router_*_linux_amd64.tgz"
  "workflow_*_linux_amd64.tgz"
  "scylla-manager-agent_*_linux_amd64.tgz"
  "scylla-manager_*_linux_amd64.tgz"
  # ── Workload services ──────────────────────────────────────────────
  "file_*_linux_amd64.tgz"
  "blog_*_linux_amd64.tgz"
  "catalog_*_linux_amd64.tgz"
  "conversation_*_linux_amd64.tgz"
  "echo_*_linux_amd64.tgz"
  "ldap_*_linux_amd64.tgz"
  "mail_*_linux_amd64.tgz"
  "media_*_linux_amd64.tgz"
  "search_*_linux_amd64.tgz"
  "sql_*_linux_amd64.tgz"
  "storage_*_linux_amd64.tgz"
  "title_*_linux_amd64.tgz"
  "torrent_*_linux_amd64.tgz"
  # ── CLI tools ──────────────────────────────────────────────────────
  "globular-cli_*_linux_amd64.tgz"
  "etcdctl_*_linux_amd64.tgz"
  "mc_*_linux_amd64.tgz"
  "sctool_*_linux_amd64.tgz"
  "ffmpeg_*_linux_amd64.tgz"
  "yt-dlp_*_linux_amd64.tgz"
  "sha256sum_*_linux_amd64.tgz"
  "restic_*_linux_amd64.tgz"
  "rclone_*_linux_amd64.tgz"
)

# ── Step 1: Discover repository endpoint ─────────────────────────────────────

# Routable node IP — never loopback.
NODE_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

# Locate the CA cert. This script runs as root (via sudo), so root's home
# and /var/lib/globular/ are both accessible.
CA_CERT=""
DOMAIN=$(python3 -c "import json; d=json.load(open('${STATE_DIR}/config.json')); print(d.get('Domain','globular.internal'))" 2>/dev/null || echo "globular.internal")
for _ca in \
    /root/.config/globular/tls/${DOMAIN}/ca.crt \
    /root/.config/globular/tls/globular.internal/ca.crt \
    "${STATE_DIR}/pki/ca.crt" \
    "$REAL_HOME/.config/globular/tls/${DOMAIN}/ca.crt" \
    "$REAL_HOME/.config/globular/tls/globular.internal/ca.crt"; do
  if [[ -f "$_ca" && -r "$_ca" ]]; then
    CA_CERT="$_ca"
    break
  fi
done
if [[ -z "$CA_CERT" ]]; then
  log_warn "No readable CA cert found — cannot publish artifacts (TLS required)"
  exit 1
fi
log_info "Using CA cert: $CA_CERT"

if [[ -z "$REPO_ADDR" ]]; then
  log_info "Discovering repository service endpoint from etcd..."

  # etcd service records use UUIDs as keys — scan all entries and match by Name.
  # This is the authoritative source; never use hardcoded ports or gateway probing.
  REPO_ADDR=$(etcdctl \
      --endpoints="https://${NODE_IP}:2379" \
      --cacert="${STATE_DIR}/pki/ca.crt" \
      --cert="${STATE_DIR}/pki/issued/services/service.crt" \
      --key="${STATE_DIR}/pki/issued/services/service.key" \
      get /globular/services/ --prefix --print-value-only 2>/dev/null \
    | python3 -c "
import json, sys
dec = json.JSONDecoder()
buf = sys.stdin.read()
pos = 0
while pos < len(buf):
    while pos < len(buf) and buf[pos] in ' \t\r\n':
        pos += 1
    if pos >= len(buf):
        break
    try:
        d, end = dec.raw_decode(buf, pos)
        pos = end
        if d.get('Name') != 'repository.PackageRepository':
            continue
        addr = d.get('Address', '')
        port = int(d.get('Port', 0))
        host = addr.rsplit(':', 1)[0] if ':' in addr else addr
        if host and port:
            print(f'{host}:{port}')
            break
    except Exception:
        pos += 1
" 2>/dev/null || true)

  # Retry up to 5 times — the repository may still be registering with etcd.
  if [[ -z "$REPO_ADDR" ]]; then
    for _repo_attempt in $(seq 2 5); do
      sleep 3
      log_info "Repository not yet in etcd (attempt $_repo_attempt/5), retrying..."
      REPO_ADDR=$(etcdctl \
          --endpoints="https://${NODE_IP}:2379" \
          --cacert="${STATE_DIR}/pki/ca.crt" \
          --cert="${STATE_DIR}/pki/issued/services/service.crt" \
          --key="${STATE_DIR}/pki/issued/services/service.key" \
          get /globular/services/ --prefix --print-value-only 2>/dev/null \
        | python3 -c "
import json, sys
dec = json.JSONDecoder()
buf = sys.stdin.read()
pos = 0
while pos < len(buf):
    while pos < len(buf) and buf[pos] in ' \t\r\n':
        pos += 1
    if pos >= len(buf):
        break
    try:
        d, end = dec.raw_decode(buf, pos)
        pos = end
        if d.get('Name') != 'repository.PackageRepository':
            continue
        addr = d.get('Address', '')
        port = int(d.get('Port', 0))
        host = addr.rsplit(':', 1)[0] if ':' in addr else addr
        if host and port:
            print(f'{host}:{port}')
            break
    except Exception:
        pos += 1
" 2>/dev/null || true)
      [[ -n "$REPO_ADDR" ]] && break
    done
  fi

  if [[ -z "$REPO_ADDR" ]]; then
    log_warn "Repository service not found in etcd after 5 attempts"
    exit 1
  fi
fi

log_success "Repository endpoint: $REPO_ADDR"

# ── Step 2: Acquire auth token ───────────────────────────────────────────────

BOOTSTRAP_CRED_GLOBAL="/var/lib/globular/.bootstrap-sa-password"
if [[ -z "${GLOBULAR_PASSWORD}" && -f "$BOOTSTRAP_CRED_GLOBAL" && -r "$BOOTSTRAP_CRED_GLOBAL" ]]; then
  GLOBULAR_PASSWORD=$(cat "$BOOTSTRAP_CRED_GLOBAL")
fi

if [[ -z "${GLOBULAR_TOKEN}" ]]; then
  if [[ -z "${GLOBULAR_PASSWORD}" ]]; then
    log_fail "bootstrap password file missing: $BOOTSTRAP_CRED_GLOBAL"
    exit 1
  fi

  # Run as root (EUID=0 since script is invoked via sudo bash).
  # Root can read /var/lib/globular/pki/ and /root/.config/globular/.
  log_info "Logging in as $GLOBULAR_USER..."
  TOKEN_FILE="/root/.config/globular/token"
  for _auth_attempt in $(seq 1 3); do
    LOGIN_OUT=$("$GLOBULAR_CLI" --ca "$CA_CERT" auth login \
      --user "$GLOBULAR_USER" \
      --password "$GLOBULAR_PASSWORD" 2>&1) || true

    # Check for token in file.
    if [[ -f "$TOKEN_FILE" ]]; then
      GLOBULAR_TOKEN=$(cat "$TOKEN_FILE")
      [[ -n "$GLOBULAR_TOKEN" ]] && break
    fi

    # Fallback: also check /root in case CLI wrote it there.
    if [[ -z "${GLOBULAR_TOKEN}" && -f "/root/.config/globular/token" ]]; then
      GLOBULAR_TOKEN=$(cat "/root/.config/globular/token")
      [[ -n "$GLOBULAR_TOKEN" ]] && break
    fi

    # Fallback: parse the token directly from CLI output.
    if [[ -z "${GLOBULAR_TOKEN}" ]]; then
      PARSED_TOKEN=$(echo "$LOGIN_OUT" | grep -oP '^Token: \K\S+' || true)
      if [[ -n "$PARSED_TOKEN" ]]; then
        GLOBULAR_TOKEN="$PARSED_TOKEN"
        break
      fi
    fi

    log_info "Auth not ready (attempt $_auth_attempt/3), retrying..."
    sleep 3
  done

  if [[ -z "${GLOBULAR_TOKEN}" ]]; then
    log_warn "Failed to acquire auth token after 3 attempts: $LOGIN_OUT"
    log_warn "Publish requires authentication — skipping artifact publish"
    exit 1
  fi

  log_success "Auth token acquired"
fi

# ── Step 3: Publish each core package ────────────────────────────────────────

# Extract a human-readable name and version from the .tgz filename.
# e.g. "etcd_3.5.14_linux_amd64.tgz" → name="etcd" version="3.5.14"
# Handles hyphenated names like "scylla-manager_3.8.1_linux_amd64.tgz"
parse_pkg_label() {
  local base="$1"
  base="${base%.tgz}"                         # strip .tgz
  base="${base%_linux_*}"                     # strip _linux_amd64
  # Split on last _ to separate name from version
  local version="${base##*_}"                 # version = after last _
  local name="${base%_*}"                     # name = before last _
  echo "${name} ${version}"
}

PUBLISHED=0
SKIPPED=0
FAILED=0
TOTAL=0
FAILED_LIST=""

# Local state file: maps entrypoint_checksum → 1 for each successfully published binary.
# This is the idempotency key — the repository assigns its own version counter (0.0.x)
# and has no dedup by content. Without this, every run creates a new version entry.
PUBLISHED_CHECKSUMS_FILE="${STATE_DIR}/.bootstrap-artifacts-checksums"
declare -A PUBLISHED_CHECKSUMS
if [[ -f "$PUBLISHED_CHECKSUMS_FILE" ]]; then
  while IFS= read -r _cs; do
    [[ -n "$_cs" ]] && PUBLISHED_CHECKSUMS["$_cs"]=1
  done < "$PUBLISHED_CHECKSUMS_FILE"
fi

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

  # Refresh token every 10 packages to avoid expiry mid-run.
  if (( TOTAL % 10 == 0 )); then
    _fresh=$("$GLOBULAR_CLI" --ca "$CA_CERT" auth login \
      --user "$GLOBULAR_USER" --password "$GLOBULAR_PASSWORD" 2>/dev/null \
      | grep "^Token:" | sed 's/^Token: //' || true)
    [[ -n "$_fresh" ]] && GLOBULAR_TOKEN="$_fresh"
  fi

  # Idempotency: extract the entrypoint_checksum from the package and skip
  # if we've already successfully published this exact binary.
  PKG_CHECKSUM=$(tar xOf "$PACKAGE" ./package.json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('entrypoint_checksum',''))" 2>/dev/null || true)

  if [[ -n "$PKG_CHECKSUM" && -n "${PUBLISHED_CHECKSUMS[$PKG_CHECKSUM]+x}" ]]; then
    log_success "$(printf '%-28s %s (already present)' "$SVC_NAME" "$SVC_VER")"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Publish — no --force so the repository doesn't bump the version counter
  # if the binary is already there under a different version label.
  PUBLISH_ERR_FILE="/tmp/publish-err-$$.log"
  PUBLISH_JSON=$("$GLOBULAR_CLI" --ca "$CA_CERT" --timeout 60s --token "$GLOBULAR_TOKEN" pkg publish \
    --file "$PACKAGE" \
    --repository "$REPO_ADDR" \
    --output json 2>"$PUBLISH_ERR_FILE") || true

  # Parse status and descriptor_action from JSON response.
  read -r STATUS DESC_ACTION < <(echo "$PUBLISH_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('status',''), data.get('descriptor_action',''))
except:
    print('', '')
" 2>/dev/null || echo " ")

  if [[ "$STATUS" == "success" ]]; then
    if [[ "$DESC_ACTION" == "unchanged" || "$DESC_ACTION" == "skipped" ]]; then
      log_success "$(printf '%-28s %s (already present)' "$SVC_NAME" "$SVC_VER")"
      SKIPPED=$((SKIPPED + 1))
    else
      log_success "$(printf '%-28s %s (published)' "$SVC_NAME" "$SVC_VER")"
      PUBLISHED=$((PUBLISHED + 1))
    fi
    # Record checksum so re-runs skip this binary.
    if [[ -n "$PKG_CHECKSUM" ]]; then
      PUBLISHED_CHECKSUMS["$PKG_CHECKSUM"]=1
      echo "$PKG_CHECKSUM" >> "$PUBLISHED_CHECKSUMS_FILE"
    fi
  else
    # Check for "already exists" style errors in the raw output
    if echo "$PUBLISH_JSON $DESC_ACTION" | grep -qiE "already exists|duplicate|conflict|unchanged|skipped"; then
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

# ── Step 4: Register upstream source (provider-neutral) ──────────────────────
#
# Registers the configured upstream source for Day-1+ sync operations.
# Default: globulario GitHub Releases. Override via GLOBULAR_UPSTREAM_* env vars.
#
# Primary path: globular repo register-upstream (RegisterUpstream RPC).
#   Uses the same code path as Day-1 operators. Supports all provider types:
#   github, http, local-dir, git. RegisterUpstream is an upsert — idempotent.
#
# Fallback path: direct etcd write with provider-neutral JSON.
#   Used only when the CLI fails (e.g. transient repository unavailability).
#
# This step is non-fatal: Day-0 service start does not depend on upstream
# registration. The upstream is metadata for Day-1+ sync operations.

# ── Provider-neutral upstream configuration ──────────────────────────────────
# Supports: github (default), http, local-dir, git via environment variables.
# Environment:
#   GLOBULAR_UPSTREAM_TYPE       — github|http|local-dir|git (default: github)
#   GLOBULAR_UPSTREAM_NAME       — source name (default: globulario-github)
#   GLOBULAR_UPSTREAM_URL        — index URL with {tag} template
#   GLOBULAR_UPSTREAM_REPO_URL   — Git repo URL or GitHub owner/repo
#   GLOBULAR_UPSTREAM_BRANCH     — Git branch (GIT_INDEX)
#   GLOBULAR_UPSTREAM_INDEX_PATH — index path template (GIT_INDEX, LOCAL_DIR)
#   GLOBULAR_UPSTREAM_ARTIFACT_BASE_URL — artifact download base URL
#   GLOBULAR_UPSTREAM_LOCAL_ROOT — local root (LOCAL_DIR)
#   GLOBULAR_UPSTREAM_CHANNEL    — release channel (default: stable)
#   GLOBULAR_UPSTREAM_PLATFORM   — platform (default: linux_amd64)

UPSTREAM_TYPE="${GLOBULAR_UPSTREAM_TYPE:-github}"
UPSTREAM_NAME="${GLOBULAR_UPSTREAM_NAME:-globulario-github}"
UPSTREAM_URL="${GLOBULAR_UPSTREAM_URL:-https://github.com/globulario/services/releases/download/{tag}/release-index.json}"
UPSTREAM_CHANNEL="${GLOBULAR_UPSTREAM_CHANNEL:-stable}"
UPSTREAM_PLATFORM="${GLOBULAR_UPSTREAM_PLATFORM:-linux_amd64}"
UPSTREAM_KEY="/globular/repository/upstreams/${UPSTREAM_NAME}"

# Build CLI flags based on provider type.
CLI_FLAGS=(
  --name "$UPSTREAM_NAME"
  --type "$UPSTREAM_TYPE"
  --channel "$UPSTREAM_CHANNEL"
  --platform "$UPSTREAM_PLATFORM"
)

case "$UPSTREAM_TYPE" in
  github)
    CLI_FLAGS+=(--url "$UPSTREAM_URL")
    if [[ -n "${GLOBULAR_UPSTREAM_REPO_URL:-}" ]]; then
      CLI_FLAGS+=(--repo-url "$GLOBULAR_UPSTREAM_REPO_URL")
    fi
    ;;
  http)
    CLI_FLAGS+=(--url "$UPSTREAM_URL")
    if [[ -n "${GLOBULAR_UPSTREAM_ARTIFACT_BASE_URL:-}" ]]; then
      CLI_FLAGS+=(--artifact-base-url "$GLOBULAR_UPSTREAM_ARTIFACT_BASE_URL")
    fi
    ;;
  local-dir)
    if [[ -n "${GLOBULAR_UPSTREAM_LOCAL_ROOT:-}" ]]; then
      CLI_FLAGS+=(--local-root "$GLOBULAR_UPSTREAM_LOCAL_ROOT")
    fi
    if [[ -n "${GLOBULAR_UPSTREAM_INDEX_PATH:-}" ]]; then
      CLI_FLAGS+=(--index-path "$GLOBULAR_UPSTREAM_INDEX_PATH")
    fi
    ;;
  git)
    if [[ -n "${GLOBULAR_UPSTREAM_REPO_URL:-}" ]]; then
      CLI_FLAGS+=(--repo-url "$GLOBULAR_UPSTREAM_REPO_URL")
    fi
    if [[ -n "${GLOBULAR_UPSTREAM_BRANCH:-}" ]]; then
      CLI_FLAGS+=(--branch "$GLOBULAR_UPSTREAM_BRANCH")
    fi
    if [[ -n "${GLOBULAR_UPSTREAM_INDEX_PATH:-}" ]]; then
      CLI_FLAGS+=(--index-path "$GLOBULAR_UPSTREAM_INDEX_PATH")
    fi
    if [[ -n "${GLOBULAR_UPSTREAM_ARTIFACT_BASE_URL:-}" ]]; then
      CLI_FLAGS+=(--artifact-base-url "$GLOBULAR_UPSTREAM_ARTIFACT_BASE_URL")
    fi
    ;;
esac

# Primary path: RegisterUpstream RPC via CLI.
UPSTREAM_CLI_OUT=$("$GLOBULAR_CLI" \
    --ca "$CA_CERT" \
    --timeout 30s \
    --token "$GLOBULAR_TOKEN" \
    repo register-upstream "${CLI_FLAGS[@]}" 2>&1) && _upstream_ok=true || _upstream_ok=false

if $_upstream_ok; then
  log_success "Upstream source '${UPSTREAM_NAME}' registered (type: ${UPSTREAM_TYPE})"
else
  # Fallback: direct etcd write using protojson-compatible schema.
  log_warn "CLI registration failed (${UPSTREAM_CLI_OUT}); falling back to direct etcd write"

  # Build provider-neutral JSON.
  UPSTREAM_JSON=$(python3 -c "
import json, os
d = {
    'name': '${UPSTREAM_NAME}',
    'type': '${UPSTREAM_TYPE}'.upper().replace('-','_').replace('GITHUB','GITHUB_RELEASE').replace('HTTP','HTTP_INDEX').replace('LOCAL_DIR','LOCAL_DIR').replace('GIT','GIT_INDEX'),
    'indexUrl': '${UPSTREAM_URL}',
    'channel': '${UPSTREAM_CHANNEL}',
    'platform': '${UPSTREAM_PLATFORM}',
    'enabled': True,
}
for k, ek in [('repoUrl','GLOBULAR_UPSTREAM_REPO_URL'),('branch','GLOBULAR_UPSTREAM_BRANCH'),
              ('indexPathTemplate','GLOBULAR_UPSTREAM_INDEX_PATH'),
              ('artifactBaseUrl','GLOBULAR_UPSTREAM_ARTIFACT_BASE_URL'),
              ('localRoot','GLOBULAR_UPSTREAM_LOCAL_ROOT')]:
    v = os.environ.get(ek, '')
    if v:
        d[k] = v
print(json.dumps(d))
" 2>/dev/null)

  if etcdctl \
      --endpoints="https://${NODE_IP}:2379" \
      --cacert="${STATE_DIR}/pki/ca.crt" \
      --cert="${STATE_DIR}/pki/issued/services/service.crt" \
      --key="${STATE_DIR}/pki/issued/services/service.key" \
      put "$UPSTREAM_KEY" "$UPSTREAM_JSON" > /dev/null 2>&1; then
    log_success "Upstream source '${UPSTREAM_NAME}' registered (etcd fallback, type: ${UPSTREAM_TYPE})"
  else
    log_warn "Failed to register upstream source '${UPSTREAM_NAME}' (non-fatal)"
  fi
fi

# ── Step 5: Sync packages from configured upstream using active release BOM ───
#
# After registering the upstream, perform an immediate sync so the local
# repository catalog reflects the versions from the active platform release.
#
# The release tag is read from release-index.json (the BOM included in the
# installer bundle). This is the authoritative source — NOT package filenames
# (which have mixed versions in the BOM model) and NOT GitHub (which is just
# one possible provider).
#
# Uses `globular repo sync` (direct repository RPC) rather than
# `globular pkg sync-upstream` (workflow). At Day-0, the WorkflowService
# and ClusterController may not yet be registered in etcd.
#
# This step is non-fatal: if sync fails (e.g. no network, upstream unreachable),
# Day-0 completes with locally published artifacts. The operator can retry:
#   globular repo sync --source <name> --tag <tag>

SYNC_TAG=""

# ── Detect release tag from release-index.json (BOM model) ─────────────────
# The release-index.json included in the installer bundle is the authoritative
# source for the platform release tag. Do NOT infer from package filenames —
# with the BOM model, packages have mixed versions that do not match the
# platform release.

RELEASE_INDEX=""
for _ri in \
    "$PKG_DIR/../release-index.json" \
    "$PKG_DIR/../../release-index.json" \
    "${SCRIPT_DIR}/../release-index.json" \
    "${SCRIPT_DIR}/../../release-index.json"; do
  if [[ -f "$_ri" ]]; then
    RELEASE_INDEX="$(cd "$(dirname "$_ri")" && pwd)/$(basename "$_ri")"
    break
  fi
done

if [[ -n "$RELEASE_INDEX" ]]; then
  SYNC_TAG=$(python3 -c "
import json, sys
try:
    idx = json.load(open('${RELEASE_INDEX}'))
    print(idx.get('release_tag', ''))
except Exception:
    print('')
" 2>/dev/null || true)
  if [[ -n "$SYNC_TAG" ]]; then
    log_success "Release tag from release-index.json: $SYNC_TAG"
  fi
fi

# Fallback: explicit env var.
if [[ -z "$SYNC_TAG" && -n "${GLOBULAR_RELEASE_TAG:-}" ]]; then
  SYNC_TAG="$GLOBULAR_RELEASE_TAG"
  log_info "Release tag from GLOBULAR_RELEASE_TAG: $SYNC_TAG"
fi

# Legacy fallback: infer from package filenames (deprecated — BOM model makes this unreliable).
if [[ -z "$SYNC_TAG" ]]; then
  for _pkg_file in "$PKG_DIR"/cluster-controller_*_linux_amd64.tgz \
                    "$PKG_DIR"/repository_*_linux_amd64.tgz \
                    "$PKG_DIR"/node-agent_*_linux_amd64.tgz; do
    [[ -f "$_pkg_file" ]] || continue
    _base=$(basename "$_pkg_file")
    _ver=$(echo "$_base" | sed -E 's/^.+_([0-9]+\.[0-9]+\.[0-9]+)_linux_amd64\.tgz$/\1/')
    if [[ "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      SYNC_TAG="v${_ver}"
      log_warn "Release tag inferred from filename (legacy): $SYNC_TAG"
      log_warn "Include release-index.json in the installer bundle to avoid this."
      break
    fi
  done
fi

if [[ -z "$SYNC_TAG" ]]; then
  log_warn "Could not detect release tag — skipping upstream sync"
  log_warn "Run 'globular repo sync --source <name> --tag <tag>' manually"
else
  log_info "Syncing packages from upstream '${UPSTREAM_NAME}' @ ${SYNC_TAG} (direct)..."
  # `repo sync` calls SyncFromUpstream directly on the repository service —
  # no WorkflowService or ClusterController required.
  SYNC_OUT=$("$GLOBULAR_CLI" \
      --ca "$CA_CERT" \
      --timeout 300s \
      --token "$GLOBULAR_TOKEN" \
      repo sync \
      --source "$UPSTREAM_NAME" \
      --tag "$SYNC_TAG" 2>&1) && _sync_ok=true || _sync_ok=false

  if $_sync_ok; then
    log_success "Upstream sync completed: ${SYNC_TAG}"
    echo "$SYNC_OUT" | grep -E "^(Imported|Skipped)" | while IFS= read -r line; do
      log_info "  $line"
    done
  else
    log_warn "Upstream sync failed (non-fatal): ${SYNC_OUT}"
    log_warn "Retry: globular repo sync --source ${UPSTREAM_NAME} --tag ${SYNC_TAG}"
    log_warn "Day-0 continues with locally published artifacts."
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
log_info "Artifact publish: $TOTAL total, $PUBLISHED new, $SKIPPED existing, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
  log_warn "Failed:$FAILED_LIST"
  exit 1
fi

exit 0
