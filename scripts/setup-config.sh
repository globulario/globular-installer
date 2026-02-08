#!/usr/bin/env bash
set -euo pipefail

# Initial Globular Configuration Bootstrap
# Creates /var/lib/globular/config.json with HTTPS enabled

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
CONFIG_FILE="${STATE_DIR}/config.json"

echo "[setup-config] Bootstrapping Globular configuration"
echo "[setup-config] STATE_DIR=${STATE_DIR}"
echo "[setup-config] CONFIG_FILE=${CONFIG_FILE}"

# Check if config already exists
if [[ -f "${CONFIG_FILE}" ]]; then
    echo "[setup-config] Configuration file already exists"

    # Check if Protocol is set
    if grep -q '"Protocol"' "${CONFIG_FILE}"; then
        CURRENT_PROTOCOL=$(jq -r '.Protocol // "http"' "${CONFIG_FILE}")
        echo "[setup-config] Current Protocol: ${CURRENT_PROTOCOL}"

        if [[ "${CURRENT_PROTOCOL}" != "https" ]]; then
            echo "[setup-config] → Updating Protocol to https"
            BACKUP="${CONFIG_FILE}.backup.$(date +%s)"
            cp "${CONFIG_FILE}" "${BACKUP}"
            jq '.Protocol = "https"' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
            mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
            echo "[setup-config] ✓ Protocol updated to https (backup: ${BACKUP})"
        else
            echo "[setup-config] ✓ Protocol already set to https"
        fi
    else
        echo "[setup-config] → Adding Protocol: https"
        BACKUP="${CONFIG_FILE}.backup.$(date +%s)"
        cp "${CONFIG_FILE}" "${BACKUP}"
        jq '. + {Protocol: "https"}' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
        mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
        echo "[setup-config] ✓ Protocol added (backup: ${BACKUP})"
    fi
else
    echo "[setup-config] Creating new configuration file with HTTPS enabled"

    # Determine domain - use globular.internal for cluster-capable setup
    # Can be overridden with GLOBULAR_DOMAIN environment variable
    DOMAIN="${GLOBULAR_DOMAIN:-globular.internal}"

    # Determine address - try to get actual hostname/IP, fallback to 127.0.0.1
    ADDRESS="${GLOBULAR_ADDRESS:-127.0.0.1}"

    echo "[setup-config] → Domain: ${DOMAIN}"
    echo "[setup-config] → Address: ${ADDRESS}"

    # Create minimal config with HTTPS and cluster-capable domain
    cat > "${CONFIG_FILE}" << EOF
{
  "Protocol": "https",
  "Domain": "${DOMAIN}",
  "Address": "${ADDRESS}",
  "PortHTTP": 8080,
  "PortHTTPS": 8443
}
EOF

    chmod 644 "${CONFIG_FILE}"
    echo "[setup-config] ✓ Configuration file created with Protocol=https, Domain=${DOMAIN}"
fi

# Set ownership if running as root AND globular user exists
if [[ $EUID -eq 0 ]] && id globular >/dev/null 2>&1; then
    chown globular:globular "${CONFIG_FILE}"
    echo "[setup-config] ✓ Ownership set to globular:globular"
elif [[ $EUID -eq 0 ]]; then
    echo "[setup-config] → globular user not yet created, ownership will be set later"
fi

echo "[setup-config] Configuration bootstrap complete"
echo "[setup-config]   Config: ${CONFIG_FILE}"
echo "[setup-config]   Protocol: https"
