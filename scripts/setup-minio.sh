#!/usr/bin/env bash
set -euo pipefail

# MinIO Setup Script for Globular Installer
# Uses the MinIO contract + credentials file to provision the single bucket with domain-scoped prefixes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_WEBROOT="$INSTALLER_ROOT/internal/assets/webroot"

CONTRACT_FILE="/var/lib/globular/objectstore/minio.json"
CRED_FILE="/var/lib/globular/minio/credentials"
MC_CONFIG_DIR="/var/lib/globular/minio/mc"
DOMAIN="${GLOBULAR_DOMAIN:-${DOMAIN:-localhost}}"

# MinIO client binary location (try installed location first, then PATH)
PREFIX="${PREFIX:-/usr/lib/globular}"
if [[ -x "${PREFIX}/bin/mc" ]]; then
    MC_BIN="${PREFIX}/bin/mc"
elif [[ -x "/home/dave/Documents/github.com/globulario/packages/bin/mc" ]]; then
    # Fallback to development location
    MC_BIN="/home/dave/Documents/github.com/globulario/packages/bin/mc"
elif command -v mc >/dev/null 2>&1; then
    MC_BIN="$(command -v mc)"
else
    MC_BIN=""
fi

MAX_RETRIES=30
RETRY_DELAY=2

log() { echo "[minio-setup] $*"; }
die() { echo "[minio-setup] ERROR: $*" >&2; exit 1; }

require_file() {
    local path="$1" description="$2"
    if [[ ! -f "$path" ]]; then
        die "$description not found: $path"
    fi
}

parse_contract_with_jq() {
    local key="$1"
    jq -r "$key // empty" "$CONTRACT_FILE" 2>/dev/null || true
}

load_contract() {
    require_file "$CONTRACT_FILE" "Contract file"
    if ! command -v jq >/dev/null 2>&1; then
        die "jq is required to read contract file $CONTRACT_FILE"
    fi

    local bucket secure
    bucket="$(parse_contract_with_jq '.bucket')"
    secure="$(parse_contract_with_jq '.secure')"

    MINIO_ENDPOINT="127.0.0.1:9000"
    MINIO_BUCKET="${bucket:-${MINIO_BUCKET:-globular}}"
    MINIO_SECURE="${secure:-${MINIO_SECURE:-false}}"

    if [[ -z "$MINIO_BUCKET" ]]; then
        die "Contract did not provide bucket (contract: $CONTRACT_FILE)"
    fi
}

wait_for_minio() {
    local host port retries=0
    host="${MINIO_ENDPOINT%%:*}"
    port="${MINIO_ENDPOINT##*:}"

    log "Waiting for MinIO to be ready at $MINIO_ENDPOINT..."
    while [[ $retries -lt $MAX_RETRIES ]]; do
        if nc -z -w2 "$host" "$port" 2>/dev/null; then
            if curl -sf "http://${host}:${port}/minio/health/ready" >/dev/null 2>&1; then
                log "MinIO health endpoint is responding"

                # Wait for IAM subsystem to initialize
                local iam_retries=0
                while [[ $iam_retries -lt 15 ]]; do
                    if run_mc ls local 2>&1 | grep -qv "IAM sub-system not initialized"; then
                        log "MinIO IAM subsystem is ready"
                        return 0
                    fi
                    iam_retries=$((iam_retries + 1))
                    log "Waiting for MinIO IAM subsystem... (attempt $iam_retries/15)"
                    sleep 2
                done

                log "MinIO is healthy"
                return 0
            fi
        fi
        retries=$((retries + 1))
        log "MinIO not ready yet (attempt $retries/$MAX_RETRIES)..."
        sleep $RETRY_DELAY
    done

    die "MinIO did not become ready after $MAX_RETRIES attempts"
}

run_mc() {
    sudo -u globular bash -lc '
        set -euo pipefail
        MC_BIN="$1"; CRED_FILE="$2"; CONFIG_DIR="$3"; shift 3
        if [[ ! -x "$MC_BIN" ]]; then
            echo "[minio-setup] ERROR: mc binary not found or not executable: $MC_BIN" >&2
            exit 1
        fi
        if [[ ! -f "$CRED_FILE" ]]; then
            echo "[minio-setup] ERROR: credentials not found: $CRED_FILE" >&2
            exit 1
        fi
        AK=$(cut -d: -f1 "$CRED_FILE")
        SK=$(cut -d: -f2- "$CRED_FILE")
        if [[ -z "$AK" || -z "$SK" ]]; then
            echo "[minio-setup] ERROR: invalid credentials in $CRED_FILE" >&2
            exit 1
        fi
        export MC_CONFIG_DIR="$CONFIG_DIR"
        "$MC_BIN" alias set local "http://127.0.0.1:9000" "$AK" "$SK" --api S3v4 >/dev/null
        "$MC_BIN" "$@"
    ' bash "$MC_BIN" "$CRED_FILE" "$MC_CONFIG_DIR" "$@"
}

ensure_bucket() {
    local attempts=0 max_attempts=20
    while [[ $attempts -lt $max_attempts ]]; do
        if run_mc ls "local/${MINIO_BUCKET}" >/dev/null 2>&1; then
            log "Bucket '$MINIO_BUCKET' already exists"
            return 0
        fi
        attempts=$((attempts + 1))
        if out="$(run_mc mb "local/${MINIO_BUCKET}" 2>&1)"; then
            log "Created bucket '$MINIO_BUCKET'"
            return 0
        fi
        log "Bucket create attempt ${attempts}/${max_attempts} failed: $out"
        sleep 2
    done
    die "Failed to create bucket $MINIO_BUCKET after ${max_attempts} attempts"
}

setup_with_mc() {
    log "Using MinIO Client (mc) for setup"

    # Create bucket first
    ensure_bucket

    # Quick writability probe after bucket is created
    local probe="local/${MINIO_BUCKET}/${DOMAIN}/webroot/.writetest"
    if ! printf '' | run_mc pipe "$probe" >/dev/null 2>&1; then
        log "MinIO not writable at $probe; recent globular-minio logs:"
        journalctl -u globular-minio --no-pager -n 50 || true
        die "MinIO is not writable; check service permissions and storage"
    else
        run_mc rm "$probe" >/dev/null 2>&1 || true
    fi

    local base="local/${MINIO_BUCKET}/${DOMAIN}"
    printf '' | run_mc pipe "${base}/webroot/.keep" >/dev/null || die "Failed to create sentinel ${base}/webroot/.keep"
    printf '' | run_mc pipe "${base}/users/.keep" >/dev/null || die "Failed to create sentinel ${base}/users/.keep"

    # Upload files: cat runs as root (can read files), pipe to mc running as globular
    if [[ -f "$ASSETS_WEBROOT/index.html" ]]; then
        log "Uploading index.html..."
        cat "$ASSETS_WEBROOT/index.html" | run_mc pipe "${base}/webroot/index.html" || die "Failed to upload index.html"
        log "Uploaded index.html to ${base}/webroot/index.html"
    else
        die "index.html not found at $ASSETS_WEBROOT/index.html"
    fi

    if [[ -f "$ASSETS_WEBROOT/logo.png" ]]; then
        log "Uploading logo.png..."
        cat "$ASSETS_WEBROOT/logo.png" | run_mc pipe "${base}/webroot/logo.png" || die "Failed to upload logo.png"
        log "Uploaded logo.png to ${base}/webroot/logo.png"
    else
        die "logo.png not found at $ASSETS_WEBROOT/logo.png"
    fi

    if [[ -f "$ASSETS_WEBROOT/style.css" ]]; then
        log "Uploading style.css..."
        cat "$ASSETS_WEBROOT/style.css" | run_mc pipe "${base}/webroot/style.css" || die "Failed to upload style.css"
        log "Uploaded style.css to ${base}/webroot/style.css"
    else
        die "style.css not found at $ASSETS_WEBROOT/style.css"
    fi

    run_mc ls "local/${MINIO_BUCKET}" >/dev/null 2>&1 || die "Bucket $MINIO_BUCKET not reachable after creation"
    run_mc stat "${base}/webroot/index.html" >/dev/null 2>&1 || die "index.html missing at ${base}/webroot/index.html"
}

main() {
    load_contract
    require_file "$CRED_FILE" "Credentials file"

    log "Starting MinIO setup..."
    log "Endpoint: $MINIO_ENDPOINT (secure: $MINIO_SECURE)"
    log "Bucket: $MINIO_BUCKET"
    log "Domain prefix: $DOMAIN"
    log "Contract file: $CONTRACT_FILE"
    log "Credentials file: $CRED_FILE"
    log "Assets directory: $ASSETS_WEBROOT"

    mkdir -p "$MC_CONFIG_DIR"
    chown globular:globular "$MC_CONFIG_DIR" || true
    chmod 0700 "$MC_CONFIG_DIR" || true

    wait_for_minio

    if [[ -z "$MC_BIN" ]]; then
        die "MinIO client 'mc' is required for Day-0 provisioning but not found.\nExpected at: ${PREFIX}/bin/mc\nEnsure the MinIO package includes the mc binary and has been properly installed."
    fi

    log "Using mc binary: $MC_BIN"
    setup_with_mc

    log "MinIO setup completed successfully"
    log "Verify via: mc ls or curl http://${MINIO_ENDPOINT}/${MINIO_BUCKET}/${DOMAIN}/webroot/index.html"
}

main "$@"
