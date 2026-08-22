# Day 76 – OpenTelemetry and Alerting

Stack in `observability/` in this folder.

---

## Task 1: OpenTelemetry

**The problem it solves is vendor lock-in in the instrumentation itself.**

Days 73–75 built a Prometheus + Loki + Grafana stack. Instrumenting an application with a Prometheus client library means that code is tied to Prometheus. Moving to Datadog means re-instrumenting everything.

OpenTelemetry is a **vendor-neutral standard** — one set of SDKs and one wire protocol (OTLP), then a collector routes the data wherever you want. Switching backends becomes a config change in the collector rather than a code change in every service.

It is a CNCF project and now the second most active after Kubernetes itself, which is why it has effectively won.

**Three signals, one SDK:**

| Signal | Status |
|---|---|
| Traces | Stable — OTel's strongest area |
| Metrics | Stable |
| Logs | Stable, newest, still catching up in tooling |

**Where the collector sits:**

```
   app (OTel SDK)
        │  OTLP
        ▼
  ┌──────────────────────────────────┐
  │  OpenTelemetry Collector         │
  │  receivers → processors → exporters │
  └───┬──────────┬──────────┬────────┘
      ▼          ▼          ▼
  Prometheus   Tempo      Loki
```

**The collector is the useful part even without OTel SDKs.** It can receive in one format and emit in another, batch, filter, sample, and add attributes — so it becomes the single place to change where telemetry goes.

devboard runs two collector layers: an **agent** DaemonSet on every node collecting host metrics and pod logs, forwarding to a **gateway** deployment that does the heavier processing and exporting. That split matters at scale — the agent stays small, and only the gateway needs credentials for the backends.

---

## Task 2: The collector

**`observability/otel/otel-collector-config.yml`**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 400
    spike_limit_mib: 100

  batch:
    timeout: 10s
    send_batch_size: 1024

  resource:
    attributes:
      - key: deployment.environment
        value: local
        action: upsert

exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    resource_to_telemetry_conversion:
      enabled: true

  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlp/tempo, debug]

    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheus]
```

**The three-stage shape is the whole model:** receivers take data in, processors transform it, exporters send it out, and `service.pipelines` wires them together per signal. A component defined but not listed in a pipeline does nothing at all — which is a common first mistake, because the config looks complete.

**`memory_limiter` should be in every pipeline, first.** Without it a traffic spike makes the collector itself the thing that OOMs, and you lose telemetry precisely when you most need it. It sheds load rather than dying.

**`batch` should be last.** Processor order in the list is the order data flows, so batching after everything else means each batch is fully processed.

**The `prometheus` exporter is scraped, not pushed.** It opens `:8889` and waits — Day 73's pull model. The naming is confusing: a component listed under `exporters` that Prometheus pulls from.

**`debug` with `verbosity: detailed` prints everything to the collector's stdout.** Invaluable while wiring things up, far too noisy to leave enabled.

```
devops@testvm:~/day-76/observability$ docker compose up -d
devops@testvm:~$ curl -s http://localhost:13133 | jq
{ "status": "Server available", "upSince": "2026-08-14T09:14:22Z" }

devops@testvm:~$ curl -s http://localhost:8888/metrics | grep otelcol_process_uptime
otelcol_process_uptime_total 142.3
```

**Two ports, two different things.** `:8889` is the Prometheus exporter carrying application telemetry; `:8888` is the collector's own internal metrics. Both are scraped, and mixing them up means monitoring the collector while thinking you are monitoring the app.

---

## Task 3: Test traces

```
devops@testvm:~$ curl -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{
    "resourceSpans": [{
      "resource": { "attributes": [
        { "key": "service.name", "value": { "stringValue": "devboard-backend" } }
      ]},
      "scopeSpans": [{
        "spans": [{
          "traceId": "5b8aa5a2d2c872e8321cf37308d69df2",
          "spanId": "051581bf3cb55c13",
          "name": "GET /api/tasks",
          "kind": 2,
          "startTimeUnixNano": "1754990400000000000",
          "endTimeUnixNano": "1754990400120000000",
          "attributes": [
            { "key": "http.method", "value": { "stringValue": "GET" } },
            { "key": "http.status_code", "value": { "intValue": 200 } }
          ]
        }]
      }]
    }]
  }'
{"partialSuccess":{}}
```

`{"partialSuccess":{}}` with nothing in it means everything was accepted.

**The HTTP endpoint on 4318 is what makes this testable with curl.** Most SDKs use gRPC on 4317, which is faster and not something you can hand-craft.

```
devops@testvm:~$ docker logs otel-collector --tail 25 | grep -A6 "Span #0"
Span #0
    Trace ID       : 5b8aa5a2d2c872e8321cf37308d69df2
    Parent ID      :
    ID             : 051581bf3cb55c13
    Name           : GET /api/tasks
    Kind           : Server
    Start time     : 2026-08-14 09:20:00 +0000 UTC
    End time       : 2026-08-14 09:20:00.12 +0000 UTC
    Status code    : Unset
```

**Reading a span:**

- **Trace ID** — one request, end to end. Every span in that request shares it.
- **Span ID** — one operation.
- **Parent ID** — empty here, so this is the root span. Child spans reference their parent, and that is what builds the waterfall.
- **Kind: Server** — this service received the request. `Client` means it made an outbound call. The pairing is how a service graph is derived.

**Tempo turns traces into metrics**, which is the part that surprised me:

```yaml
metrics_generator:
  storage:
    remote_write:
      - url: http://prometheus:9090/api/v1/write
overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics]
```

Tempo watches spans and generates RED metrics — rate, errors, duration per service — pushing them into Prometheus via `remote_write`. So instrumenting for traces gives you a latency and error-rate dashboard **for free**, with no separate metrics instrumentation.

That is why Prometheus needs `--web.enable-remote-write-receiver` in the Day 77 compose file.

devboard's alert rules use exactly these generated metrics:

```promql
sum(rate(traces_span_metrics_calls_total{service_name="ai-service",status_code="STATUS_CODE_ERROR"}[5m]))
  / sum(rate(traces_span_metrics_calls_total{service_name="ai-service"}[5m])) > 0.1
```

---

## Task 4: Prometheus alerting rules

**`observability/prometheus/rules/devboard-alerts.yml`**

```yaml
groups:
  - name: host
    rules:
      - alert: HostHighCPU
        expr: 100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "CPU above 85% for 10 minutes on {{ $labels.instance }}"
          description: "Currently {{ $value | printf \"%.1f\" }}%"
          runbook: "ssh in and run: top -o %CPU, then ps aux --sort=-%cpu | head"
```

**`for: 10m` is the field that decides whether an alert is useful or noise.** Without it a single scrape above the threshold pages someone. With it, the condition must hold continuously for ten minutes — the alert sits in `Pending` until then.

**Every alert has a `runbook` annotation.** This is copied straight from devboard's `prometheusrule-devboard.yaml`, and it is the best habit in that file. An alert firing at 3 a.m. that says "CPU is high" leaves the responder to work out what to do. One that says "run `top -o %CPU`, then `ps aux --sort=-%cpu`" is actionable by someone who did not write it.

devboard goes further and explains the *cause* in the description:

> A PersistentVolumeClaim stuck Pending almost always means no StorageClass. EKS does not mark gp2 default, so a PVC that names no class waits forever.

That is Day 66's EKS trap, encoded into the alert that detects it. The knowledge lives where it is needed instead of in someone's head.

### The three alerts worth explaining

**Predicting rather than reporting:**

```yaml
      - alert: HostDiskFillingUp
        expr: |
          predict_linear(node_filesystem_avail_bytes{mountpoint="/rootfs"}[6h], 4 * 3600) < 0
        for: 15m
```

`predict_linear` extrapolates the last 6 hours forward 4 hours. **It fires when the disk *will* be full, not when it already is** — four hours of warning instead of an outage. This is the saturation signal from Day 73, and it is the single most useful alert in the file.

**Catching OOM before it happens:**

```yaml
      - alert: ContainerMemoryNearLimit
        expr: |
          container_memory_working_set_bytes{name!=""}
            / container_spec_memory_limit_bytes{name!=""} > 0.9
        annotations:
          description: "It will be OOMKilled with exit 137 if it keeps climbing"
```

Day 57's exit code 137, as a warning rather than a postmortem.

**The alert about the alerting:**

```yaml
      - alert: TargetDown
        expr: up == 0
        for: 5m
        annotations:
          description: "Every other alert for this target is now blind"
```

**The most important rule in the file.** If Prometheus stops scraping a target, every other alert on it goes quiet — which looks exactly like health. Without this, a dead exporter is indistinguishable from a healthy system.

The gap it does not cover is Day 73's `absent()` case: if the target is removed from config entirely, there is no `up` series to be zero.

```
devops@testvm:~$ curl -s http://localhost:9090/api/v1/rules | jq -r '.data.groups[] | "\(.name): \(.rules | length) rules"'
host: 3 rules
containers: 2 rules
monitoring: 1 rules

devops@testvm:~$ curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname)  \(.state)"'
HostDiskFillingUp  pending
```

**`pending`, not `firing`** — the condition is true but `for: 15m` has not elapsed. That state is worth knowing; it is not a bug.

### Alertmanager

**`observability/alertmanager/alertmanager.yml`**

```yaml
route:
  group_by: ["alertname", "severity"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: default

  routes:
    - matchers:
        - severity = "critical"
      receiver: critical
      repeat_interval: 1h

inhibit_rules:
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ["alertname", "instance"]
```

**Prometheus decides *when*; Alertmanager decides *who and how often*.** That split is the design.

**Grouping** collapses 40 firing instances of one alert into a single notification. Without it a node failure produces one message per affected series.

**`inhibit_rules`** suppress a warning when a critical is already firing for the same thing. This is what stops one incident becoming a wall of messages — the most valuable feature and the one most often left unconfigured.

**`repeat_interval: 4h`** so an unresolved alert re-notifies occasionally rather than every evaluation cycle.

---

## Task 5: Grafana alerts

Grafana 9+ has unified alerting, and it overlaps with Prometheus rules.

**Where each fits:**

| | Prometheus rules | Grafana alerts |
|---|---|---|
| Defined as | YAML, in git | UI, or provisioned YAML |
| Data sources | Prometheus only | Any — including **Loki** |
| Runs when | Prometheus is up | Grafana is up |
| Best for | Infrastructure alerts as code | Alerts spanning datasources |

**The case for Grafana alerting is alerting on logs**, which Prometheus cannot do:

```logql
sum(rate({container=~".+"} |~ "(?i)(error|fatal|panic)" [5m])) > 0.1
```

Day 75's log-derived metric, as an alert. No application counter needed.

**I would keep infrastructure alerts in Prometheus rules** — they are files in git, reviewed like code, and they do not depend on Grafana being up. Grafana alerting for anything that needs Loki or spans two datasources.

Grafana alerts should also be **provisioned as files**, not clicked. Day 74's argument applies identically — a UI-built alert dies with the volume.

---

## Task 6: The full architecture

```
   APPLICATIONS                COLLECTION              STORAGE           QUERY
                                                                              
   app + OTel SDK ──OTLP──▶ otel-collector ──┬──▶  Tempo    ─┐
                              :4317 :4318    │     (traces)  │
                                             │               │
                                             ├──▶  Prometheus├──▶ Grafana
                                             │     (metrics) │      :3000
   host ─────────────────▶ node-exporter ────┤               │
                              :9100          │               │
                                             │               │
   containers ───────────▶ cAdvisor ─────────┘               │
                              :8080                          │
                                                             │
   container stdout ─────▶ Promtail ────────▶  Loki  ────────┘
                                               (logs)
                                                  
                          Prometheus rules ──▶ Alertmanager ──▶ notifications
                                                 :9093
```

**Tempo also pushes back into Prometheus** via `remote_write`, carrying the span-derived RED metrics. That is the one arrow that is not obvious from the diagram and it is why the collector layer earns its place.

**Ports:**

| Port | Service |
|---|---|
| 3000 | Grafana |
| 9090 | Prometheus |
| 9093 | Alertmanager |
| 3100 | Loki |
| 3200 | Tempo |
| 4317 / 4318 | OTLP gRPC / HTTP |
| 8889 / 8888 | Collector exporter / internal metrics |
| 9100 | Node Exporter |
| 8081 | cAdvisor |

---

## Files in this folder

| Path | What it is |
|---|---|
| `observability/otel/otel-collector-config.yml` | Receivers, processors, exporters, three pipelines |
| `observability/tempo/tempo-config.yml` | Trace storage plus the metrics generator |
| `observability/prometheus/rules/devboard-alerts.yml` | Six alerts, each with a runbook |
| `observability/alertmanager/alertmanager.yml` | Grouping, routing, inhibition |
| `observability/grafana/provisioning/datasources/datasources.yml` | All three, with cross-links |

---

## What I learned

**1. Tempo generates metrics from traces, so instrumenting once gives you two signals.** `span-metrics` produces per-service rate, error and duration series and pushes them into Prometheus. A latency dashboard with no metrics instrumentation at all — which reframes tracing as the highest-leverage thing to instrument first.

**2. `for:` is what separates an alert from noise, and `runbook` is what makes it actionable.** A threshold with no `for:` pages on a single scrape spike. An alert with no runbook makes the responder work out what to do at 3 a.m. devboard's rules encode the *cause* in the description — the EKS default-storage-class trap sits in the alert that detects it.

**3. `TargetDown` is the alert that protects every other alert.** A dead exporter makes all its alerts go silent, which looks identical to health. Without an explicit `up == 0` rule, the monitoring failing is invisible.

**Two extras:**

- `memory_limiter` first and `batch` last in every collector pipeline. Without the limiter, a spike makes the collector the thing that dies, losing telemetry exactly when it matters.
- `predict_linear` on disk space warns four hours ahead instead of reporting a full disk. Saturation over utilisation, from Day 73's golden signals.
