#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ Deploying XDS etcd TLS Fix ━━━"
echo ""

XDS_SOURCE="/home/dave/Documents/github.com/globulario/Globular/.bin/xds"
XDS_DEST="/usr/lib/globular/bin/xds"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)" >&2
    exit 1
fi

if [[ ! -f "${XDS_SOURCE}" ]]; then
    echo "ERROR: XDS binary not found: ${XDS_SOURCE}" >&2
    echo "       Please build it first: cd /home/dave/Documents/github.com/globulario/Globular && make build-xds" >&2
    exit 1
fi

echo "→ Stopping XDS service..."
systemctl stop globular-xds.service
echo "  ✓ Service stopped"

echo "→ Backing up current XDS binary..."
if [[ -f "${XDS_DEST}" ]]; then
    cp "${XDS_DEST}" "${XDS_DEST}.backup.$(date +%s)"
    echo "  ✓ Backup created"
fi

echo "→ Deploying new XDS binary..."
cp "${XDS_SOURCE}" "${XDS_DEST}"
chmod 755 "${XDS_DEST}"
echo "  ✓ Binary deployed"

echo "→ Starting XDS service..."
systemctl start globular-xds.service
sleep 2

if systemctl is-active --quiet globular-xds.service; then
    echo "  ✓ XDS service restarted successfully"
else
    echo "  ✗ XDS service failed to start" >&2
    echo "  Check logs: journalctl -u globular-xds.service -n 50" >&2
    exit 1
fi

echo ""
echo "━━━ XDS Fix Deployed Successfully ━━━"
echo ""
echo "Checking etcd connectivity..."
sleep 3

if journalctl -u globular-xds.service --since "10 seconds ago" | grep -q "certificate signed by unknown authority"; then
    echo "  ✗ Still getting TLS errors - check logs" >&2
    journalctl -u globular-xds.service --since "10 seconds ago" | grep -i "etcd\|tls\|certificate" | tail -5
else
    echo "  ✓ No TLS errors detected"
fi

echo ""
echo "Monitor XDS logs: journalctl -u globular-xds.service -f"
echo "Test DNS status: globular dns status"
echo ""
