#!/usr/bin/env bash
set -euo pipefail

# MinIO Setup Script for Globular Installer
# Creates webroot and users buckets, uploads index.html and logo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_WEBROOT="$INSTALLER_ROOT/internal/assets/webroot"

# MinIO configuration
MINIO_ENDPOINT="${MINIO_ENDPOINT:-127.0.0.1:9000}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"
MINIO_USE_SSL="${MINIO_USE_SSL:-false}"

# Retry configuration
MAX_RETRIES=30
RETRY_DELAY=2

log() { echo "[minio-setup] $*"; }
die() { echo "[minio-setup] ERROR: $*" >&2; exit 1; }

# Wait for MinIO to be ready
wait_for_minio() {
    local host="${MINIO_ENDPOINT%%:*}"
    local port="${MINIO_ENDPOINT##*:}"
    local retries=0

    log "Waiting for MinIO to be ready at $MINIO_ENDPOINT..."

    while [ $retries -lt $MAX_RETRIES ]; do
        if nc -z -w2 "$host" "$port" 2>/dev/null; then
            log "MinIO is accessible"
            return 0
        fi
        retries=$((retries + 1))
        log "MinIO not ready yet (attempt $retries/$MAX_RETRIES)..."
        sleep $RETRY_DELAY
    done

    die "MinIO did not become ready after $MAX_RETRIES attempts"
}

# Check if mc (MinIO Client) is available
check_mc() {
    if command -v mc >/dev/null 2>&1; then
        echo "mc"
        return 0
    fi
    return 1
}

# Setup using MinIO Client (mc)
setup_with_mc() {
    local mc_cmd="$1"
    local alias="globular-installer"

    log "Using MinIO Client (mc) for setup"

    # Configure mc alias
    local protocol="http"
    if [ "$MINIO_USE_SSL" = "true" ]; then
        protocol="https"
    fi

    $mc_cmd alias set "$alias" "${protocol}://${MINIO_ENDPOINT}" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" --api S3v4 >/dev/null 2>&1 || true

    # Create buckets
    for bucket in webroot users; do
        if $mc_cmd ls "${alias}/${bucket}" >/dev/null 2>&1; then
            log "Bucket '$bucket' already exists"
        else
            $mc_cmd mb "${alias}/${bucket}" || die "Failed to create bucket $bucket"
            log "Created bucket '$bucket'"
        fi
    done

    # Set webroot bucket policy to public read
    local policy_file
    policy_file="$(mktemp)"
    cat > "$policy_file" <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {"AWS": ["*"]},
            "Action": ["s3:GetObject"],
            "Resource": ["arn:aws:s3:::webroot/*"]
        }
    ]
}
EOF

    $mc_cmd anonymous set-json "$policy_file" "${alias}/webroot" 2>/dev/null || \
        $mc_cmd policy set download "${alias}/webroot" 2>/dev/null || \
        log "Warning: Could not set public read policy on webroot bucket"
    rm -f "$policy_file"

    # Upload files
    if [ -f "$ASSETS_WEBROOT/index.html" ]; then
        $mc_cmd cp "$ASSETS_WEBROOT/index.html" "${alias}/webroot/index.html" || \
            die "Failed to upload index.html"
        log "Uploaded index.html to webroot"
    else
        log "Warning: index.html not found at $ASSETS_WEBROOT/index.html"
    fi

    if [ -f "$ASSETS_WEBROOT/logo.png" ]; then
        $mc_cmd cp "$ASSETS_WEBROOT/logo.png" "${alias}/webroot/logo.png" || \
            die "Failed to upload logo.png"
        log "Uploaded logo.png to webroot"
    else
        log "Warning: logo.png not found at $ASSETS_WEBROOT/logo.png"
    fi

    # Cleanup alias
    $mc_cmd alias rm "$alias" >/dev/null 2>&1 || true
}

# Setup using Python boto3
setup_with_python() {
    log "Using Python boto3 for setup"

    # Check if boto3 is available
    if ! python3 -c "import boto3" 2>/dev/null; then
        log "Warning: boto3 not available. Skipping MinIO setup."
        log "To enable MinIO setup, install boto3: pip3 install boto3"
        log "Or install MinIO Client: https://min.io/docs/minio/linux/reference/minio-mc.html"
        return 0
    fi

    python3 - <<EOF
import sys
import os
from pathlib import Path

try:
    import boto3
    from botocore.client import Config
    from botocore.exceptions import ClientError
except ImportError:
    print("[minio-setup] Warning: boto3 import failed unexpectedly", file=sys.stderr)
    sys.exit(0)

endpoint = "${MINIO_ENDPOINT}"
access_key = "${MINIO_ACCESS_KEY}"
secret_key = "${MINIO_SECRET_KEY}"
use_ssl = "${MINIO_USE_SSL}" == "true"

protocol = "https" if use_ssl else "http"
endpoint_url = f"{protocol}://{endpoint}"

s3 = boto3.client(
    's3',
    endpoint_url=endpoint_url,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    config=Config(signature_version='s3v4')
)

# Create buckets
for bucket in ['webroot', 'users']:
    try:
        s3.head_bucket(Bucket=bucket)
        print(f"[minio-setup] Bucket '{bucket}' already exists")
    except ClientError:
        try:
            s3.create_bucket(Bucket=bucket)
            print(f"[minio-setup] Created bucket '{bucket}'")
        except ClientError as e:
            print(f"[minio-setup] ERROR: Failed to create bucket {bucket}: {e}", file=sys.stderr)
            sys.exit(1)

# Set webroot policy
policy = """{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"AWS": ["*"]},
        "Action": ["s3:GetObject"],
        "Resource": ["arn:aws:s3:::webroot/*"]
    }]
}"""

try:
    s3.put_bucket_policy(Bucket='webroot', Policy=policy)
except ClientError as e:
    print(f"[minio-setup] Warning: Could not set bucket policy: {e}", file=sys.stderr)

# Upload files
assets_dir = Path("${ASSETS_WEBROOT}")
files = {
    'index.html': 'text/html',
    'logo.png': 'image/png'
}

for filename, content_type in files.items():
    filepath = assets_dir / filename
    if filepath.exists():
        try:
            s3.upload_file(
                str(filepath),
                'webroot',
                filename,
                ExtraArgs={'ContentType': content_type}
            )
            print(f"[minio-setup] Uploaded {filename} to webroot")
        except ClientError as e:
            print(f"[minio-setup] ERROR: Failed to upload {filename}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"[minio-setup] Warning: {filename} not found at {filepath}", file=sys.stderr)

print("[minio-setup] MinIO setup completed successfully")
EOF
}

# Setup using curl (fallback, limited functionality)
setup_with_curl() {
    log "Using curl for setup (limited functionality)"
    log "Warning: Bucket creation and policy setup require mc or Python boto3"
    log "Skipping MinIO setup - please install 'mc' or Python 'boto3' for full functionality"
    return 0
}

# Main setup
main() {
    log "Starting MinIO setup..."
    log "Endpoint: $MINIO_ENDPOINT"
    log "Assets directory: $ASSETS_WEBROOT"

    # Wait for MinIO to be ready
    wait_for_minio

    # Try different methods in order of preference
    if mc_cmd=$(check_mc); then
        setup_with_mc "$mc_cmd"
    elif command -v python3 >/dev/null 2>&1; then
        setup_with_python
    else
        setup_with_curl
    fi

    log "MinIO setup completed"
    log ""
    log "Access the welcome page at: http://${MINIO_ENDPOINT}/webroot/index.html"
}

main "$@"
