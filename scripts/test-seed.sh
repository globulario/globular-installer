#!/usr/bin/env bash
# test-seed.sh — Standalone script to test the desired-state seed flow.
# Run this AFTER bootstrap has succeeded (node is registered).
# Usage: sudo ./scripts/test-seed.sh
set -euo pipefail

GLOBULAR_CLI="/usr/lib/globular/bin/globularcli"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[seed]${NC} $*"; }
warn() { echo -e "${YELLOW}[seed]${NC} $*"; }
die()  { echo -e "${RED}[seed] ERROR:${NC} $*" >&2; exit 1; }

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
  die "Controller not listening on :12000"
fi
echo "  ✓ Controller listening on :12000"

# ── 2. Check node registration ──────────────────────────────────────────────
log "Checking node registration..."

CC_STATE="/var/lib/globular/clustercontroller/state.json"
if [[ -f "$CC_STATE" ]]; then
  NODE_COUNT=$(jq '.nodes | length' "$CC_STATE" 2>/dev/null || echo "0")
  if [[ "$NODE_COUNT" -eq 0 ]]; then
    die "No nodes registered in controller. Run test-bootstrap.sh first."
  fi
  echo "  ✓ Controller has $NODE_COUNT registered node(s)"
  jq -r '.nodes | to_entries[] | "    Node \(.key): profiles=\(.value.profiles // [] | join(","))"' "$CC_STATE" 2>/dev/null || true
else
  warn "Cannot read controller state at $CC_STATE — continuing anyway"
fi

# ── 3. Check node-agent has a nodeID ────────────────────────────────────────
NA_STATE="/var/lib/globular/node_agent/state.json"
if [[ -f "$NA_STATE" ]]; then
  NODE_ID=$(jq -r '.node_id // ""' "$NA_STATE" 2>/dev/null)
  if [[ -n "$NODE_ID" && "$NODE_ID" != "null" ]]; then
    echo "  ✓ Node-agent registered as: $NODE_ID"
  else
    warn "Node-agent has no nodeID — seed may fail"
  fi
else
  warn "Cannot read node-agent state at $NA_STATE"
fi

# ── 4. Test direct gRPC to controller ───────────────────────────────────────
log "Testing gRPC connectivity to controller..."
CTRL_TEST=$("$GLOBULAR_CLI" --insecure --timeout 10s --controller localhost:12000 services desired list 2>&1) || true
if echo "$CTRL_TEST" | grep -qiE "error|deadline|unavailable"; then
  warn "Controller connectivity issue: $CTRL_TEST"
  echo ""
  warn "Trying with explicit TLS skip..."
  CTRL_TEST2=$("$GLOBULAR_CLI" --insecure --timeout 10s --controller localhost:12000 services desired list 2>&1) || true
  echo "  Result: $CTRL_TEST2"
else
  echo "  ✓ Controller reachable"
  echo "  Current desired state: $CTRL_TEST"
fi

# ── 5. Wait for heartbeat ───────────────────────────────────────────────────
log "Waiting for node-agent heartbeat (15s)..."
echo "  The node-agent must report installed services via heartbeat before seed works."
sleep 15

# Check if controller has received any node reports
if [[ -f "$CC_STATE" ]]; then
  HAS_PACKAGES=$(jq '[.nodes[].installed_packages // {} | length] | add // 0' "$CC_STATE" 2>/dev/null || echo "0")
  echo "  Controller sees $HAS_PACKAGES installed package(s) across all nodes"
  if [[ "$HAS_PACKAGES" -eq 0 ]]; then
    warn "No installed packages reported yet — seed may report 'no nodes have reported'"
    echo ""
    warn "=== Recent node-agent heartbeat logs ==="
    journalctl -u globular-node-agent --since "2 min ago" --no-pager 2>&1 | \
      grep -E "heartbeat|report|status|installed|package" -i | tail -10
    echo ""
  fi
fi

# ── 6. Run seed ─────────────────────────────────────────────────────────────
log "Running services seed (timeout=60s)..."
echo "  Command: $GLOBULAR_CLI --insecure --timeout 60s services seed"
echo ""

SEED_OUTPUT=$("$GLOBULAR_CLI" --insecure --timeout 60s services seed 2>&1) && SEED_OK=1 || SEED_OK=0

echo ""
if [[ $SEED_OK -eq 1 ]]; then
  log "✓ SEED SUCCEEDED"
  echo "$SEED_OUTPUT"
else
  warn "✗ SEED FAILED"
  echo "  Output: $SEED_OUTPUT"
  echo ""

  # ── Diagnostics ──────────────────────────────────────────────────────────
  warn "=== Diagnostics ==="
  echo ""

  warn "--- Controller logs (seed-related) ---"
  journalctl -u globular-cluster-controller --since "2 min ago" --no-pager 2>&1 | \
    grep -v "retry_interceptor" | grep -E "seed|import|desired|node|installed|error" -i | tail -15
  echo ""

  warn "--- Node-agent logs (heartbeat/status) ---"
  journalctl -u globular-node-agent --since "2 min ago" --no-pager 2>&1 | \
    grep -E "heartbeat|report|status|controller|error" -i | tail -10
  echo ""

  warn "--- Controller state summary ---"
  if [[ -f "$CC_STATE" ]]; then
    echo "  Nodes: $(jq '.nodes | length' "$CC_STATE" 2>/dev/null || echo '?')"
    echo "  Join tokens: $(jq '.join_tokens | length' "$CC_STATE" 2>/dev/null || echo '?')"
    echo "  Network spec protocol: $(jq -r '.cluster_network_spec.protocol // "?"' "$CC_STATE" 2>/dev/null)"
    echo "  Node details:"
    jq -r '.nodes | to_entries[] | "    \(.key): last_seen=\(.value.last_seen // "never"), packages=\(.value.installed_packages // {} | length)"' "$CC_STATE" 2>/dev/null || true
  fi
  echo ""

  warn "--- Trying fallback: seed from local systemd units ---"
  FALLBACK=$("$GLOBULAR_CLI" --insecure --timeout 60s services desired list 2>&1) || true
  echo "  Current desired list: $FALLBACK"

  exit 1
fi

# ── 7. Verify result ────────────────────────────────────────────────────────
log "Verifying desired state..."
DESIRED=$("$GLOBULAR_CLI" --insecure --timeout 10s services desired list 2>&1) || true
echo "$DESIRED"

echo ""
log "=== Seed test complete ==="
