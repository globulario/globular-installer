#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ Fixing TLS Certificate Permissions ━━━"
echo ""

# INV-PKI-1: Use canonical PKI paths only
STATE_DIR="${STATE_DIR:-/var/lib/globular}"
PKI_DIR="${STATE_DIR}/pki"
SERVICE_CERT_DIR="${PKI_DIR}/issued/services"
ETCD_CERT_DIR="${PKI_DIR}/issued/etcd"
MINIO_CERTS_DIR="${STATE_DIR}/.minio/certs"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)" >&2
    exit 1
fi

# Verify directories exist
if [[ ! -d "${PKI_DIR}" ]]; then
    echo "ERROR: PKI directory not found: ${PKI_DIR}" >&2
    exit 1
fi

if [[ ! -d "${SERVICE_CERT_DIR}" ]]; then
    echo "ERROR: Service certificate directory not found: ${SERVICE_CERT_DIR}" >&2
    exit 1
fi

if [[ ! -d "${ETCD_CERT_DIR}" ]]; then
    echo "WARNING: etcd certificate directory not found: ${ETCD_CERT_DIR}" >&2
    echo "         Services may not be able to connect to etcd" >&2
fi

echo "→ Making directories accessible..."
chmod 755 "${STATE_DIR}" "${PKI_DIR}" "${SERVICE_CERT_DIR}" "${ETCD_CERT_DIR}"
chmod 755 "${PKI_DIR}/issued" 2>/dev/null || true

echo "→ Making configuration files world-readable..."
chmod 644 "${STATE_DIR}/config.json" 2>/dev/null || true

echo "→ Making CA certificates world-readable (public keys)..."
chmod 644 "${PKI_DIR}/ca.pem" "${PKI_DIR}/ca.crt" 2>/dev/null || true

echo "→ Making service certificates accessible..."
chmod 644 "${SERVICE_CERT_DIR}/service.crt" 2>/dev/null || true

echo "→ Making etcd client certificates accessible..."
chmod 644 "${ETCD_CERT_DIR}/client.crt" 2>/dev/null || true

echo "→ Securing private keys (owner-only access)..."
chmod 400 "${PKI_DIR}/ca.key" 2>/dev/null || true
chmod 400 "${SERVICE_CERT_DIR}/service.key" 2>/dev/null || true
chmod 400 "${ETCD_CERT_DIR}/client.key" 2>/dev/null || true
chmod 400 "${MINIO_CERTS_DIR}/private.key" 2>/dev/null || true

echo ""
echo "✓ TLS certificate permissions fixed"
echo ""
echo "Verification:"
ls -l "${PKI_DIR}/ca.pem" "${SERVICE_CERT_DIR}/service.crt" "${ETCD_CERT_DIR}/client.crt" 2>/dev/null || echo "  (Some files may not exist - this is normal)"
echo ""
echo "Restarting services to apply changes..."
systemctl restart globular-xds.service 2>/dev/null || echo "  (XDS service not installed or failed to restart)"
systemctl restart globular-dns.service 2>/dev/null || echo "  (DNS service not installed or failed to restart)"
echo ""
echo "You can now run: globular dns status"
echo ""
