#!/usr/bin/env bash
set -e
cp "$1" "$2"
echo "ROLLBACK_OK: restored target from backup"
