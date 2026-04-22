#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ DNS Bootstrap (Day-0) ━━━"
echo ""

# Skip etcd discovery during bootstrap
export GLOBULAR_SKIP_ETCD_DISCOVERY=1

STATE_DIR="${STATE_DIR:-/var/lib/globular}"

# Routable node IP — used throughout; never loopback.
# Services bind to the primary routable IP, not 127.0.0.1.
NODE_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

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

# Pick DNS gRPC endpoint: etcd is the source of truth for all service endpoints.
# If etcd has the DNS service registered, use that address.
# If not yet registered, fall back to ss to find what port dns_server is listening on.
# Never use hardcoded port numbers or env var overrides.
DNS_GRPC_ADDR=""

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

# Strategy 2: Authenticate via auth service (Day-0 default password: adminadmin).
# During Day-0, Envoy is not yet running so the standard mesh routing (host:443)
# fails. Use --auth <node-ip>:<port> to connect directly, bypassing mesh rewriting.
# The auth service binds to the node's routable IP, not 127.0.0.1.
if [[ -z "$SA_TOKEN" ]]; then
    SA_CRED_FILE="${STATE_DIR}/.bootstrap-sa-password"
    SA_PASS=""
    if [[ -f "$SA_CRED_FILE" ]]; then
        SA_PASS=$(cat "$SA_CRED_FILE")
    fi
    SA_PASS="${SA_PASS:-adminadmin}"

    # Resolve auth endpoint from etcd (authoritative source of truth).
    # etcd service records use UUIDs as keys; search all /config entries by Name field.
    # Fall back to ss probe if etcd doesn't have the record yet.
    _ETCD_EP="https://${NODE_IP}:2379"
    _ETCD_CA="${STATE_DIR}/pki/ca.crt"
    _ETCD_CERT="${STATE_DIR}/pki/issued/services/service.crt"
    _ETCD_KEY="${STATE_DIR}/pki/issued/services/service.key"
    # etcd --print-value-only emits multi-line JSON objects concatenated together.
    # Use raw_decode to walk the stream and extract each object individually.
    _AUTH_DIRECT=$(etcdctl --endpoints="$_ETCD_EP" \
        --cacert="$_ETCD_CA" --cert="$_ETCD_CERT" --key="$_ETCD_KEY" \
        get /globular/services/ --prefix --print-value-only 2>/dev/null \
      | python3 -c "
import json, sys
dec = json.JSONDecoder()
buf = sys.stdin.read()
pos = 0
while pos < len(buf):
    # skip whitespace between objects
    while pos < len(buf) and buf[pos] in ' \t\r\n':
        pos += 1
    if pos >= len(buf):
        break
    try:
        d, end = dec.raw_decode(buf, pos)
        pos = end
        if d.get('Name') != 'authentication.AuthenticationService':
            continue
        addr = d.get('Address', '')
        port = int(d.get('Port', 0))
        host = addr.rsplit(':', 1)[0] if ':' in addr else addr
        if host and port:
            print(f'{host}:{port}')
            break
    except Exception:
        pos += 1
" 2>/dev/null || true)
    # If etcd has no record yet, find what port authentication_server is actually on.
    # NOTE: Linux truncates comm names to 15 chars in ss output, so "authentication_server"
    # appears as "authentication_" — match on the truncated prefix.
    if [[ -z "$_AUTH_DIRECT" ]]; then
        _AUTH_PORT=$(sudo ss -tlnp 2>/dev/null \
          | awk '/authentication_/{match($4,/[^:]+$/); print substr($4,RSTART,RLENGTH)}' \
          | head -1 || true)
        [[ -n "$_AUTH_PORT" ]] && _AUTH_DIRECT="${NODE_IP}:${_AUTH_PORT}"
    fi
    [[ -n "$_AUTH_DIRECT" ]] || { echo "[bootstrap-dns] ERROR: could not resolve auth service address from etcd or ss" >&2; exit 1; }

    echo "[bootstrap-dns] Authenticating as sa (direct: ${_AUTH_DIRECT})..."
    _auth_out=$(HOME="$CLIENT_HOME" globular --timeout 10s --insecure --auth "${_AUTH_DIRECT}" auth login --user sa --password "$SA_PASS" 2>&1 || true)
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
    # causing RBAC to reject with "authentication required".
    HOME="$CLIENT_HOME" globular --dns "${DNS_GRPC_ADDR}" $token_flag "$@"
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

    # Discover the DNS gRPC endpoint: etcd is authoritative.
    # If etcd doesn't have it yet, ask ss what port the dns_server process is on.
    if [[ -z "$DNS_GRPC_ADDR" ]]; then
        # etcd service records use UUIDs as keys; scan all /globular/services/ entries
        # and match by Name field — never use a hardcoded key path.
        # etcd --print-value-only emits multi-line JSON; use raw_decode to parse.
        _DNS_CANDIDATE=$(etcdctl \
            --endpoints="https://${NODE_IP}:2379" \
            --cacert="${STATE_DIR}/pki/ca.crt" \
            --cert="${STATE_DIR}/pki/issued/services/service.crt" \
            --key="${STATE_DIR}/pki/issued/services/service.key" \
            get /globular/services/ --prefix --print-value-only 2>/dev/null \
          | python3 -c "
import json, sys
dec = json.JSONDecoder()
buf = sys.stdin.read()
pos = 0
while pos < len(buf):
    while pos < len(buf) and buf[pos] in ' \t\r\n':
        pos += 1
    if pos >= len(buf):
        break
    try:
        d, end = dec.raw_decode(buf, pos)
        pos = end
        if d.get('Name') != 'dns.DnsService':
            continue
        addr = d.get('Address', '')
        port = int(d.get('Port', 0))
        host = addr.rsplit(':', 1)[0] if ':' in addr else addr
        if host and port:
            print(f'{host}:{port}')
            break
    except Exception:
        pos += 1
" 2>/dev/null || true)
        if [[ -n "$_DNS_CANDIDATE" ]]; then
            if _probe_dns_grpc "$_DNS_CANDIDATE"; then
                DNS_GRPC_ADDR="$_DNS_CANDIDATE"
            fi
        fi
        # Fallback: probe what the dns_server process is actually listening on.
        # "dns_server" is 10 chars — fits within Linux's 15-char comm limit, no truncation.
        if [[ -z "$DNS_GRPC_ADDR" ]]; then
            _DNS_SS_PORT=$(sudo ss -tlnp 2>/dev/null \
              | awk '/dns_server/{match($4,/[^:]+$/); print substr($4,RSTART,RLENGTH)}' \
              | head -1 || true)
            if [[ -n "$_DNS_SS_PORT" ]]; then
                _candidate="${NODE_IP}:${_DNS_SS_PORT}"
                if _probe_dns_grpc "$_candidate"; then
                    DNS_GRPC_ADDR="$_candidate"
                fi
            fi
        fi
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
        echo "  DNS gRPC: not found via etcd or ss probe" >&2
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

# Verify NODE_IP is still valid (set at top of script via ip route get)
if [[ -z "$NODE_IP" || "$NODE_IP" == "127.0.0.1" ]]; then
    echo "[bootstrap-dns] ERROR: Could not determine routable node IP" >&2
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

# Wait for ScyllaDB to be ready for writes before probing DNS.
# The DNS service binds its gRPC port and port 53 quickly, but its ScyllaDB
# schema init runs in the background. Without this gate, the first 8-10 write
# probes always fail with exit code 1, producing misleading noise in the log.
echo "[bootstrap-dns] Waiting for ScyllaDB to accept writes..."
_SCYLLA_READY=0
for _si in $(seq 1 60); do
    if cqlsh "${NODE_IP}" 9042 --ssl \
        --ssl-ca-certs "${STATE_DIR}/pki/ca.crt" \
        --ssl-certfile "${STATE_DIR}/pki/issued/services/service.crt" \
        --ssl-keyfile  "${STATE_DIR}/pki/issued/services/service.key" \
        -e "SELECT now() FROM system.local;" >/dev/null 2>&1; then
        _SCYLLA_READY=1
        echo "[bootstrap-dns] ✓ ScyllaDB ready (after ${_si}s)"
        break
    fi
    sleep 1
done
if [[ $_SCYLLA_READY -eq 0 ]]; then
    echo "[bootstrap-dns] ⚠ ScyllaDB not confirmed ready after 60s — proceeding anyway" >&2
fi

# Wait for DNS service to be ready for write operations
echo "[bootstrap-dns] Waiting for DNS database to accept writes..."
MAX_WAIT=120
DNS_WRITABLE=0
TEST_RECORD="bootstrap-test.${DOMAIN}."
TEST_IP="$NODE_IP"

for i in $(seq 1 $MAX_WAIT); do
    # Try to create a test record
    set +e
    SET_OUTPUT=$(globular_dns --timeout 5s dns a set "$TEST_RECORD" "$TEST_IP" --ttl 60 2>&1)
    SET_EXIT=$?
    set -e

    if [[ $SET_EXIT -ne 0 ]]; then
        echo "[bootstrap-dns] Attempt $i/$MAX_WAIT: write not ready yet (${SET_OUTPUT})" >&2
        sleep 1
        continue
    fi

    # Verify the record is readable
    set +e
    GET_OUTPUT=$(globular_dns --timeout 5s dns a get "$TEST_RECORD" 2>&1)
    GET_EXIT=$?
    set -e

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
