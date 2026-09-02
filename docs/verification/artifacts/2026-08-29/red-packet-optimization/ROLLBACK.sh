#!/usr/bin/env bash
set -euo pipefail
pwsh -NoProfile -File "$(dirname "$0")/ROLLBACK.ps1"
