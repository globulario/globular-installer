#!/usr/bin/env bash
# Common utilities for conformance tests

# Default configuration
STATE_DIR="${STATE_DIR:-/var/lib/globular}"
BIN_DIR="${BIN_DIR:-/usr/lib/globular/bin}"
VERBOSE="${VERBOSE:-0}"
CI="${CI:-0}"

# Color codes (disabled in CI)
if [[ "$CI" == "1" ]] || [[ ! -t 1 ]]; then
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
else
  GREEN="\033[0;32m"
  RED="\033[0;31m"
  YELLOW="\033[1;33m"
  RESET="\033[0m"
fi

# Test result tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Print pass message
pass() {
  echo -e "${GREEN}✓${RESET} $*"
  ((TESTS_PASSED++))
  ((TESTS_RUN++))
  return 0
}

# Print fail message and exit (or continue if not in fail-fast mode)
fail() {
  echo -e "${RED}✗${RESET} $*" >&2
  ((TESTS_FAILED++))
  ((TESTS_RUN++))

  if [[ "$CI" == "1" ]]; then
    exit 1
  fi
  return 1
}

# Print warning message
warn() {
  echo -e "${YELLOW}⚠${RESET} $*" >&2
}

# Print verbose/debug message
verbose() {
  if [[ "$VERBOSE" == "1" ]]; then
    echo "  → $*" >&2
  fi
}

# Check if running as root or with sudo
check_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This test requires root privileges (use sudo)"
    exit 1
  fi
}

# Check if a command exists
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    fail "Required command not found: $cmd"
    exit 2
  fi
}

# Check if a file exists
require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  return 0
}

# Check if a directory exists
require_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    return 1
  fi
  return 0
}

# Get file permissions in octal
get_perms() {
  stat -c %a "$1" 2>/dev/null
}

# Check if service is running
is_service_running() {
  local service="$1"
  systemctl is-active --quiet "$service"
}

# Get port from --describe output
get_describe_port() {
  local binary="$1"
  "$binary" --describe 2>/dev/null | jq -r '.Port // empty' 2>/dev/null
}

# Get actual listening port for a process
get_listening_port() {
  local process_name="$1"
  ss -tlnp 2>/dev/null | grep "$process_name" | grep -oP ':\K\d+' | head -1
}

# Check if port is listening
is_port_listening() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port} "
}

# Summary of test results
print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Conformance Test Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Total:  $TESTS_RUN"
  echo -e "Passed: ${GREEN}$TESTS_PASSED${RESET}"
  echo -e "Failed: ${RED}$TESTS_FAILED${RESET}"
  echo ""

  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All conformance tests passed!${RESET}"
    return 0
  else
    echo -e "${RED}$TESTS_FAILED test(s) failed.${RESET}"
    return 1
  fi
}
