# Instrumentation coverage matrix

Lab namespace: `service.namespace = deployment.environment.name = easytrade-otel-lab`. Every instrumented service
exports directly to `https://<env>.live.dynatrace.com/api/v2/otlp` (OTLP/HTTP protobuf, `Authorization: Bearer`
platform token), traces + logs, sampler `always_on`, metrics disabled. The actual service key in Dynatrace is the
pair (`service.namespace`, `service.name`); Dynatrace additionally derives one `dt.entity.service`
(= `dt.smartscape.service`) per service name, which is present on both spans and logs of that service.
"Verified" means observed in stored records via `dtctl` DQL during the runs referenced in `evidence/`;
"expected" means configured but not separately exercised.

| Compose service | Runtime / framework | Official zero-code package (pinned) | Tracing | Logging | Export route | Stored `service.name` | Evidence | Gap / note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| credit-card-order-service | Java 21, Spring Boot 4.0.7 (Tomcat 11) | opentelemetry-javaagent 2.31.1 | **Verified**: SERVER spans (`io.opentelemetry.tomcat-10.0`, `http.route`), JDBC + `java.net.http` CLIENT spans | **Verified**: SLF4J/Logback via agent logback-appender, ERROR records with exception, trace context on request-scoped logs | direct OTLP | `credit-card-order-service` | smoke `card-*` DQL | scheduler (`WorkScheduler`) traffic is background noise on other routes |
| broker-service | .NET 8 (ASP.NET Core) on Alpine musl | opentelemetry-dotnet-instrumentation 1.16.0 (linux-musl-x64) | **Verified**: SERVER (`Microsoft.AspNetCore`), HttpClient + SqlClient/EF Core CLIENT spans | **Verified after source change**: ILogger bridge; `ClearProviders()` replaced (see NOTES 4.2) | direct OTLP | `broker-service` | smoke `broker-*` DQL | flag cache lowered to 5 s (`FEATURE_FLAG_CACHE_DURATION_S`) |
| accountservice | Java 21, Spring Boot 4.0.7 | opentelemetry-javaagent 2.31.1 | **Verified**: SERVER + CLIENT (`java.net.http` to manager), W3C context propagated to manager | **Verified**: Logback via agent | direct OTLP | `accountservice` | smoke `baseline-trace` DQL | - |
| manager | .NET 8 on Alpine | opentelemetry-dotnet-instrumentation 1.16.0 | **Verified**: SERVER spans with `span.parent_id` = accountservice CLIENT span | **Verified after source change** (`Startup.cs` `ClearProviders()`) | direct OTLP | `manager` | smoke `baseline-trace` DQL | - |
| loginservice | .NET 8 on Alpine | opentelemetry-dotnet-instrumentation 1.16.0 | **Verified**: SERVER + SqlClient | **Verified after source change** (`Startup.cs`) | direct OTLP | `loginservice` | inventory DQL | - |
| engine | Java 21, Spring Boot 4.0.7 | opentelemetry-javaagent 2.31.1 | **Verified**: CLIENT spans to broker (`POST /v1/trade/long/process`, parent of broker SERVER span), SERVER spans | **Verified**: Logback via agent | direct OTLP | `engine` | inventory DQL | 1-minute scheduler is paused by the suite via `/engine/api/trade/scheduler/stop` |
| feature-flag-service | Java 21, Spring Boot 4.0.7 | opentelemetry-javaagent 2.31.1 | **Verified**: SERVER spans (called by every flag evaluation) | **Verified** | direct OTLP | `feature-flag-service` | inventory DQL | high span volume from flag polling (expected) |
| third-party-service | Java 21, Spring Boot 4.0.7 | opentelemetry-javaagent 2.31.1 | **Verified**: SERVER/CLIENT (scheduler-driven) | **Verified** | direct OTLP | `third-party-service` | inventory DQL | traffic only from schedulers |
| contentcreator | Java 21 (plain JVM, JDBC, no HTTP server) | opentelemetry-javaagent 2.31.1 | **Verified**: JDBC CLIENT spans only (no server spans by design) | **Verified**: Logback via agent | direct OTLP | `contentcreator` | inventory DQL | root spans are JDBC calls, no request context |
| offerservice | Node.js 24, Express 5, winston 3 | @opentelemetry/auto-instrumentations-node 0.80.0 (+ api 1.9.0, winston-transport 0.32.0) | **Verified**: SERVER (`@opentelemetry/instrumentation-http`, Express route) + CLIENT to manager/loginservice | **Verified**: winston -> `@opentelemetry/winston-transport` log bridge, trace context on request logs | direct OTLP | `offerservice` | inventory DQL | preload via `NODE_PATH` + `--require` (NOTES 4.1) |
| pricing-service | Go 1.27, Gin, GORM (SQL Server) | none applied | **Not instrumented** (broker CLIENT spans to it exist; no SERVER spans) | not exported | - | (none) | broker CLIENT spans | Official Go zero-code instrumentation is eBPF based and requires a privileged sidecar with host PID access; not applied in this milestone (explicit gap, see NOTES) |
| aggregator-service | Go 1.27, plain net/http client + zap | none applied | **Not instrumented** (its calls appear as root SERVER spans on offerservice) | not exported | - | (none) | offerservice SERVER spans with `user_agent.original: Go-http-client` | same as pricing-service; it is a synthetic traffic source and is paused during measured runs |
| calculationservice | C++ (AMQP consumer) linked with Dynatrace OneAgent SDK for C 1.7.1 | none available | **Not instrumented** | not exported | - | (none) | - | No official OTel zero-code instrumentation for C++; the OneAgent SDK is inert without OneAgent (documented proprietary integration, left as-is) |
| frontendreverseproxy | nginx 1.29 | none applied | **Not instrumented** (infrastructure) | container stdout only | - | (none) | - | The upstream config references OneAgent `$dt_*` variables but declares them, so it runs without OneAgent. `ngx_otel_module` (official nginx OTel module) could add proxy spans; not done |
| frontend | React/Vite static bundle served by nginx | none | **Not instrumented** (browser app / static files) | - | - | (none) | - | Browser RUM is out of scope |
| db | MSSQL 2022 (Express) | none | infrastructure | - | - | - | - | appears as `db.*` attributes on JDBC/SqlClient CLIENT spans |
| rabbitmq | RabbitMQ 3.13 | none | infrastructure | - | - | - | - | - |
| loadgen | Node.js + Puppeteer (headless Chrome) | none (intentional) | **Not instrumented** - load driver, Compose profile `load`, off by default | - | - | (none) | - | its traffic shows up as server spans on the services it hits |
| problem-operator | Go, Kubernetes operator | n/a | not deployed (Kubernetes-only, not in Compose) | - | - | - | - | out of scope |

Reference evidence: `evidence/run-20260919T082103Z-0944`, `run-20260919T082305Z-3783`, `run-20260919T082542Z-0897` (all cases PASS).

Summary: 10 of 18 deployed Compose services are instrumented with official zero-code packages (6 Java, 3 .NET,
1 Node) for traces and logs; 2 Go services are an explicit gap; 1 C++ service has no official option; 4 are
infrastructure/static; loadgen is intentionally uninstrumented. The milestone services
(credit-card-order-service, broker-service, accountservice) are fully covered.
