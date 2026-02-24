#!/usr/bin/env bash
# Adds http://localhost:5174 to AllowedOrigins for all Globular services that have a config.
set -euo pipefail

SERVICES_DIR="/var/lib/globular/services"
ORIGIN="http://localhost:5174"

patch_config() {
  local cfg="$1"
  python3 - "$cfg" "$ORIGIN" <<'PYEOF'
import json, sys

path, origin = sys.argv[1], sys.argv[2]

with open(path) as f:
    cfg = json.load(f)

if "AllowedOrigins" not in cfg:
    sys.exit(0)

existing = cfg.get("AllowedOrigins", "")

if isinstance(existing, str):
    origins = [o.strip() for o in existing.split(",") if o.strip()]
    if origin not in origins:
        origins.append(origin)
    cfg["AllowedOrigins"] = ",".join(origins)
elif isinstance(existing, list):
    if origin not in existing:
        existing.append(origin)
    cfg["AllowedOrigins"] = existing

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(f"  AllowedOrigins -> {cfg['AllowedOrigins']}")
PYEOF
}

for bin in /usr/lib/globular/bin/*_server /usr/lib/globular/bin/gateway; do
  id=$("$bin" --describe 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Id',''))" 2>/dev/null || true)
  [[ -z "$id" ]] && continue

  cfg="$SERVICES_DIR/${id}.json"
  [[ ! -f "$cfg" ]] && continue

  echo "Patching $(basename $bin) ($id)..."
  patch_config "$cfg"
done

echo ""
echo "Restarting all globular services..."
systemctl restart globular-authentication.service \
                  globular-discovery.service \
                  globular-dns.service \
                  globular-echo.service \
                  globular-event.service \
                  globular-file.service \
                  globular-log.service \
                  globular-rbac.service \
                  globular-repository.service \
                  globular-resource.service \
                  globular-gateway.service 2>/dev/null || true

echo "Done."
