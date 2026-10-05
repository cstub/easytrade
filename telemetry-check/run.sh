#!/usr/bin/env bash
# Telemetry check: starts easytrade with a local OpenTelemetry Collector, drives requests
# through the reverse proxy, then verifies per instrumented component what the collector
# wrote to ./out (resource identity, span kinds, trace context across hops, logs, metrics).
#
#   ./run.sh [--build] [--keep] [--rounds N] [--extra]
#
#   --build    build the images locally first (docker compose build)
#   --keep     leave the stack running afterwards
#   --rounds   rounds of requests to drive (default 5)
#   --extra    also start calculationservice and loadgen (x86-64 images)
#
# Images come from ${REGISTRY:-et-local}/<component>:${TAG:-dev}. To check pushed images:
#   REGISTRY=ghcr.io/<owner>/easytrade TAG=<short SHA> ./run.sh
# Needs Docker with about 6 GB of memory for the containers, and python3.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
compose=(docker compose -f "$here/compose.yaml")
build=false keep=false rounds=5
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) build=true ;;
        --keep) keep=true ;;
        --rounds) rounds="$2"; shift ;;
        --extra) compose+=(--profile extra) ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
export REGISTRY="${REGISTRY:-et-local}" TAG="${TAG:-dev}"

if $build; then
    "${compose[@]}" build
fi

"${compose[@]}" down --remove-orphans >/dev/null 2>&1 || true
mkdir -p "$here/out"
rm -f "$here/out/traces.jsonl" "$here/out/metrics.jsonl" "$here/out/logs.jsonl" "$here/out/results.json"

cleanup() { $keep || "${compose[@]}" down --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${compose[@]}" up -d
python3 "$here/check.py" drive --proxy "http://localhost:${PROXY_PORT:-8080}" --rounds "$rounds"

echo "waiting 30 s for batches and a metric export interval to flush"
sleep 30
python3 "$here/check.py" verify --out "$here/out" --tag "$TAG" --json "$here/out/results.json"
