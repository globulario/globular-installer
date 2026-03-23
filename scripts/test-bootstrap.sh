#!/usr/bin/env bash
# test-bootstrap.sh — Standalone script to test Day-0 first-node registration.
# Run this AFTER services are installed and running (etcd, controller, node-agent).
# Usage: sudo ./test-bootstrap.sh [--domain globular.internal]
set -euo pipefail

DOMAIN="${1:-globular.internal}"
GLOBULAR_CLI="/usr/lib/globular/bin/globularcli"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
die()  { echo -e "${RED}[bootstrap] ERROR:${NC} $*" >&2; exit 1; }

# ── 1. Check prerequisites ──────────────────────────────────────────────────
log "Checking prerequisites..."

for svc in globular-etcd globular-cluster-controller globular-node-agent; do
  if ! systemctl is-active --quiet "$svc"; then
    die "$svc is not running"
  fi
  echo "  ✓ $svc is active"
done

if [[ ! -x "$GLOBULAR_CLI" ]]; then
  die "CLI not found at $GLOBULAR_CLI"
fi
echo "  ✓ CLI found"

# Check controller is listening
if ! ss -tlnp | grep -q ':12000'; then
  die "Nothing listening on port 12000 (controller)"
fi
echo "  ✓ Controller listening on :12000"

# Check node-agent is listening
if ! ss -tlnp | grep -q ':11000'; then
  die "Nothing listening on port 11000 (node-agent)"
fi
echo "  ✓ Node-agent listening on :11000"

# ── 2. Provision shared join token ───────────────────────────────────────────
log "Provisioning Day-0 join token..."

DAY0_TOKEN=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
echo "  Token: $DAY0_TOKEN"

# Write to controller config
CC_CONFIG="/var/lib/globular/cluster-controller/config.json"
if [[ -f "$CC_CONFIG" ]]; then
  jq --arg tok "$DAY0_TOKEN" '.join_token = $tok' "$CC_CONFIG" > "${CC_CONFIG}.tmp" \
    && mv "${CC_CONFIG}.tmp" "$CC_CONFIG"
  echo "  ✓ Written to controller config"
else
  mkdir -p "$(dirname "$CC_CONFIG")"
  echo "{\"join_token\": \"$DAY0_TOKEN\", \"port\": 12000}" > "$CC_CONFIG"
  echo "  ✓ Controller config created"
fi

# Write to node-agent systemd drop-in
NA_DROPIN_DIR="/etc/systemd/system/globular-node-agent.service.d"
mkdir -p "$NA_DROPIN_DIR"
cat > "${NA_DROPIN_DIR}/join-token.conf" <<DROPIN
[Service]
Environment="NODE_AGENT_JOIN_TOKEN=${DAY0_TOKEN}"
DROPIN
echo "  ✓ Written to node-agent drop-in"

# Fix controller state protocol if stale
CC_STATE="/var/lib/globular/clustercontroller/state.json"
if [[ -f "$CC_STATE" ]]; then
  STATE_PROTO=$(jq -r '.cluster_network_spec.protocol // "http"' "$CC_STATE" 2>/dev/null)
  if [[ "$STATE_PROTO" != "https" ]]; then
    jq '.cluster_network_spec.protocol = "https"' "$CC_STATE" > "${CC_STATE}.tmp" \
      && mv "${CC_STATE}.tmp" "$CC_STATE"
    echo "  ✓ Fixed controller state protocol to https"
  fi
fi

# ── 3. Restart services with new token ───────────────────────────────────────
log "Restarting controller and node-agent..."
systemctl daemon-reload
systemctl restart globular-cluster-controller globular-node-agent

# Wait for services to start
for i in $(seq 1 15); do
  if systemctl is-active --quiet globular-cluster-controller && \
     systemctl is-active --quiet globular-node-agent; then
    break
  fi
  echo "  Waiting for services to start... ($i/15)"
  sleep 2
done

# Verify they're running
for svc in globular-cluster-controller globular-node-agent; do
  if ! systemctl is-active --quiet "$svc"; then
    echo ""
    warn "=== $svc logs ==="
    journalctl -u "$svc" -n 15 --no-pager 2>&1 | grep -v "retry_interceptor"
    die "$svc failed to start after restart"
  fi
done
echo "  ✓ Both services running"

# Verify controller is listening on 12000
# The controller needs time to connect to etcd, load state, seed token, and start gRPC.
for i in $(seq 1 30); do
  if ss -tlnp | grep -q ':12000'; then
    break
  fi
  echo "  Waiting for controller to listen on :12000... ($i/30)"
  sleep 2
done
if ! ss -tlnp | grep -q ':12000'; then
  warn "=== Controller logs ==="
  journalctl -u globular-cluster-controller -n 20 --no-pager 2>&1 | grep -v "retry_interceptor"
  die "Controller not listening on :12000 after restart"
fi
echo "  ✓ Controller listening"

# ── 4. Test TLS connectivity ────────────────────────────────────────────────
log "Testing TLS connectivity..."

# Test direct TLS to controller
CERT_SUBJECT=$(echo | openssl s_client -connect localhost:12000 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
if [[ -z "$CERT_SUBJECT" ]]; then
  die "Cannot establish TLS to controller on localhost:12000"
fi
echo "  ✓ Controller TLS: $CERT_SUBJECT"

# Test direct TLS to node-agent
CERT_SUBJECT=$(echo | openssl s_client -connect localhost:11000 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
if [[ -z "$CERT_SUBJECT" ]]; then
  warn "Cannot establish TLS to node-agent on localhost:11000 (may be expected)"
else
  echo "  ✓ Node-agent TLS: $CERT_SUBJECT"
fi

# ── 5. Check join token was seeded ──────────────────────────────────────────
log "Checking join token seeded in controller state..."
sleep 3  # Give controller time to seed token

if [[ -f "$CC_STATE" ]]; then
  TOKEN_EXISTS=$(jq --arg tok "$DAY0_TOKEN" '.join_tokens[$tok] != null' "$CC_STATE" 2>/dev/null || echo "false")
  if [[ "$TOKEN_EXISTS" == "true" ]]; then
    echo "  ✓ Join token found in controller state"
  else
    warn "Join token NOT found in controller state — checking logs..."
    journalctl -u globular-cluster-controller --since "1 min ago" --no-pager 2>&1 | grep -i "token\|seed" | head -5
    echo ""
    warn "State file join_tokens keys:"
    jq '.join_tokens | keys' "$CC_STATE" 2>/dev/null || true
  fi
else
  warn "Controller state file not found at $CC_STATE"
fi

# ── 6. Check node-agent has join token ──────────────────────────────────────
log "Checking node-agent has join token..."
NA_ENV=$(systemctl show globular-node-agent --property=Environment 2>/dev/null || true)
if echo "$NA_ENV" | grep -q "NODE_AGENT_JOIN_TOKEN"; then
  echo "  ✓ NODE_AGENT_JOIN_TOKEN is set in environment"
else
  warn "NODE_AGENT_JOIN_TOKEN not found in node-agent environment"
fi

# ── 7. Run bootstrap ────────────────────────────────────────────────────────
BOOTSTRAP_NODE_IP="$(hostname -I | awk '{print $1}')"
log "Running cluster bootstrap (blocking, timeout=120s)..."
echo "  Command: $GLOBULAR_CLI --insecure --timeout 120s cluster bootstrap --node ${BOOTSTRAP_NODE_IP}:11000 --domain $DOMAIN"
echo ""

BOOTSTRAP_OUTPUT=$("$GLOBULAR_CLI" --insecure --timeout 120s cluster bootstrap \
    --node "${BOOTSTRAP_NODE_IP}:11000" \
    --domain "$DOMAIN" 2>&1) && BOOTSTRAP_OK=1 || BOOTSTRAP_OK=0

echo ""
if [[ $BOOTSTRAP_OK -eq 1 ]]; then
  log "✓ BOOTSTRAP SUCCEEDED"
  echo "  $BOOTSTRAP_OUTPUT"
else
  warn "✗ BOOTSTRAP FAILED"
  echo "  Output: $BOOTSTRAP_OUTPUT"
  echo ""
  warn "=== Node-agent logs (last 20 lines, filtered) ==="
  journalctl -u globular-node-agent --since "2 min ago" --no-pager 2>&1 | \
    grep -E "bootstrap|join|token|error|fatal|controller|deadline|connect" -i | tail -20
  echo ""
  warn "=== Controller logs (last 20 lines, filtered) ==="
  journalctl -u globular-cluster-controller --since "2 min ago" --no-pager 2>&1 | \
    grep -v "retry_interceptor" | grep -E "join|token|approve|error|seed" -i | tail -20
  exit 1
fi

# ── 8. Verify registration ──────────────────────────────────────────────────
log "Verifying node registration..."

# Check node-agent state for nodeID
NA_STATE="/var/lib/globular/node_agent/state.json"
if [[ -f "$NA_STATE" ]]; then
  NODE_ID=$(jq -r '.node_id // ""' "$NA_STATE" 2>/dev/null)
  if [[ -n "$NODE_ID" && "$NODE_ID" != "null" ]]; then
    echo "  ✓ Node registered with ID: $NODE_ID"
  else
    warn "Node ID not found in node-agent state"
  fi
else
  warn "Node-agent state file not found at $NA_STATE"
fi

# Check controller has the node
if [[ -f "$CC_STATE" ]]; then
  NODE_COUNT=$(jq '.nodes | length' "$CC_STATE" 2>/dev/null || echo "0")
  echo "  Controller knows $NODE_COUNT node(s)"
  if [[ "$NODE_COUNT" -gt 0 ]]; then
    jq -r '.nodes | to_entries[] | "  ✓ Node \(.key): profiles=\(.value.profiles // [] | join(","))"' "$CC_STATE" 2>/dev/null
  fi
fi

echo ""
log "=== Bootstrap test complete ==="
