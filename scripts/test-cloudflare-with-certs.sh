#!/bin/bash
#
# Cloudflare Provider Test with Wildcard Certificate Setup
#
# Usage:
#   ./test-cloudflare-with-certs.sh [FQDN] [ZONE] [EMAIL]
#
# Example (apex domain with wildcard cert):
#   ./test-cloudflare-with-certs.sh globular.cloud globular.cloud admin@globular.cloud
#
# This script will:
#   - Register apex domain (globular.cloud) for external DNS
#   - Request wildcard certificate (*.globular.cloud)
#   - Configure ingress routing
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*"; }
log_step() { echo -e "${CYAN}▶${NC} ${MAGENTA}$*${NC}"; }

# Configuration - Default to apex domain (NOT node-specific)
# INV-DNS-EXT-1: Only publish cluster public domain, never node-specific hostnames
FQDN="${1:-globular.io}"
ZONE="${2:-globular.io}"
ACME_EMAIL="${3:-admin@globular.io}"
PROVIDER_NAME="cloudflare-app"

# Ensure we're running as the user (not root) so HOME is correct
if [[ "${USER}" == "root" ]]; then
    log_error "Don't run as root - run as your regular user"
    exit 1
fi

# Verify client certificates exist (CLI auto-discovers them)
CERT_DIR="${HOME}/.config/globular/tls/localhost"
if [[ ! -f "$CERT_DIR/client.crt" ]] || [[ ! -f "$CERT_DIR/client.key" ]]; then
    log_error "Client certificates not found in: $CERT_DIR"
    log_error "Make sure you have client certificates set up"
    exit 1
fi

log_success "Using client certificates from: $CERT_DIR"
echo ""

# Export Cloudflare token
TOKEN_FILE="/home/dave/Documents/tmp/cloudflare_api_token"
if [[ -f "$TOKEN_FILE" ]]; then
    export CLOUDFLARE_API_TOKEN=$(cat "$TOKEN_FILE" | tr -d '\n' | tr -d ' ')
    log_success "Cloudflare API token loaded"
fi
echo ""

# Globular command wrapper with proper auth
# Uses wrapper script to access user's etcd certificates
globular_cmd() {
    /home/dave/Documents/tmp/globular-cli-wrapper.sh "$@"
}

log_step "═══════════════════════════════════════════════════════"
log_step "  Cloudflare Provider Setup"
log_step "═══════════════════════════════════════════════════════"
echo ""

# Step 1: Add Cloudflare provider
log_step "Step 1: Add Cloudflare Provider"
echo ""

if globular_cmd domain provider list --output json 2>/dev/null | jq -e ".[] | select(.name == \"$PROVIDER_NAME\")" >/dev/null 2>&1; then
    log_success "Provider '$PROVIDER_NAME' already exists"
else
    log_info "Adding Cloudflare provider..."

    if globular_cmd domain provider add \
        --name "$PROVIDER_NAME" \
        --type cloudflare \
        --zone "$ZONE" \
        --ttl 600; then
        log_success "Provider added successfully"
    else
        log_error "Failed to add provider"
        exit 1
    fi
fi
echo ""

# Step 2: Check if domain already exists
log_step "Step 2: Register External Domain"
echo ""

if globular_cmd domain status --fqdn "$FQDN" 2>/dev/null; then
    log_success "Domain '$FQDN' already registered"
    log_info "Checking current status..."

    STATUS=$(globular_cmd domain status --fqdn "$FQDN" --output json 2>/dev/null || echo "{}")
    PHASE=$(echo "$STATUS" | jq -r '.status.phase // "Unknown"' 2>/dev/null || echo "Unknown")

    echo "  Current phase: $PHASE"
else
    log_info "Registering domain: $FQDN"
    log_info "  Zone: $ZONE"
    log_info "  Provider: $PROVIDER_NAME"
    log_info "  External DNS: Enabled (publish_external=true)"
    log_info "  Certificate: Wildcard (*.${ZONE} + apex ${ZONE})"
    log_info "  ACME: Enabled (DNS-01)"
    log_info "  Ingress: Enabled (Envoy:443 HTTPS → gateway:8443 HTTPS)"
    log_info ""
    log_info "  Architecture:"
    log_info "    • External: HTTPS on port 443 (Envoy with Let's Encrypt cert)"
    log_info "    • Internal: HTTPS on port 8443 (Gateway with internal certs)"
    log_info "    • End-to-end encryption (no plain HTTP)"
    echo ""

    if globular_cmd domain add \
        --fqdn "$FQDN" \
        --zone "$ZONE" \
        --provider "$PROVIDER_NAME" \
        --target-ip auto \
        --publish-external \
        --use-wildcard-cert \
        --enable-acme \
        --acme-email "$ACME_EMAIL" \
        --acme-directory staging \
        --enable-ingress \
        --ingress-service gateway \
        --ingress-port 8443 \
        --ttl 600; then
        log_success "Domain registered successfully!"
    else
        log_error "Failed to register domain"
        exit 1
    fi
fi
echo ""

# Step 3: Monitor status
log_step "Step 3: Monitor Status"
echo ""

log_info "Monitoring reconciliation (max 5 minutes)..."
echo ""

MAX_WAIT=300
INTERVAL=10
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    STATUS=$(globular_cmd domain status --fqdn "$FQDN" --output json 2>/dev/null || echo "{}")
    PHASE=$(echo "$STATUS" | jq -r '.status.phase // "Unknown"' 2>/dev/null || echo "Unknown")
    MESSAGE=$(echo "$STATUS" | jq -r '.status.message // ""' 2>/dev/null || echo "")

    echo "[${ELAPSED}s] Phase: $PHASE"

    if [[ -n "$MESSAGE" ]]; then
        echo "        Message: $MESSAGE"
    fi

    # Show conditions
    CONDITIONS=$(echo "$STATUS" | jq -r '.status.conditions[]? | "        [\(.status)] \(.type): \(.message)"' 2>/dev/null || true)
    if [[ -n "$CONDITIONS" ]]; then
        echo "$CONDITIONS"
    fi

    if [[ "$PHASE" == "Ready" ]]; then
        echo ""
        log_success "═══════════════════════════════════════════════════════"
        log_success "  Domain is READY! ✨"
        log_success "═══════════════════════════════════════════════════════"
        echo ""

        log_info "Your cluster is now accessible at:"
        echo "  https://$FQDN"
        echo ""

        log_info "Certificate location:"
        echo "  /var/lib/globular/domains/$FQDN/"
        echo ""

        log_info "Next steps:"
        echo "  • Test: curl -v https://$FQDN"
        echo "  • Check DNS: dig $FQDN"
        echo "  • View status: globular domain status --fqdn $FQDN"
        echo ""

        exit 0
    fi

    if [[ "$PHASE" == "Error" ]]; then
        echo ""
        log_error "Domain reconciliation failed"
        echo ""
        globular_cmd domain status --fqdn "$FQDN" --output json | jq .
        exit 1
    fi

    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

log_info "Still processing after ${MAX_WAIT}s"
log_info "Check status with: globular domain status --fqdn $FQDN"
echo ""

globular_cmd domain status --fqdn "$FQDN" --output table
