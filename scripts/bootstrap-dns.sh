#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ DNS Bootstrap (Day-0) ━━━"
echo ""

# Skip etcd discovery during bootstrap
export GLOBULAR_SKIP_ETCD_DISCOVERY=1

STATE_DIR="${STATE_DIR:-/var/lib/globular}"

echo "[bootstrap-dns] Waiting for DNS service to be ready..."

# Wait for DNS service to be fully ready (both gRPC and port 53)
MAX_WAIT=30
DNS_READY=0
for i in $(seq 1 $MAX_WAIT); do
    # Check 1: gRPC service responds (any response means it's up)
    if globular dns domains >/dev/null 2>&1; then
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
    echo "  gRPC status: $(globular dns domains 2>&1 | head -1)" >&2
    echo "  Port 53 status: $(ss -ulnp 2>/dev/null | grep ':53\s' || echo 'not listening')" >&2
    exit 1
fi

echo "[bootstrap-dns] ✓ DNS service ready (gRPC + port 53)"

# Give DNS service extra time to fully initialize its database
echo "[bootstrap-dns] Waiting for DNS database initialization..."
sleep 3

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
globular --timeout 10s dns a set "${NODE_HOSTNAME}.globular.internal." "$NODE_IP" --ttl 300
echo "  ✓ ${NODE_HOSTNAME}.globular.internal. → $NODE_IP"

# api.globular.internal → node IP (API endpoint)
globular --timeout 10s dns a set api.globular.internal. "$NODE_IP" --ttl 300
echo "  ✓ api.globular.internal. → $NODE_IP"

# Wildcard for all undefined subdomains (catches service discovery)
globular --timeout 10s dns a set "*.globular.internal." "$NODE_IP" --ttl 300
echo "  ✓ *.globular.internal. → $NODE_IP (wildcard)"

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
