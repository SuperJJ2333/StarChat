#!/usr/bin/env bash
set -euo pipefail
cd /opt/starchat
# Restore gateway configuration and compose overlay from deployment backup
cp /opt/starchat-backups/20260827-部署前/nginx.conf data/nginx/nginx.conf
cp /opt/starchat-backups/20260827-部署前/docker-compose.production.yml docker-compose.production.yml
docker compose -f docker-compose.yml -f docker-compose.production.yml up -d --no-deps --force-recreate gateway
nginx_status=$(docker exec starchat-gateway-1 nginx -t 2>&1)
printf '%s\n' "$nginx_status"
# business-api rollback requires restoring the recorded pre-deploy image digest:
# sha256:b3db1d4a0f623269dc11ed2c0b7ce047bd71deb9a61bb740c3653301e8a8ae29
