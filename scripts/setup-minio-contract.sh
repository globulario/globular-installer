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

# Try to read real credentials from MinIO's environment file if not provided
if [ -z "${MINIO_ACCESS_KEY}" ] && [ -f "/var/lib/globular/minio/minio.env" ]; then
    MINIO_ACCESS_KEY=$(grep MINIO_ROOT_USER /var/lib/globular/minio/minio.env 2>/dev/null | cut -d= -f2 | tr -d ' ')
    MINIO_SECRET_KEY=$(grep MINIO_ROOT_PASSWORD /var/lib/globular/minio/minio.env 2>/dev/null | cut -d= -f2 | tr -d ' ')
    if [ -n "$MINIO_ACCESS_KEY" ] && [ -n "$MINIO_SECRET_KEY" ]; then
        log "Using credentials from MinIO environment file"
    fi
fi

# Fallback to defaults if still not found
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"

CONTRACT_DIR="/var/lib/globular/objectstore"
CONTRACT_FILE="$CONTRACT_DIR/minio.json"
CRED_DIR="/var/lib/globular/minio"
CRED_FILE="$CRED_DIR/credentials.txt"

# Create directories
create_dirs() {
    log "Creating directories..."

    if ! mkdir -p "$CONTRACT_DIR" 2>/dev/null; then
        sudo mkdir -p "$CONTRACT_DIR" || die "Failed to create $CONTRACT_DIR"
        sudo chown globular:globular "$CONTRACT_DIR" || log "Warning: Could not chown $CONTRACT_DIR"
    fi

    if ! mkdir -p "$CRED_DIR" 2>/dev/null; then
        sudo mkdir -p "$CRED_DIR" || die "Failed to create $CRED_DIR"
        sudo chown globular:globular "$CRED_DIR" || log "Warning: Could not chown $CRED_DIR"
    fi
}

# Create credentials file
create_credentials() {
    log "Creating credentials file..."

    local cred_content="${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}"
    local temp_cred
    temp_cred="$(mktemp)"

    echo "$cred_content" > "$temp_cred"
    chmod 600 "$temp_cred"

    if ! mv "$temp_cred" "$CRED_FILE" 2>/dev/null; then
        sudo mv "$temp_cred" "$CRED_FILE" || die "Failed to create $CRED_FILE"
        sudo chown globular:globular "$CRED_FILE" || log "Warning: Could not chown $CRED_FILE"
        sudo chmod 600 "$CRED_FILE" || log "Warning: Could not chmod $CRED_FILE"
    fi

    log "Created credentials file at $CRED_FILE"
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
    "credFile": "${CRED_FILE}"
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

    create_dirs
    create_credentials
    create_contract
    verify_contract

    log ""
    log "MinIO contract setup completed successfully!"
    log "Contract file: $CONTRACT_FILE"
    log "Credentials file: $CRED_FILE"
    log ""
    log "Node-agent will now automatically create domain-scoped buckets at Day-0"
}

main "$@"
