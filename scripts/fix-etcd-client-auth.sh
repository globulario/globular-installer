#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ Fixing etcd Client Certificate Requirement ━━━"
echo ""

ETCD_CONFIG="/var/lib/globular/config/etcd.yaml"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)" >&2
    exit 1
fi

if [[ ! -f "${ETCD_CONFIG}" ]]; then
    echo "ERROR: etcd config not found: ${ETCD_CONFIG}" >&2
    exit 1
fi

echo "→ Backing up current etcd config..."
cp "${ETCD_CONFIG}" "${ETCD_CONFIG}.backup.$(date +%s)"
echo "  ✓ Backup created"

echo "→ Commenting out trusted-ca-file in client-transport-security..."
sed -i '/^client-transport-security:/,/^peer-transport-security:/ {
  s/^  trusted-ca-file:/#  trusted-ca-file:/
}' "${ETCD_CONFIG}"

echo "  ✓ Configuration updated"

echo ""
echo "→ Restarting etcd service..."
systemctl restart globular-etcd.service
sleep 2

echo "  ✓ etcd restarted"

echo ""
echo "━━━ Fix Applied Successfully ━━━"
echo ""
echo "etcd will now accept connections without requiring client certificates."
echo "Services should be able to connect to etcd for service discovery."
echo ""
echo "Test with: journalctl -u globular-xds.service -f"
echo ""
