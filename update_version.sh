#!/usr/bin/env bash
# Regenerate version.cfg with the current short git commit hash.
# Run this before exporting your project:
#   ./update_version.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)

cat > "$SCRIPT_DIR/version.cfg" <<EOF
[version]
commit="$COMMIT"
EOF

echo "Updated version.cfg: commit=$COMMIT"
