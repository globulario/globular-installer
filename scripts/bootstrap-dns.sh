#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ DNS Bootstrap (Day-0) ━━━"
echo ""

# Skip etcd discovery during bootstrap
export GLOBULAR_SKIP_ETCD_DISCOVERY=1

STATE_DIR="${STATE_DIR:-/var/lib/globular}"

echo "[bootstrap-dns] Waiting for DNS service to be ready..."

# Wait for DNS service to respond
MAX_WAIT=30
DNS_READY=0
for i in $(seq 1 $MAX_WAIT); do
    if globular dns domains 2>/dev/null | grep -q "globular.internal"; then
        DNS_READY=1
        break
    fi
    sleep 1
done

if [[ $DNS_READY -eq 0 ]]; then
    echo "[bootstrap-dns] ERROR: DNS service not ready after ${MAX_WAIT}s" >&2
    exit 1
fi

echo "[bootstrap-dns] ✓ DNS service ready"

# Determine node IP (prefer non-loopback)
NODE_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$NODE_IP" || "$NODE_IP" == "127.0.0.1" ]]; then
    echo "[bootstrap-dns] ERROR: Could not determine node IP" >&2
    exit 1
fi

echo "[bootstrap-dns] Node IP: $NODE_IP"

# Add DNS A records for Day-0
echo "[bootstrap-dns] Creating DNS records..."

# n0.globular.internal → node IP (this node)
globular dns a set n0.globular.internal. "$NODE_IP" --ttl 300
echo "  ✓ n0.globular.internal. → $NODE_IP"

# api.globular.internal → node IP (API endpoint)
globular dns a set api.globular.internal. "$NODE_IP" --ttl 300
echo "  ✓ api.globular.internal. → $NODE_IP"

# Optional: Add wildcard for all services (uncomment if desired)
# globular dns a set "*.globular.internal." "$NODE_IP" --ttl 300
# echo "  ✓ *.globular.internal. → $NODE_IP"

echo ""
echo "[bootstrap-dns] ✓ DNS bootstrap complete"
echo ""

# Verify records
echo "[bootstrap-dns] Verifying DNS records..."
if dig @127.0.0.1 +short n0.globular.internal 2>/dev/null | grep -q "$NODE_IP"; then
    echo "  ✓ n0.globular.internal resolves correctly"
else
    echo "  ⚠ Warning: n0.globular.internal resolution test failed"
fi

if dig @127.0.0.1 +short api.globular.internal 2>/dev/null | grep -q "$NODE_IP"; then
    echo "  ✓ api.globular.internal resolves correctly"
else
    echo "  ⚠ Warning: api.globular.internal resolution test failed"
fi

echo ""
