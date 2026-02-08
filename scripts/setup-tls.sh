#!/usr/bin/env bash
set -euo pipefail

# TLS Bootstrap for Globular Day-0
# Generates root CA and service certificates using RSA (not ECDSA) for XDS compatibility

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
PKI_DIR="${STATE_DIR}/pki"
TLS_DIR="${STATE_DIR}/config/tls"
MINIO_CERTS_DIR="${STATE_DIR}/.minio/certs"

echo "[setup-tls] Bootstrapping TLS certificates (RSA)"
echo "[setup-tls] STATE_DIR=${STATE_DIR}"

# Create directories
mkdir -p "${PKI_DIR}"
mkdir -p "${TLS_DIR}"
mkdir -p "${MINIO_CERTS_DIR}"

# Function to generate RSA key (not ECDSA - for XDS compatibility)
gen_rsa_key() {
    local keyfile="$1"
    local bits="${2:-2048}"
    openssl genrsa -out "${keyfile}" "${bits}"
    chmod 400 "${keyfile}"
}

# Function to generate root CA
gen_ca() {
    local keyfile="${PKI_DIR}/ca.key"
    local crtfile="${PKI_DIR}/ca.crt"
    local pemfile="${PKI_DIR}/ca.pem"

    echo "[setup-tls] Generating root CA (RSA 4096)..."

    # Generate CA private key (RSA 4096 for strong CA)
    gen_rsa_key "${keyfile}" 4096

    # Generate self-signed CA certificate (10 years)
    openssl req -new -x509 \
        -key "${keyfile}" \
        -out "${crtfile}" \
        -days 3650 \
        -subj "/CN=Globular Root CA/O=Globular" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

    chmod 444 "${crtfile}"

    # Create CA bundle
    cp "${crtfile}" "${pemfile}"
    chmod 444 "${pemfile}"

    echo "[setup-tls] ✓ Root CA generated (RSA)"
}

# Function to generate service certificate
gen_service_cert() {
    local keyfile="${TLS_DIR}/privkey.pem"
    local crtfile="${TLS_DIR}/fullchain.pem"
    local csrfile="${TLS_DIR}/server.csr"

    echo "[setup-tls] Generating service certificate (RSA 2048)..."

    # Generate service private key (RSA 2048)
    gen_rsa_key "${keyfile}" 2048

    # Generate CSR with SANs
    openssl req -new \
        -key "${keyfile}" \
        -out "${csrfile}" \
        -subj "/CN=localhost/O=Globular" \
        -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1,IP:::1"

    # Sign with CA (1 year validity)
    openssl x509 -req \
        -in "${csrfile}" \
        -CA "${PKI_DIR}/ca.crt" \
        -CAkey "${PKI_DIR}/ca.key" \
        -CAcreateserial \
        -out "${crtfile}" \
        -days 365 \
        -sha256 \
        -extfile <(printf "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1,IP:::1\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth")

    chmod 444 "${crtfile}"
    rm -f "${csrfile}"

    echo "[setup-tls] ✓ Service certificate generated (RSA)"
}

# Function to setup MinIO certs
setup_minio_certs() {
    echo "[setup-tls] Setting up MinIO certificates..."

    # MinIO expects: public.crt and private.key
    cp "${TLS_DIR}/fullchain.pem" "${MINIO_CERTS_DIR}/public.crt"
    cp "${TLS_DIR}/privkey.pem" "${MINIO_CERTS_DIR}/private.key"

    chmod 444 "${MINIO_CERTS_DIR}/public.crt"
    chmod 400 "${MINIO_CERTS_DIR}/private.key"

    echo "[setup-tls] ✓ MinIO certificates configured"
}

# Function to create compatibility symlinks
setup_compat_symlinks() {
    echo "[setup-tls] Creating compatibility symlinks for service discovery..."

    # Create ca.pem symlink in config/tls for compatibility
    if [[ ! -e "${TLS_DIR}/ca.pem" ]]; then
        ln -sf "${PKI_DIR}/ca.pem" "${TLS_DIR}/ca.pem"
    fi

    # Services look for server.crt, server.key, ca.crt via GetTLSFile()
    # Create symlinks with expected names
    ln -sf fullchain.pem "${TLS_DIR}/server.crt"
    ln -sf privkey.pem "${TLS_DIR}/server.key"
    ln -sf ca.pem "${TLS_DIR}/ca.crt"

    echo "[setup-tls] ✓ Compatibility symlinks created"
}

# Main execution
echo "[setup-tls] Removing old ECDSA certificates..."
rm -f "${PKI_DIR}/ca.key" "${PKI_DIR}/ca.crt" "${PKI_DIR}/ca.pem" "${PKI_DIR}/ca.srl"
rm -f "${TLS_DIR}/privkey.pem" "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/ca.pem"
rm -f "${MINIO_CERTS_DIR}/public.crt" "${MINIO_CERTS_DIR}/private.key"

echo "[setup-tls] Generating new RSA certificates..."
gen_ca
gen_service_cert

# Always setup MinIO certs (idempotent)
setup_minio_certs

# Setup compatibility symlinks
setup_compat_symlinks

# Setup etcd client certificates (for application services)
setup_etcd_client_certs() {
    local etcd_client_dir="${STATE_DIR}/tls/etcd"
    echo "[setup-tls] Setting up etcd client certificates..."

    mkdir -p "${etcd_client_dir}"

    # The Go code expects specific filenames:
    # 1. Server triplet (for hasServerTriplet detection):
    #    - ca.crt, server.crt, server.pem
    # 2. Client certificates (for etcd connection):
    #    - ca.crt, client.crt, client.pem

    # CA certificate (used by both checks)
    cp "${PKI_DIR}/ca.crt" "${etcd_client_dir}/ca.crt"

    # Server triplet files (for detection)
    cp "${TLS_DIR}/fullchain.pem" "${etcd_client_dir}/server.crt"
    cp "${TLS_DIR}/privkey.pem" "${etcd_client_dir}/server.pem"

    # Client certificate files (for actual connection)
    cp "${TLS_DIR}/fullchain.pem" "${etcd_client_dir}/client.crt"
    cp "${TLS_DIR}/privkey.pem" "${etcd_client_dir}/client.pem"

    chmod 755 "${etcd_client_dir}"
    chmod 644 "${etcd_client_dir}/ca.crt"
    chmod 644 "${etcd_client_dir}/server.crt"
    chmod 644 "${etcd_client_dir}/client.crt"
    chmod 400 "${etcd_client_dir}/server.pem"
    chmod 400 "${etcd_client_dir}/client.pem"

    echo "[setup-tls] ✓ etcd client certificates configured"
}

# Setup etcd client certs
setup_etcd_client_certs

# Set ownership if running as root AND globular user exists
if [[ $EUID -eq 0 ]] && id globular >/dev/null 2>&1; then
    chown -R globular:globular "${PKI_DIR}" "${TLS_DIR}" "${MINIO_CERTS_DIR}" "${STATE_DIR}/tls"
    echo "[setup-tls] ✓ Ownership set to globular:globular"

    # Make CA certificates world-readable (public keys)
    # Private keys remain accessible only to globular user
    chmod 755 "${PKI_DIR}" "${TLS_DIR}"
    chmod 644 "${PKI_DIR}/ca.pem" "${PKI_DIR}/ca.crt" 2>/dev/null || true
    chmod 644 "${TLS_DIR}/ca.pem" "${TLS_DIR}/ca.crt" 2>/dev/null || true
    chmod 644 "${TLS_DIR}/fullchain.pem" "${TLS_DIR}/server.crt" 2>/dev/null || true
    chmod 400 "${PKI_DIR}/ca.key" 2>/dev/null || true
    chmod 400 "${TLS_DIR}/privkey.pem" "${TLS_DIR}/server.key" 2>/dev/null || true

    # Make etcd client certificates accessible (for service discovery)
    chmod 755 "${STATE_DIR}/tls" 2>/dev/null || true
    chmod 755 "${STATE_DIR}/tls/etcd" 2>/dev/null || true
    chmod 644 "${STATE_DIR}/tls/etcd/ca.crt" 2>/dev/null || true
    chmod 644 "${STATE_DIR}/tls/etcd/server.crt" 2>/dev/null || true
    chmod 644 "${STATE_DIR}/tls/etcd/client.crt" 2>/dev/null || true
    chmod 400 "${STATE_DIR}/tls/etcd/server.pem" 2>/dev/null || true
    chmod 400 "${STATE_DIR}/tls/etcd/client.pem" 2>/dev/null || true

    echo "[setup-tls] ✓ CA certificates set to world-readable"
elif [[ $EUID -eq 0 ]]; then
    echo "[setup-tls] → globular user not yet created, ownership will be set during package installation"
fi

echo "[setup-tls] TLS bootstrap complete (RSA)"
echo "[setup-tls]   CA: ${PKI_DIR}/ca.{key,crt,pem} (RSA 4096)"
echo "[setup-tls]   Service cert: ${TLS_DIR}/{fullchain.pem,privkey.pem} (RSA 2048)"
echo "[setup-tls]   Service symlinks: ${TLS_DIR}/{server.crt,server.key,ca.crt} -> {fullchain.pem,privkey.pem,ca.pem}"
echo "[setup-tls]   MinIO certs: ${MINIO_CERTS_DIR}/{public.crt,private.key}"
echo "[setup-tls]   etcd client certs: ${STATE_DIR}/tls/etcd/{ca.crt,server.{crt,pem},client.{crt,pem}}"
