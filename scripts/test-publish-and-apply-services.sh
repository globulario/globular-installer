#!/usr/bin/env bash
# test_publish_and_apply_services.sh
#
# Publishes one or more service packages to the cluster's repository service,
# then installs each on the local node using the globular installer.
#
# Default packages: echo, torrent, title, search, media (amd64, v0.0.1).
# Override with PACKAGES env var (space-separated list of package paths).
#
# Usage:
#   ./test-publish-and-apply-services.sh
#   PACKAGES="/path/pkg1.tgz /path/pkg2.tgz" ./test-publish-and-apply-services.sh
#   GLOBULAR_TOKEN=<token> ./test-publish-and-apply-services.sh   # skip login
#   DRY_RUN=1 ./test-publish-and-apply-services.sh                # validate only
#
# Environment variables (all optional):
#   GLOBULAR_TOKEN    Auth token. If unset, the script runs 'globular auth login'.
#   GLOBULAR_PASSWORD Password for auth login (prompted if unset)
#   REPO_ADDR         Override repository gRPC endpoint (default: auto-discover)
#   INSTALLER_BIN     Override globular-installer binary path (default: auto-detect)
#   PACKAGES          Override package paths (space-separated list)
#   DRY_RUN           Set to 1 to validate without actually publishing/installing

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

# Space-separated list of package paths to process. Override with PACKAGES env.
# Example: PACKAGES="/path/service.echo_0.0.1_linux_amd64.tgz /path/service.torrent_0.0.1_linux_amd64.tgz"
DEFAULT_PACKAGES=(
    /home/dave/Documents/github.com/globulario/services/generated/packages/service.echo_0.0.1_linux_amd64.tgz
    /home/dave/Documents/github.com/globulario/services/generated/packages/service.torrent_0.0.1_linux_amd64.tgz
    /home/dave/Documents/github.com/globulario/services/generated/packages/service.title_0.0.1_linux_amd64.tgz
    /home/dave/Documents/github.com/globulario/services/generated/packages/service.search_0.0.1_linux_amd64.tgz
    /home/dave/Documents/github.com/globulario/services/generated/packages/service.media_0.0.1_linux_amd64.tgz
)

# Convert PACKAGES string to array if provided, else use defaults.
if [[ -n "${PACKAGES:-}" ]]; then
    read -r -a PACKAGES_ARR <<<"${PACKAGES}"
else
    PACKAGES_ARR=("${DEFAULT_PACKAGES[@]}")
fi

DRY_RUN="${DRY_RUN:-0}"

# Auto-detect installer binary
if [[ -z "${INSTALLER_BIN:-}" ]]; then
    if command -v globular-installer >/dev/null 2>&1; then
        INSTALLER_BIN="$(command -v globular-installer)"
    elif [[ -x "$HOME/Documents/github.com/globulario/globular-installer/bin/globular-installer" ]]; then
        INSTALLER_BIN="$HOME/Documents/github.com/globulario/globular-installer/bin/globular-installer"
    else
        echo "ERROR: globular-installer not found. Set INSTALLER_BIN env var." >&2
        exit 1
    fi
fi

# Require jq for JSON result parsing
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required (apt install jq)" >&2
    exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

log()     { echo "  → $*"; }
success() { echo "  ✓ $*"; }
fail()    { echo "  ✗ ERROR: $*" >&2; exit 1; }
step()    { echo ""; echo "━━━ $* ━━━"; echo ""; }

# ─── Step 0: Validate package file ────────────────────────────────────────────

step "Package Validation"

for PACKAGE in "${PACKAGES_ARR[@]}"; do
    log "Validating $(basename "$PACKAGE")"
    [[ -f "$PACKAGE" ]] || fail "Package not found: $PACKAGE"

    PKG_INFO=$(globular pkg validate --file "$PACKAGE" 2>&1) \
        && success "Package valid: $PKG_INFO" \
        || fail "Package validation failed: $PKG_INFO"
done

# ─── Step 1: Discover repository service ──────────────────────────────────────

step "Repository Service Discovery"

REPO_ADDR="${REPO_ADDR:-}"

if [[ -z "$REPO_ADDR" ]]; then
    # Find a readable CA cert — mirrors the CLI's resolveCAPath() priority order.
    CA_CERT=""
    for _ca in \
            "$HOME/.config/globular/pki/ca.crt" \
            "$HOME/.config/globular/tls/localhost/ca.crt" \
            "$HOME/.config/globular/tls/globular.internal/ca.crt" \
            "/var/lib/globular/pki/ca.crt"; do
        if [[ -f "$_ca" && -r "$_ca" ]]; then
            CA_CERT="$_ca"
            break
        fi
    done
    [[ -n "$CA_CERT" ]] || fail "No readable CA cert found. Run 'globular auth install-certs' first."

    log "Querying gateway config for repository.PackageRepository (CA: $CA_CERT)..."
    REPO_ADDR=$(curl -sf --max-time 5 \
        --cacert "$CA_CERT" \
        "https://localhost:8443/config" 2>/dev/null \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
for svc in data.get('Services', {}).values():
    name = svc.get('Name', '')
    if 'repository' in name.lower() and 'PackageRepository' in name:
        addr = svc.get('Address', '')
        host = addr.split(':')[0] if addr else '127.0.0.1'
        port = int(svc.get('Port', 0))
        if port:
            print(f'{host}:{port}')
            break
" 2>/dev/null || true)
    [[ -n "$REPO_ADDR" ]] || fail "Repository service not found via gateway /config. Is the gateway running?"
fi

success "Repository endpoint: $REPO_ADDR"

# ─── Step 2: Acquire authentication token ─────────────────────────────────────

step "Authentication"

if [[ -z "${GLOBULAR_TOKEN:-}" ]]; then
    GLOBULAR_USER="sa"

    if [[ -z "${GLOBULAR_PASSWORD:-}" ]]; then
        read -rsp "Password for $GLOBULAR_USER: " GLOBULAR_PASSWORD
        echo
    fi

    # Ensure config dir is writable by the current user.
    if [[ -d "$HOME/.config/globular" && ! -w "$HOME/.config/globular" ]]; then
        sudo chown -R "$USER":"$USER" "$HOME/.config/globular"
    fi

    log "Logging in as $GLOBULAR_USER..."
    if ! globular auth login \
            --user "$GLOBULAR_USER" \
            --password "$GLOBULAR_PASSWORD" 2>&1; then
        fail "Login failed. Check password or cluster connectivity."
    fi

    # CLI writes the token to ~/.config/globular/token; export for env-var path.
    GLOBULAR_TOKEN=$(cat "$HOME/.config/globular/token" 2>/dev/null || true)
    [[ -n "$GLOBULAR_TOKEN" ]] \
        || fail "Login succeeded but token file is empty. Run 'globular auth login' manually."

    success "Token acquired"
else
    success "Using GLOBULAR_TOKEN from environment"
fi

export GLOBULAR_TOKEN

# ─── Step 3: Publish package to repository ────────────────────────────────────

step "Publish to Repository"

for PACKAGE in "${PACKAGES_ARR[@]}"; do
    log "Publishing $(basename "$PACKAGE") → $REPO_ADDR"

    if [[ "$DRY_RUN" == "1" ]]; then
        globular pkg publish \
            --file "$PACKAGE" \
            --repository "$REPO_ADDR" \
            --dry-run \
            --output json | jq .
        success "Dry-run complete"
    else
        # --output json gives a stable, script-safe result; jq -e fails if .status != "success".
        PUBLISH_JSON=$(globular --timeout 60s pkg publish \
            --file "$PACKAGE" \
            --repository "$REPO_ADDR" \
            --output json)

        echo "$PUBLISH_JSON" | jq .

        if ! echo "$PUBLISH_JSON" | jq -e '.status == "success"' >/dev/null 2>&1; then
            ERR_MSG=$(echo "$PUBLISH_JSON" | jq -r '.error.message // "unknown error"')
            ERR_CODE=$(echo "$PUBLISH_JSON" | jq -r '.error.code // "unknown"')
            fail "Publish failed [$ERR_CODE]: $ERR_MSG"
        fi

        BUNDLE_ID=$(echo "$PUBLISH_JSON" | jq -r '.bundle_id // "unknown"')
        DESC_ACTION=$(echo "$PUBLISH_JSON" | jq -r '.descriptor_action // "unknown"')
        success "Package published: bundle_id=$BUNDLE_ID descriptor=$DESC_ACTION"
    fi
done

# ─── Step 4: Install (apply) on local node ────────────────────────────────────
#
# The installer extracts the package to a temp staging dir, reads the embedded
# spec (specs/echo_service.yaml), and runs each installation step:
#   ensure_user_group, ensure_dirs, install_package_payload,
#   install_services, enable_services, start_services
#
# Requires root (uses sudo if not already root).

step "Apply Package on Local Node"

for PACKAGE in "${PACKAGES_ARR[@]}"; do
    STAGING=$(mktemp -d)

    log "Extracting package to staging dir: $STAGING"
    tar -xzf "$PACKAGE" -C "$STAGING"

    SPEC=$(find "$STAGING/specs" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) \
        | head -1)
    [[ -n "$SPEC" && -f "$SPEC" ]] || fail "No spec found inside package"
    log "Spec: $SPEC"

    log "Running installer (requires root)..."
    INSTALL_CMD=(
        "$INSTALLER_BIN" install
        --staging-dir "$STAGING"
        --spec       "$SPEC"
    )

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] would run: ${INSTALL_CMD[*]} --dry-run"
        INSTALL_CMD+=(--dry-run)
    fi

    if [[ $EUID -eq 0 ]]; then
        "${INSTALL_CMD[@]}"
    else
        sudo "${INSTALL_CMD[@]}"
    fi

    success "Installed $(basename "$PACKAGE")"

    # Clean up staging dir now that install is done.
    rm -rf "$STAGING"
done

# ─── Step 5: Verify service is running ────────────────────────────────────────

step "Verify"

if [[ "$DRY_RUN" != "1" ]]; then
    sleep 2
    for svc in globular-echo.service globular-torrent.service globular-title.service globular-search.service globular-media.service; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            success "$svc is running"
            log "Journal tail for $svc:"
            journalctl -u "$svc" -n 10 --no-pager 2>/dev/null || true
        else
            log "Warning: $svc is not active yet"
            log "Check: journalctl -u $svc -n 30"
        fi
    done
fi

echo ""
echo "━━━ Done ━━━"
echo ""
success "Packages published to $REPO_ADDR and applied to local node"
echo ""
