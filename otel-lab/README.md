# EasyTrade OTel lab - runbook

Deploys this EasyTrade fork with Docker Compose on a single Linux x86-64 host and replaces the expected OneAgent
monitoring with **official OpenTelemetry zero-code instrumentation** exporting directly (OTLP/HTTP protobuf) to a
Dynatrace tenant. Verification of stored telemetry is done with `dtctl` and DQL.

Companion documents: [COVERAGE.md](COVERAGE.md) (per-service instrumentation matrix), [NOTES.md](NOTES.md)
(experiment notes: attempts, failures, fixes), `evidence/<run-id>/` (per-run manifests, DQL and raw results).

## Prerequisites

* Linux x86-64 host with Docker Engine (tested: 29.2.1) and the Compose plugin v2.24+ (tested: v5.0.2), `curl`,
  `jq`, `git`, `python3`, `bash`. About 6 GiB of RAM free for the lab (or swap); ~15 GB of disk for images.
* `dtctl` >= 0.39.0 on the PATH (`scripts/install-dtctl.sh` installs the pinned release for linux/amd64).
* User-supplied inputs (paths relative to the home directory of the account running the lab; never committed):
  * `~/.config/easytrade-otel-lab/lab.json` - `{ "fork_url", "platform_url", "otlp_endpoint" }`
  * `~/.config/easytrade-otel-lab/dynatrace-platform-token` - the raw platform token on one line
    (directory mode `0700`, file mode `0600`). Required scopes: `openpipeline:traces:ingest`,
    `openpipeline:logs:ingest`, `storage:spans:read`, `storage:logs:read`, `storage:buckets:read`.
* Generated at first start (mode 0600, outside the checkout): `~/.config/easytrade-otel-lab/otel.env` with the
  OTLP endpoint and the `Authorization: Bearer` header. Template without secrets: [`otel.env.template`](otel.env.template).

## Layout

| Path | Purpose |
| --- | --- |
| `compose.otel.yaml` | Compose overlay applied on top of the upstream `compose.dev.yaml` (build from source, inject agents, ports, env) |
| `versions.env` | Pinned instrumentation / tool versions and SHA-256 checksums |
| `agents/` | Downloaded official agents (git-ignored; `agents/node/package*.json` pin the Node packages) |
| `scripts/lab.sh` | Lab control: agents, env, build, up, ready, status, flags, background traffic, down |
| `scripts/lab-env.sh` | Shared settings (project name, port, namespace, image tag = last commit touching `src/`) |
| `scripts/smoke.sh` | The fault-and-recovery smoke suite (one command) |
| `scripts/dtctl-lab.sh` / `scripts/query.sh` | dtctl in the lab's read-only context; replay a saved DQL template |
| `queries/*.dql` | DQL templates used for verification (`{{ .var }}` placeholders, `--set var=value`) |
| `evidence/<run-id>/` | Manifest, request log, resolved DQL, bounded raw JSON results per smoke run |

## Deploy / start

```bash
cd <checkout>                                # branch codex/otel-easytrade-lab
otel-lab/scripts/install-dtctl.sh            # once; installs the pinned dtctl to /usr/local/bin
otel-lab/scripts/setup-dtctl-context.sh      # once; creates the read-only dtctl context "easytrade-otel-lab"
otel-lab/scripts/lab.sh build                # build all lab images from this checkout (10-20 min first time)
otel-lab/scripts/lab.sh up                   # fetch/verify agents, generate otel.env, start everything (no loadgen)
otel-lab/scripts/lab.sh ready                # block until all HTTP readiness probes pass (up to 10 min: MSSQL seed)
```

`up` is idempotent: a second invocation reuses running containers and only recreates services whose
configuration or image changed. The image tag is the git revision of `src/` (`LAB_IMAGE_TAG`, `-dirty` suffix if
`src/` has uncommitted changes), so the image <-> source relationship is explicit.

Application access (bound to localhost only; use SSH port forwarding from elsewhere,
`ssh -L 8080:127.0.0.1:8080 <host>`):

* UI: http://127.0.0.1:8080/ (demo credentials `demouser` / `demopass`)
* Feature flags: `otel-lab/scripts/lab.sh flag credit_card_meltdown [true|false]`
  (REST: `GET/PUT /feature-flag-service/v1/flags/{id}` with `{"enabled": true|false}`)
* Swagger UIs, e.g. http://127.0.0.1:8080/broker-service/swagger/index.html

Override defaults with environment variables: `LAB_HTTP_PORT` (8080), `LAB_PROJECT` (easytrade-otel-lab),
`LAB_NAMESPACE` (easytrade-otel-lab - the `service.namespace`/`deployment.environment.name` value),
`LAB_JAVA_XMX` (256m), `LAB_MSSQL_MEMORY_MB` (1536), `LAB_BROKER_FLAG_CACHE_S` (5).

## Background traffic

* `otel-lab/scripts/lab.sh load on|off` starts/stops the upstream Puppeteer load generator (Compose profile
  `load`, off by default).
* `otel-lab/scripts/lab.sh background pause|resume|status` pauses/resumes the uncontrolled traffic sources
  (loadgen, `aggregator-service`, and the engine's 1-minute scheduler). The smoke suite does this automatically.
* Intrinsic schedulers that cannot be paused without a restart: credit-card-order-service `WorkScheduler` and
  third-party-service courier/manufacture schedulers (lab rates: initial delay 60 s, period 180 s). They call
  other routes than the measured ones and never produce 5xx on the measured routes.

## Run the smoke suite

```bash
otel-lab/scripts/lab.sh smoke            # or: otel-lab/scripts/smoke.sh
otel-lab/scripts/lab.sh smoke            # second unattended run must pass as well
```

Cases: healthy baseline (incl. accountservice -> manager cross-service trace) -> `credit_card_meltdown`
(6 x `GET /credit-card-order-service/v1/orders/{accountId}/status/latest`, expect 500) -> `db_not_responding`
(6 x `POST /broker-service/v1/trade/buy`, expect 503) -> recovery. Each failure case is only accepted when Dynatrace
stores **> 3 unique SERVER spans with HTTP status 500-599** of that service in the batch window and at least one
ERROR log record of that service. Flags are restored on any exit (trap) and recovery is re-verified.
Tunables: `LAB_SMOKE_BATCH` (6), `LAB_SMOKE_USER` (demouser), `LAB_SMOKE_WAIT` (300s per stored-telemetry wait).

Evidence lands in `otel-lab/evidence/<run-id>/`: `manifest.json` (windows, revision, running container image ids,
effective non-secret settings, per-case results), `requests.jsonl` (every request with status), `smoke.log`,
`dql/<name>.dql|.vars|.json|.wait.json` (template, variables, raw result with `metadata` including
`analysisTimeframe`, `scannedRecords`, `scannedBytes`, and the bounded-polling result).
Reference runs: `run-20260919T082103Z-0944`, `run-20260919T082305Z-3783`, `run-20260919T082542Z-0897` (all PASS).

Field notes for replaying queries: spans use `service.name`, `service.namespace`, `span.kind` (`server`/`client`),
`http.response.status_code`, `http.route`, `trace.id`, `span.id`, `span.parent_id`, `start_time`; logs use
`service.name`, `service.namespace`, `loglevel`, `content`, `trace_id`, `span_id`, `otel.scope.name`,
`exception.*`. The captured `X-Lab-Run-Id` header is `http.request.header.x-lab-run-id` (array on Java spans,
string on .NET spans).

## Query telemetry manually

```bash
otel-lab/scripts/lab.sh dtctl doctor
otel-lab/scripts/query.sh otel-lab/queries/spans-inventory.dql --set ns=easytrade-otel-lab \
    --set start=2026-09-19T08:00:00Z --set end=2026-09-19T09:00:00Z | jq '.result.records'
otel-lab/scripts/lab.sh dtctl query 'fetch spans, from:now()-15m | filter service.namespace == "easytrade-otel-lab" | limit 5' -o json
```

The dtctl context `easytrade-otel-lab` is read-only (`safety-level: readonly`) and resolves the token from the
environment variable `EASYTRADE_OTEL_LAB_DT_TOKEN`, which `scripts/dtctl-lab.sh` fills from the token file.
Other dtctl contexts are untouched; plain `dtctl` outside the wrapper needs that variable exported.

## Restore healthy state / stop

```bash
otel-lab/scripts/lab.sh flag credit_card_meltdown false; otel-lab/scripts/lab.sh flag db_not_responding false
otel-lab/scripts/lab.sh background resume
otel-lab/scripts/lab.sh status
otel-lab/scripts/lab.sh stop      # keep containers/DB state
otel-lab/scripts/lab.sh start
otel-lab/scripts/lab.sh down      # remove containers (DB is re-seeded on next up); images stay
```
