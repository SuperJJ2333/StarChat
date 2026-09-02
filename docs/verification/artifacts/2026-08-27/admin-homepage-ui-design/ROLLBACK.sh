#!/usr/bin/env bash
set -e
COPY_PATH="$1"
rm -f "$COPY_PATH"
if [ -e "$COPY_PATH" ]; then echo "ROLLBACK_FAIL"; exit 1; fi
echo "ROLLBACK_OK: copy restored to absent baseline"
