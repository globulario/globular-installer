#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ DNS Bootstrap (Day-0) ━━━"
echo ""

# Skip etcd discovery during bootstrap
export GLOBULAR_SKIP_ETCD_DISCOVERY=1

STATE_DIR="${STATE_DIR:-/var/lib/globular}"

# Determine user for client certificates (handle sudo context)
# Try SUDO_USER first (original user who invoked sudo), fallback to finding any valid certs
if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    CLIENT_USER="$SUDO_USER"
    CLIENT_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CA_PATH="${CLIENT_HOME}/.config/globular/tls/localhost/ca.crt"
elif [[ -f "/home/dave/.config/globular/tls/localhost/ca.crt" ]]; then
    # Fallback: use dave's certificates if they exist (common case)
    CLIENT_USER="dave"
    CLIENT_HOME="/home/dave"
    CA_PATH="/home/dave/.config/globular/tls/localhost/ca.crt"
else
    # Last resort: try root's certificates
    CLIENT_USER="${USER:-root}"
    CLIENT_HOME="${HOME:-/root}"
    CA_PATH="${CLIENT_HOME}/.config/globular/tls/localhost/ca.crt"
fi

if [[ ! -f "$CA_PATH" ]]; then
    echo "[bootstrap-dns] ERROR: CA certificate not found at $CA_PATH" >&2
    echo "[bootstrap-dns] Tried: SUDO_USER, /home/dave, ${CLIENT_HOME}" >&2
    echo "[bootstrap-dns] Client certificates must be generated before DNS bootstrap" >&2
    exit 1
fi

echo "[bootstrap-dns] Using client certificates for user: $CLIENT_USER"
echo "[bootstrap-dns] CA certificate: $CA_PATH"

# Pick DNS gRPC endpoint: the service may reallocate from its default port
# (10006) if another service occupies it at startup time. We probe candidate
# ports and pick the first one that actually responds as dns.DnsService.
# Override via DNS_GRPC_ADDR env var to skip discovery.
DNS_GRPC_ADDR="${DNS_GRPC_ADDR:-}"

# Create wrapper function for globular commands with proper HOME and explicit
# DNS endpoint. The CLI needs HOME to find client certificates for mTLS
# authentication. NOTE: Do NOT use --ca flag as it disables client certificate
# loading!
globular_dns() {
    HOME="$CLIENT_HOME" globular --dns "${DNS_GRPC_ADDR:-127.0.0.1:10006}" "$@"
}

# Probe whether a candidate address actually hosts the DNS gRPC service.
# Returns 0 if the service responded (even with auth/not-found errors).
# Returns 1 if the port has a different service or is not reachable.
_probe_dns_grpc() {
    local addr="$1"
    local out
    out=$(HOME="$CLIENT_HOME" globular --dns "$addr" --timeout 3s dns domains get 2>&1)
    echo "$out" | grep -qE "unknown service dns\.DnsService|connect: connection refused|no route to host" && return 1
    return 0
}

echo "[bootstrap-dns] Waiting for DNS service to be ready..."

# Wait for DNS service to be fully ready (gRPC responding on correct port + port 53 bound).
# NOTE: Do NOT use `globular dns domains` (no subcommand) — it prints help and
# exits 0 without connecting. Use `dns domains get` for a real gRPC call.
MAX_WAIT=30
DNS_READY=0
for i in $(seq 1 $MAX_WAIT); do
    # Discover the actual DNS gRPC port on each iteration until found.
    # The service defaults to 10006 but reallocates if there is a port conflict.
    if [[ -z "$DNS_GRPC_ADDR" ]]; then
        for _port in 10006 10007 10008 10009; do
            if _probe_dns_grpc "127.0.0.1:$_port"; then
                DNS_GRPC_ADDR="127.0.0.1:$_port"
                [[ "$_port" != "10006" ]] && \
                    echo "[bootstrap-dns] Note: DNS service found on port $_port (port conflict forced reallocation from 10006)"
                break
            fi
        done
    fi

    # Require both: gRPC port discovered AND port 53 UDP bound
    if [[ -n "$DNS_GRPC_ADDR" ]] && ss -uln 2>/dev/null | grep -qE ':53\s'; then
        DNS_READY=1
        break
    fi

    sleep 1
done

if [[ $DNS_READY -eq 0 ]]; then
    echo "[bootstrap-dns] ERROR: DNS service not ready after ${MAX_WAIT}s" >&2
    echo "[bootstrap-dns] Debug info:" >&2
    if [[ -n "$DNS_GRPC_ADDR" ]]; then
        echo "  DNS gRPC endpoint: $DNS_GRPC_ADDR" >&2
        echo "  gRPC status: $(globular_dns --timeout 5s dns domains get 2>&1 | head -1)" >&2
    else
        echo "  DNS gRPC: not found on ports 10006-10009" >&2
    fi
    echo "  Port 53 status: $(ss -ulnp 2>/dev/null | grep ':53\s' || echo 'not listening')" >&2
    exit 1
fi

echo "[bootstrap-dns] ✓ DNS service ready (${DNS_GRPC_ADDR} + port 53)"

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
    echo "  DNS gRPC endpoint: $DNS_GRPC_ADDR" >&2
    echo "  Set command exit: $SET_EXIT" >&2
    echo "  Set output: $SET_OUTPUT" >&2
    echo "  Get command exit: $GET_EXIT" >&2
    echo "  Get output: $GET_OUTPUT" >&2
    echo "[bootstrap-dns] DNS service may not be functioning correctly" >&2
    echo "[bootstrap-dns] Check: journalctl -u globular-dns.service -n 50" >&2
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
