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

# Backup current scylla.yaml (if it exists)
if [[ -f "${SCYLLA_YAML}" ]]; then
    echo "→ Backing up scylla.yaml..."
    cp "${SCYLLA_YAML}" "${SCYLLA_YAML}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "  ✓ Backup created"
else
    echo "→ No existing scylla.yaml (fresh install) — generating new config"
fi
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

# REST API port — moved to 56093 to avoid conflict with Globular service
# ports (10000+). ScyllaDB defaults to 10000 which collides with persistence.
api_port: 56093
api_address: ${LOCAL_IP}
EOF

echo "  ✓ scylla.yaml updated"
echo ""

# Ensure all ScyllaDB data directories exist with correct ownership.
# These may be missing after a data-dir wipe or fresh reinstall.
echo "→ Ensuring ScyllaDB data directories exist..."
for dir in /var/lib/scylla /var/lib/scylla/data /var/lib/scylla/commitlog; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        echo "  ✓ Created $dir"
    fi
done
chown -R scylla:scylla /var/lib/scylla
echo "  ✓ /var/lib/scylla ownership set to scylla:scylla"

# Ensure /var/lib/scylla/conf/ points to /etc/scylla/ — ScyllaDB looks here
# for its config even though we write to /etc/scylla/scylla.yaml.
# After a data-dir wipe this symlink is gone and ScyllaDB fails to start with:
#   "Could not open file at /var/lib/scylla/conf/scylla.yaml"
SCYLLA_DATA_CONF="/var/lib/scylla/conf"
if [[ -L "${SCYLLA_DATA_CONF}" ]]; then
    # Already a symlink — verify it points to the right place
    echo "  ✓ ${SCYLLA_DATA_CONF} (symlink exists)"
elif [[ -d "${SCYLLA_DATA_CONF}" ]]; then
    # Real directory — symlink the yaml file inside it
    echo "→ Symlinking scylla.yaml into ${SCYLLA_DATA_CONF}..."
    ln -sf "${SCYLLA_YAML}" "${SCYLLA_DATA_CONF}/scylla.yaml"
    echo "  ✓ ${SCYLLA_DATA_CONF}/scylla.yaml → ${SCYLLA_YAML}"
else
    # Missing — create symlink to /etc/scylla
    echo "→ Creating ${SCYLLA_DATA_CONF} symlink to /etc/scylla..."
    ln -sfn /etc/scylla "${SCYLLA_DATA_CONF}"
    echo "  ✓ ${SCYLLA_DATA_CONF} → /etc/scylla"
fi
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

# Ensure ScyllaDB environment file exists (Ubuntu/Mint don't have /etc/sysconfig)
SCYLLA_ENV_DIR="/etc/sysconfig"
SCYLLA_ENV_FILE="${SCYLLA_ENV_DIR}/scylla-server"
if [[ ! -f "${SCYLLA_ENV_FILE}" ]]; then
    echo "→ Creating ScyllaDB environment file..."
    mkdir -p "${SCYLLA_ENV_DIR}"
    cat > "${SCYLLA_ENV_FILE}" <<ENVEOF
# ScyllaDB server environment (auto-generated by Globular installer)
SCYLLA_ARGS="--log-to-syslog 1 --log-to-stdout 0 --default-log-level info --network-stack posix"
SCYLLA_HOME="/var/lib/scylla"
ENVEOF
    echo "  ✓ Created ${SCYLLA_ENV_FILE}"
fi

# Ensure scylla.d conf files exist (systemd EnvironmentFile glob fails on empty dir)
if [[ -d /etc/scylla.d ]] && ! ls /etc/scylla.d/*.conf &>/dev/null; then
    echo "→ Creating default scylla.d conf files..."
    echo "DEV_MODE=--developer-mode=1" > /etc/scylla.d/dev-mode.conf
    echo "# memory.conf" > /etc/scylla.d/memory.conf
    echo "# io.conf" > /etc/scylla.d/io.conf
    echo "# cpuset.conf" > /etc/scylla.d/cpuset.conf
    echo "  ✓ Default conf files created in /etc/scylla.d/"
fi

# Ensure systemd overrides for Debian/Ubuntu (sysconfdir, dependencies)
SCYLLA_OVERRIDE_DIR="/etc/systemd/system/scylla-server.service.d"
mkdir -p "${SCYLLA_OVERRIDE_DIR}"
if [[ ! -f "${SCYLLA_OVERRIDE_DIR}/sysconfdir.conf" ]]; then
    echo "→ Creating systemd override for sysconfig path..."
    cat > "${SCYLLA_OVERRIDE_DIR}/sysconfdir.conf" <<SYSEOF
[Service]
EnvironmentFile=
EnvironmentFile=-/etc/sysconfig/scylla-server
EnvironmentFile=-/etc/scylla.d/*.conf
SYSEOF
    echo "  ✓ Created ${SCYLLA_OVERRIDE_DIR}/sysconfdir.conf"
fi
if [[ ! -f "${SCYLLA_OVERRIDE_DIR}/dependencies.conf" ]]; then
    cat > "${SCYLLA_OVERRIDE_DIR}/dependencies.conf" <<DEPEOF
[Unit]
After=network-online.target
Wants=network-online.target
DEPEOF
fi
systemctl daemon-reload
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
    echo "  ✓ ScyllaDB starting..."
    echo ""
    echo "→ Waiting for ScyllaDB to be ready (port 9042)..."
    for i in {1..90}; do
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
