#!/usr/bin/env bash
# EasyTrade OTel lab control script. Run from anywhere; all paths are derived from the checkout.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$LAB_DIR/.." && pwd)"
export LAB_DIR REPO_DIR
export LAB_PROJECT="${LAB_PROJECT:-easytrade-otel-lab}"
export LAB_HTTP_PORT="${LAB_HTTP_PORT:-8080}"
export LAB_NAMESPACE="${LAB_NAMESPACE:-easytrade-otel-lab}"
export LAB_BASE_URL="${LAB_BASE_URL:-http://127.0.0.1:${LAB_HTTP_PORT}}"
CFG_DIR="${EASYTRADE_LAB_CONFIG_DIR:-$HOME/.config/easytrade-otel-lab}"

git_tag() {
  local sha dirty=""
  sha="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD)"
  if [ -n "$(git -C "$REPO_DIR" status --porcelain -- src compose.dev.yaml)" ]; then dirty="-dirty"; fi
  echo "${sha}${dirty}"
}
export LAB_IMAGE_TAG="${LAB_IMAGE_TAG:-$(git_tag)}"

compose() {
  docker compose -p "$LAB_PROJECT" --project-directory "$REPO_DIR" \
    -f "$REPO_DIR/compose.dev.yaml" -f "$LAB_DIR/compose.otel.yaml" "$@"
}

# Readiness probes through the reverse proxy: path -> expected HTTP status regex
READY_PROBES=(
  "/ 200"
  "/feature-flag-service/v1/flags 200"
  "/broker-service/version 200"
  "/credit-card-order-service/version 200"
  "/accountservice/api/version 200"
  "/engine/api/version 200"
  "/third-party-service/version 200"
  "/pricing-service/version 200"
  "/loginservice/api/version 200"
  "/manager/api/version 200"
  "/offerservice/api/version 200"
  "/broker-service/v1/balance/1 200"
)

cmd_ready() {
  local timeout="${1:-600}" start now all_ok code path want
  start=$(date +%s)
  while :; do
    all_ok=1
    for p in "${READY_PROBES[@]}"; do
      path="${p% *}"; want="${p#* }"
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$LAB_BASE_URL$path" || true)"
      if ! [[ "$code" =~ ^$want$ ]]; then all_ok=0; echo "  waiting: $path -> $code (want $want)"; break; fi
    done
    if [ "$all_ok" = 1 ]; then echo "READY: all probes OK at $LAB_BASE_URL"; return 0; fi
    now=$(date +%s)
    if [ $((now-start)) -ge "$timeout" ]; then echo "NOT READY after ${timeout}s" >&2; compose ps; return 1; fi
    sleep 5
  done
}

cmd_flag() {
  local id="$1" val="${2:-}"
  if [ -z "$val" ]; then
    curl -sf "$LAB_BASE_URL/feature-flag-service/v1/flags/$id"; echo
  else
    curl -sf -X PUT -H 'Content-Type: application/json' -d "{\"enabled\": $val}" "$LAB_BASE_URL/feature-flag-service/v1/flags/$id"; echo
  fi
}

cmd_background() {
  # pause|resume uncontrolled traffic sources: loadgen (if running), aggregator-service, engine scheduler
  local action="$1" running
  running="$(compose --profile load ps --status running --format '{{.Service}}' 2>/dev/null || true)"
  case "$action" in
    pause)
      for s in loadgen aggregator-service; do
        if grep -qx "$s" <<<"$running"; then compose --profile load pause "$s"; echo "paused $s"; fi
      done
      curl -sf "$LAB_BASE_URL/engine/api/trade/scheduler/stop" && echo ;;
    resume)
      for s in loadgen aggregator-service; do
        if compose --profile load ps --status paused --format '{{.Service}}' 2>/dev/null | grep -qx "$s"; then compose --profile load unpause "$s"; echo "resumed $s"; fi
      done
      curl -sf "$LAB_BASE_URL/engine/api/trade/scheduler/start" && echo ;;
    status)
      compose --profile load ps --format 'table {{.Service}}\t{{.Status}}' | grep -E 'loadgen|aggregator|SERVICE' || true
      curl -sf "$LAB_BASE_URL/engine/api/trade/scheduler/status" && echo ;;
    *) echo "usage: lab.sh background pause|resume|status" >&2; return 2 ;;
  esac
}

usage() {
  cat <<USAGE
usage: $(basename "$0") <command> [args]
  agents                 download/verify pinned OTel agents into otel-lab/agents
  env                    (re)generate the secret runtime env file from ~/.config/easytrade-otel-lab
  build [service...]     build lab images from this checkout (tag: $LAB_IMAGE_TAG)
  up                     agents + env + start the whole lab (no load generator)
  ready [timeout_s]      wait until all readiness probes pass
  status                 compose ps + container memory
  down                   stop and remove the lab containers (data in the DB container is discarded)
  stop | start           stop / start containers keeping state
  logs [service...]      follow logs
  flag <id> [true|false] get / set a feature flag
  load on|off            start / stop the loadgen profile
  background pause|resume|status   pause uncontrolled traffic (loadgen, aggregator-service, engine scheduler)
  compose <args...>      raw docker compose with the lab files/project
  dtctl <args...>        dtctl in the lab's read-only context
  smoke [args...]        run the fault-and-recovery smoke suite (otel-lab/scripts/smoke.sh)
env: LAB_HTTP_PORT=$LAB_HTTP_PORT LAB_PROJECT=$LAB_PROJECT LAB_IMAGE_TAG=$LAB_IMAGE_TAG LAB_NAMESPACE=$LAB_NAMESPACE
USAGE
}

case "${1:-}" in
  agents) "$LAB_DIR/scripts/fetch-agents.sh" ;;
  env) "$LAB_DIR/scripts/gen-runtime-env.sh" ;;
  build) shift; compose build "$@" ;;
  up) "$LAB_DIR/scripts/fetch-agents.sh" >/dev/null; [ -r "$CFG_DIR/otel.env" ] || "$LAB_DIR/scripts/gen-runtime-env.sh"
      compose up -d --remove-orphans; echo "lab started: $LAB_BASE_URL (images easytrade-otel-lab/*:$LAB_IMAGE_TAG)" ;;
  ready) shift; cmd_ready "$@" ;;
  status) compose --profile load ps; docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' $(compose --profile load ps -q 2>/dev/null) 2>/dev/null || true ;;
  down) compose --profile load down --remove-orphans ;;
  stop) compose --profile load stop ;;
  start) compose start ;;
  logs) shift; compose logs -f "$@" ;;
  flag) shift; cmd_flag "$@" ;;
  load) case "${2:-}" in on) compose --profile load up -d loadgen ;; off) compose --profile load stop loadgen ;; *) usage; exit 2 ;; esac ;;
  background) shift; cmd_background "$@" ;;
  compose) shift; compose "$@" ;;
  dtctl) shift; "$LAB_DIR/scripts/dtctl-lab.sh" "$@" ;;
  smoke) shift; "$LAB_DIR/scripts/smoke.sh" "$@" ;;
  *) usage; exit 2 ;;
esac
