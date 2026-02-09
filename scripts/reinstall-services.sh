#!/usr/bin/env bash
set -euo pipefail

echo "━━━ Reinstalling Globular Services ━━━"
echo ""
echo "This script properly reinstalls services with certificate regeneration"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Regenerate TLS certificates (server certs)
echo "Step 1: Regenerating server TLS certificates..."
if [[ -x "$SCRIPT_DIR/setup-tls.sh" ]]; then
    "$SCRIPT_DIR/setup-tls.sh" || exit 1
    echo "✓ Server certificates regenerated"
else
    echo "ERROR: setup-tls.sh not found" >&2
    exit 1
fi
echo ""

# Step 2: Regenerate client certificates (CRITICAL!)
echo "Step 2: Regenerating client certificates..."
if [[ -x "$SCRIPT_DIR/generate-user-client-cert.sh" ]]; then
    # Generate for root
    "$SCRIPT_DIR/generate-user-client-cert.sh" || exit 1
    echo "✓ Root client certificates generated"

    # Generate for SUDO_USER if different
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        "$SCRIPT_DIR/generate-user-client-cert.sh" || exit 1
        echo "✓ User ($SUDO_USER) client certificates generated"
    fi
else
    echo "ERROR: generate-user-client-cert.sh not found" >&2
    exit 1
fi
echo ""

# Step 3: Restart services to pick up new certificates
echo "Step 3: Restarting services..."
for service in etcd minio dns; do
    if systemctl is-active "globular-${service}.service" >/dev/null 2>&1; then
        echo "  Restarting globular-${service}..."
        systemctl restart "globular-${service}.service"
    fi
done
echo "✓ Services restarted"
echo ""

# Step 4: Verify
echo "Step 4: Verifying setup..."
sleep 2  # Give services time to start

if command -v globular >/dev/null 2>&1; then
    echo "Testing DNS connection..."
    if HOME=$(eval echo ~${SUDO_USER:-root}) globular --timeout 10s dns domains get >/dev/null 2>&1; then
        echo "✓ DNS connection successful"
    else
        echo "⚠ DNS connection failed - you may need to run bootstrap-dns.sh"
    fi
fi

echo ""
echo "━━━ Reinstall Complete ━━━"
echo ""
echo "Next steps:"
echo "  - If DNS records need to be recreated, run: sudo $SCRIPT_DIR/bootstrap-dns.sh"
echo "  - Test CLI: globular dns domains get"
echo ""
