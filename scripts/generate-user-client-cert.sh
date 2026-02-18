#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ Generating User Client Certificate ━━━"
echo ""

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
PKI_DIR="${STATE_DIR}/pki"

# Detect actual user (not root when using sudo)
ACTUAL_USER="${USER:-$(whoami)}"
if [[ "${ACTUAL_USER}" == "root" ]] && [[ -n "${SUDO_USER:-}" ]]; then
  ACTUAL_USER="${SUDO_USER}"
fi

# Get actual user's home directory
if [[ "${ACTUAL_USER}" == "root" ]]; then
  ACTUAL_HOME="/root"
else
  ACTUAL_HOME=$(eval echo ~${ACTUAL_USER})
fi

USER_TLS_DIR="${ACTUAL_HOME}/.config/globular/tls"
DOMAIN="${DOMAIN:-localhost}"
USERNAME="${ACTUAL_USER}"

# Read domain from config if available
if [[ -f "${STATE_DIR}/config.json" ]]; then
    CONFIG_DOMAIN=$(jq -r '.Domain // "localhost"' "${STATE_DIR}/config.json" 2>/dev/null || echo "localhost")
    if [[ -n "${CONFIG_DOMAIN}" && "${CONFIG_DOMAIN}" != "null" ]]; then
        DOMAIN="${CONFIG_DOMAIN}"
    fi
fi

DOMAIN_DIR="${USER_TLS_DIR}/${DOMAIN}"

echo "Domain: ${DOMAIN}"
echo "User: ${USERNAME}"
echo "Output: ${DOMAIN_DIR}"
echo ""

# Create user TLS directory
mkdir -p "${DOMAIN_DIR}"
chmod 700 "${DOMAIN_DIR}"

# Check if client certificate exists and is still valid with current CA
NEED_REGEN=false
if [[ -f "${DOMAIN_DIR}/client.crt" ]] && [[ -f "${DOMAIN_DIR}/ca.crt" ]]; then
    # Check if CA has changed
    if ! diff -q "${PKI_DIR}/ca.crt" "${DOMAIN_DIR}/ca.crt" >/dev/null 2>&1; then
        echo "→ CA certificate changed, regenerating client certificate..."
        NEED_REGEN=true
    else
        # Check if client cert is still valid
        if openssl verify -CAfile "${PKI_DIR}/ca.crt" "${DOMAIN_DIR}/client.crt" >/dev/null 2>&1; then
            echo "  ✓ Client certificate is valid, skipping regeneration"
            exit 0
        else
            echo "→ Client certificate invalid, regenerating..."
            NEED_REGEN=true
        fi
    fi
else
    echo "→ No existing client certificate found, generating new one..."
    NEED_REGEN=true
fi

# Copy CA certificate
echo "→ Copying CA certificate..."
cp "${PKI_DIR}/ca.crt" "${DOMAIN_DIR}/ca.crt"
chmod 644 "${DOMAIN_DIR}/ca.crt"
echo "  ✓ CA certificate copied"

# Generate client private key
echo "→ Generating client private key..."
openssl genrsa -out "${DOMAIN_DIR}/client.key" 2048 2>/dev/null
chmod 600 "${DOMAIN_DIR}/client.key"
echo "  ✓ Private key generated"

# Create client certificate request
echo "→ Creating certificate signing request..."
cat > "${DOMAIN_DIR}/client.conf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = ${USERNAME}@${DOMAIN}
O = Globular

[v3_req]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl req -new -key "${DOMAIN_DIR}/client.key" \
    -out "${DOMAIN_DIR}/client.csr" \
    -config "${DOMAIN_DIR}/client.conf" 2>/dev/null

echo "  ✓ CSR created"

# Sign the certificate with Globular CA
echo "→ Signing certificate..."
if [[ ! -f "${PKI_DIR}/ca.key" ]]; then
    echo "ERROR: CA private key not found: ${PKI_DIR}/ca.key" >&2
    echo "       This script must be run on the Globular server with access to the CA key" >&2
    exit 1
fi

# Sign certificate (must be run as root - script already called with sudo)
openssl x509 -req \
    -in "${DOMAIN_DIR}/client.csr" \
    -CA "${PKI_DIR}/ca.crt" \
    -CAkey "${PKI_DIR}/ca.key" \
    -CAcreateserial \
    -out "${DOMAIN_DIR}/client.crt" \
    -days 365 \
    -extfile "${DOMAIN_DIR}/client.conf" \
    -extensions v3_req 2>/dev/null

chmod 644 "${DOMAIN_DIR}/client.crt"
echo "  ✓ Certificate signed"

# Create PEM format (same as key for compatibility)
cp "${DOMAIN_DIR}/client.key" "${DOMAIN_DIR}/client.pem"
chmod 600 "${DOMAIN_DIR}/client.pem"

# Cleanup
rm -f "${DOMAIN_DIR}/client.csr" "${DOMAIN_DIR}/client.conf"

# Fix ownership - critical for user access!
# When run via sudo, files are created as root but need to be owned by the actual user
if [[ "${ACTUAL_USER}" != "root" ]]; then
    echo "→ Setting ownership to ${ACTUAL_USER}..."
    chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${DOMAIN_DIR}"
    echo "  ✓ Ownership set to ${ACTUAL_USER}:${ACTUAL_USER}"
fi

echo ""
echo "━━━ Client Certificate Generated Successfully ━━━"
echo ""
echo "Certificate files:"
echo "  CA:   ${DOMAIN_DIR}/ca.crt"
echo "  Cert: ${DOMAIN_DIR}/client.crt"
echo "  Key:  ${DOMAIN_DIR}/client.key"
echo ""
echo "Verifying certificate..."
openssl verify -CAfile "${DOMAIN_DIR}/ca.crt" "${DOMAIN_DIR}/client.crt"
echo ""
echo "Certificate details:"
openssl x509 -in "${DOMAIN_DIR}/client.crt" -noout -subject -issuer -ext extendedKeyUsage
echo ""
echo "You can now use the globular CLI with:"
echo "  globular dns status"
echo ""
