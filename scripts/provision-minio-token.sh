#!/usr/bin/env bash
# provision-minio-token.sh — Generate a Prometheus bearer token for MinIO metrics.
#
# Usage:
#   sudo ./provision-minio-token.sh
#
# Requires: mc (MinIO Client) on PATH, MinIO running and reachable.
# Reads credentials from /var/lib/globular/minio/credentials (access:secret format).
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
CRED_FILE="${STATE_DIR}/minio/credentials"
TOKEN_FILE="${STATE_DIR}/prometheus/minio_token"
ALIAS_NAME="globular-prom"

if [[ ! -f "${CRED_FILE}" ]]; then
  echo "ERROR: MinIO credentials not found at ${CRED_FILE}" >&2
  exit 1
fi

if ! command -v mc >/dev/null 2>&1; then
  echo "ERROR: 'mc' (MinIO Client) not found on PATH." >&2
  exit 1
fi

IFS=":" read -r ACCESS_KEY SECRET_KEY < "${CRED_FILE}"
if [[ -z "${ACCESS_KEY}" || -z "${SECRET_KEY}" ]]; then
  echo "ERROR: Empty credentials in ${CRED_FILE}" >&2
  exit 1
fi

# Determine scheme: if MinIO TLS certs exist, use https
SCHEME="http"
if [[ -f "${STATE_DIR}/.minio/certs/public.crt" ]]; then
  SCHEME="https"
fi
MINIO_HOST="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
ENDPOINT="${SCHEME}://${MINIO_HOST}:9000"

echo "[provision-minio-token] Setting up mc alias → ${ENDPOINT}"
mc alias rm "${ALIAS_NAME}" >/dev/null 2>&1 || true
mc alias set "${ALIAS_NAME}" "${ENDPOINT}" "${ACCESS_KEY}" "${SECRET_KEY}" --api s3v4 --insecure >/dev/null

echo "[provision-minio-token] Generating Prometheus bearer token..."
TOKEN=$(mc admin prometheus generate "${ALIAS_NAME}" --insecure 2>/dev/null \
  | grep -oP 'bearer_token:\s*\K\S+' || true)

if [[ -z "${TOKEN}" ]]; then
  # Fallback: try the newer mc output format
  TOKEN=$(mc admin prometheus generate "${ALIAS_NAME}" --insecure 2>&1 \
    | grep -oP 'bearer_token_file.*token["\s:]+\K[A-Za-z0-9_-]+' || true)
fi

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: Failed to extract bearer token from 'mc admin prometheus generate'." >&2
  echo "Try running manually: mc admin prometheus generate ${ALIAS_NAME} --insecure" >&2
  exit 1
fi

# Write token file
mkdir -p "$(dirname "${TOKEN_FILE}")"
printf '%s' "${TOKEN}" > "${TOKEN_FILE}"
chown globular:globular "${TOKEN_FILE}"
chmod 0640 "${TOKEN_FILE}"

echo "[provision-minio-token] Token written to ${TOKEN_FILE}"

# Reload Prometheus if running
if systemctl is-active --quiet globular-prometheus.service 2>/dev/null; then
  echo "[provision-minio-token] Reloading Prometheus..."
  curl -sS -X POST http://127.0.0.1:9090/-/reload || true
fi

echo "[provision-minio-token] Done."
