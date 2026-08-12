#!/bin/sh
set -eu

if [ -z "${SYNAPSE_BOT_USERNAME:-}" ] || [ -z "${SYNAPSE_BOT_PASSWORD:-}" ]; then
  echo "SYNAPSE_BOT_USERNAME and SYNAPSE_BOT_PASSWORD are required." >&2
  exit 1
fi

register_new_matrix_user \
  -c /data/homeserver.yaml \
  http://localhost:8008 \
  -u "${SYNAPSE_BOT_USERNAME}" \
  -p "${SYNAPSE_BOT_PASSWORD}"

