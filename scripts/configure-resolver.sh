#!/usr/bin/env bash
set -euo pipefail

# Globular DNS System Resolver Configuration
# Configures system resolver to use Globular DNS for the cluster domain
#
# Environment Variables:
#   DOMAIN          - Cluster domain (default: globular.internal, set by install-day0.sh)
#   JOIN_DNS_SERVER - DNS server IP for Day-1+ nodes (e.g., 10.0.0.63)
#                     If not set, uses 127.0.0.1 (Day-0 mode)

DOMAIN="${DOMAIN:-globular.internal}"

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

# Search + routing domain for short names and .${DOMAIN}
Domains=~${DOMAIN} ${DOMAIN}

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
                +ipv4.dns-search "${DOMAIN}" 2>/dev/null || {
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
    echo "    Domains=~${DOMAIN} ${DOMAIN}"
    echo "    FallbackDNS=1.1.1.1 8.8.8.8"
    echo ""
fi

echo ""
echo "[configure-resolver] Step 2b: Add MinIO /etc/hosts fallback..."
# MinIO must be reachable before DNS/ScyllaDB/repository services start.
# /etc/hosts ensures resolution works even if systemd-resolved or the
# Globular DNS service is not yet running. On Day-0, only the local node
# runs MinIO; additional nodes are added by the node agent after join.
sed -i '/minio\.globular\.internal/d' /etc/hosts
if [[ -n "${NODE_IP}" ]]; then
    echo "${NODE_IP} minio.globular.internal  # MinIO (local)" >> /etc/hosts
    echo "  ✓ minio.globular.internal -> ${NODE_IP}"
else
    echo "  ⚠ No node IP detected, skipping /etc/hosts entry"
fi
if [[ -n "${JOIN_DNS_SERVER:-}" && "${JOIN_DNS_SERVER}" != "${NODE_IP}" ]]; then
    echo "${JOIN_DNS_SERVER} minio.globular.internal  # MinIO (bootstrap)" >> /etc/hosts
    echo "  ✓ minio.globular.internal -> ${JOIN_DNS_SERVER} (bootstrap)"
fi

echo ""
echo "[configure-resolver] Step 3a: Ensure NSS resolve module..."
# Without libnss-resolve, Go binaries use glibc's stub resolver which doesn't
# honor systemd-resolved routing domains (~globular.internal). The mdns4_minimal
# module with [NOTFOUND=return] blocks .internal lookups before reaching DNS.
if ! dpkg -l libnss-resolve 2>/dev/null | grep -q '^ii'; then
    apt-get install -y libnss-resolve >/dev/null 2>&1 || true
    echo "  ✓ libnss-resolve installed"
else
    echo "  → libnss-resolve already installed"
fi
if grep -q 'mdns4_minimal.*NOTFOUND.*return' /etc/nsswitch.conf; then
    sed -i 's/^hosts:.*/hosts:          files resolve dns myhostname/' /etc/nsswitch.conf
    echo "  ✓ nsswitch.conf updated (resolve before dns)"
else
    echo "  → nsswitch.conf already configured"
fi

echo ""
echo "[configure-resolver] Step 3b: Configure log management..."
# Globular services produce verbose audit logs that can grow syslog to 300GB+
# in hours if the reconcile loop encounters persistent errors.

# rsyslog: rate-limit to 500 messages per 10 seconds
if systemctl is-active --quiet rsyslog 2>/dev/null; then
    mkdir -p /etc/rsyslog.d
    cat > /etc/rsyslog.d/50-globular-rate-limit.conf <<'RSYSLOG_RL'
# Globular: rate-limit to prevent audit log flood filling disk
$SystemLogRateLimitInterval 10
$SystemLogRateLimitBurst 500
RSYSLOG_RL
    systemctl restart rsyslog 2>/dev/null || true
    echo "  ✓ rsyslog rate-limited (500 msg / 10s)"
else
    echo "  → rsyslog not active, skipping"
fi

# journald: cap total disk usage to 2GB, keep max 7 days
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-globular.conf <<'JOURNALD_CONF'
[Journal]
SystemMaxUse=2G
SystemKeepFree=10G
MaxRetentionSec=7day
JOURNALD_CONF
systemctl restart systemd-journald 2>/dev/null || true
echo "  ✓ journald capped at 2GB / 7 days"

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

TEST_DOMAIN="api.${DOMAIN}"
verify_ok=1

echo "  → Verifying DNS resolution for ${TEST_DOMAIN}"
echo "    Expected resolver for .${DOMAIN}: ${GLOBULAR_DNS_SERVER} (node type: ${NODE_TYPE})"

# Test connectivity for joining nodes
if [[ "$NODE_TYPE" == "joining" ]]; then
    if command -v nc >/dev/null 2>&1; then
        echo "  → Testing connectivity to ${GLOBULAR_DNS_SERVER}:53..."
        if timeout 2 nc -zvu "${GLOBULAR_DNS_SERVER}" 53 2>&1 | grep -q "succeeded"; then
            echo "  ✓ DNS server ${GLOBULAR_DNS_SERVER}:53 is reachable"
        else
            echo "  ⚠ Cannot reach DNS server ${GLOBULAR_DNS_SERVER}:53"
            echo "    Check network connectivity and firewall rules"
            verify_ok=0
        fi
    else
        echo "  ⚠ nc not found; skipping UDP reachability check"
    fi
fi

# System resolver check (glibc)
if getent_out=$(getent hosts "$TEST_DOMAIN" 2>/dev/null); then
    RESOLVED_IPS=$(echo "$getent_out" | awk '{print $1}' | paste -sd, -)
    echo "  ✓ getent hosts ${TEST_DOMAIN} -> ${RESOLVED_IPS}"
else
    echo "  ⚠ getent hosts ${TEST_DOMAIN} failed (system resolver did not return an address)"
    verify_ok=0
fi

# systemd-resolved diagnostic (non-fatal)
if command -v resolvectl >/dev/null 2>&1; then
    echo "  → resolvectl query ${TEST_DOMAIN} (diagnostic)"
    if resolvectl_out=$(resolvectl query "$TEST_DOMAIN" 2>/dev/null); then
        echo "$resolvectl_out" | sed 's/^/    /'
    else
        echo "    ⚠ resolvectl query failed (service inactive or DNS unresolved)"
    fi
fi

# Direct query against the configured DNS server
if command -v dig >/dev/null 2>&1; then
    if dig_out=$(dig @"${GLOBULAR_DNS_SERVER}" "$TEST_DOMAIN" +short 2>/dev/null) && [[ -n "$dig_out" ]]; then
        DIG_IPS=$(echo "$dig_out" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        echo "  ✓ dig @${GLOBULAR_DNS_SERVER} ${TEST_DOMAIN} -> ${DIG_IPS}"
    else
        echo "  ⚠ dig @${GLOBULAR_DNS_SERVER} ${TEST_DOMAIN} returned no records"
        verify_ok=0
    fi
elif command -v nslookup >/dev/null 2>&1; then
    if nslookup_out=$(nslookup "$TEST_DOMAIN" "${GLOBULAR_DNS_SERVER}" 2>/dev/null) && echo "$nslookup_out" | grep -qE "Address: [0-9a-fA-F:.]+"; then
        NS_IP=$(echo "$nslookup_out" | awk '/Address: /{print $2}' | head -n1)
        echo "  ✓ nslookup ${TEST_DOMAIN} ${GLOBULAR_DNS_SERVER} -> ${NS_IP}"
    else
        echo "  ⚠ nslookup ${TEST_DOMAIN} ${GLOBULAR_DNS_SERVER} returned no address"
        verify_ok=0
    fi
else
    echo "  → dig/nslookup not found; skipping direct DNS server query"
fi

if [[ $verify_ok -eq 1 ]]; then
    VERIFY_RESULT="PASS"
    echo "  ✓ DNS resolution verified for ${TEST_DOMAIN}"
else
    VERIFY_RESULT="FAIL"
    echo "  ⚠ DNS resolution verification FAILED for ${TEST_DOMAIN}"
    echo "    - Ensure .${DOMAIN} routes to ${GLOBULAR_DNS_SERVER}"
    echo "    - Check firewall rules for port 53/udp and 53/tcp"
    echo "    - Try: dig @${GLOBULAR_DNS_SERVER} ${TEST_DOMAIN} +trace"
    if [[ "$NODE_TYPE" == "joining" ]]; then
        echo "    - Confirm ${GLOBULAR_DNS_SERVER} is reachable from this node"
    fi
fi
echo "VERIFY_RESULT=${VERIFY_RESULT}"

echo ""
if [[ "${VERIFY_RESULT}" == "PASS" ]]; then
    echo "[configure-resolver] ✓ System resolver configuration complete (verify: PASS)"
else
    echo "[configure-resolver] ⚠ System resolver configuration complete (verify: FAIL)"
fi
echo ""

# Save configuration info
cat > /etc/globular-dns.conf <<EOF
# Globular DNS Configuration Info
NODE_TYPE=${NODE_TYPE}
DNS_SERVER=${GLOBULAR_DNS_SERVER}
SEARCH_DOMAIN=${DOMAIN}
CONFIGURED_DATE=$(date -Iseconds)
NODE_IP=${NODE_IP}
HOSTNAME=${HOSTNAME}
EOF

echo "Configuration Summary:"
echo "  • Node Type: ${NODE_TYPE}"
echo "  • DNS Server: ${GLOBULAR_DNS_SERVER}"
echo "  • Search Domain: ${DOMAIN}"
echo "  • Fallback DNS: 1.1.1.1, 8.8.8.8"
echo "  • Configuration: /etc/globular-dns.conf"
echo ""
echo "Testing:"
if [[ "$NODE_TYPE" == "day0" ]]; then
    echo "  ping ${HOSTNAME}.${DOMAIN}"
    echo "  curl -k -I https://${HOSTNAME}.${DOMAIN}:8443"
else
    echo "  # After cluster join:"
    echo "  ping ${HOSTNAME}.${DOMAIN}"
fi
echo ""
echo "For Day-1+ nodes joining this cluster:"
JOIN_HINT_IP="${NODE_IP}"
if [[ -z "${JOIN_HINT_IP}" ]]; then
    JOIN_HINT_IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)
fi

if [[ -n "${JOIN_HINT_IP}" ]]; then
    echo "  sudo JOIN_DNS_SERVER=${JOIN_HINT_IP} /path/to/configure-resolver.sh"
else
    echo "  sudo JOIN_DNS_SERVER=<cluster-node-ip> /path/to/configure-resolver.sh"
    echo "  (No IP detected automatically; use 'ip -4 addr show' to pick the node's IP)"
fi
echo ""
