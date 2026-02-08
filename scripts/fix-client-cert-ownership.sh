#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ Fixing Client Certificate Ownership ━━━"
echo ""

# Get the actual user who invoked sudo (not root)
ACTUAL_USER="${SUDO_USER:-${USER}}"
if [[ "${ACTUAL_USER}" == "root" ]]; then
    echo "ERROR: This script must be run with sudo from a regular user account" >&2
    echo "       Usage: sudo $0" >&2
    exit 1
fi

# Get the actual user's home directory
ACTUAL_HOME=$(eval echo ~${ACTUAL_USER})
CERT_DIR="${ACTUAL_HOME}/.config/globular/tls/localhost"

if [[ ! -d "${CERT_DIR}" ]]; then
    echo "ERROR: Certificate directory not found: ${CERT_DIR}" >&2
    echo "       Run generate-user-client-cert.sh first" >&2
    exit 1
fi

echo "User: ${ACTUAL_USER}"
echo "Cert Directory: ${CERT_DIR}"
echo ""

echo "→ Fixing ownership..."
chown -R ${ACTUAL_USER}:${ACTUAL_USER} "${CERT_DIR}"
echo "  ✓ Ownership fixed"

echo "→ Setting correct permissions..."
chmod 700 "${CERT_DIR}"
chmod 644 "${CERT_DIR}/ca.crt" 2>/dev/null || true
chmod 644 "${CERT_DIR}/client.crt" 2>/dev/null || true
chmod 600 "${CERT_DIR}/client.key" 2>/dev/null || true
chmod 600 "${CERT_DIR}/client.pem" 2>/dev/null || true
echo "  ✓ Permissions set"

echo "→ Cleaning up temp files..."
rm -f "${CERT_DIR}/client.csr" "${CERT_DIR}/client.conf"
echo "  ✓ Cleanup done"

echo ""
echo "━━━ Client Certificates Fixed ━━━"
echo ""
echo "Certificate files:"
ls -la "${CERT_DIR}"
echo ""
echo "Verifying certificate..."
openssl verify -CAfile "${CERT_DIR}/ca.crt" "${CERT_DIR}/client.crt"
echo ""
echo "✓ Client certificates are ready for use"
echo ""
