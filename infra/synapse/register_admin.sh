#!/bin/sh
set -eu

if [ -z "${SYNAPSE_ADMIN_USERNAME:-}" ] || [ -z "${SYNAPSE_ADMIN_PASSWORD:-}" ]; then
  echo "SYNAPSE_ADMIN_USERNAME and SYNAPSE_ADMIN_PASSWORD are required." >&2
  exit 1
fi

register_new_matrix_user \
  -c /data/homeserver.yaml \
  http://localhost:8008 \
  -u "${SYNAPSE_ADMIN_USERNAME}" \
  -p "${SYNAPSE_ADMIN_PASSWORD}" \
  -a

