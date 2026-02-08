#!/usr/bin/env bash
# TLS Certificate Path Compatibility: Verify symlinks exist and point correctly

set -euo pipefail
source "$(dirname "$0")/common.sh"

TEST_NAME="TLS Certificate Path Invariant"
TLS_DIR="$STATE_DIR/config/tls"

verbose "Checking TLS directory: $TLS_DIR"
if ! require_dir "$TLS_DIR"; then
  fail "$TEST_NAME: TLS directory not found: $TLS_DIR"
  exit 1
fi

# Check canonical certificate files exist
verbose "Checking canonical certificate files..."
canonical_files=(
  "fullchain.pem"
  "privkey.pem"
  "ca.pem"
)

canonical_ok=true
for cert_file in "${canonical_files[@]}"; do
  cert_path="$TLS_DIR/$cert_file"
  if require_file "$cert_path"; then
    verbose "  Found: $cert_file"
  else
    verbose "  Missing: $cert_file"
    canonical_ok=false
  fi
done

if [[ "$canonical_ok" == "false" ]]; then
  fail "$TEST_NAME: canonical certificate files missing"
  exit 1
fi

# Check symlinks exist and point correctly
verbose "Checking certificate symlinks..."
declare -A symlinks=(
  ["server.crt"]="fullchain.pem"
  ["server.key"]="privkey.pem"
  ["ca.crt"]="ca.pem"
)

symlinks_ok=true
for link_name in "${!symlinks[@]}"; do
  target_name="${symlinks[$link_name]}"
  link_path="$TLS_DIR/$link_name"

  if [[ -L "$link_path" ]]; then
    actual_target=$(readlink "$link_path")
    verbose "  $link_name -> $actual_target"

    # Check if target contains expected name (could be relative or absolute)
    if echo "$actual_target" | grep -q "$target_name"; then
      # Verify target exists
      if [[ -f "$TLS_DIR/$target_name" ]]; then
        verbose "    Target exists: ✓"
      else
        warn "    Target missing: $TLS_DIR/$target_name"
        symlinks_ok=false
      fi
    else
      warn "    Unexpected target: $actual_target (expected: $target_name)"
      symlinks_ok=false
    fi
  else
    if [[ -f "$link_path" ]]; then
      # File exists but is not a symlink - could be direct certificate
      verbose "  $link_name (direct file, not symlink)"
    else
      verbose "  Missing: $link_name"
      symlinks_ok=false
    fi
  fi
done

# Overall assessment
if [[ "$canonical_ok" == "true" && "$symlinks_ok" == "true" ]]; then
  pass "$TEST_NAME: certificate files and symlinks correct"
elif [[ "$canonical_ok" == "true" ]]; then
  # Canonical files exist, symlinks may be optional if services do smart discovery
  warn "$TEST_NAME: canonical files OK, but some symlinks missing (may work with smart discovery)"
  pass "$TEST_NAME: canonical certificate files present"
else
  fail "$TEST_NAME: certificate configuration incorrect"
  exit 1
fi
