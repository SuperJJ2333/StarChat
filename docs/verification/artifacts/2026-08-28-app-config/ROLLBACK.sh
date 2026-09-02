#!/usr/bin/env bash
set -euo pipefail
cp "$(dirname "$0")/MODIFIED_FILE" "apps/mobile_flutter/lib/core/app_config.dart"
