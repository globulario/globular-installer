#!/usr/bin/env bash
set -euo pipefail

# Globular DNS System Resolver Configuration
# Configures system resolver to use Globular DNS for .globular.internal domain
#
# Environment Variables:
#   JOIN_DNS_SERVER - DNS server IP for Day-1+ nodes (e.g., 10.0.0.63)
#                     If not set, uses 127.0.0.1 (Day-0 mode)

echo ""
echo "━━━ System Resolver Configuration ━━━"
echo ""

DNS_BINARY="/usr/lib/globular/bin/dns_server"
RESOLVED_CONF_DIR="/etc/systemd/resolved.conf.d"
NETWORKMANAGER_CONF_DIR="/etc/NetworkManager/conf.d"
NETWORKMANAGER_DNS_CONF="${NETWORKMANAGER_CONF_DIR}/99-globular-dns.conf"

# Detect node type
NODE_TYPE="day0"
GLOBULAR_DNS_SERVER="127.0.0.1"

if [[ -n "${JOIN_DNS_SERVER:-}" ]]; then
    NODE_TYPE="joining"
    GLOBULAR_DNS_SERVER="${JOIN_DNS_SERVER}"
    echo "→ Joining node mode: Using DNS server ${GLOBULAR_DNS_SERVER}"
else
    echo "→ Day-0 node mode: Using local DNS server 127.0.0.1"
fi

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
  echo "❌ This script must be run as root (use sudo)" >&2
  exit 1
fi

# Get local node information
HOSTNAME=$(hostname)
NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null || echo "")

echo "→ Node: ${HOSTNAME}"
echo "→ IP: ${NODE_IP}"
echo ""

# Step 1: Grant CAP_NET_BIND_SERVICE (Day-0 only)
if [[ "$NODE_TYPE" == "day0" ]]; then
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
else
    echo "[configure-resolver] Step 1: Skipping (Joining Node)"
fi

echo ""
echo "[configure-resolver] Step 2: Check for port 53 conflicts..."

# Check if another service is already using port 53 (Day-0 only)
if [[ "$NODE_TYPE" == "day0" ]]; then
    if ss -ulnp 2>/dev/null | grep -E ':53\s' | grep -v dns_server >/dev/null; then
        echo "  ⚠ WARNING: Another process is already listening on port 53"
        echo ""
        ss -ulnp 2>/dev/null | grep -E ':53\s' | grep -v dns_server
        echo ""
        echo "  Common conflicts and solutions:"
        echo "    - systemd-resolved stub: Edit /etc/systemd/resolved.conf, set DNSStubListener=no"
        echo "    - dnsmasq:               sudo systemctl stop dnsmasq && sudo systemctl disable dnsmasq"
        echo "    - bind9/named:           sudo systemctl stop bind9 && sudo systemctl disable bind9"
        echo ""
        echo "  Note: Globular DNS service may fail to start until port 53 is free"
        echo ""
    fi
else
    echo "  → Skipping (Joining node)"
fi

echo ""
echo "[configure-resolver] Step 3: Configure systemd-resolved..."

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "  → systemd-resolved is active"

    mkdir -p "${RESOLVED_CONF_DIR}"

    cat > "${RESOLVED_CONF_DIR}/globular-dns.conf" <<EOF
# Globular DNS Configuration
# Generated: $(date)
# Node Type: ${NODE_TYPE}

[Resolve]
# Use Globular DNS as primary resolver
DNS=${GLOBULAR_DNS_SERVER}

# Search domain for short names
Domains=globular.internal

# Allow fallback to other DNS servers for external domains
FallbackDNS=1.1.1.1 8.8.8.8

# DNS over TLS
DNSOverTLS=no

# DNSSEC validation (if supported)
DNSSEC=allow-downgrade

# Cache DNS results
Cache=yes
CacheFromLocalhost=yes

# Disable multicast DNS
MulticastDNS=no
LLMNR=no
EOF

    echo "  ✓ Created ${RESOLVED_CONF_DIR}/globular-dns.conf"

    # Restart systemd-resolved
    systemctl restart systemd-resolved
    echo "  ✓ Restarted systemd-resolved"

elif command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "  → Using NetworkManager (without systemd-resolved)"

    mkdir -p "${NETWORKMANAGER_CONF_DIR}"

    cat > "${NETWORKMANAGER_DNS_CONF}" <<EOF
# Globular DNS Configuration for NetworkManager
# Generated: $(date)

[main]
dns=default

[connection]
ipv4.ignore-auto-dns=false
ipv6.ignore-auto-dns=false
EOF

    echo "  ✓ Created ${NETWORKMANAGER_DNS_CONF}"

    # Get active connection(s)
    ACTIVE_CONNS=$(nmcli -t -f NAME connection show --active 2>/dev/null || echo "")

    if [[ -n "$ACTIVE_CONNS" ]]; then
        while IFS= read -r CONN; do
            if [[ -z "$CONN" ]]; then
                continue
            fi

            echo "  → Configuring connection: $CONN"

            # Add Globular DNS as primary, keep existing as fallback
            nmcli connection modify "$CONN" \
                +ipv4.dns "${GLOBULAR_DNS_SERVER}" \
                +ipv4.dns-search "globular.internal" 2>/dev/null || {
                echo "  ⚠ Warning: Could not modify connection $CONN"
                continue
            }

            # Apply changes
            nmcli connection up "$CONN" >/dev/null 2>&1 || true

            echo "  ✓ $CONN configured"
        done <<< "$ACTIVE_CONNS"
    fi

    echo "  ✓ NetworkManager configured"

else
    echo "  ⚠ No supported resolver system found (systemd-resolved, NetworkManager)"
    echo ""
    echo "  Manual configuration required:"
    echo "  For systemd-resolved:"
    echo "    Create /etc/systemd/resolved.conf.d/globular-dns.conf with:"
    echo "    [Resolve]"
    echo "    DNS=${GLOBULAR_DNS_SERVER}"
    echo "    Domains=globular.internal"
    echo "    FallbackDNS=1.1.1.1 8.8.8.8"
    echo ""
fi

echo ""
echo "[configure-resolver] Step 4: Configure firewall (Day-0 only)..."

if [[ "$NODE_TYPE" == "day0" ]]; then
    # Get cluster network
    SUBNET=$(ip route | grep "$NODE_IP" | grep -v default | awk '{print $1}' | head -1)

    if [[ -z "$SUBNET" ]]; then
        SUBNET="10.0.0.0/8"
        echo "  → Using default subnet: ${SUBNET}"
    else
        echo "  → Detected subnet: ${SUBNET}"
    fi

    # Configure firewall
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "  → Configuring firewalld..."
        firewall-cmd --permanent --zone=public --add-service=dns 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-source="${SUBNET}" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        echo "  ✓ firewalld configured"

    elif systemctl is-active --quiet ufw 2>/dev/null; then
        echo "  → Configuring UFW..."
        ufw allow from "${SUBNET}" to any port 53 proto udp comment "Globular DNS" 2>/dev/null || true
        ufw allow from "${SUBNET}" to any port 53 proto tcp comment "Globular DNS TCP" 2>/dev/null || true
        echo "  ✓ UFW configured"

    elif command -v iptables >/dev/null 2>&1; then
        echo "  → Configuring iptables..."
        iptables -C INPUT -p udp -s "${SUBNET}" --dport 53 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp -s "${SUBNET}" --dport 53 -j ACCEPT -m comment --comment "Globular DNS"
        iptables -C INPUT -p tcp -s "${SUBNET}" --dport 53 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp -s "${SUBNET}" --dport 53 -j ACCEPT -m comment --comment "Globular DNS TCP"

        # Try to save rules
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        fi
        echo "  ✓ iptables configured"

    else
        echo "  ⚠ No firewall detected"
    fi
else
    echo "  → Skipping (Joining node - configure firewall manually if needed)"
fi

echo ""
echo "[configure-resolver] Step 5: Verification..."

# Test connectivity for joining nodes
if [[ "$NODE_TYPE" == "joining" ]]; then
    echo "  → Testing connectivity to ${GLOBULAR_DNS_SERVER}..."
    if timeout 2 nc -zvu "${GLOBULAR_DNS_SERVER}" 53 2>&1 | grep -q "succeeded"; then
        echo "  ✓ DNS server ${GLOBULAR_DNS_SERVER}:53 is reachable"
    else
        echo "  ⚠ Cannot reach DNS server ${GLOBULAR_DNS_SERVER}:53"
        echo "  Check network connectivity and firewall rules"
    fi
fi

# Check resolver status
if command -v resolvectl >/dev/null 2>&1; then
    echo "  → Resolver status:"
    if resolvectl status | grep -q "globular.internal"; then
        echo "  ✓ Search domain 'globular.internal' configured"
    else
        echo "  ⚠ Search domain not found"
    fi

    if resolvectl status | grep -q "${GLOBULAR_DNS_SERVER}"; then
        echo "  ✓ DNS server ${GLOBULAR_DNS_SERVER} configured"
    else
        echo "  ⚠ DNS server not found in resolver status"
    fi
fi

echo ""
echo "[configure-resolver] ✓ System resolver configuration complete"
echo ""

# Save configuration info
cat > /etc/globular-dns.conf <<EOF
# Globular DNS Configuration Info
NODE_TYPE=${NODE_TYPE}
DNS_SERVER=${GLOBULAR_DNS_SERVER}
SEARCH_DOMAIN=globular.internal
CONFIGURED_DATE=$(date -Iseconds)
NODE_IP=${NODE_IP}
HOSTNAME=${HOSTNAME}
EOF

echo "Configuration Summary:"
echo "  • Node Type: ${NODE_TYPE}"
echo "  • DNS Server: ${GLOBULAR_DNS_SERVER}"
echo "  • Search Domain: globular.internal"
echo "  • Fallback DNS: 1.1.1.1, 8.8.8.8"
echo "  • Configuration: /etc/globular-dns.conf"
echo ""
echo "Testing:"
if [[ "$NODE_TYPE" == "day0" ]]; then
    echo "  ping ${HOSTNAME}.globular.internal"
    echo "  curl -k -I https://${HOSTNAME}.globular.internal:8443"
else
    echo "  # After cluster join:"
    echo "  ping ${HOSTNAME}.globular.internal"
fi
echo ""
echo "For Day-1+ nodes joining this cluster:"
echo "  sudo JOIN_DNS_SERVER=${NODE_IP} /path/to/configure-resolver.sh"
echo ""
