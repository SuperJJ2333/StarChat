#!/bin/sh
# Install as /etc/letsencrypt/renewal-hooks/deploy/zz-starchat-turn.sh (root:root 0750).
# Runs only after successful renewal of this deployment's TURN certificate.
set -eu
[ "${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/liuhetong888.com" ] || exit 0
python3 /opt/starchat/scripts/sync_turn_certificates.py --source "$RENEWED_LINEAGE"
docker restart starchat-coturn-1 >/dev/null
