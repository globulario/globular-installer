#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
CRED_FILE="${STATE_DIR}/minio/credentials"
CONTRACT_DIR="${STATE_DIR}/objectstore"
CONTRACT_FILE="${GLOBULAR_MINIO_CONTRACT_PATH:-${CONTRACT_DIR}/minio.json}"

# Create objectstore directory if it doesn't exist
if [[ ! -d "${CONTRACT_DIR}" ]]; then
  echo "[setup-minio-contract] Creating ${CONTRACT_DIR}..."
  mkdir -p "${CONTRACT_DIR}"
fi

# Always ensure credentials file exists and is valid
if [[ ! -f "${CRED_FILE}" ]]; then
  echo "[setup-minio-contract] Creating default credentials file at ${CRED_FILE}..."
  mkdir -p "$(dirname "${CRED_FILE}")"
  echo "globular:globularadmin" > "${CRED_FILE}"
  chmod 600 "${CRED_FILE}"

  # Set ownership to globular user if it exists
  if id globular >/dev/null 2>&1; then
    chown globular:globular "${CRED_FILE}"
    echo "[setup-minio-contract] Set credentials file ownership to globular:globular"
  fi
else
  echo "[setup-minio-contract] Credentials file already exists at ${CRED_FILE}"

  # Verify existing file is readable and valid
  if [[ ! -r "${CRED_FILE}" ]]; then
    echo "[setup-minio-contract] WARNING: Cannot read existing credentials file, recreating..."
    echo "globular:globularadmin" > "${CRED_FILE}"
    chmod 600 "${CRED_FILE}"
    if id globular >/dev/null 2>&1; then
      chown globular:globular "${CRED_FILE}"
    fi
  fi
fi

# Verify credentials file was created successfully
if [[ ! -f "${CRED_FILE}" ]]; then
  echo "ERROR: Failed to create credentials file at ${CRED_FILE}" >&2
  exit 1
fi

# Ensure minio directory has correct ownership
if id globular >/dev/null 2>&1; then
  chown -R globular:globular "$(dirname "${CRED_FILE}")" 2>/dev/null || true
fi

echo "[setup-minio-contract] ✓ Credentials file ready at ${CRED_FILE}"

if ! IFS=":" read -r MINIO_ACCESS_KEY MINIO_SECRET_KEY < "${CRED_FILE}"; then
  echo "ERROR: Unable to read credentials from ${CRED_FILE} (expected 'access:secret' format)." >&2
  exit 1
fi

if [[ -z "${MINIO_ACCESS_KEY}" || -z "${MINIO_SECRET_KEY}" ]]; then
  echo "ERROR: Credentials in ${CRED_FILE} are empty; verify the minio package wrote valid contents." >&2
  exit 1
fi

STATE_DIR="${STATE_DIR}" CRED_FILE="${CRED_FILE}" CONTRACT_FILE="${CONTRACT_FILE}" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

contract_file = Path(os.environ["CONTRACT_FILE"])
state_dir = os.environ["STATE_DIR"]
cred_file_default = os.environ["CRED_FILE"]

default_domain = (
    os.environ.get("GLOBULAR_DOMAIN")
    or os.environ.get("DOMAIN")
    or "localhost"
)

defaults = {
    "type": "minio",
    "endpoint": "127.0.0.1:9000",
    "bucket": "globular",
    "prefix": default_domain,
    "secure": True,  # TLS enabled by default
    "caBundlePath": f"{state_dir}/pki/ca.pem",
}

existing = {}
if contract_file.exists():
    try:
        with contract_file.open() as fh:
            existing = json.load(fh)
    except json.JSONDecodeError as exc:
        print(f"ERROR: Failed to parse existing contract at {contract_file}: {exc}", file=sys.stderr)
        sys.exit(1)

def pick(key: str, *env_keys: str):
    for env_key in env_keys:
        if env_key in os.environ:
            val = os.environ[env_key]
            if key == "secure":
                return str(val).lower() in ("1", "true", "yes", "y", "on")
            return val
    if key in existing:
        return existing[key]
    return defaults[key]

auth = existing.get("auth", {})
cred_file = os.environ.get(
    "GLOBULAR_MINIO_CRED_FILE",
    os.environ.get("MINIO_CRED_FILE", auth.get("credFile", cred_file_default)),
)

contract = {
    "type": pick("type", "GLOBULAR_MINIO_TYPE", "MINIO_TYPE"),
    "endpoint": pick("endpoint", "GLOBULAR_MINIO_ENDPOINT", "MINIO_ENDPOINT"),
    "bucket": pick("bucket", "GLOBULAR_MINIO_BUCKET", "MINIO_BUCKET"),
    "prefix": pick("prefix", "GLOBULAR_MINIO_PREFIX", "MINIO_PREFIX", "GLOBULAR_DOMAIN", "DOMAIN"),
    "secure": pick("secure", "GLOBULAR_MINIO_SECURE", "MINIO_SECURE"),
    "caBundlePath": pick("caBundlePath", "GLOBULAR_MINIO_CA_BUNDLE", "MINIO_CA_BUNDLE"),
    "auth": {
        "mode": "file",
        "credFile": cred_file,
    },
}

tmp_path = contract_file.with_suffix(".tmp")
tmp_path.write_text(json.dumps(contract, indent=2) + "\n")
tmp_path.replace(contract_file)

print(f"Wrote MinIO contract to {contract_file}")
PY
