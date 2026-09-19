#!/usr/bin/env bash
# EasyTrade OTel lab - repeatable fault-and-recovery smoke suite.
# One command: probes -> healthy baseline -> card failure -> broker failure -> recovery, with stored-telemetry checks
# through dtctl/DQL. Evidence is written to otel-lab/evidence/<run-id>/ (bounded raw JSON + manifest).
# Exit code: 0 when every case passed, 1 when a case failed (fault state is restored regardless), 2 on setup errors.
set -uo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$LAB_DIR/.." && pwd)"
LAB="$LAB_DIR/scripts/lab.sh"
DT="$LAB_DIR/scripts/dtctl-lab.sh"
Q="$LAB_DIR/queries"
BASE="${LAB_BASE_URL:-http://127.0.0.1:${LAB_HTTP_PORT:-8080}}"
NS="${LAB_NAMESPACE:-easytrade-otel-lab}"
BATCH="${LAB_SMOKE_BATCH:-6}"
USERNAME="${LAB_SMOKE_USER:-demouser}"
INSTRUMENT_ID="${LAB_SMOKE_INSTRUMENT:-1}"
WAIT_TIMEOUT="${LAB_SMOKE_WAIT:-300s}"
ACTIVATION_TIMEOUT_S="${LAB_SMOKE_ACTIVATION_S:-90}"
KEEP_BACKGROUND="${LAB_SMOKE_KEEP_BACKGROUND:-0}"

RUN_ID="run-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' $RANDOM)"
EV="$LAB_DIR/evidence/$RUN_ID"; mkdir -p "$EV/dql"
REQ_LOG="$EV/requests.jsonl"; : > "$REQ_LOG"
LOG="$EV/smoke.log"
declare -A RESULT=()
declare -A NOTE=()
FAILED=0

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
iso_shift() { date -u -d "$1 $2" +%Y-%m-%dT%H:%M:%S.%3NZ; }   # iso_shift <iso> "-2 seconds"

# req <case> <method> <path> [json-body]  -> prints HTTP status, appends a line to requests.jsonl
req() {
  local case="$1" method="$2" path="$3" body="${4:-}" ts code out
  ts="$(now)"
  out="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -s -o "$out" -w '%{http_code}' --max-time 30 -X "$method" -H 'Content-Type: application/json' \
      -H "X-Lab-Run-Id: $RUN_ID" -H "X-Lab-Case: $case" -d "$body" "$BASE$path" || echo 000)"
  else
    code="$(curl -s -o "$out" -w '%{http_code}' --max-time 30 -X "$method" \
      -H "X-Lab-Run-Id: $RUN_ID" -H "X-Lab-Case: $case" "$BASE$path" || echo 000)"
  fi
  jq -cn --arg ts "$ts" --arg case "$case" --arg m "$method" --arg p "$path" --arg c "$code" --arg b "$(head -c 300 "$out")" \
    '{ts:$ts, case:$case, method:$m, path:$p, status:($c|tonumber), body_head:$b}' >> "$REQ_LOG"
  rm -f "$out"
  echo "$code"
}

# dql_save <name> <template.dql> [--set k=v ...] -> runs the query, saves resolved template + JSON result (bounded)
dql_save() {
  local name="$1" tpl="$2"; shift 2
  local out="$EV/dql/$name.json"
  cp "$tpl" "$EV/dql/$name.dql"
  printf '%s\n' "$@" | sed 's/^--set$//' | grep -v '^$' > "$EV/dql/$name.vars"
  "$DT" query -f "$tpl" -o json -M --plain --no-progress "$@" > "$out" 2> "$EV/dql/$name.stderr" || true
  if jq -e '.ok == true' "$out" >/dev/null 2>&1; then
    jq -r '"    \(input_filename|split("/")|last): records=\((.result.records // [])|length) scanned=\(.metadata.scannedRecords // "?")rec/\(.metadata.scannedBytes // "?")B exec=\(.metadata.executionTimeMilliseconds // "?")ms"' "$out" >&2
  else
    log "    DQL $name FAILED: $(jq -r '.error.message // .' "$out" 2>/dev/null | head -c 300) $(head -c 300 "$EV/dql/$name.stderr")"
  fi
}

# dql_count <name> -> number of records in a saved result
dql_count() { jq -r '(.result.records // []) | length' "$EV/dql/$1.json" 2>/dev/null || echo 0; }

# dql_wait <name> <template.dql> <count-condition> [--set ...]  bounded polling until the condition holds
dql_wait() {
  local name="$1" tpl="$2" cond="$3"; shift 3
  log "  waiting (<= $WAIT_TIMEOUT) for stored telemetry: $name --for=$cond"
  "$DT" wait query -f "$tpl" --for="$cond" --timeout "$WAIT_TIMEOUT" --initial-delay 5s --min-interval 5s --max-interval 20s -q --plain "$@" \
     > "$EV/dql/$name.wait.json" 2> "$EV/dql/$name.wait.stderr"
  local rc=$?
  log "    wait rc=$rc $(head -c 200 "$EV/dql/$name.wait.stderr" | tr '\n' ' ')"
  return $rc
}

flag_set() { curl -sf -X PUT -H 'Content-Type: application/json' -d "{\"enabled\": $2}" "$BASE/feature-flag-service/v1/flags/$1" >/dev/null; }
flag_get() { curl -sf "$BASE/feature-flag-service/v1/flags/$1" | jq -r '.enabled'; }
flags_snapshot() { curl -sf "$BASE/feature-flag-service/v1/flags" | jq -c '[.results[]? // .[]? | {id, enabled}]' 2>/dev/null; }

restore_faults() {
  flag_set credit_card_meltdown false || true
  flag_set db_not_responding false || true
}

cleanup() {
  log "cleanup: restoring fault flags"
  restore_faults
  local card_code buy_code i
  for i in $(seq 1 30); do
    card_code="$(req cleanup GET "/credit-card-order-service/v1/orders/$ACCOUNT_ID/status/latest")"
    buy_code="$(req cleanup POST "/broker-service/v1/trade/buy" "{\"accountId\":$ACCOUNT_ID,\"instrumentId\":$INSTRUMENT_ID,\"amount\":1}")"
    if [[ "$card_code" =~ ^(200|404)$ ]] && [ "$buy_code" = 200 ]; then break; fi
    sleep 2
  done
  log "cleanup: card=$card_code buy=$buy_code flags=$(flags_snapshot)"
  [ "$KEEP_BACKGROUND" = 1 ] || "$LAB" background resume >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ preflight
log "run $RUN_ID  base=$BASE ns=$NS batch=$BATCH evidence=$EV"
if ! "$LAB" ready 60 >>"$LOG" 2>&1; then log "lab not ready"; exit 2; fi
ACCOUNT_ID="$(curl -sf "$BASE/loginservice/api/Accounts/GetAccountByUsername/$USERNAME" | jq -r '.id')"
if ! [[ "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then log "cannot resolve account id for $USERNAME"; exit 2; fi
log "account $USERNAME -> id $ACCOUNT_ID"
trap cleanup EXIT

restore_faults
"$LAB" background pause >>"$LOG" 2>&1 || log "warning: could not pause background traffic"
BACKGROUND_STATE="$("$LAB" background status 2>/dev/null | tr '\n' ';')"

# fixtures: funded account + an existing credit-card order so status/latest is 200 when healthy
FIXTURE_ERRORS=()
# deposit DTO in this fork requires card fields (DepositMoneyDTO); validation middleware is a no-op unless credit_card_validation is on
c="$(req fixture POST "/broker-service/v1/balance/$ACCOUNT_ID/deposit" '{"amount": 5000, "name": "Lab User", "address": "1 Lab Street", "email": "lab@example.invalid", "cardNumber": "4111111111111111", "cardType": "visa", "cvv": "123"}')"; [ "$c" = 200 ] || FIXTURE_ERRORS+=("deposit=$c")
c="$(req fixture POST "/credit-card-order-service/v1/orders" "{\"accountId\":$ACCOUNT_ID,\"email\":\"lab@example.invalid\",\"name\":\"Lab User\",\"shippingAddress\":\"1 Lab Street\",\"cardLevel\":\"silver\"}")"
[[ "$c" =~ ^(201|400)$ ]] || FIXTURE_ERRORS+=("order=$c")
[ ${#FIXTURE_ERRORS[@]} -eq 0 ] || log "FIXTURE errors: ${FIXTURE_ERRORS[*]}"

# ------------------------------------------------------------------ case 1: healthy baseline
log "== case baseline"
FLAGS_BASELINE="$(flags_snapshot)"
B_START="$(iso_shift "$(now)" '-1 seconds')"
codes=()
for i in $(seq 1 3); do codes+=("acct:$(req baseline GET "/accountservice/api/account/$ACCOUNT_ID")"); done
codes+=("balance:$(req baseline GET "/broker-service/v1/balance/$ACCOUNT_ID")")
codes+=("card:$(req baseline GET "/credit-card-order-service/v1/orders/$ACCOUNT_ID/status/latest")")
codes+=("buy:$(req baseline POST "/broker-service/v1/trade/buy" "{\"accountId\":$ACCOUNT_ID,\"instrumentId\":$INSTRUMENT_ID,\"amount\":1}")")
codes+=("prices:$(req baseline GET "/pricing-service/v1/prices/last?instrumentId=$INSTRUMENT_ID&count=1")")
sleep 1; B_END="$(iso_shift "$(now)" '+2 seconds')"
log "  baseline statuses: ${codes[*]}  window $B_START .. $B_END"
baseline_ok=1
for c in "${codes[@]}"; do
  case "$c" in acct:200|balance:200|card:200|buy:200|prices:200|prices:404) ;; *) baseline_ok=0;; esac
done
# cross-service trace: accountservice (Java, client) -> manager (.NET, server) in the same trace
sleep 20
if dql_wait baseline-trace "$Q/trace-cross-service.dql" count-gte=2 --set ns="$NS" --set caller=accountservice --set callee=manager --set start="$B_START" --set end="$(iso_shift "$B_END" '+120 seconds')"; then :; fi
dql_save baseline-trace "$Q/trace-cross-service.dql" --set ns="$NS" --set caller=accountservice --set callee=manager --set start="$B_START" --set end="$(iso_shift "$B_END" '+120 seconds')"
LINKED="$(jq -r --arg run "$RUN_ID" '
  [.result.records[]? | select(.["http.request.header.x-lab-run-id"]==null or (.["http.request.header.x-lab-run-id"]|tostring|contains($run)))] as $r
  | [ $r[] | select(.["service.name"]=="accountservice" and .["span.kind"]=="client") ] as $clients
  | [ $r[] | select(.["service.name"]=="manager" and .["span.kind"]=="server") ] as $servers
  | [ $servers[] as $s | $clients[] | select(.["span.id"]==$s["span.parent_id"] and .["trace.id"]==$s["trace.id"]) | {trace: .["trace.id"], client_span: .["span.id"], server_span: $s["span.id"]} ] | length' "$EV/dql/baseline-trace.json" 2>/dev/null || echo 0)"
log "  cross-service linked pairs (accountservice client -> manager server, same trace, parent match): $LINKED"
if [ "$baseline_ok" = 1 ] && [ "${LINKED:-0}" -ge 1 ]; then RESULT[baseline]=PASS; else RESULT[baseline]=FAIL; FAILED=1; fi
NOTE[baseline]="statuses=${codes[*]} linked_pairs=$LINKED"

# ------------------------------------------------------------------ generic failure case runner
# run_fault <case> <flag> <method> <path> <body> <expected-status>
run_fault() {
  local case="$1" flag="$2" method="$3" path="$4" body="$5" want="$6"
  local probes=0 code activated=0 start end i statuses=() sent=0 got=0 uniq=0 errs=0 retries=0
  log "== case $case (flag $flag, expect HTTP $want)"
  flag_set "$flag" true
  local t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$ACTIVATION_TIMEOUT_S" ]; do
    code="$(req "$case-probe" "$method" "$path" "$body")"; probes=$((probes+1))
    if [ "$code" = "$want" ]; then activated=1; break; fi
    sleep 2
  done
  log "  activation probes: $probes (activated=$activated, flag now $(flag_get "$flag"))"
  sleep 1
  start="$(iso_shift "$(now)" '-1 seconds')"
  for i in $(seq 1 "$BATCH"); do
    code="$(req "$case" "$method" "$path" "$body")"; statuses+=("$code"); sent=$((sent+1))
    [ "$code" = "$want" ] && got=$((got+1))
  done
  sleep 1; end="$(iso_shift "$(now)" '+2 seconds')"
  log "  batch: sent=$sent statuses=${statuses[*]} window $start .. $end"
  # stored telemetry: qualifying SERVER spans (unique span ids) and ERROR logs of the service in the window
  local svc; case "$case" in card) svc=credit-card-order-service;; broker) svc=broker-service;; esac
  local qend; qend="$(iso_shift "$end" '+120 seconds')"   # query window end padded for delivery delay; records are still selected by start_time<=end via wait/verify filters below
  dql_wait "$case-spans" "$Q/spans-5xx-server.dql" count-gt=3 --set ns="$NS" --set service="$svc" --set start="$start" --set end="$end" || true
  dql_save "$case-spans" "$Q/spans-5xx-server.dql" --set ns="$NS" --set service="$svc" --set start="$start" --set end="$end"
  dql_save "$case-spans-summary" "$Q/spans-5xx-server-summary.dql" --set ns="$NS" --set service="$svc" --set start="$start" --set end="$end"
  dql_save "$case-spans-by-kind" "$Q/spans-by-kind-status.dql" --set ns="$NS" --set service="$svc" --set start="$start" --set end="$end"
  uniq="$(jq -r '[.result.records[]? | .["span.id"]] | unique | length' "$EV/dql/$case-spans.json" 2>/dev/null || echo 0)"
  local uniq_run; uniq_run="$(jq -r --arg run "$RUN_ID" '[.result.records[]? | select((.["http.request.header.x-lab-run-id"]|tostring)|contains($run)) | .["span.id"]] | unique | length' "$EV/dql/$case-spans.json" 2>/dev/null || echo 0)"
  dql_wait "$case-logs" "$Q/logs-error-samples.dql" count-gte=1 --set ns="$NS" --set service="$svc" --set start="$start" --set end="$end" || true
  dql_save "$case-logs" "$Q/logs-error-samples.dql" --set ns="$NS" --set service="$svc" --set start="$start" --set end="$end"
  dql_save "$case-logs-by-level" "$Q/logs-by-level.dql" --set ns="$NS" --set service="$svc" --set start="$start" --set end="$end"
  errs="$(jq -r '(.result.records // []) | length' "$EV/dql/$case-logs.json" 2>/dev/null || echo 0)"
  local errs_total; errs_total="$(jq -r '[.result.records[]? | select(.loglevel=="ERROR") | .records] | add // 0' "$EV/dql/$case-logs-by-level.json" 2>/dev/null || echo 0)"
  log "  stored: unique 5xx server spans=$uniq (with run id=$uniq_run), ERROR logs=$errs_total (samples saved: $errs)"
  NOTE[$case]="activated=$activated probes=$probes sent=$sent returned_${want}=$got statuses=${statuses[*]} unique_5xx_server_spans=$uniq spans_with_run_id=$uniq_run error_logs=$errs_total window=$start..$end"
  if [ "$activated" = 1 ] && [ "$got" -gt 3 ] && [ "$uniq" -gt 3 ] && [ "$errs_total" -ge 1 ]; then RESULT[$case]=PASS; else RESULT[$case]=FAIL; FAILED=1; fi
  flag_set "$flag" false
  log "  flag $flag restored -> $(flag_get "$flag")"
}

run_fault card credit_card_meltdown GET "/credit-card-order-service/v1/orders/$ACCOUNT_ID/status/latest" "" 500
run_fault broker db_not_responding POST "/broker-service/v1/trade/buy" "{\"accountId\":$ACCOUNT_ID,\"instrumentId\":$INSTRUMENT_ID,\"amount\":1}" 503

# ------------------------------------------------------------------ recovery
log "== case recovery"
restore_faults
R_START="$(iso_shift "$(now)" '-1 seconds')"
rec_ok=0; rprobes=0
for i in $(seq 1 45); do
  rprobes=$((rprobes+1))
  card="$(req recovery GET "/credit-card-order-service/v1/orders/$ACCOUNT_ID/status/latest")"
  buy="$(req recovery POST "/broker-service/v1/trade/buy" "{\"accountId\":$ACCOUNT_ID,\"instrumentId\":$INSTRUMENT_ID,\"amount\":1}")"
  if [ "$card" = 200 ] && [ "$buy" = 200 ]; then rec_ok=1; break; fi
  sleep 2
done
R_END="$(iso_shift "$(now)" '+2 seconds')"
FLAGS_END="$(flags_snapshot)"
log "  recovery: ok=$rec_ok probes=$rprobes card=$card buy=$buy flags=$FLAGS_END"
if [ "$rec_ok" = 1 ]; then RESULT[recovery]=PASS; else RESULT[recovery]=FAIL; FAILED=1; fi
NOTE[recovery]="probes=$rprobes card=$card buy=$buy window=$R_START..$R_END"

# ------------------------------------------------------------------ manifest
IMAGES="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Digest}}' | grep '^easytrade-otel-lab/' | sort | jq -R -s 'split("\n") | map(select(length>0))')"
EFFECTIVE_ENV="$("$LAB" compose config --format json 2>/dev/null | jq '{services: (.services | with_entries({key: .key, value: {image: .value.image, environment: ((.value.environment // {}) | with_entries(select(.key|test("^OTEL_|^JAVA_TOOL|^CORECLR|^DOTNET_|^NODE_OPTIONS|^FEATURE_FLAG_CACHE|^WORK_|^COURIER_|^MANUFACTURE_|^MSSQL_MEMORY"))) | with_entries(if (.key|test("HEADERS")) then .value = "<redacted>" else . end))}}))}')"
jq -n --arg run "$RUN_ID" --arg ns "$NS" --arg base "$BASE" --arg acct "$ACCOUNT_ID" --arg batch "$BATCH" \
  --arg git "$(git -C "$REPO_DIR" rev-parse HEAD)" --arg branch "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)" --arg tag "${LAB_IMAGE_TAG:-}" \
  --arg dtctl "$(dtctl version 2>/dev/null | head -1)" --arg host "$(hostname) $(uname -m)" \
  --argjson images "$IMAGES" --argjson env "$EFFECTIVE_ENV" \
  --arg flags_baseline "$FLAGS_BASELINE" --arg flags_end "$FLAGS_END" --arg background "$BACKGROUND_STATE" \
  --arg r_b "${RESULT[baseline]}" --arg n_b "${NOTE[baseline]}" --arg r_c "${RESULT[card]}" --arg n_c "${NOTE[card]}" \
  --arg r_k "${RESULT[broker]}" --arg n_k "${NOTE[broker]}" --arg r_r "${RESULT[recovery]}" --arg n_r "${NOTE[recovery]}" \
  --arg fixtures "${FIXTURE_ERRORS[*]:-none}" --arg agents "java=$(cat "$LAB_DIR/agents/java/VERSION" 2>/dev/null) dotnet=$(cat "$LAB_DIR/agents/dotnet/VERSION" 2>/dev/null) node=$(jq -r '.dependencies["@opentelemetry/auto-instrumentations-node"]' "$LAB_DIR/agents/node/package.json")" \
  '{run_id:$run, generated_utc: (now|todate), lab_namespace:$ns, base_url:$base, host:$host, git_commit:$git, git_branch:$branch, image_tag:$tag,
    images:$images, agents:$agents, dtctl:$dtctl, account_id:($acct|tonumber), batch_size:($batch|tonumber),
    background_traffic_state:$background, flags_at_baseline:$flags_baseline, flags_at_end:$flags_end, fixture_errors:$fixtures,
    effective_settings:$env,
    cases:{baseline:{result:$r_b, note:$n_b}, card:{result:$r_c, note:$n_c}, broker:{result:$r_k, note:$n_k}, recovery:{result:$r_r, note:$n_r}}}' > "$EV/manifest.json"
log "== RESULT baseline=${RESULT[baseline]} card=${RESULT[card]} broker=${RESULT[broker]} recovery=${RESULT[recovery]}  (evidence: $EV)"
exit $FAILED
