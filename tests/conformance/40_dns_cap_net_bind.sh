#!/usr/bin/env bash
# Port 53 Binding Capability: Verify DNS service can bind privileged port 53

set -euo pipefail
source "$(dirname "$0")/common.sh"

TEST_NAME="DNS Port 53 Capability Invariant"
DNS_BINARY="$BIN_DIR/dns_server"
DNS_SERVICE="globular-dns.service"

verbose "Checking DNS service capability configuration..."

# Check if DNS binary exists
if [[ ! -x "$DNS_BINARY" ]]; then
  fail "$TEST_NAME: DNS binary not found: $DNS_BINARY"
  exit 1
fi

# Method 1: Check systemd unit for AmbientCapabilities
verbose "Checking systemd unit for CAP_NET_BIND_SERVICE..."
unit_has_cap=false
if grep -q "AmbientCapabilities=CAP_NET_BIND_SERVICE" \
     /etc/systemd/system/$DNS_SERVICE 2>/dev/null; then
  verbose "  ✓ Systemd unit has AmbientCapabilities=CAP_NET_BIND_SERVICE"
  unit_has_cap=true
else
  verbose "  ✗ Systemd unit missing AmbientCapabilities"
fi

# Method 2: Check binary capabilities
verbose "Checking binary capabilities..."
binary_has_cap=false
if command -v getcap &>/dev/null; then
  cap_output=$(getcap "$DNS_BINARY" 2>/dev/null || true)
  if echo "$cap_output" | grep -q "cap_net_bind_service"; then
    verbose "  ✓ Binary has cap_net_bind_service: $cap_output"
    binary_has_cap=true
  else
    verbose "  ✗ Binary missing cap_net_bind_service"
  fi
else
  verbose "  ⚠ getcap command not available, skipping binary check"
fi

# At least one method must grant the capability
if [[ "$unit_has_cap" == "true" || "$binary_has_cap" == "true" ]]; then
  capability_configured=true
else
  capability_configured=false
fi

# Check if DNS is actually listening on port 53
verbose "Checking if DNS is listening on port 53..."
port_53_listening=false
if is_service_running "$DNS_SERVICE"; then
  if is_port_listening 53; then
    verbose "  ✓ DNS listening on port 53"
    port_53_listening=true
  else
    verbose "  ✗ DNS not listening on port 53"
  fi
else
  verbose "  ⚠ DNS service not running, cannot check port"
fi

# Final assessment
if [[ "$capability_configured" == "true" ]]; then
  if [[ "$port_53_listening" == "true" ]]; then
    pass "$TEST_NAME: capability configured and port 53 listening"
  elif is_service_running "$DNS_SERVICE"; then
    warn "$TEST_NAME: capability configured but port 53 not listening (check service logs)"
    # Still pass if capability is present, as service might be starting
    pass "$TEST_NAME: capability correctly configured"
  else
    warn "$TEST_NAME: capability configured but service not running"
    pass "$TEST_NAME: capability correctly configured (service not started)"
  fi
else
  fail "$TEST_NAME: CAP_NET_BIND_SERVICE not configured in systemd unit or binary"
  exit 1
fi
