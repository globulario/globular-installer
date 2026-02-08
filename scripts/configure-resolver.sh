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
echo "[configure-resolver] Step 2: Check for port 53 conflicts..."

# Check if another service is already using port 53
if ss -ulnp 2>/dev/null | grep -E ':53\s' | grep -v dns_server >/dev/null; then
    echo "  ⚠ WARNING: Another process is already listening on port 53"
    echo ""
    ss -ulnp 2>/dev/null | grep -E ':53\s' | grep -v dns_server
    echo ""
    echo "  Common conflicts and solutions:"
    echo "    - dnsmasq:           sudo systemctl stop dnsmasq && sudo systemctl disable dnsmasq"
    echo "    - systemd-resolved:  Edit /etc/systemd/resolved.conf, set DNSStubListener=no"
    echo "    - bind9/named:       sudo systemctl stop bind9 && sudo systemctl disable bind9"
    echo ""
    echo "  Note: Globular DNS service may fail to start until port 53 is free"
    echo ""
fi

echo ""
echo "[configure-resolver] Step 3: Configure system DNS resolver..."

# Detect resolver system (check NetworkManager FIRST - most common on Mint/Ubuntu Desktop)
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "  → Using NetworkManager (split-DNS)"

    # Get active connection(s)
    ACTIVE_CONNS=$(nmcli -t -f NAME connection show --active 2>/dev/null)

    if [[ -z "$ACTIVE_CONNS" ]]; then
        echo "  ⚠ Warning: No active NetworkManager connections found"
        echo "  Falling back to manual configuration instructions"
    else
        # Configure each active connection for split-DNS
        while IFS= read -r CONN; do
            if [[ -z "$CONN" ]]; then
                continue
            fi

            echo "  → Configuring connection: $CONN"

            # Add 127.0.0.1 as additional DNS server (not replacing existing)
            # Use ipv4.dns-search to limit scope to globular.internal
            nmcli connection modify "$CONN" \
                +ipv4.dns "127.0.0.1" \
                +ipv4.dns-search "globular.internal" 2>/dev/null || {
                echo "  ⚠ Warning: Could not modify connection $CONN"
                continue
            }

            # Apply changes (bring connection up to reload settings)
            nmcli connection up "$CONN" >/dev/null 2>&1 || true

            echo "  ✓ $CONN configured for globular.internal split-DNS"
        done <<< "$ACTIVE_CONNS"

        echo "  ✓ NetworkManager configured for *.globular.internal"
        echo "  ✓ System will query 127.0.0.1 for globular.internal domain"
    fi

elif systemctl is-active --quiet systemd-resolved 2>/dev/null; then
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

else
    echo "  ⚠ No supported resolver system found (NetworkManager, systemd-resolved)"
    echo ""
    echo "  Manual configuration required:"
    echo "  For NetworkManager:"
    echo "    nmcli connection modify <connection-name> +ipv4.dns 127.0.0.1"
    echo "    nmcli connection modify <connection-name> +ipv4.dns-search globular.internal"
    echo ""
    echo "  For systemd-resolved:"
    echo "    Create /etc/systemd/resolved.conf.d/globular.conf with:"
    echo "    [Resolve]"
    echo "    DNS=127.0.0.1"
    echo "    Domains=~globular.internal"
    echo ""
    echo "  For other systems:"
    echo "    Configure your DNS to forward *.globular.internal queries to 127.0.0.1"
    echo ""
fi

echo ""
echo "[configure-resolver] Step 4: Verification..."

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
