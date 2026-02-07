#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
CRED_FILE="${STATE_DIR}/minio/credentials"
CA_CERT="${STATE_DIR}/pki/ca.pem"
CONTRACT_FILE="${STATE_DIR}/objectstore/minio.json"

echo "[ensure-minio-buckets] Ensuring MinIO buckets exist..."

# Wait for MinIO to be ready
MAX_WAIT=30
WAITED=0
while ! systemctl is-active --quiet globular-minio.service && [ $WAITED -lt $MAX_WAIT ]; do
    echo "[ensure-minio-buckets] Waiting for MinIO to start... ($WAITED/$MAX_WAIT)"
    sleep 1
    WAITED=$((WAITED + 1))
done

if ! systemctl is-active --quiet globular-minio.service; then
    echo "[ensure-minio-buckets] ERROR: MinIO service not running" >&2
    exit 1
fi

# Additional wait for MinIO to be fully ready
sleep 2

# Read credentials
if [[ ! -f "${CRED_FILE}" ]]; then
    echo "[ensure-minio-buckets] ERROR: Credentials file not found: ${CRED_FILE}" >&2
    exit 1
fi

if ! IFS=":" read -r ACCESS_KEY SECRET_KEY < "${CRED_FILE}"; then
    echo "[ensure-minio-buckets] ERROR: Cannot read credentials from ${CRED_FILE}" >&2
    exit 1
fi

# Configure mc client
export MC_HOST_local="https://${ACCESS_KEY}:${SECRET_KEY}@127.0.0.1:9000"
MC_CONFIG_DIR="${HOME}/.mc"
mkdir -p "${MC_CONFIG_DIR}/certs/CAs"

# Copy CA certificate for mc
if [[ -f "${CA_CERT}" ]]; then
    cp "${CA_CERT}" "${MC_CONFIG_DIR}/certs/CAs/" 2>/dev/null || true
fi

# Test MinIO connection with retries
MAX_RETRIES=10
for i in $(seq 1 $MAX_RETRIES); do
    if mc admin info local/ >/dev/null 2>&1; then
        echo "[ensure-minio-buckets] MinIO connection successful"
        break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
        echo "[ensure-minio-buckets] ERROR: Cannot connect to MinIO after $MAX_RETRIES attempts" >&2
        exit 1
    fi
    echo "[ensure-minio-buckets] Waiting for MinIO to be ready... (attempt $i/$MAX_RETRIES)"
    sleep 2
done

# Read bucket name and prefix from contract
BUCKET_NAME="globular"
PREFIX=""
if [[ -f "${CONTRACT_FILE}" ]]; then
    BUCKET_FROM_CONTRACT=$(python3 -c "import json; print(json.load(open('${CONTRACT_FILE}'))['bucket'])" 2>/dev/null || echo "globular")
    if [[ -n "${BUCKET_FROM_CONTRACT}" ]]; then
        BUCKET_NAME="${BUCKET_FROM_CONTRACT}"
    fi
    PREFIX=$(python3 -c "import json; print(json.load(open('${CONTRACT_FILE}'))['prefix'])" 2>/dev/null || echo "")
fi

echo "[ensure-minio-buckets] Ensuring bucket '${BUCKET_NAME}' exists..."

# Check if bucket exists
if mc ls "local/${BUCKET_NAME}/" >/dev/null 2>&1; then
    echo "[ensure-minio-buckets] Bucket '${BUCKET_NAME}' already exists"
else
    echo "[ensure-minio-buckets] Creating bucket '${BUCKET_NAME}'..."
    mc mb "local/${BUCKET_NAME}"
    echo "[ensure-minio-buckets] ✓ Bucket '${BUCKET_NAME}' created"
fi

# Set bucket policy to public read
echo "[ensure-minio-buckets] Setting public read policy on '${BUCKET_NAME}'..."
mc anonymous set download "local/${BUCKET_NAME}" >/dev/null 2>&1 || true

# Determine correct webroot path based on prefix
if [[ -n "${PREFIX}" ]]; then
    WEBROOT_PATH="${PREFIX}/webroot"
else
    WEBROOT_PATH="webroot"
fi

# Locate webroot assets directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_WEBROOT="${INSTALLER_ROOT}/internal/assets/webroot"

# Upload webroot content (always upload to ensure clean state)
echo "[ensure-minio-buckets] Uploading webroot content to: ${WEBROOT_PATH}/"

if [[ -d "${ASSETS_WEBROOT}" ]]; then
    echo "[ensure-minio-buckets] Uploading webroot assets from ${ASSETS_WEBROOT}..."

    # Upload index.html
    if [[ -f "${ASSETS_WEBROOT}/index.html" ]]; then
        mc cp "${ASSETS_WEBROOT}/index.html" "local/${BUCKET_NAME}/${WEBROOT_PATH}/index.html"
        echo "[ensure-minio-buckets]   ✓ index.html"
    fi

    # Upload style.css
    if [[ -f "${ASSETS_WEBROOT}/style.css" ]]; then
        mc cp "${ASSETS_WEBROOT}/style.css" "local/${BUCKET_NAME}/${WEBROOT_PATH}/style.css"
        echo "[ensure-minio-buckets]   ✓ style.css"
    fi

    # Upload logo.png
    if [[ -f "${ASSETS_WEBROOT}/logo.png" ]]; then
        mc cp "${ASSETS_WEBROOT}/logo.png" "local/${BUCKET_NAME}/${WEBROOT_PATH}/logo.png"
        echo "[ensure-minio-buckets]   ✓ logo.png"
    fi

    echo "[ensure-minio-buckets] ✓ Webroot assets uploaded to ${WEBROOT_PATH}/"
else
    echo "[ensure-minio-buckets] Warning: Assets directory not found at ${ASSETS_WEBROOT}"
    echo "[ensure-minio-buckets] Creating minimal default index.html..."
    echo "<html><head><title>Welcome to Globular</title></head><body><h1>Welcome to Globular</h1><p>Your Globular cluster is running.</p></body></html>" | \
        mc pipe "local/${BUCKET_NAME}/${WEBROOT_PATH}/index.html"
    echo "[ensure-minio-buckets] ✓ Minimal webroot created"
fi

# Verify upload was successful
if mc ls "local/${BUCKET_NAME}/${WEBROOT_PATH}/index.html" >/dev/null 2>&1; then
    echo "[ensure-minio-buckets] ✓ Verified: index.html is accessible in bucket"
else
    echo "[ensure-minio-buckets] ⚠ Warning: Could not verify index.html in bucket"
fi

# Fix contract file permissions
if [[ -f "${CONTRACT_FILE}" ]]; then
    chown globular:globular "${CONTRACT_FILE}" 2>/dev/null || true
    chmod 644 "${CONTRACT_FILE}" 2>/dev/null || true
fi

echo "[ensure-minio-buckets] ✓ MinIO buckets configured successfully"
