#!/usr/bin/env bash
set -e

VARIANT="$1"
CONF="config/variants.conf"

# Load spell list for variant
SPELLS=$(grep "^${VARIANT}|" "$CONF" | cut -d'|' -f2)

IFS=',' read -ra PATCHES <<< "$SPELLS"

for patch in "${PATCHES[@]}"; do
    PATCH_PATH="spells/$patch.patch"
    if [ -f "$PATCH_PATH" ]; then
        git apply "$PATCH_PATH"
        echo "[✓] Applied $patch"
    else
        echo "[⚠] Patch not found: $patch"
    fi
done
