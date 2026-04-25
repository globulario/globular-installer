#!/usr/bin/env bash
set -euo pipefail

# ── Globular Node PKI Trust Purge ─────────────────────────────────────────────
#
# Removes all Globular PKI artifacts from a node and rebuilds the system CA
# trust store. Run this BEFORE rejoining a node to a new or rotated cluster,
# and AFTER clean-node.sh if the node previously had Globular installed.
#
# On rejoin the node agent will:
#   1. Fetch /globular/pki/ca.crt from etcd to bootstrap trust.
#   2. Verify fingerprint against /globular/pki/ca metadata.
#   3. Regenerate service certs and report clean CertificateStatus.
#
# Usage:
#   sudo bash purge-node-trust.sh              # interactive
#   sudo bash purge-node-trust.sh --force      # non-interactive
#   sudo bash purge-node-trust.sh --dry-run    # show what would be removed

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  [[ "$arg" == "--force"   ]] && FORCE=1
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

die()         { echo "  ✗ ERROR: $*" >&2; exit 1; }
log_info()    { echo "  → $*"; }
log_success() { echo "  ✓ $*"; }
log_warn()    { echo "  ⚠ $*"; }
log_step()    { echo ""; echo "━━━ $* ━━━"; echo ""; }

remove() {
  local target="$1"
  if [[ ! -e "$target" ]]; then return; fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "DRY-RUN: would remove $target"
    return
  fi
  rm -rf "$target" && log_success "Removed $target" || log_warn "Could not remove $target"
}

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       GLOBULAR NODE PKI TRUST PURGE                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Host:    $(hostname)"
echo "  Date:    $(date)"
[[ $DRY_RUN -eq 1 ]] && echo "  Mode:    DRY-RUN (nothing will be removed)"
echo ""

if [[ $FORCE -eq 0 && $DRY_RUN -eq 0 ]] && [[ -t 0 ]]; then
  echo "  This will remove all Globular PKI artifacts and rebuild the CA trust store."
  echo "  Press Enter to continue, or Ctrl+C to abort..."
  read -r
fi

# ── Phase 1: Globular PKI directory ──────────────────────────────────────────

log_step "Removing Globular PKI artifacts"

PKI_ROOT="/var/lib/globular/pki"

for path in \
    "$PKI_ROOT/ca.crt" \
    "$PKI_ROOT/ca.pem" \
    "$PKI_ROOT/ca.key" \
    "$PKI_ROOT/issued"; do
  remove "$path"
done

# Service cert directory used by globular_service framework
for path in \
    "$PKI_ROOT/issued/services/service.crt" \
    "$PKI_ROOT/issued/services/service.key"; do
  remove "$path"
done

# MinIO TLS certs (inside and outside PKI dir)
for path in \
    "/var/lib/globular/.minio/certs/public.crt" \
    "/var/lib/globular/.minio/certs/private.key"; do
  remove "$path"
done

# Stale rendered configs that embed old credentials
remove "/var/lib/globular/objectstore/minio.json"

# xDS TLS bundle symlinks and ACME certs
remove "/var/lib/globular/config/tls"
remove "/var/lib/globular/domains"

# ── Phase 2: System CA trust store ───────────────────────────────────────────

log_step "Cleaning System CA Trust Store"

TRUST_CHANGED=0

if [[ -f /usr/local/share/ca-certificates/globular-ca.crt ]]; then
  remove "/usr/local/share/ca-certificates/globular-ca.crt"
  TRUST_CHANGED=1
fi

for cert in /etc/ssl/certs/*globular* /etc/ssl/certs/*Globular*; do
  [[ -e "$cert" ]] || continue
  remove "$cert"
  TRUST_CHANGED=1
done

if [[ $DRY_RUN -eq 0 && $TRUST_CHANGED -eq 1 ]]; then
  update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates >/dev/null 2>&1 || true
  log_success "Rebuilt system CA trust store"
fi

# ── Phase 3: Per-user Globular CA copies ─────────────────────────────────────

log_step "Removing Per-User CA Copies"

for user_home in /root /home/*; do
  [[ -d "$user_home" ]] || continue
  for f in \
      "$user_home/.config/globular/ca.crt" \
      "$user_home/.config/globular/client.crt" \
      "$user_home/.config/globular/client.pem" \
      "$user_home/.config/globular/client.key"; do
    [[ -f "$f" ]] && remove "$f"
  done
done

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
if [[ $DRY_RUN -eq 1 ]]; then
echo "║     DRY-RUN COMPLETE — nothing was removed                    ║"
else
echo "║     ✓ PKI TRUST PURGE COMPLETE                                ║"
fi
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Node $(hostname) PKI state is clean."
echo "  On rejoin the node agent will bootstrap trust from etcd (/globular/pki/ca.crt)."
echo ""
