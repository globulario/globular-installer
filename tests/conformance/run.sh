#!/usr/bin/env bash
# Globular Conformance Test Suite - Main Runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Banner
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Globular v1.0 Conformance Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if running as root (required for most tests)
if [[ "${SKIP_SUDO:-0}" == "0" ]]; then
  if [[ $EUID -ne 0 ]]; then
    fail "Conformance tests require root privileges (use sudo)"
    echo ""
    echo "Or set SKIP_SUDO=1 to skip tests requiring root"
    exit 2
  fi
fi

# List of test files in execution order
tests=(
  "00_smoke.sh"
  "10_dns_port_describe.sh"
  "20_client_certs_exist.sh"
  "30_tls_symlinks.sh"
  "40_dns_cap_net_bind.sh"
)

verbose "Test configuration:"
verbose "  STATE_DIR: $STATE_DIR"
verbose "  BIN_DIR: $BIN_DIR"
verbose "  VERBOSE: $VERBOSE"
verbose "  CI: $CI"
verbose ""

# Run each test
for test_file in "${tests[@]}"; do
  test_path="$SCRIPT_DIR/$test_file"

  if [[ ! -f "$test_path" ]]; then
    warn "Test file not found: $test_file (skipping)"
    continue
  fi

  if [[ ! -x "$test_path" ]]; then
    warn "Test file not executable: $test_file (skipping)"
    continue
  fi

  # Run test
  if bash "$test_path"; then
    verbose "  $test_file completed successfully"
  else
    exit_code=$?
    if [[ "$CI" == "1" ]]; then
      fail "Test failed: $test_file (exit code: $exit_code)"
      exit $exit_code
    else
      verbose "  $test_file failed (continuing...)"
    fi
  fi
done

# Print summary
print_summary
exit_code=$?

# Suggest next steps on failure
if [[ $exit_code -ne 0 ]]; then
  echo ""
  echo "Troubleshooting:"
  echo "  - Review test output above for specific failures"
  echo "  - Run individual tests with VERBOSE=1 for details"
  echo "  - Check system logs: journalctl -u globular-*.service"
  echo "  - See docs/v1-invariants.md for detailed specifications"
  echo ""
fi

exit $exit_code
