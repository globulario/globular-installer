#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ System Resolver Configuration ━━━"
echo ""

DNS_BINARY="/usr/lib/globular/bin/dns_server"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
  echo "❌ This script must be run as root (use sudo)" >&2
  exit 1
fi

echo "[configure-resolver] Step 1: Grant CAP_NET_BIND_SERVICE to DNS server..."
if [[ ! -f "$DNS_BINARY" ]]; then
    echo "  ⚠ DNS binary not found at $DNS_BINARY" >&2
    echo "  This is expected if DNS service hasn't been installed yet"
else
    # Grant capability for DNS to bind port 53
    setcap 'cap_net_bind_service=+ep' "$DNS_BINARY"
    echo "  ✓ CAP_NET_BIND_SERVICE granted"

    # Verify capability
    if getcap "$DNS_BINARY" | grep -q cap_net_bind_service; then
        echo "  ✓ Capability verified"
    else
        echo "  ⚠ Warning: Capability verification failed" >&2
    fi
fi

echo ""
echo "[configure-resolver] Step 2: Configure system DNS resolver..."

# Detect resolver system
if systemctl is-active --quiet systemd-resolved; then
    echo "  → Using systemd-resolved (split-DNS)"

    # Create configuration directory
    mkdir -p /etc/systemd/resolved.conf.d

    # Configure split-DNS for globular.internal domain
    cat > /etc/systemd/resolved.conf.d/globular.conf <<'EOF'
[Resolve]
# Use Globular DNS for globular.internal zone
DNS=127.0.0.1
Domains=~globular.internal
EOF

    # Restart systemd-resolved
    systemctl restart systemd-resolved

    echo "  ✓ systemd-resolved configured for globular.internal zone"
    echo "  ✓ System will query 127.0.0.1 for *.globular.internal"

elif command -v resolvconf >/dev/null 2>&1; then
    echo "  → Using resolvconf"

    # Add nameserver to resolvconf
    echo "nameserver 127.0.0.1" | resolvconf -a globular

    echo "  ✓ resolvconf configured"

else
    echo "  ⚠ No supported resolver system found (systemd-resolved or resolvconf)"
    echo ""
    echo "  Manual configuration required:"
    echo "  1. Ensure /etc/resolv.conf includes: nameserver 127.0.0.1"
    echo "  2. Or configure your DNS system to forward *.globular.internal to 127.0.0.1"
    echo ""
fi

echo ""
echo "[configure-resolver] Step 3: Verification..."

# Test if resolver is configured
if command -v resolvectl >/dev/null 2>&1; then
    echo "  → Resolver status:"
    resolvectl status | grep -A 5 "globular" || true
fi

echo ""
echo "[configure-resolver] ✓ System resolver configuration complete"
echo ""
echo "Notes:"
echo "  - DNS service will bind to 127.0.0.1:53 (UDP and TCP)"
echo "  - System queries for *.globular.internal will use Globular DNS"
echo "  - Other queries will use system default DNS"
echo ""
