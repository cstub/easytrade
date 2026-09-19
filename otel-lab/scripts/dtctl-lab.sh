#!/usr/bin/env bash
# Runs dtctl in the lab's read-only context with the platform token loaded from the token file.
set -euo pipefail
CFG="${EASYTRADE_LAB_CONFIG_DIR:-$HOME/.config/easytrade-otel-lab}"
EASYTRADE_OTEL_LAB_DT_TOKEN="$(tr -d '\r\n' < "$CFG/dynatrace-platform-token")"
export EASYTRADE_OTEL_LAB_DT_TOKEN
export DTCTL_TOKEN_STORAGE=file
exec dtctl --context "${DTCTL_LAB_CONTEXT:-easytrade-otel-lab}" "$@"
