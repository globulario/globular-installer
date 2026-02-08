#!/usr/bin/env bash
# Client Certificate Invariant: Verify user client certificates exist

set -euo pipefail
source "$(dirname "$0")/common.sh"

TEST_NAME="Client Certificate Invariant"

# Check root user certificates
verbose "Checking root user certificates..."
ROOT_TLS_DIR="/root/.config/globular/tls/localhost"

root_certs_ok=true
for cert_file in ca.crt client.crt client.key; do
  cert_path="$ROOT_TLS_DIR/$cert_file"
  if require_file "$cert_path"; then
    verbose "  Found: $cert_path"

    # Check permissions on private key
    if [[ "$cert_file" == "client.key" ]]; then
      perms=$(get_perms "$cert_path")
      if [[ "$perms" == "600" ]]; then
        verbose "    Permissions: $perms (correct)"
      else
        warn "    Permissions: $perms (should be 600)"
        root_certs_ok=false
      fi
    fi
  else
    verbose "  Missing: $cert_path"
    root_certs_ok=false
  fi
done

if [[ "$root_certs_ok" == "true" ]]; then
  pass "$TEST_NAME: root user certificates present and correct"
else
  fail "$TEST_NAME: root user certificates missing or incorrect permissions"
fi

# Check installing user certificates (if different from root)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  verbose "Checking $SUDO_USER user certificates..."
  USER_HOME=$(eval echo ~${SUDO_USER})
  USER_TLS_DIR="$USER_HOME/.config/globular/tls/localhost"

  user_certs_ok=true
  for cert_file in ca.crt client.crt client.key; do
    cert_path="$USER_TLS_DIR/$cert_file"
    if require_file "$cert_path"; then
      verbose "  Found: $cert_path"

      # Check permissions on private key
      if [[ "$cert_file" == "client.key" ]]; then
        perms=$(get_perms "$cert_path")
        if [[ "$perms" == "600" ]]; then
          verbose "    Permissions: $perms (correct)"
        else
          warn "    Permissions: $perms (should be 600)"
          user_certs_ok=false
        fi
      fi

      # Check ownership
      owner=$(stat -c %U "$cert_path")
      if [[ "$owner" == "$SUDO_USER" ]]; then
        verbose "    Owner: $owner (correct)"
      else
        warn "    Owner: $owner (should be $SUDO_USER)"
        user_certs_ok=false
      fi
    else
      verbose "  Missing: $cert_path"
      user_certs_ok=false
    fi
  done

  if [[ "$user_certs_ok" == "true" ]]; then
    pass "$TEST_NAME: $SUDO_USER user certificates present and correct"
  else
    fail "$TEST_NAME: $SUDO_USER user certificates missing or incorrect"
  fi
else
  verbose "No SUDO_USER detected, skipping user certificate check"
fi
