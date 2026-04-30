#!/usr/bin/env bash
set -euo pipefail

# Lint service specs: fail if any spec declares the shared state root
# (/var/lib/globular or {{.StateDir}}) with mode less than 0755.
#
# Usage: bash scripts/lint-service-specs.sh [specs-dir]

SPECS_DIR="${1:-internal/specs}"

[[ -d "$SPECS_DIR" ]] || { echo "FAIL: specs dir not found: $SPECS_DIR" >&2; exit 1; }

ERRORS=0

for spec in "$SPECS_DIR"/*.yaml; do
  [[ -f "$spec" ]] || continue
  name=$(basename "$spec")

  # Find lines that declare path: "{{.StateDir}}" (the shared root, not subdirs)
  # and check their mode
  python3 -c "
import yaml, sys
with open('$spec') as f:
    doc = yaml.safe_load(f)

for step in doc.get('steps', []):
    if step.get('type') != 'ensure_dirs':
        continue
    for d in step.get('dirs', []):
        path = d.get('path', '')
        mode = d.get('mode', 0)
        # Check if this is the shared state root (not a subdir)
        shared_roots = ('{{.StateDir}}', '/var/lib/globular', '{{.StateDir}}/pki', '/var/lib/globular/pki')
        if path in shared_roots:
            if isinstance(mode, int) and mode > 0:
                # mode is octal in YAML (parsed as int)
                if mode & 0o005 == 0:  # no world r+x
                    print(f'FAIL: {\"$name\"}: {path} has mode {oct(mode)} — shared root must be >= 0755')
                    sys.exit(1)
" 2>/dev/null || {
    ERRORS=$((ERRORS + 1))
  }
done

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo "FAILED: $ERRORS spec(s) have restrictive shared root permissions"
  echo "Fix: change 'mode: 0750' to 'mode: 0755' for {{.StateDir}} entries"
  exit 1
fi

echo "PASS: all $(ls "$SPECS_DIR"/*.yaml | wc -l) specs have correct shared root permissions"
