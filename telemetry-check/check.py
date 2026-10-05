#!/usr/bin/env python3
"""Drive easytrade through the reverse proxy and verify what the collector received.

  check.py drive  --proxy http://localhost:8080 [--rounds 5]
  check.py verify --out ./out --tag dev [--environment telemetry-check]

verify reads the collector's JSON-lines files (traces.jsonl, metrics.jsonl, logs.jsonl)
and checks, per instrumented component: resource identity, span kinds, trace context
across the expected hops, logs (with trace context where requests are served) and
metrics. It prints one line per check and exits 1 if any check fails.
Standard library only.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

SERVER, CLIENT, PRODUCER = 2, 3, 4
KIND_NAMES = {1: "INTERNAL", 2: "SERVER", 3: "CLIENT", 4: "PRODUCER", 5: "CONSUMER"}

# component: (span kinds expected, request logs expected to carry trace context, sends logs, sends metrics)
COMPONENTS = {
    "frontendreverseproxy": ({SERVER}, None, False, False),  # ngx_otel_module: server spans only
    "accountservice": ({SERVER, CLIENT}, True, True, True),
    "broker-service": ({SERVER, CLIENT}, True, True, True),
    "contentcreator": ({CLIENT}, False, True, True),  # background writer: no inbound requests
    "credit-card-order-service": ({SERVER, CLIENT}, True, True, True),
    "engine": ({SERVER, CLIENT}, True, True, True),
    "feature-flag-service": ({SERVER}, True, True, True),  # makes no outbound calls
    "third-party-service": ({SERVER, CLIENT}, True, True, True),
    "loginservice": ({SERVER, CLIENT}, True, True, True),
    "manager": ({SERVER, CLIENT}, True, True, True),
    "offerservice": ({SERVER, CLIENT}, True, True, True),
    "pricing-service": ({SERVER, CLIENT, PRODUCER}, True, True, True),
    "aggregator-service": ({CLIENT}, False, True, True),  # background job: no inbound requests
}

# (caller, callee): a SERVER span in callee whose parent span belongs to caller.
HOPS = [
    ("frontendreverseproxy", "loginservice"),
    ("frontendreverseproxy", "accountservice"),
    ("frontendreverseproxy", "broker-service"),
    ("frontendreverseproxy", "pricing-service"),
    ("frontendreverseproxy", "offerservice"),
    ("frontendreverseproxy", "credit-card-order-service"),
    ("frontendreverseproxy", "feature-flag-service"),
    ("frontendreverseproxy", "manager"),
    ("frontendreverseproxy", "engine"),
    ("frontendreverseproxy", "third-party-service"),
    # broker-service -> accountservice is not listed: broker-service registers an account
    # service client but no code path calls it.
    ("broker-service", "pricing-service"),  # .NET -> Go
    ("broker-service", "feature-flag-service"),  # .NET -> Java
    ("accountservice", "manager"),  # Java -> .NET
    ("engine", "broker-service"),  # Java -> .NET
    ("aggregator-service", "offerservice"),  # Go -> Node.js
    ("offerservice", "loginservice"),
    ("offerservice", "manager"),
    ("offerservice", "feature-flag-service"),
    ("credit-card-order-service", "third-party-service"),
    ("third-party-service", "credit-card-order-service"),
]


# ---------------------------------------------------------------- drive


def request(proxy, method, path, body=None, accept="application/json"):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(proxy + path, data=data, method=method)
    req.add_header("Accept", accept)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        return 0, str(e).encode()


def wait_ready(proxy, timeout):
    paths = [
        "/loginservice/api/version",
        "/accountservice/api/version",
        "/broker-service/version",
        "/pricing-service/version",
        "/offerservice/api/version",
        "/manager/api/version",
        "/engine/api/version",
        "/credit-card-order-service/version",
        "/third-party-service/version",
        "/feature-flag-service/version",
    ]
    deadline = time.time() + timeout
    pending = list(paths)
    while pending and time.time() < deadline:
        pending = [p for p in pending if request(proxy, "GET", p)[0] != 200]
        if pending:
            time.sleep(5)
    if pending:
        print("not ready:", ", ".join(pending))
        return False
    return True


def drive(args):
    proxy = args.proxy.rstrip("/")
    if not wait_ready(proxy, args.ready_timeout):
        return 1
    statuses = defaultdict(lambda: defaultdict(int))

    def call(method, path, body=None, label=None):
        status, payload = request(proxy, method, path, body)
        statuses[label or path][status] += 1
        return status, payload

    for _ in range(args.rounds):
        status, payload = call("POST", "/loginservice/api/Login", {"username": "demouser", "password": "demopass"})
        account_id = json.loads(payload).get("id", 1) if status == 200 else 1
        call("GET", f"/accountservice/api/accounts/{account_id}", label="/accountservice/api/accounts/{id}")
        call("GET", f"/broker-service/v1/balance/{account_id}", label="/broker-service/v1/balance/{id}")
        call("GET", "/pricing-service/v1/prices/latest")
        call("GET", "/pricing-service/v1/prices/instrument/1?records=10")
        call("POST", f"/broker-service/v1/balance/{account_id}/deposit", {
            "accountId": account_id,
            "amount": 1000,
            "name": "Demo User",
            "address": "1 Example Street",
            "email": "demo.user@example.com",
            "cardNumber": "2293562484488276",
            "cardType": "mastercard",
            "cvv": "123",
        }, label="/broker-service/v1/balance/{id}/deposit")
        call("POST", "/broker-service/v1/trade/buy", {"accountId": account_id, "instrumentId": 1, "amount": 1})
        call("POST", "/broker-service/v1/trade/sell", {"accountId": account_id, "instrumentId": 1, "amount": 1})
        call("GET", f"/broker-service/v1/trade/{account_id}?count=5&onlyLong=true", label="/broker-service/v1/trade/{id}")
        call("POST", "/credit-card-order-service/v1/orders", {
            "accountId": account_id,
            "email": "demo.user@example.com",
            "name": "Demo User",
            "shippingAddress": "1 Example Street",
            "cardLevel": "Platinum",
        })
        call("GET", f"/credit-card-order-service/v1/orders/{account_id}/status", label="/credit-card-order-service/v1/orders/{id}/status")
        call("GET", "/feature-flag-service/v1/flags?tag=config")
        user = f"checkuser{int(time.time() * 1000)}"
        call("POST", "/offerservice/api/signup", {
            "PackageId": 1,
            "FirstName": "Check",
            "LastName": "User",
            "Username": user,
            "Email": f"{user}@example.com",
            "Address": "1 Example Street",
            "HashedPassword": "0" * 64,
            "Origin": "ergo",
        })
        call("GET", "/offerservice/api/offers/ergo?productFilter=%5B%22Shares%22%5D&maxYearlyFeeFilter=1000")
        for path in ["/manager/api/version", "/engine/api/version", "/third-party-service/version"]:
            call("GET", path)
        time.sleep(args.pause)

    print("requests through the reverse proxy (path: status x count):")
    for path, counts in statuses.items():
        print(f"  {path}: " + ", ".join(f"{s} x{n}" for s, n in sorted(counts.items())))
    return 0


# ---------------------------------------------------------------- verify


def attrs(items):
    out = {}
    for a in items or []:
        v = a.get("value", {})
        out[a["key"]] = next(iter(v.values()), None) if v else None
    return out


def read_lines(path):
    if not path.exists():
        return []
    with path.open() as f:
        return [json.loads(line) for line in f if line.strip()]


def load(out):
    spans, logs, metrics, resources = [], [], [], defaultdict(list)
    for batch in read_lines(out / "traces.jsonl"):
        for rs in batch.get("resourceSpans", []):
            res = attrs(rs.get("resource", {}).get("attributes"))
            resources[res.get("service.name")].append(res)
            for ss in rs.get("scopeSpans", []):
                for s in ss.get("spans", []):
                    spans.append((res, s))
    for batch in read_lines(out / "logs.jsonl"):
        for rl in batch.get("resourceLogs", []):
            res = attrs(rl.get("resource", {}).get("attributes"))
            resources[res.get("service.name")].append(res)
            for sl in rl.get("scopeLogs", []):
                for r in sl.get("logRecords", []):
                    logs.append((res, r))
    for batch in read_lines(out / "metrics.jsonl"):
        for rm in batch.get("resourceMetrics", []):
            res = attrs(rm.get("resource", {}).get("attributes"))
            resources[res.get("service.name")].append(res)
            for sm in rm.get("scopeMetrics", []):
                for m in sm.get("metrics", []):
                    metrics.append((res, m))
    return spans, logs, metrics, resources


def verify(args):
    out = Path(args.out)
    spans, logs, metrics, resources = load(out)
    expected_identity = {
        "service.namespace": "easytrade",
        "service.version": args.tag,
        "deployment.environment.name": args.environment,
    }
    owner = {}
    for res, s in spans:
        owner[(s["traceId"], s["spanId"])] = (res.get("service.name"), s.get("kind"))

    results = []

    def record(component, check, ok, detail=""):
        status = {True: "PASS", False: "FAIL", None: "N/A"}[ok]
        results.append((component, check, status, detail))

    for component, (kinds, trace_logs, sends_logs, sends_metrics) in COMPONENTS.items():
        res_list = resources.get(component, [])
        if not res_list:
            record(component, "telemetry received", False, "nothing with this service.name")
            continue
        bad = sorted({
            f"{k}={r.get(k)!r}" for r in res_list for k, v in expected_identity.items() if r.get(k) != v
        })
        record(component, "resource identity", not bad, "; ".join(bad[:4]) or
               ", ".join(f"{k}={v}" for k, v in expected_identity.items()))

        own = [s for r, s in spans if r.get("service.name") == component]
        seen = defaultdict(int)
        for s in own:
            seen[s.get("kind")] += 1
        for kind in sorted(kinds):
            record(component, f"{KIND_NAMES[kind]} spans", seen[kind] > 0, f"{seen[kind]} spans")

        if sends_logs:
            own_logs = [r for res, r in logs if res.get("service.name") == component]
            record(component, "logs over OTLP", bool(own_logs), f"{len(own_logs)} records")
            with_ctx = [r for r in own_logs if r.get("traceId")]
            if trace_logs:
                record(component, "request logs carry trace context", bool(with_ctx),
                       f"{len(with_ctx)} of {len(own_logs)} records with traceId")
            else:
                record(component, "request logs carry trace context", None,
                       f"no request logs expected (background work); {len(with_ctx)} of {len(own_logs)} with traceId")
        else:
            record(component, "logs over OTLP", None, "the agent exports traces only")

        if sends_metrics:
            names = sorted({m["name"] for res, m in metrics if res.get("service.name") == component})
            record(component, "metrics over OTLP", bool(names),
                   f"{len(names)} metrics, e.g. {', '.join(names[:3])}" if names else "none")
        else:
            record(component, "metrics over OTLP", None, "the agent exports traces only")

    for caller, callee in HOPS:
        count = 0
        for res, s in spans:
            if res.get("service.name") != callee or s.get("kind") != SERVER or not s.get("parentSpanId"):
                continue
            parent = owner.get((s["traceId"], s["parentSpanId"]))
            if parent and parent[0] == caller:
                count += 1
        record(f"{caller} -> {callee}", "trace context propagated", count > 0, f"{count} server spans with a parent in {caller}")

    # pricing-service: the PRODUCER span is a child of its own request trace.
    producers = [s for r, s in spans if r.get("service.name") == "pricing-service" and s.get("kind") == PRODUCER]
    joined = [s for s in producers if owner.get((s["traceId"], s.get("parentSpanId", "")), (None,))[0] == "pricing-service"]
    record("pricing-service", "RabbitMQ PRODUCER span in the request trace", bool(joined) if producers else False,
           f"{len(joined)} of {len(producers)}")

    width = max(len(c) for c, *_ in results)
    for component, check, status, detail in results:
        print(f"{status:4}  {component:{width}}  {check}: {detail}")
    failed = [r for r in results if r[2] == "FAIL"]
    print(f"\n{len(results)} checks, {len(failed)} failed, {sum(r[2] == 'N/A' for r in results)} not applicable")
    if args.json:
        Path(args.json).write_text(json.dumps(
            [dict(zip(("component", "check", "status", "detail"), r)) for r in results], indent=2))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("drive")
    d.add_argument("--proxy", default="http://localhost:8080")
    d.add_argument("--rounds", type=int, default=5)
    d.add_argument("--pause", type=float, default=2.0)
    d.add_argument("--ready-timeout", type=int, default=600)
    v = sub.add_parser("verify")
    v.add_argument("--out", default=str(Path(__file__).parent / "out"))
    v.add_argument("--tag", default="dev")
    v.add_argument("--environment", default="telemetry-check")
    v.add_argument("--json", help="also write the results to this file")
    args = parser.parse_args()
    return drive(args) if args.command == "drive" else verify(args)


if __name__ == "__main__":
    sys.exit(main())
