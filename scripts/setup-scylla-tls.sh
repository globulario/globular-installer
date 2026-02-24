#!/bin/bash
set -euo pipefail

echo "=================================="
echo "CONFIGURING SCYLLA TLS"
echo "=================================="
echo ""

# Auto-detect the outbound IP address (the IP Globular services will use to reach ScyllaDB)
# ScyllaDB does not support 0.0.0.0 for listen_address/rpc_address — must be a specific IP.
LOCAL_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
if [[ -z "${LOCAL_IP}" ]]; then
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [[ -z "${LOCAL_IP}" ]]; then
    echo "✗ ERROR: Cannot detect local IP address for ScyllaDB configuration"
    exit 1
fi
echo "→ Detected local IP: ${LOCAL_IP}"
echo ""

# Certificate paths (from Globular TLS setup - canonical paths)
# INV-PKI-1: Use canonical PKI paths instead of config/tls
GLOBULAR_SERVICE_CERT_DIR="/var/lib/globular/pki/issued/services"
GLOBULAR_PKI_DIR="/var/lib/globular/pki"

# ScyllaDB paths
SCYLLA_CONFIG_DIR="/etc/scylla"
SCYLLA_TLS_DIR="/etc/scylla/tls"
SCYLLA_YAML="${SCYLLA_CONFIG_DIR}/scylla.yaml"

# Create ScyllaDB TLS directory
echo "→ Creating ScyllaDB TLS directory..."
mkdir -p "${SCYLLA_TLS_DIR}"

# Copy certificates for ScyllaDB
echo "→ Copying TLS certificates for ScyllaDB..."

if [[ ! -f "${GLOBULAR_SERVICE_CERT_DIR}/service.crt" ]]; then
    echo "✗ ERROR: Globular certificates not found at ${GLOBULAR_SERVICE_CERT_DIR}"
    echo "  Run setup-tls.sh first to generate certificates"
    exit 1
fi

cp "${GLOBULAR_SERVICE_CERT_DIR}/service.crt" "${SCYLLA_TLS_DIR}/server.crt"
cp "${GLOBULAR_SERVICE_CERT_DIR}/service.key" "${SCYLLA_TLS_DIR}/server.key"
cp "${GLOBULAR_PKI_DIR}/ca.pem" "${SCYLLA_TLS_DIR}/ca.crt"

# Set permissions (ScyllaDB runs as scylla user)
chown -R scylla:scylla "${SCYLLA_TLS_DIR}"
chmod 755 "${SCYLLA_TLS_DIR}"
chmod 644 "${SCYLLA_TLS_DIR}/server.crt"
chmod 644 "${SCYLLA_TLS_DIR}/ca.crt"
chmod 400 "${SCYLLA_TLS_DIR}/server.key"

echo "  ✓ Certificates copied to ${SCYLLA_TLS_DIR}"
echo ""

# Backup current scylla.yaml
echo "→ Backing up scylla.yaml..."
cp "${SCYLLA_YAML}" "${SCYLLA_YAML}.backup-$(date +%Y%m%d-%H%M%S)"
echo "  ✓ Backup created"
echo ""

# Update scylla.yaml to enable TLS
echo "→ Updating scylla.yaml for TLS..."

cat > "${SCYLLA_YAML}" <<EOF
seed_provider:
  - class_name: org.apache.cassandra.locator.SimpleSeedProvider
    parameters:
      - seeds: "${LOCAL_IP}"

# --- Client ↔ Node TLS (CQL/native transport) ---
client_encryption_options:
  enabled: true
  certificate: /etc/scylla/tls/server.crt
  keyfile: /etc/scylla/tls/server.key
  truststore: /etc/scylla/tls/ca.crt
  require_client_auth: false

# TLS-enabled CQL port (9142)
native_transport_port_ssl: 9142

# Plaintext CQL port (9042)
listen_address: ${LOCAL_IP}
rpc_address: ${LOCAL_IP}
native_transport_port: 9042

# Addresses advertised to peers and clients
broadcast_address: ${LOCAL_IP}
broadcast_rpc_address: ${LOCAL_IP}
endpoint_snitch: SimpleSnitch

# Developer mode (disable for production)
developer_mode: true

# Data directories
data_file_directories:
  - /var/lib/scylla/data

commitlog_directory: /var/lib/scylla/commitlog

# Performance tuning
commitlog_sync: batch
commitlog_sync_batch_window_in_ms: 2
commitlog_sync_period_in_ms: 10000

# Auto-tune memory (recommended)
auto_adjust_flush_quota: true
EOF

echo "  ✓ scylla.yaml updated"
echo ""

# Verify configuration
echo "→ Verifying certificate files..."
for file in server.crt server.key ca.crt; do
    if [[ -f "${SCYLLA_TLS_DIR}/${file}" ]]; then
        ls -lh "${SCYLLA_TLS_DIR}/${file}" | awk '{print "  ✓ " $9 " (" $5 ", owner: " $3 ":" $4 ")"}'
    else
        echo "  ✗ Missing: ${file}"
    fi
done
echo ""

# Check if ScyllaDB is running
if systemctl is-active --quiet scylla-server.service; then
    echo "→ Restarting ScyllaDB service..."
    systemctl restart scylla-server.service
    echo "  ✓ ScyllaDB restarting..."
    echo ""
    echo "→ Waiting for ScyllaDB to be ready (port 9042)..."
    for i in {1..60}; do
        if ss -tlnp | grep -q ":9042 "; then
            echo "  ✓ ScyllaDB is listening on port 9042 (plaintext)"
            break
        fi
        sleep 1
        echo -n "."
    done
    echo ""
    echo ""
    echo "→ Checking TLS port 9142..."
    for i in {1..30}; do
        if ss -tlnp | grep -q ":9142 "; then
            echo "  ✓ ScyllaDB is listening on port 9142 (TLS)"
            break
        fi
        sleep 1
        echo -n "."
    done
    echo ""
else
    echo "→ Starting ScyllaDB service..."
    systemctl start scylla-server.service
    echo "  ✓ ScyllaDB started"
fi

echo ""
echo "=================================="
echo "TLS CONFIGURATION COMPLETE"
echo "=================================="
echo ""
echo "ScyllaDB is now configured with TLS:"
echo "  • Plaintext CQL: ${LOCAL_IP}:9042"
echo "  • TLS CQL: ${LOCAL_IP}:9142"
echo ""
echo "Certificates:"
echo "  • Server cert: ${SCYLLA_TLS_DIR}/server.crt"
echo "  • Server key: ${SCYLLA_TLS_DIR}/server.key"
echo "  • CA cert: ${SCYLLA_TLS_DIR}/ca.crt"
echo ""
echo "To test TLS connection:"
echo "  cqlsh --ssl ${LOCAL_IP} 9142"
echo ""
echo "To check ScyllaDB status:"
echo "  systemctl status scylla-server.service"
echo "  nodetool status"
echo ""
