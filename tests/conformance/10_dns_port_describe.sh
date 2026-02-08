#!/usr/bin/env bash
# DNS Port Invariant: Verify DNS service reports correct port in --describe

set -euo pipefail
source "$(dirname "$0")/common.sh"

DNS_BINARY="$BIN_DIR/dns_server"
TEST_NAME="DNS Port Invariant"

# Check if DNS binary exists
if [[ ! -x "$DNS_BINARY" ]]; then
  fail "$TEST_NAME: DNS binary not found: $DNS_BINARY"
  exit 1
fi

# Check if DNS service is running
if ! is_service_running "globular-dns.service"; then
  warn "$TEST_NAME: DNS service not running, skipping port check"
  pass "$TEST_NAME: skipped (service not running)"
  exit 0
fi

# Get port from --describe
verbose "Getting port from --describe metadata..."
DESCRIBE_PORT=$(get_describe_port "$DNS_BINARY")

if [[ -z "$DESCRIBE_PORT" ]]; then
  fail "$TEST_NAME: --describe did not return a port"
  exit 1
fi
verbose "  Reported port: $DESCRIBE_PORT"

# Get actual listening port
verbose "Getting actual listening port..."
ACTUAL_PORT=$(get_listening_port "dns_server")

if [[ -z "$ACTUAL_PORT" ]]; then
  fail "$TEST_NAME: DNS server not listening on any port"
  exit 1
fi
verbose "  Actual listening port: $ACTUAL_PORT"

# Compare ports
if [[ "$DESCRIBE_PORT" == "$ACTUAL_PORT" ]]; then
  pass "$TEST_NAME: reported port ($DESCRIBE_PORT) matches actual port ($ACTUAL_PORT)"
else
  fail "$TEST_NAME: port mismatch - reported: $DESCRIBE_PORT, actual: $ACTUAL_PORT"
  exit 1
fi
