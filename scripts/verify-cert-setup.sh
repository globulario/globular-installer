#!/usr/bin/env bash
# Verification script to check certificate setup is correct

set -euo pipefail

echo "━━━ Certificate Setup Verification ━━━"
echo ""

FAIL=0

# Check server certificates
echo "1. Checking server certificates..."
if [[ -f /var/lib/globular/pki/ca.crt ]] && [[ -f /var/lib/globular/pki/ca.key ]]; then
    echo "   ✓ CA certificates exist"

    # Check CA is world-readable
    if [[ -r /var/lib/globular/pki/ca.crt ]]; then
        echo "   ✓ CA certificate is readable"
    else
        echo "   ✗ CA certificate is NOT readable" >&2
        FAIL=1
    fi
else
    echo "   ✗ CA certificates missing" >&2
    FAIL=1
fi

# INV-PKI-1: Check canonical PKI paths
if [[ -f /var/lib/globular/pki/issued/services/service.crt ]] && [[ -f /var/lib/globular/pki/issued/services/service.key ]]; then
    echo "   ✓ Service certificates exist at canonical location"

    # Check ownership
    OWNER=$(stat -c "%U:%G" /var/lib/globular/pki/issued/services/service.crt 2>/dev/null || echo "unknown")
    if [[ "$OWNER" == "globular:globular" ]]; then
        echo "   ✓ Service certificates owned by globular:globular"
    else
        echo "   ⚠ Service certificates owned by $OWNER (expected globular:globular)" >&2
    fi
else
    echo "   ✗ Service certificates missing at canonical location" >&2
    FAIL=1
fi

# Check etcd client certificates
echo ""
echo "2. Checking etcd client certificates..."
if [[ -f /var/lib/globular/pki/issued/etcd/client.crt ]] && [[ -f /var/lib/globular/pki/issued/etcd/client.key ]]; then
    echo "   ✓ etcd client certificates exist at canonical location"
else
    echo "   ✗ etcd client certificates missing" >&2
    FAIL=1
fi

# Check client certificates
echo ""
echo "3. Checking client certificates..."

check_user_certs() {
    local user=$1
    local home=$(eval echo ~$user)
    local cert_dir="$home/.config/globular/tls/localhost"

    echo "   User: $user"

    if [[ -d "$cert_dir" ]]; then
        echo "   ✓ Certificate directory exists: $cert_dir"

        # Check ownership
        OWNER=$(stat -c "%U:%G" "$cert_dir" 2>/dev/null || echo "unknown")
        if [[ "$OWNER" == "$user:$user" ]]; then
            echo "   ✓ Directory owned by $user:$user"
        else
            echo "   ✗ Directory owned by $OWNER (expected $user:$user)" >&2
            FAIL=1
        fi

        # Check files exist
        for file in ca.crt client.crt client.key; do
            if [[ -f "$cert_dir/$file" ]]; then
                FILE_OWNER=$(stat -c "%U:%G" "$cert_dir/$file" 2>/dev/null || echo "unknown")
                if [[ "$FILE_OWNER" == "$user:$user" ]]; then
                    echo "   ✓ $file exists and owned by $user:$user"
                else
                    echo "   ✗ $file owned by $FILE_OWNER (expected $user:$user)" >&2
                    FAIL=1
                fi
            else
                echo "   ✗ $file missing" >&2
                FAIL=1
            fi
        done

        # Verify CA matches server CA
        if [[ -f "$cert_dir/ca.crt" ]] && [[ -f /var/lib/globular/pki/ca.crt ]]; then
            if diff -q "$cert_dir/ca.crt" /var/lib/globular/pki/ca.crt >/dev/null 2>&1; then
                echo "   ✓ Client CA matches server CA"
            else
                echo "   ✗ Client CA does NOT match server CA (will cause TLS errors!)" >&2
                FAIL=1
            fi
        fi
    else
        echo "   ✗ Certificate directory not found: $cert_dir" >&2
        FAIL=1
    fi
    echo ""
}

# Check root certificates
if id root >/dev/null 2>&1; then
    check_user_certs root
fi

# Check SUDO_USER certificates if set
if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    check_user_certs "$SUDO_USER"
fi

# Test CLI connection (if globular is installed)
echo "4. Testing CLI connection..."
if command -v globular >/dev/null 2>&1; then
    if HOME=$(eval echo ~${SUDO_USER:-root}) globular --timeout 5s dns domains get >/dev/null 2>&1; then
        echo "   ✓ CLI can connect to DNS service"
    else
        echo "   ✗ CLI cannot connect to DNS service" >&2
        FAIL=1
    fi
else
    echo "   ⚠ globular CLI not installed yet (skipping connection test)"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "━━━ ✓ All certificate checks passed ━━━"
    exit 0
else
    echo "━━━ ✗ Certificate setup has issues ━━━"
    exit 1
fi
