#!/usr/bin/env bash
# Resumable chunk uploader: appends only the missing bytes of one chunk.
# Usage: upload_chunk.sh c00
set -u
CHUNK_ID="$1"
BASE="D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-06/v0.3.45-release"
LOCAL="$BASE/chunks/$CHUNK_ID"
REMOTE_DIR="/opt/starchat/frontend/downloads/.parts-0.3.45"
REMOTE="$REMOTE_DIR/$CHUNK_ID"

ssh_server() {
  ssh -o "ProxyCommand=connect -H 127.0.0.1:7897 %h %p" \
      -o ConnectTimeout=25 -o ServerAliveInterval=15 \
      -p 23421 root@207.56.8.8 "$@"
}

SIZE=$(stat -c %s "$LOCAL")
for attempt in $(seq 1 100); do
  HAVE=$(ssh_server "stat -c %s '$REMOTE' 2>/dev/null || echo 0")
  if [ "$HAVE" -ge "$SIZE" ]; then
    echo "CHUNK_DONE $CHUNK_ID size=$HAVE"
    exit 0
  fi
  echo "attempt $attempt: have=$HAVE need=$SIZE"
  tail -c +$((HAVE + 1)) "$LOCAL" | ssh_server "cat >> '$REMOTE'"
done
echo "CHUNK_INCOMPLETE $CHUNK_ID"
exit 1
