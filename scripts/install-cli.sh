#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "━━━ Installing Globular CLI ━━━"
echo ""

CLI_SOURCE="/home/dave/Documents/github.com/globulario/services/golang/globularcli/globularcli"
CLI_DEST="/usr/local/bin/globular"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)" >&2
    exit 1
fi

if [[ ! -f "${CLI_SOURCE}" ]]; then
    echo "ERROR: CLI binary not found: ${CLI_SOURCE}" >&2
    echo "       Please build it first: cd /home/dave/Documents/github.com/globulario/services/golang/globularcli && go build -o globularcli ." >&2
    exit 1
fi

echo "→ Backing up current CLI..."
if [[ -f "${CLI_DEST}" ]]; then
    cp "${CLI_DEST}" "${CLI_DEST}.backup.$(date +%s)"
    echo "  ✓ Backup created"
fi

echo "→ Installing new CLI..."
cp "${CLI_SOURCE}" "${CLI_DEST}"
chmod 755 "${CLI_DEST}"
echo "  ✓ CLI installed to ${CLI_DEST}"

echo ""
echo "━━━ CLI Installed Successfully ━━━"
echo ""
echo "Test with:"
echo "  globular dns status"
echo ""
