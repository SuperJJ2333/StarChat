#!/usr/bin/env bash
set -euo pipefail
TARGET="$1"
BACKUP="$2"
cp -- "$BACKUP" "$TARGET"
printf 'ROLLBACK_RESTORED=%s\n' "$TARGET"
