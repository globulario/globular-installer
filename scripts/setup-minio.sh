#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
CONTRACT_DIR="${STATE_DIR}/objectstore"
CONTRACT_FILE="${GLOBULAR_MINIO_CONTRACT_PATH:-${CONTRACT_DIR}/minio.json}"
WEBROOT_DIR="${WEBROOT_DIR:-${STATE_DIR}/webroot}"
DOMAIN="${GLOBULAR_DOMAIN:-${DOMAIN:-localhost}}"

if [[ ! -f "${CONTRACT_FILE}" ]]; then
  echo "ERROR: Missing MinIO contract at ${CONTRACT_FILE}; run setup-minio-contract.sh after the package installs the directories." >&2
  exit 1
fi

# Create webroot directory if it doesn't exist
if [[ ! -d "${WEBROOT_DIR}" ]]; then
  echo "[setup-minio] Creating ${WEBROOT_DIR}..."
  mkdir -p "${WEBROOT_DIR}"
fi

# Check if webroot has content
if [[ -z "$(find "${WEBROOT_DIR}" -type f -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "[setup-minio] WEBROOT_DIR (${WEBROOT_DIR}) is empty - skipping asset upload."
  echo "[setup-minio] Add web assets (index.html, logo.png, etc.) to seed MinIO with content."
  exit 0
fi

# Warn about missing recommended assets (non-fatal for testing)
for recommended in index.html logo.png; do
  if [[ ! -f "${WEBROOT_DIR}/${recommended}" ]]; then
    echo "[setup-minio] WARNING: Recommended asset ${WEBROOT_DIR}/${recommended} not found." >&2
  fi
done

eval "$(
  STATE_DIR="${STATE_DIR}" CONTRACT_FILE="${CONTRACT_FILE}" DOMAIN="${DOMAIN}" GLOBULAR_DOMAIN="${DOMAIN}" python3 - <<'PY'
import json
import os
import shlex
import sys
from pathlib import Path

contract_file = Path(os.environ["CONTRACT_FILE"])
state_dir = os.environ["STATE_DIR"]

if not contract_file.exists():
    print(f"echo \"ERROR: Contract file not found at {contract_file}\" >&2")
    print("exit 1")
    sys.exit(0)

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
    "secure": False,
    "caBundlePath": "",
}

try:
    with contract_file.open() as fh:
        data = json.load(fh)
except json.JSONDecodeError as exc:
    print(f"echo \"ERROR: Invalid JSON in {contract_file}: {exc}\" >&2")
    print("exit 1")
    sys.exit(0)

def pick(key: str, *env_keys: str):
    for env_key in env_keys:
        if env_key in os.environ:
            val = os.environ[env_key]
            if key == "secure":
                return str(val).lower() in ("1", "true", "yes", "y", "on")
            return val
    if key in data:
        return data[key]
    return defaults[key]

auth = data.get("auth", {})
cred_file = os.environ.get(
    "GLOBULAR_MINIO_CRED_FILE",
    os.environ.get("MINIO_CRED_FILE", auth.get("credFile", os.path.join(state_dir, "minio", "credentials"))),
)
ca_bundle = pick("caBundlePath", "GLOBULAR_MINIO_CA_BUNDLE")
if isinstance(ca_bundle, bool):
    ca_bundle = "" if not ca_bundle else str(ca_bundle)
if ca_bundle is None:
    ca_bundle = ""

values = {
    "CONTRACT_ENDPOINT": pick("endpoint", "GLOBULAR_MINIO_ENDPOINT", "MINIO_ENDPOINT"),
    "CONTRACT_BUCKET": pick("bucket", "GLOBULAR_MINIO_BUCKET", "MINIO_BUCKET"),
    "CONTRACT_PREFIX": pick("prefix", "GLOBULAR_MINIO_PREFIX", "MINIO_PREFIX", "GLOBULAR_DOMAIN", "DOMAIN"),
    "CONTRACT_SECURE": str(pick("secure", "GLOBULAR_MINIO_SECURE", "MINIO_SECURE")).lower(),
    "CONTRACT_CA_BUNDLE": ca_bundle,
    "CONTRACT_CRED_FILE": cred_file,
}

for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
)"

if [[ ! -f "${CONTRACT_CRED_FILE}" ]]; then
  echo "ERROR: Credential file referenced by contract is missing: ${CONTRACT_CRED_FILE}" >&2
  exit 1
fi

if ! IFS=":" read -r MINIO_ACCESS_KEY MINIO_SECRET_KEY < "${CONTRACT_CRED_FILE}"; then
  echo "ERROR: Unable to read credentials from ${CONTRACT_CRED_FILE} (expected 'access:secret' format)." >&2
  exit 1
fi

if [[ -z "${MINIO_ACCESS_KEY}" || -z "${MINIO_SECRET_KEY}" ]]; then
  echo "ERROR: Empty credentials in ${CONTRACT_CRED_FILE}." >&2
  exit 1
fi

has_boto3() {
  python3 - <<'PY' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("boto3") else 1)
PY
}

prefix_base="${CONTRACT_PREFIX:-${DOMAIN}}"
prefix_path="${prefix_base%/}/"

provision_with_mc() {
  local alias="globular-minio"
  local scheme="http"
  [[ "${CONTRACT_SECURE}" == "true" ]] && scheme="https"
  local endpoint_url="${scheme}://${CONTRACT_ENDPOINT}"

  mc alias rm "${alias}" >/dev/null 2>&1 || true
  mc alias set "${alias}" "${endpoint_url}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" --api s3v4 >/dev/null

  if ! mc ls "${alias}/${CONTRACT_BUCKET}" >/dev/null 2>&1; then
    mc mb "${alias}/${CONTRACT_BUCKET}"
  fi

  local dest="${alias}/${CONTRACT_BUCKET}/${prefix_path}webroot/"
  mc mirror --overwrite "${WEBROOT_DIR}/" "${dest}" >/dev/null

  printf 'keep\n' | mc pipe "${alias}/${CONTRACT_BUCKET}/${prefix_path}webroot/.keep" >/dev/null
  printf 'keep\n' | mc pipe "${alias}/${CONTRACT_BUCKET}/${prefix_path}users/.keep" >/dev/null

  mc stat "${alias}/${CONTRACT_BUCKET}" >/dev/null
  mc stat "${alias}/${CONTRACT_BUCKET}/${prefix_path}webroot/.keep" >/dev/null
  mc stat "${alias}/${CONTRACT_BUCKET}/${prefix_path}users/.keep" >/dev/null
  mc stat "${alias}/${CONTRACT_BUCKET}/${prefix_path}webroot/index.html" >/dev/null
}

provision_with_boto3() {
  CONTRACT_ENDPOINT="${CONTRACT_ENDPOINT}" \
  CONTRACT_BUCKET="${CONTRACT_BUCKET}" \
  CONTRACT_PREFIX="${CONTRACT_PREFIX}" \
  CONTRACT_SECURE="${CONTRACT_SECURE}" \
  CONTRACT_CA_BUNDLE="${CONTRACT_CA_BUNDLE}" \
  CONTRACT_CRED_FILE="${CONTRACT_CRED_FILE}" \
  WEBROOT_DIR="${WEBROOT_DIR}" \
  DOMAIN="${DOMAIN}" \
  GLOBULAR_DOMAIN="${DOMAIN}" \
  python3 - <<'PY'
import mimetypes
import os
import sys
from pathlib import Path

try:
    import boto3
    from botocore import exceptions as boto_exc
    from botocore.client import Config
except ImportError:
    print("ERROR: boto3 is required but not installed.", file=sys.stderr)
    sys.exit(1)

endpoint = os.environ["CONTRACT_ENDPOINT"]
bucket = os.environ["CONTRACT_BUCKET"]
domain = os.environ.get("DOMAIN") or os.environ.get("GLOBULAR_DOMAIN") or "localhost"
prefix = os.environ.get("CONTRACT_PREFIX", "") or domain
secure = os.environ.get("CONTRACT_SECURE", "false").lower() == "true"
ca_bundle = os.environ.get("CONTRACT_CA_BUNDLE", "")
cred_file = Path(os.environ["CONTRACT_CRED_FILE"])
webroot_dir = Path(os.environ["WEBROOT_DIR"])

if not bucket:
    print("ERROR: Contract bucket is empty.", file=sys.stderr)
    sys.exit(1)

try:
    creds = cred_file.read_text().strip()
    access_key, secret_key = creds.split(":", 1)
except (OSError, ValueError) as exc:
    print(f"ERROR: Unable to read credentials from {cred_file}: {exc}", file=sys.stderr)
    sys.exit(1)

scheme = "https" if secure else "http"
endpoint_url = f"{scheme}://{endpoint}"
verify = ca_bundle if ca_bundle else secure

session = boto3.session.Session()
config = Config(signature_version="s3v4", s3={"addressing_style": "path"})
client = session.client(
    "s3",
    endpoint_url=endpoint_url,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    verify=verify,
    config=config,
)
s3 = session.resource(
    "s3",
    endpoint_url=endpoint_url,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    verify=verify,
    config=config,
)

bucket_obj = s3.Bucket(bucket)
try:
    client.head_bucket(Bucket=bucket)
except boto_exc.ClientError as exc:
    code = exc.response.get("Error", {}).get("Code", "")
    if code in ("404", "NoSuchBucket", "NotFound", "BucketNotFound"):
        bucket_obj.create()
    else:
        print(f"ERROR: Failed to access bucket {bucket}: {exc}", file=sys.stderr)
        sys.exit(1)

def object_key(subpath: Path) -> str:
    key_parts = []
    if prefix:
        key_parts.append(prefix.strip("/"))
    key_parts.extend(subpath.parts)
    return "/".join(key_parts)

for path in webroot_dir.rglob("*"):
    if not path.is_file():
        continue
    rel = path.relative_to(webroot_dir)
    key = object_key(Path("webroot") / rel)
    content_type, _ = mimetypes.guess_type(path.as_posix())
    extra = {"ContentType": content_type} if content_type else {}
    bucket_obj.upload_file(path.as_posix(), key, ExtraArgs=extra)

bucket_obj.put_object(Key=object_key(Path("webroot") / ".keep"), Body=b"keep", ContentType="text/plain")
bucket_obj.put_object(Key=object_key(Path("users") / ".keep"), Body=b"keep", ContentType="text/plain")

try:
    client.head_bucket(Bucket=bucket)
    client.head_object(Bucket=bucket, Key=object_key(Path("webroot") / ".keep"))
    client.head_object(Bucket=bucket, Key=object_key(Path("users") / ".keep"))
    client.head_object(Bucket=bucket, Key=object_key(Path("webroot") / "index.html"))
except boto_exc.ClientError as exc:
    print(f"ERROR: Post-provision verification failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

if [[ -n "${CONTRACT_CA_BUNDLE}" ]] && has_boto3; then
  echo "[setup-minio] Using boto3 path because CONTRACT_CA_BUNDLE is set."
  provision_with_boto3
elif [[ -n "${CONTRACT_CA_BUNDLE}" ]]; then
  echo "ERROR: CONTRACT_CA_BUNDLE is set but boto3 is unavailable; install boto3 to honor TLS verification." >&2
  exit 1
elif command -v mc >/dev/null 2>&1; then
  echo "[setup-minio] Using mc for provisioning."
  provision_with_mc
elif has_boto3; then
  echo "[setup-minio] Using boto3 fallback for provisioning."
  provision_with_boto3
else
  echo "ERROR: Neither 'mc' nor 'boto3' is available. Install MinIO Client (mc) or Python boto3." >&2
  exit 1
fi

echo "[setup-minio] Provisioning complete."
