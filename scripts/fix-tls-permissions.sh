#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ Fixing TLS Certificate Permissions ━━━"
echo ""

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
PKI_DIR="${STATE_DIR}/pki"
TLS_DIR="${STATE_DIR}/config/tls"
ETCD_TLS_DIR="${STATE_DIR}/tls/etcd"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)" >&2
    exit 1
fi

# Verify directories exist
if [[ ! -d "${PKI_DIR}" ]]; then
    echo "ERROR: PKI directory not found: ${PKI_DIR}" >&2
    exit 1
fi

if [[ ! -d "${TLS_DIR}" ]]; then
    echo "ERROR: TLS directory not found: ${TLS_DIR}" >&2
    exit 1
fi

if [[ ! -d "${ETCD_TLS_DIR}" ]]; then
    echo "WARNING: etcd TLS directory not found: ${ETCD_TLS_DIR}" >&2
    echo "         Services may not be able to connect to etcd" >&2
fi

echo "→ Making directories accessible..."
chmod 755 "${STATE_DIR}" "${PKI_DIR}" "${TLS_DIR}"
chmod 755 "${STATE_DIR}/config" 2>/dev/null || true
chmod 755 "${STATE_DIR}/tls" 2>/dev/null || true
chmod 755 "${ETCD_TLS_DIR}" 2>/dev/null || true

echo "→ Making configuration files world-readable..."
chmod 644 "${STATE_DIR}/config.json" 2>/dev/null || true

echo "→ Making CA certificates world-readable (public keys)..."
chmod 644 "${PKI_DIR}/ca.pem" "${PKI_DIR}/ca.crt" 2>/dev/null || true
chmod 644 "${TLS_DIR}/ca.pem" "${TLS_DIR}/ca.crt" 2>/dev/null || true
chmod 644 "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/server.crt" 2>/dev/null || true

echo "→ Making etcd client certificates accessible..."
chmod 644 "${ETCD_TLS_DIR}/ca.crt" 2>/dev/null || true
chmod 644 "${ETCD_TLS_DIR}/server.crt" 2>/dev/null || true
chmod 644 "${ETCD_TLS_DIR}/client.crt" 2>/dev/null || true

echo "→ Securing private keys (owner-only access)..."
chmod 400 "${PKI_DIR}/ca.key" 2>/dev/null || true
chmod 400 "${TLS_DIR}/privkey.pem" "${TLS_DIR}/server.key" 2>/dev/null || true
chmod 400 "${ETCD_TLS_DIR}/server.pem" 2>/dev/null || true
chmod 400 "${ETCD_TLS_DIR}/client.pem" 2>/dev/null || true

echo ""
echo "✓ TLS certificate permissions fixed"
echo ""
echo "Verification:"
ls -l "${PKI_DIR}/ca.pem" "${TLS_DIR}/ca.pem" "${ETCD_TLS_DIR}/ca.crt" 2>/dev/null || echo "  (Some files may not exist - this is normal)"
echo ""
echo "Restarting services to apply changes..."
systemctl restart globular-xds.service 2>/dev/null || echo "  (XDS service not installed or failed to restart)"
systemctl restart globular-dns.service 2>/dev/null || echo "  (DNS service not installed or failed to restart)"
echo ""
echo "You can now run: globular dns status"
echo ""
