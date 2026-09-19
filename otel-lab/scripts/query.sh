#!/usr/bin/env bash
# Replay a saved DQL template against the lab tenant (read-only context), returning JSON with execution metadata.
#   otel-lab/scripts/query.sh otel-lab/queries/spans-5xx-server.dql --set ns=easytrade-otel-lab --set service=broker-service \
#       --set start=2026-09-19T08:00:00Z --set end=2026-09-19T08:05:00Z
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$1"; shift
exec "$LAB_DIR/scripts/dtctl-lab.sh" query -f "$FILE" -o json -M --plain --no-progress "$@"
