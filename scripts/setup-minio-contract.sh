#!/usr/bin/env bash
set -euo pipefail

# MinIO Contract File Generator for Globular
# Creates the MinIO contract file that node-agent and gateway use

log() { echo "[minio-contract] $*"; }
die() { echo "[minio-contract] ERROR: $*" >&2; exit 1; }

# Configuration
MINIO_ENDPOINT="${MINIO_ENDPOINT:-127.0.0.1:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-globular}"
MINIO_SECURE="${MINIO_SECURE:-false}"

CONTRACT_DIR="/var/lib/globular/objectstore"
CONTRACT_FILE="$CONTRACT_DIR/minio.json"

# SINGLE SOURCE OF TRUTH: MinIO package creates this file
# This script does NOT create credentials - it only references them
CRED_FILE="/var/lib/globular/minio/credentials"

# Create directories
create_dirs() {
    log "Creating directories..."

    if ! mkdir -p "$CONTRACT_DIR" 2>/dev/null; then
        sudo mkdir -p "$CONTRACT_DIR" || die "Failed to create $CONTRACT_DIR"
        sudo chown globular:globular "$CONTRACT_DIR" || log "Warning: Could not chown $CONTRACT_DIR"
    fi
}

# Verify credentials file exists (created by MinIO package)
verify_credentials() {
    log "Verifying credentials file..."

    if [ ! -f "$CRED_FILE" ]; then
        log "ERROR: Credentials file not found at $CRED_FILE"
        log "The MinIO package should have created this file during installation."
        log ""
        log "To fix manually:"
        log "  echo 'globular:globularadmin' | sudo tee $CRED_FILE"
        log "  sudo chmod 600 $CRED_FILE"
        log "  sudo chown globular:globular $CRED_FILE"
        die "Credentials file missing"
    fi

    log "Found credentials file at $CRED_FILE"
}

# Create contract file
create_contract() {
    log "Creating MinIO contract file..."

    local temp_contract
    temp_contract="$(mktemp)"

    cat > "$temp_contract" <<EOF
{
  "type": "minio",
  "endpoint": "${MINIO_ENDPOINT}",
  "bucket": "${MINIO_BUCKET}",
  "prefix": "",
  "secure": ${MINIO_SECURE},
  "caBundlePath": "",
  "auth": {
    "mode": "file",
    "credFile": "/var/lib/globular/minio/credentials"
  }
}
EOF

    if ! mv "$temp_contract" "$CONTRACT_FILE" 2>/dev/null; then
        sudo mv "$temp_contract" "$CONTRACT_FILE" || die "Failed to create $CONTRACT_FILE"
        sudo chown globular:globular "$CONTRACT_FILE" || log "Warning: Could not chown $CONTRACT_FILE"
        sudo chmod 644 "$CONTRACT_FILE" || log "Warning: Could not chmod $CONTRACT_FILE"
    fi

    log "Created contract file at $CONTRACT_FILE"
}

# Verify contract
verify_contract() {
    log "Verifying contract file..."

    if [ ! -f "$CONTRACT_FILE" ]; then
        die "Contract file not found at $CONTRACT_FILE"
    fi

    if [ ! -f "$CRED_FILE" ]; then
        die "Credentials file not found at $CRED_FILE"
    fi

    # Validate JSON
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$CONTRACT_FILE" 2>/dev/null; then
            die "Contract file is not valid JSON"
        fi
    fi

    log "Contract file verified successfully"
}

# Main
main() {
    log "Setting up MinIO contract for Globular..."
    log "Endpoint: $MINIO_ENDPOINT"
    log "Bucket: $MINIO_BUCKET"
    log "Secure: $MINIO_SECURE"
    log "Credentials source: $CRED_FILE (provided by MinIO package)"

    create_dirs
    verify_credentials
    create_contract
    verify_contract

    log ""
    log "MinIO contract setup completed successfully!"
    log "Contract file: $CONTRACT_FILE"
    log "Credentials: $CRED_FILE (owned by MinIO service)"
    log ""
    log "Node-agent will now automatically create domain-scoped buckets at Day-0"
}

main "$@"
