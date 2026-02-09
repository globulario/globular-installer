#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ DNS Bootstrap (Day-0) ━━━"
echo ""

# Skip etcd discovery during bootstrap
export GLOBULAR_SKIP_ETCD_DISCOVERY=1

STATE_DIR="${STATE_DIR:-/var/lib/globular}"

# Determine user for client certificates (handle sudo context)
if [[ -n "${SUDO_USER:-}" ]]; then
    # Script run with sudo - use original user's certificates
    CLIENT_USER="$SUDO_USER"
    CLIENT_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    # Script run directly as root or regular user
    CLIENT_USER="${USER}"
    CLIENT_HOME="${HOME}"
fi

# Set up CA certificate path for globular CLI
CA_PATH="${CLIENT_HOME}/.config/globular/tls/localhost/ca.crt"
if [[ ! -f "$CA_PATH" ]]; then
    echo "[bootstrap-dns] ERROR: CA certificate not found at $CA_PATH" >&2
    echo "[bootstrap-dns] Client certificates must be generated before DNS bootstrap" >&2
    exit 1
fi

echo "[bootstrap-dns] Using client certificates for user: $CLIENT_USER"
echo "[bootstrap-dns] CA certificate: $CA_PATH"

# Create wrapper function for globular commands with proper CA
globular_dns() {
    globular --ca "$CA_PATH" "$@"
}

echo "[bootstrap-dns] Waiting for DNS service to be ready..."

# Wait for DNS service to be fully ready (both gRPC and port 53)
MAX_WAIT=30
DNS_READY=0
for i in $(seq 1 $MAX_WAIT); do
    # Check 1: gRPC service responds (any response means it's up)
    if globular_dns dns domains >/dev/null 2>&1; then
        # Check 2: Port 53 UDP listener is bound
        if ss -ulnp 2>/dev/null | grep -qE ':53\s.*dns_server'; then
            DNS_READY=1
            break
        fi
    fi
    sleep 1
done

if [[ $DNS_READY -eq 0 ]]; then
    echo "[bootstrap-dns] ERROR: DNS service not ready after ${MAX_WAIT}s" >&2
    echo "[bootstrap-dns] Debug info:" >&2
    echo "  gRPC status: $(globular_dns dns domains 2>&1 | head -1)" >&2
    echo "  Port 53 status: $(ss -ulnp 2>/dev/null | grep ':53\s' || echo 'not listening')" >&2
    exit 1
fi

echo "[bootstrap-dns] ✓ DNS service ready (gRPC + port 53)"

# Check if globular CLI is available
if ! command -v globular >/dev/null 2>&1; then
    echo "[bootstrap-dns] ERROR: globular command not found in PATH" >&2
    echo "[bootstrap-dns] Expected location: /usr/local/bin/globular" >&2
    echo "[bootstrap-dns] Make sure globular-cli-cmd package is installed" >&2
    exit 1
fi

echo "[bootstrap-dns] Using globular CLI: $(command -v globular)"

# Wait for DNS service to be ready for write operations
echo "[bootstrap-dns] Waiting for DNS database to accept writes..."
MAX_WAIT=30
DNS_WRITABLE=0
TEST_RECORD="bootstrap-test.globular.internal."
TEST_IP="127.0.0.1"

for i in $(seq 1 $MAX_WAIT); do
    echo "[bootstrap-dns] Attempt $i/$MAX_WAIT: Testing DNS write..." >&2

    # Try to create a test record (capture output, don't fail on error)
    set +e
    SET_OUTPUT=$(globular_dns --timeout 5s dns a set "$TEST_RECORD" "$TEST_IP" --ttl 60 2>&1)
    SET_EXIT=$?
    set -e

    echo "[bootstrap-dns]   Set exit code: $SET_EXIT" >&2

    # Verify it actually exists (don't trust exit code due to CLI bug)
    set +e
    GET_OUTPUT=$(globular_dns --timeout 5s dns a get "$TEST_RECORD" 2>&1)
    GET_EXIT=$?
    set -e

    echo "[bootstrap-dns]   Get exit code: $GET_EXIT" >&2

    if echo "$GET_OUTPUT" | grep -q "$TEST_IP"; then
        # Cleanup test record
        globular_dns dns a remove "$TEST_RECORD" >/dev/null 2>&1 || true
        DNS_WRITABLE=1
        echo "[bootstrap-dns] ✓ DNS database ready for writes (after ${i}s)"
        break
    fi
    sleep 1
done

if [[ $DNS_WRITABLE -eq 0 ]]; then
    echo "[bootstrap-dns] ERROR: DNS database not ready for writes after ${MAX_WAIT}s" >&2
    echo "[bootstrap-dns] Diagnostics:" >&2
    echo "  Set command exit: $SET_EXIT" >&2
    echo "  Set output: $SET_OUTPUT" >&2
    echo "  Get command exit: $GET_EXIT" >&2
    echo "  Get output: $GET_OUTPUT" >&2
    echo "[bootstrap-dns] DNS service may not be functioning correctly" >&2
    exit 1
fi

# Determine node IP (prefer non-loopback)
NODE_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$NODE_IP" || "$NODE_IP" == "127.0.0.1" ]]; then
    echo "[bootstrap-dns] ERROR: Could not determine node IP" >&2
    exit 1
fi

# Get actual hostname (short name, not FQDN)
NODE_HOSTNAME=$(hostname -s)
if [[ -z "$NODE_HOSTNAME" ]]; then
    echo "[bootstrap-dns] ERROR: Could not determine hostname" >&2
    exit 1
fi

echo "[bootstrap-dns] Hostname: $NODE_HOSTNAME"
echo "[bootstrap-dns] Node IP: $NODE_IP"

# Add DNS A records for Day-0
echo "[bootstrap-dns] Creating DNS records..."

# <hostname>.globular.internal → node IP (this node)
if globular_dns --timeout 10s dns a set "${NODE_HOSTNAME}.globular.internal." "$NODE_IP" --ttl 300 2>&1; then
    echo "  ✓ ${NODE_HOSTNAME}.globular.internal. → $NODE_IP"
else
    echo "[bootstrap-dns] ERROR: Failed to create ${NODE_HOSTNAME}.globular.internal record" >&2
    exit 1
fi

# api.globular.internal → node IP (API endpoint)
if globular_dns --timeout 10s dns a set api.globular.internal. "$NODE_IP" --ttl 300 2>&1; then
    echo "  ✓ api.globular.internal. → $NODE_IP"
else
    echo "[bootstrap-dns] ERROR: Failed to create api.globular.internal record" >&2
    exit 1
fi

# Wildcard for all undefined subdomains (catches service discovery)
if globular_dns --timeout 10s dns a set "*.globular.internal." "$NODE_IP" --ttl 300 2>&1; then
    echo "  ✓ *.globular.internal. → $NODE_IP (wildcard)"
else
    echo "[bootstrap-dns] ERROR: Failed to create wildcard record" >&2
    exit 1
fi

echo ""
echo "[bootstrap-dns] ✓ DNS bootstrap complete"
echo ""

# Verify records
echo "[bootstrap-dns] Verifying DNS records..."
if dig @127.0.0.1 +short "${NODE_HOSTNAME}.globular.internal" 2>/dev/null | grep -q "$NODE_IP"; then
    echo "  ✓ ${NODE_HOSTNAME}.globular.internal resolves correctly"
else
    echo "  ⚠ Warning: ${NODE_HOSTNAME}.globular.internal resolution test failed"
fi

if dig @127.0.0.1 +short api.globular.internal 2>/dev/null | grep -q "$NODE_IP"; then
    echo "  ✓ api.globular.internal resolves correctly"
else
    echo "  ⚠ Warning: api.globular.internal resolution test failed"
fi

echo ""
