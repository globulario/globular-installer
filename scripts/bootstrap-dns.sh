#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ DNS Bootstrap (Day-0) ━━━"
echo ""

# Skip etcd discovery during bootstrap
export GLOBULAR_SKIP_ETCD_DISCOVERY=1

STATE_DIR="${STATE_DIR:-/var/lib/globular}"

# Enable bootstrap mode so RBAC interceptors allow Day-0 writes.
# The bootstrap gate has a 30-minute window and restricts to loopback.
# Use the unix-timestamp format that the bootstrap gate reads (enabled_at_unix/expires_at_unix).
# If install-day0.sh already created a valid (non-expired) flag, reuse it.
# Otherwise recreate it (standalone invocation).
BOOTSTRAP_FILE="${STATE_DIR}/bootstrap.enabled"
_now=$(date +%s)
_existing_expires=0
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    _existing_expires=$(python3 -c "import json,sys; d=json.load(open('$BOOTSTRAP_FILE')); print(d.get('expires_at_unix',0))" 2>/dev/null || echo 0)
fi
if [[ "$_existing_expires" -gt "$_now" ]]; then
    echo "[bootstrap-dns] Reusing existing bootstrap flag (expires in $(( _existing_expires - _now ))s)"
else
    ENABLED_AT=$(date +%s)
    EXPIRES_AT=$((ENABLED_AT + 1800))
    NONCE=$(openssl rand -hex 16 2>/dev/null || echo "bs-dns-$$")
    mkdir -p "$(dirname "$BOOTSTRAP_FILE")"
    cat > "$BOOTSTRAP_FILE" <<BSEOF
{
  "enabled_at_unix": $ENABLED_AT,
  "expires_at_unix": $EXPIRES_AT,
  "nonce": "$NONCE",
  "created_by": "bootstrap-dns.sh",
  "version": "1.0"
}
BSEOF
    chmod 0600 "$BOOTSTRAP_FILE"
    # chown to globular so services running as globular can read it (0600 root-owned = unreadable by globular)
    if id globular >/dev/null 2>&1; then
        chown globular:globular "$BOOTSTRAP_FILE" 2>/dev/null || true
    fi
    echo "[bootstrap-dns] Enabled bootstrap mode (30-minute window)"
fi
DOMAIN="${DOMAIN:-globular.internal}"

# Determine user for client certificates (handle sudo context)
# Try SUDO_USER first (original user who invoked sudo), fallback to finding any valid certs
if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    CLIENT_USER="$SUDO_USER"
    CLIENT_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
elif [[ -n "${ORIGINAL_USER:-}" ]] && [[ "${ORIGINAL_USER}" != "root" ]]; then
    CLIENT_USER="$ORIGINAL_USER"
    CLIENT_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
else
    CLIENT_USER="${USER:-root}"
    CLIENT_HOME="${HOME:-/root}"
fi

# Find CA cert — try domain dir first, then localhost (legacy)
CA_PATH=""
for _tls_domain in "${DOMAIN}" "localhost"; do
    _candidate="${CLIENT_HOME}/.config/globular/tls/${_tls_domain}/ca.crt"
    if [[ -f "$_candidate" ]]; then
        CA_PATH="$_candidate"
        break
    fi
done
# Also check root's certs if not found
if [[ -z "$CA_PATH" ]] && [[ "$CLIENT_USER" != "root" ]]; then
    for _tls_domain in "${DOMAIN}" "localhost"; do
        _candidate="/root/.config/globular/tls/${_tls_domain}/ca.crt"
        if [[ -f "$_candidate" ]]; then
            CA_PATH="$_candidate"
            CLIENT_USER="root"
            CLIENT_HOME="/root"
            break
        fi
    done
fi

if [[ -z "$CA_PATH" ]]; then
    echo "[bootstrap-dns] ERROR: CA certificate not found" >&2
    echo "[bootstrap-dns] Searched: ${CLIENT_HOME}/.config/globular/tls/{${DOMAIN},localhost}/ca.crt" >&2
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

# Authenticate as sa to get a JWT token for RBAC-protected calls.
# Three strategies, tried in order:
#   1. Use an existing SA token file (written by authentication service at bootstrap)
#   2. Authenticate via `globular auth login` with saved or default Day-0 password
#   3. Fall back to client certs only (may be denied by RBAC)
SA_TOKEN=""

# Strategy 1: Look for pre-generated SA token files under ${STATE_DIR}/tokens/
if [[ -d "${STATE_DIR}/tokens" ]]; then
    for _tokfile in "${STATE_DIR}"/tokens/*_token; do
        if [[ -f "$_tokfile" ]]; then
            _tok=$(cat "$_tokfile" 2>/dev/null || true)
            # Sanity check: JWT tokens have 3 dot-separated segments
            if [[ "$_tok" == *.*.* ]]; then
                SA_TOKEN="$_tok"
                echo "[bootstrap-dns] ✓ Using existing SA token from ${_tokfile##*/}"
                break
            fi
        fi
    done
fi

# Strategy 2: Authenticate via auth service (Day-0 default password: adminadmin)
if [[ -z "$SA_TOKEN" ]]; then
    SA_CRED_FILE="${STATE_DIR}/.bootstrap-sa-password"
    SA_PASS=""
    if [[ -f "$SA_CRED_FILE" ]]; then
        SA_PASS=$(cat "$SA_CRED_FILE")
    fi
    SA_PASS="${SA_PASS:-adminadmin}"

    echo "[bootstrap-dns] Authenticating as sa..."
    _auth_out=$(HOME="$CLIENT_HOME" globular --timeout 5s --insecure auth login --user sa --password "$SA_PASS" 2>&1 || true)
    SA_TOKEN=$(echo "$_auth_out" | grep "^Token:" | sed 's/^Token: //' || true)
    if [[ -n "$SA_TOKEN" ]]; then
        echo "[bootstrap-dns] ✓ Authenticated (token acquired)"
    else
        echo "[bootstrap-dns] ⚠ Authentication failed — will try client certs only"
        echo "[bootstrap-dns]   auth login output: $_auth_out" >&2
    fi
fi

# Create wrapper function for globular commands with proper HOME, DNS endpoint,
# and sa token (if available). Token auth bypasses bootstrap gate restrictions.
globular_dns() {
    local token_flag=""
    if [[ -n "$SA_TOKEN" ]]; then
        token_flag="--token $SA_TOKEN"
    fi
    # Do NOT use --insecure here: it strips client certificates from the TLS handshake,
    # causing RBAC to reject with "authentication required". The server cert has
    # DNS:localhost in its SANs so full mTLS to localhost:10006 works without --insecure.
    HOME="$CLIENT_HOME" globular --dns "${DNS_GRPC_ADDR:-localhost:10006}" $token_flag "$@"
}

# Probe whether a candidate address actually hosts the DNS gRPC service.
# Returns 0 if the service responded (even with auth/not-found errors).
# Returns 1 if the port has a different service or is not reachable.
_probe_dns_grpc() {
    local addr="$1"
    local out
    out=$(HOME="$CLIENT_HOME" globular --dns "$addr" --insecure --timeout 3s dns domains get 2>&1)
    echo "$out" | grep -qE "unknown service dns\.DnsService|connect: connection refused|no route to host" && return 1
    return 0
}

# Ensure etcd is running before waiting for DNS — DNS cannot start without it.
# During Day-0 install, etcd can hit systemd's restart rate limiter if TLS certs
# were briefly unreadable during regeneration.  Reset and restart it.
_ensure_etcd() {
    if ! systemctl is-active --quiet globular-etcd.service 2>/dev/null; then
        echo "[bootstrap-dns] etcd is not running — attempting recovery..."
        systemctl reset-failed globular-etcd.service 2>/dev/null || true
        # Ensure cert ownership is correct before starting
        if [[ -d "${STATE_DIR}/pki" ]] && id globular >/dev/null 2>&1; then
            chown -R globular:globular "${STATE_DIR}/pki" 2>/dev/null || true
        fi
        systemctl start globular-etcd.service 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet globular-etcd.service 2>/dev/null; then
            echo "[bootstrap-dns] ✓ etcd recovered"
        else
            echo "[bootstrap-dns] ⚠ etcd still not running — DNS may fail to start"
        fi
    fi
}
_ensure_etcd

echo "[bootstrap-dns] Waiting for DNS service to be ready..."

# Wait for DNS service to be fully ready (gRPC responding on correct port + port 53 bound).
# NOTE: Do NOT use `globular dns domains` (no subcommand) — it prints help and
# exits 0 without connecting. Use `dns domains get` for a real gRPC call.
# 90s budget: etcd may wait up to 60s for TLS certs + DNS needs a few seconds after etcd.
MAX_WAIT=90
DNS_READY=0
ETCD_RECOVERY_ATTEMPTED=0
for i in $(seq 1 $MAX_WAIT); do
    # If DNS still hasn't appeared after 30s, try recovering etcd again — it may
    # have been rate-limited by systemd after the first _ensure_etcd call.
    if [[ $i -eq 30 ]] && [[ $ETCD_RECOVERY_ATTEMPTED -eq 0 ]]; then
        ETCD_RECOVERY_ATTEMPTED=1
        _ensure_etcd
    fi

    # Discover the actual DNS gRPC port on each iteration until found.
    # The service defaults to 10006 but reallocates if there is a port conflict.
    if [[ -z "$DNS_GRPC_ADDR" ]]; then
        for _port in 10006 10007 10008 10009; do
            if _probe_dns_grpc "localhost:$_port"; then
                DNS_GRPC_ADDR="localhost:$_port"
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

# Determine node IP (prefer non-loopback) — needed for test record and DNS A records
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

# Wait for DNS service to be ready for write operations
echo "[bootstrap-dns] Waiting for DNS database to accept writes..."
MAX_WAIT=120
DNS_WRITABLE=0
TEST_RECORD="bootstrap-test.${DOMAIN}."
TEST_IP="$NODE_IP"

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

# Ensure domain/zone is registered before adding records.
# The DNS service requires a domain in its managed list before SetA works.
echo "[bootstrap-dns] Registering DNS zone: ${DOMAIN}"
if globular_dns --timeout 10s dns domains add "${DOMAIN}" 2>&1; then
    echo "  ✓ Zone ${DOMAIN} registered"
else
    echo "[bootstrap-dns] WARNING: Failed to register zone ${DOMAIN} (may already exist)" >&2
fi

# Add DNS A records for Day-0
echo "[bootstrap-dns] Creating DNS records..."

# <hostname>.<domain> → node IP (this node)
if globular_dns --timeout 10s dns a set "${NODE_HOSTNAME}.${DOMAIN}." "$NODE_IP" --ttl 300 2>&1; then
    echo "  ✓ ${NODE_HOSTNAME}.${DOMAIN}. → $NODE_IP"
else
    echo "[bootstrap-dns] ERROR: Failed to create ${NODE_HOSTNAME}.${DOMAIN} record" >&2
    exit 1
fi

# api.<domain> → node IP (API endpoint)
if globular_dns --timeout 10s dns a set "api.${DOMAIN}." "$NODE_IP" --ttl 300 2>&1; then
    echo "  ✓ api.${DOMAIN}. → $NODE_IP"
else
    echo "[bootstrap-dns] ERROR: Failed to create api.${DOMAIN} record" >&2
    exit 1
fi

# Wildcard for all undefined subdomains (catches service discovery)
if globular_dns --timeout 10s dns a set "*.${DOMAIN}." "$NODE_IP" --ttl 300 2>&1; then
    echo "  ✓ *.${DOMAIN}. → $NODE_IP (wildcard)"
else
    echo "[bootstrap-dns] ERROR: Failed to create wildcard record" >&2
    exit 1
fi

echo ""
echo "[bootstrap-dns] ✓ DNS bootstrap complete"
echo ""

# Verify records
echo "[bootstrap-dns] Verifying DNS records..."
if dig @127.0.0.1 +short "${NODE_HOSTNAME}.${DOMAIN}" 2>/dev/null | grep -q "$NODE_IP"; then
    echo "  ✓ ${NODE_HOSTNAME}.${DOMAIN} resolves correctly"
else
    echo "  ⚠ Warning: ${NODE_HOSTNAME}.${DOMAIN} resolution test failed"
fi

if dig @127.0.0.1 +short "api.${DOMAIN}" 2>/dev/null | grep -q "$NODE_IP"; then
    echo "  ✓ api.${DOMAIN} resolves correctly"
else
    echo "  ⚠ Warning: api.${DOMAIN} resolution test failed"
fi

echo ""
