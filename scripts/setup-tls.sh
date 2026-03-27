#!/usr/bin/env bash
set -euo pipefail

# TLS Bootstrap for Globular Day-0
# Generates root CA and service certificates using RSA (not ECDSA) for XDS compatibility

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
PKI_DIR="${STATE_DIR}/pki"
# Canonical locations for certificates (INV-PKI-1)
SERVICE_CERT_DIR="${PKI_DIR}/issued/services"
ETCD_CERT_DIR="${PKI_DIR}/issued/etcd"
MINIO_CERTS_DIR="${STATE_DIR}/.minio/certs"

echo "[setup-tls] Bootstrapping TLS certificates (RSA)"
echo "[setup-tls] STATE_DIR=${STATE_DIR}"

# Create directories (canonical PKI structure)
mkdir -p "${PKI_DIR}"
mkdir -p "${SERVICE_CERT_DIR}"
mkdir -p "${ETCD_CERT_DIR}"
mkdir -p "${MINIO_CERTS_DIR}"
chmod 755 "${STATE_DIR}" "${PKI_DIR}"

# Function to generate RSA key (not ECDSA - for XDS compatibility)
# Writes to a temp file first, then atomically renames into place so that
# running services never see a missing or half-written key file.
gen_rsa_key() {
    local keyfile="$1"
    local bits="${2:-2048}"
    local tmpfile="${keyfile}.tmp.$$"
    openssl genrsa -out "${tmpfile}" "${bits}"
    chmod 400 "${tmpfile}"
    # Set ownership before the rename so the file is readable by the service
    # user from the instant it appears at the final path.
    if [[ $EUID -eq 0 ]] && id globular >/dev/null 2>&1; then
        chown globular:globular "${tmpfile}"
    fi
    mv -f "${tmpfile}" "${keyfile}"
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
        -subj "/CN=Globular Root CA/O=globular.internal" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

    chmod 444 "${crtfile}"

    # Ensure canonical CA location exists (INV-PKI-1)
    if [[ ! -f "${PKI_DIR}/ca.crt" ]]; then
        cp "${crtfile}" "${PKI_DIR}/ca.crt"
    fi
    chmod 644 "${PKI_DIR}/ca.crt"

    # Create CA bundle
    cp "${crtfile}" "${pemfile}"
    chmod 444 "${pemfile}"

    echo "[setup-tls] ✓ Root CA generated (RSA)"
}

# Function to generate service certificate
gen_service_cert() {
    # Use canonical paths (INV-PKI-1)
    local keyfile="${SERVICE_CERT_DIR}/service.key"
    local crtfile="${SERVICE_CERT_DIR}/service.crt"
    local csrfile="${SERVICE_CERT_DIR}/service.csr"

    echo "[setup-tls] Generating service certificate (RSA 2048)..."

    # Generate service private key (RSA 2048)
    gen_rsa_key "${keyfile}" 2048

    # Auto-detect node IP and hostname for SANs
    local NODE_IP=$(hostname -I | awk '{print $1}')
    local NODE_HOSTNAME=$(hostname -s)
    local NODE_FQDN=$(hostname -f 2>/dev/null || echo "${NODE_HOSTNAME}")

    # Build SANs dynamically — routable IPs only, NO 127.0.0.1.
    # Using 127.0.0.1 in SANs masks multi-node TLS bugs: services appear to
    # work locally but fail when accessed from other nodes.
    local SANS="DNS:localhost,DNS:*.localhost"

    # Add ALL routable IPs from this node (not just the first one)
    local ALL_IPS
    ALL_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$')
    local IP_COUNT=0
    for ip in ${ALL_IPS}; do
        if [[ "${ip}" != "127.0.0.1" && "${ip}" != "::1" ]]; then
            SANS="${SANS},IP:${ip}"
            echo "[setup-tls]   Adding node IP: ${ip}"
            IP_COUNT=$((IP_COUNT + 1))
        fi
    done
    if [[ $IP_COUNT -eq 0 ]]; then
        echo "[setup-tls] ERROR: No routable IP detected. Cannot generate cert with only loopback." >&2
        exit 1
    fi

    # Add hostname
    if [[ -n "${NODE_HOSTNAME}" ]]; then
        SANS="${SANS},DNS:${NODE_HOSTNAME}"
        echo "[setup-tls]   Adding hostname: ${NODE_HOSTNAME}"
    fi

    # Add FQDN if different from hostname
    if [[ -n "${NODE_FQDN}" ]] && [[ "${NODE_FQDN}" != "${NODE_HOSTNAME}" ]]; then
        SANS="${SANS},DNS:${NODE_FQDN}"
        echo "[setup-tls]   Adding FQDN: ${NODE_FQDN}"
    fi

    # Add cluster domain wildcards (DOMAIN exported by install-day0.sh)
    local CLUSTER_DOMAIN="${DOMAIN:-globular.internal}"
    SANS="${SANS},DNS:*.${CLUSTER_DOMAIN},DNS:${CLUSTER_DOMAIN}"

    echo "[setup-tls]   SANs: ${SANS}"

    # Generate CSR with SANs
    openssl req -new \
        -key "${keyfile}" \
        -out "${csrfile}" \
        -subj "/CN=${NODE_HOSTNAME}/O=globular.internal" \
        -addext "subjectAltName=${SANS}"

    # Sign with CA (1 year validity)
    openssl x509 -req \
        -in "${csrfile}" \
        -CA "${PKI_DIR}/ca.crt" \
        -CAkey "${PKI_DIR}/ca.key" \
        -CAcreateserial \
        -out "${crtfile}" \
        -days 365 \
        -sha256 \
        -extfile <(printf "subjectAltName=${SANS}\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth")

    chmod 444 "${crtfile}"
    rm -f "${csrfile}"

    echo "[setup-tls] ✓ Service certificate generated (RSA)"
}

# Function to setup MinIO certs
setup_minio_certs() {
    echo "[setup-tls] Setting up MinIO certificates..."

    # MinIO expects: public.crt and private.key
    ln -sf "${SERVICE_CERT_DIR}/service.crt" "${MINIO_CERTS_DIR}/public.crt"
    ln -sf "${SERVICE_CERT_DIR}/service.key" "${MINIO_CERTS_DIR}/private.key"

    echo "[setup-tls] ✓ MinIO certificates configured"
}

# Function to create compatibility symlinks (deprecated - canonical paths used directly)
setup_compat_symlinks() {
    echo "[setup-tls] Skipping compatibility symlinks (using canonical paths)"
    # Services now use GetServiceCertPath() which reads from canonical locations directly
}

# Main execution
# Track whether certs changed so we can restart services if needed.
CERTS_CHANGED=0

# Check if CA exists and is RSA (idempotent - don't regenerate unnecessarily)
CA_EXISTS=0
CA_IS_RSA=0

if [[ -f "${PKI_DIR}/ca.key" ]] && [[ -f "${PKI_DIR}/ca.crt" ]]; then
    CA_EXISTS=1
    # Check if CA key is RSA (not ECDSA)
    if openssl rsa -in "${PKI_DIR}/ca.key" -check -noout >/dev/null 2>&1; then
        CA_IS_RSA=1
    fi
fi

if [[ $CA_EXISTS -eq 1 ]] && [[ $CA_IS_RSA -eq 1 ]]; then
    echo "[setup-tls] ✓ RSA CA already exists, reusing..."
    CA_SERIAL=$(openssl x509 -in "${PKI_DIR}/ca.crt" -noout -serial)
    echo "[setup-tls]   CA Serial: ${CA_SERIAL}"
else
    if [[ $CA_EXISTS -eq 1 ]]; then
        echo "[setup-tls] Removing old ECDSA CA..."
        rm -f "${PKI_DIR}/ca.key" "${PKI_DIR}/ca.crt" "${PKI_DIR}/ca.pem" "${PKI_DIR}/ca.srl"
    fi
    echo "[setup-tls] Generating new RSA CA..."
    gen_ca
    CERTS_CHANGED=1
fi

# Check if service certificate exists and is valid
CERT_VALID=0
if [[ -f "${SERVICE_CERT_DIR}/service.key" ]] && [[ -f "${SERVICE_CERT_DIR}/service.crt" ]]; then
    # Check if cert is signed by current CA
    if openssl verify -CAfile "${PKI_DIR}/ca.crt" "${SERVICE_CERT_DIR}/service.crt" >/dev/null 2>&1; then
        CERT_VALID=1
    fi
fi

if [[ $CERT_VALID -eq 1 ]]; then
    echo "[setup-tls] ✓ Service certificate is valid, skipping regeneration..."
else
    echo "[setup-tls] Generating new service certificate..."
    # Do NOT rm the old key/cert before generating the new one.  gen_service_cert
    # (via gen_rsa_key) writes to a temp file and atomically renames into place,
    # so running services always see either the old or the new file — never a gap.
    rm -f "${MINIO_CERTS_DIR}/public.crt" "${MINIO_CERTS_DIR}/private.key"
    gen_service_cert
    CERTS_CHANGED=1
fi

# Always setup MinIO certs (idempotent)
setup_minio_certs

# Setup compatibility symlinks
setup_compat_symlinks

# Setup etcd client certificates at canonical location (INV-PKI-1)
setup_etcd_client_certs() {
    echo "[setup-tls] Setting up etcd client certificates at canonical location..."

    # GetEtcdTLS() expects:
    # - /var/lib/globular/pki/issued/etcd/client.crt
    # - /var/lib/globular/pki/issued/etcd/client.key
    # - /var/lib/globular/pki/ca.crt

    # Symlink service cert to etcd client cert location (reuse service cert for etcd client)
    ln -sf "${SERVICE_CERT_DIR}/service.crt" "${ETCD_CERT_DIR}/client.crt"
    ln -sf "${SERVICE_CERT_DIR}/service.key" "${ETCD_CERT_DIR}/client.key"

    chmod 755 "${ETCD_CERT_DIR}"

    echo "[setup-tls] ✓ etcd client certificates configured at canonical location"
}

# Setup etcd client certs
setup_etcd_client_certs

# Set ownership if running as root AND globular user exists
if [[ $EUID -eq 0 ]] && id globular >/dev/null 2>&1; then
    chown -R globular:globular "${PKI_DIR}" "${MINIO_CERTS_DIR}"
    echo "[setup-tls] ✓ Ownership set to globular:globular"

    # Make CA certificates world-readable (public keys)
    # Private keys remain accessible only to globular user
    chmod 755 "${PKI_DIR}" "${SERVICE_CERT_DIR}" "${ETCD_CERT_DIR}"
    chmod 644 "${PKI_DIR}/ca.pem" "${PKI_DIR}/ca.crt" 2>/dev/null || true
    # TLS_DIR no longer used - certs at canonical paths
    chmod 644 "${SERVICE_CERT_DIR}/service.crt" 2>/dev/null || true
    chmod 400 "${PKI_DIR}/ca.key" 2>/dev/null || true
    chmod 400 "${SERVICE_CERT_DIR}/service.key" 2>/dev/null || true

    # Make etcd client certificates accessible (for service discovery)
    chmod 644 "${ETCD_CERT_DIR}/client.crt" 2>/dev/null || true
    chmod 400 "${ETCD_CERT_DIR}/client.key" 2>/dev/null || true

    echo "[setup-tls] ✓ CA certificates set to world-readable"
elif [[ $EUID -eq 0 ]]; then
    echo "[setup-tls] → globular user not yet created, ownership will be set during package installation"
fi

echo "[setup-tls] TLS bootstrap complete (RSA)"
echo "[setup-tls]   CA: ${PKI_DIR}/ca.{key,crt,pem} (RSA 4096)"
echo "[setup-tls]   Service cert: ${SERVICE_CERT_DIR}/{service.crt,service.key} (RSA 2048)"
echo "[setup-tls]   MinIO certs: ${MINIO_CERTS_DIR}/{public.crt,private.key}"
echo "[setup-tls]   etcd client certs: ${ETCD_CERT_DIR}/{client.crt,client.key}"

# Restart running Globular services so they pick up the new certificates.
# Without this, services hold the old CA/cert in memory and get
# "tls: bad certificate" rejections from etcd and each other.
if [[ $CERTS_CHANGED -eq 1 ]]; then
    RUNNING_UNITS=$(systemctl list-units --type=service --state=running --no-legend 'globular-*' 2>/dev/null | awk '{print $1}')
    if [[ -n "${RUNNING_UNITS}" ]]; then
        echo "[setup-tls] Certificates changed — restarting Globular services..."
        # Restart etcd first so it loads the new server cert before clients reconnect.
        if systemctl is-active --quiet globular-etcd.service 2>/dev/null; then
            systemctl restart globular-etcd.service
            echo "[setup-tls]   ✓ globular-etcd restarted"
            sleep 2
        fi
        # Restart remaining services.
        for unit in ${RUNNING_UNITS}; do
            if [[ "${unit}" != "globular-etcd.service" ]]; then
                systemctl restart "${unit}" 2>/dev/null && \
                    echo "[setup-tls]   ✓ ${unit} restarted" || \
                    echo "[setup-tls]   ⚠ ${unit} restart failed"
            fi
        done
        echo "[setup-tls] ✓ All running services restarted with new certificates"
    fi
fi
echo "[setup-tls]   etcd client certs: ${ETCD_CERT_DIR}/{client.crt,client.key}"
