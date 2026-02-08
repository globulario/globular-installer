#!/usr/bin/env bash
# Smoke test: Verify required binaries and paths exist

set -euo pipefail
source "$(dirname "$0")/common.sh"

# Check required commands
verbose "Checking required commands..."
for cmd in systemctl ss jq grep; do
  if command -v "$cmd" &>/dev/null; then
    verbose "  Found: $cmd"
  else
    fail "Smoke test: required command missing: $cmd"
    exit 2
  fi
done

# Check state directory
verbose "Checking state directory: $STATE_DIR"
if require_dir "$STATE_DIR"; then
  verbose "  Found: $STATE_DIR"
else
  fail "Smoke test: state directory missing: $STATE_DIR"
  exit 1
fi

# Check bin directory
verbose "Checking bin directory: $BIN_DIR"
if require_dir "$BIN_DIR"; then
  verbose "  Found: $BIN_DIR"
else
  fail "Smoke test: bin directory missing: $BIN_DIR"
  exit 1
fi

# Check critical binaries
verbose "Checking critical binaries..."
critical_bins=(
  "$BIN_DIR/dns_server"
  "$BIN_DIR/globularcli"
)

missing_bins=()
for binary in "${critical_bins[@]}"; do
  if [[ -x "$binary" ]]; then
    verbose "  Found: $binary"
  else
    missing_bins+=("$binary")
  fi
done

if [[ ${#missing_bins[@]} -gt 0 ]]; then
  fail "Smoke test: critical binaries missing: ${missing_bins[*]}"
  exit 1
fi

# Check systemd services
verbose "Checking systemd services..."
if systemctl list-unit-files | grep -q globular-dns.service; then
  verbose "  Found: globular-dns.service"
else
  fail "Smoke test: globular-dns.service not installed"
  exit 1
fi

pass "Smoke test: all required binaries and paths exist"
