# Day 77 – Observability Project: Full Stack with Docker Compose

The complete stack is in `observability/` in this folder — everything from Days 73–76 in one Compose file, with a `Makefile` and a validation script.

```
observability/
├── docker-compose.yml       nine services
├── Makefile                 up / down / validate / clean
├── validate.sh              proves all three pipelines flow
├── .env.example
├── prometheus/              config + alert rules
├── loki/  promtail/         logs
├── tempo/  otel/            traces
├── alertmanager/            routing
└── grafana/
    ├── provisioning/        datasources + dashboard provider
    └── dashboards/          host-overview, production-overview
```

---

## Task 1: Launching

```
devops@testvm:~/day-77/observability$ make up
docker compose up -d
[+] Running 15/15
 ✔ Network observability_default   Created
 ✔ Volume "prometheus_data"        Created
 ✔ Volume "loki_data"              Created
 ✔ Volume "tempo_data"             Created
 ✔ Volume "grafana_data"           Created
 ✔ Container tempo                 Started
 ✔ Container loki                  Started
 ✔ Container prometheus            Started
 ✔ Container node-exporter         Started
 ✔ Container cadvisor              Started
 ✔ Container alertmanager          Started
 ✔ Container promtail              Started
 ✔ Container otel-collector        Started
 ✔ Container grafana               Started

grafana      http://localhost:3000
prometheus   http://localhost:9090
alertmanager http://localhost:9093
```

Nine services. `make up` also copies `.env.example` to `.env` if it is missing, so the stack starts with one command — the same idea as devboard's own `Makefile`.

```
devops@testvm:~/day-77/observability$ make ps
NAME             STATUS          PORTS
alertmanager     Up 2 minutes    0.0.0.0:9093->9093/tcp
cadvisor         Up 2 minutes    0.0.0.0:8081->8080/tcp
grafana          Up 2 minutes    0.0.0.0:3000->3000/tcp
loki             Up 2 minutes    0.0.0.0:3100->3100/tcp
node-exporter    Up 2 minutes
otel-collector   Up 2 minutes    0.0.0.0:4317-4318->4317-4318/tcp, 0.0.0.0:8889->8889/tcp
prometheus       Up 2 minutes    0.0.0.0:9090->9090/tcp
promtail         Up 2 minutes
tempo            Up 2 minutes    0.0.0.0:3200->3200/tcp
```

`node-exporter` shows no ports because of `network_mode: host` (Day 74). `promtail` has none because it only pushes outbound.

**Resource cost**, which is worth knowing before putting this on a small box:

```
devops@testvm:~$ docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
NAME             CPU %     MEM USAGE
prometheus       1.84%     184.2MiB
grafana          0.91%     142.7MiB
loki             1.12%     98.4MiB
tempo            0.63%     87.1MiB
otel-collector   0.44%     52.3MiB
cadvisor         2.31%     71.8MiB
promtail         0.38%     41.2MiB
alertmanager     0.09%     24.6MiB
node-exporter    0.11%     14.3MiB
```

**About 720 MB and 8% of two cores at idle.** cAdvisor is the most expensive per unit of value — it walks every container's cgroups on a timer. On a `t3.micro` this stack alone would be most of the machine.

---

## Task 2–4: Validating the pipelines

`make validate` runs `validate.sh`, which checks that data is **flowing** rather than that containers are running.

```
devops@testvm:~/day-77/observability$ make validate
--- containers ---
prometheus running                           OK
grafana running                              OK
loki running                                 OK
promtail running                             OK
tempo running                                OK
otel-collector running                       OK
alertmanager running                         OK
cadvisor running                             OK

--- endpoints ---
prometheus ready                             OK
grafana healthy                              OK
loki ready                                   OK
tempo ready                                  OK
alertmanager healthy                         OK
otel collector healthy                       OK

--- metrics pipeline ---
all prometheus targets up                    OK
node metrics present                         OK
container metrics present                    OK

--- logs pipeline ---
loki has labels                              OK
loki has container logs                      OK

--- rules ---
alert rules loaded                           OK

passed: 21   failed: 0
```

**The distinction the script is built around** is Day 57's liveness-versus-readiness point applied to a whole stack: a container being `Up` proves the process started, not that telemetry is arriving. Every check here queries for actual data.

### Metrics

```
devops@testvm:~$ curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | "\(.labels.job)  \(.health)  \(.lastScrapeDuration | tostring[0:6])s"'
cadvisor                  up  0.0821s
node-exporter             up  0.0134s
otel-collector            up  0.0021s
otel-collector-internal   up  0.0019s
prometheus                up  0.0024s
```

Five targets, all up. cAdvisor's scrape takes 80ms — 40× the others, again because it walks every cgroup.

### Logs

```
devops@testvm:~$ curl -s http://localhost:3100/loki/api/v1/label/container/values | jq -r '.data[]'
alertmanager
cadvisor
grafana
loki
otel-collector
prometheus
promtail
tempo
```

Eight containers discovered. `node-exporter` is missing, and that is expected — `network_mode: host` puts it outside the Compose network, and Promtail's Docker service discovery still sees it but it produces almost no output at idle.

### Traces

```
devops@testvm:~$ curl -X POST http://localhost:4318/v1/traces -H "Content-Type: application/json" -d @trace.json
{"partialSuccess":{}}

devops@testvm:~$ curl -s "http://localhost:3200/api/traces/5b8aa5a2d2c872e8321cf37308d69df2" \
  | jq -r '.batches[].scopeSpans[].spans[] | "\(.name)  \(.spanId)"'
GET /api/tasks  051581bf3cb55c13
```

Sent through the collector, stored in Tempo, retrievable by trace ID.

**The span-derived metrics arriving in Prometheus** are the check worth doing, because they prove the whole loop:

```
devops@testvm:~$ curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=traces_spanmetrics_calls_total' | jq -r '.data.result[] | .metric.service_name'
devboard-backend
```

Tempo generated that from the trace and pushed it into Prometheus via `remote_write` (Day 76). One `curl` of a trace produced a metric series with no metrics instrumentation anywhere.

---

## Task 5: The unified dashboard

**`grafana/dashboards/production-overview.json`** — one dashboard reading from all three datasources.

```
┌─ HEALTH ─────────────────────────────────────────────────────┐
│ Targets up │ Targets down │ CPU % │ Memory % │ Error log rate │
└──────────────────────────────────────────────────────────────┘
┌─ METRICS ────────────────────────────────────────────────────┐
│ Container CPU              │ Container memory                 │
└──────────────────────────────────────────────────────────────┘
┌─ LOGS ───────────────────────────────────────────────────────┐
│ Log volume by container    │ Recent errors (live log panel)   │
└──────────────────────────────────────────────────────────────┘
┌─ TRACES ─────────────────────────────────────────────────────┐
│ Request rate by service    │ p95 latency by service           │
└──────────────────────────────────────────────────────────────┘
```

Three deliberate choices:

**The health row is the golden signals from Day 73**, at the top, readable in two seconds. Everything below is for after you know something is wrong.

**A `$container` template variable** drives the metric and log panels together:

```json
"templating": {
  "list": [{
    "name": "container",
    "type": "query",
    "query": "label_values(container_memory_working_set_bytes{name!=\"\"}, name)",
    "includeAll": true,
    "multi": true
  }]
}
```

Selecting one container filters the Prometheus panels **and** the Loki panels, because Day 75's shared label scheme means `name` in cAdvisor and `container` in Promtail refer to the same thing. Without agreed labels the variable could only drive one of them.

**The trace panels come from Tempo's generated metrics**, not from Tempo directly — so they are ordinary Prometheus time series and can sit alongside everything else:

```promql
sum by (service_name) (rate(traces_spanmetrics_calls_total[5m]))
histogram_quantile(0.95, sum by (le, service_name) (rate(traces_spanmetrics_latency_bucket[5m])))
```

```
devops@testvm:~$ curl -s -u admin:admin 'http://localhost:3000/api/search' | jq -r '.[] | "\(.title)  (\(.uid))"'
Host Overview        (devboard-host)
Production Overview  (devboard-prod-overview)
```

Both provisioned on first boot, nothing clicked.

### The workflow this enables

Which is the actual point of the day:

1. **Error log rate goes red** on the health row.
2. **Select the spike** on the log-volume panel — the metric panels follow the same time range.
3. **Read the error** in the live log panel below it.
4. **Click the trace ID** in the log line — Day 75's `derivedFields` — and land in Tempo on that exact request.
5. **See which span was slow** in the waterfall.

Metric → log → trace, in four clicks, without leaving Grafana. Before this that meant `docker stats`, then `docker logs`, then correlating timestamps across two terminals by hand.

---

## Task 6: Comparison with the reference

The reference stack for this block is the Docker Compose one. devboard's `mega-project` branch runs the same signals on Kubernetes, and the differences are instructive.

| | This stack (Compose) | devboard (Kubernetes) |
|---|---|---|
| Deployment | `docker compose up` | Helm charts via ArgoCD |
| Metrics collection | Static scrape config | `ServiceMonitor` CRDs, discovered by the operator |
| Log collection | Promtail, Docker SD | OTel Collector DaemonSet |
| Collector topology | One collector | **Agent DaemonSet + gateway Deployment** |
| Alert rules | A file in `rules/` | `PrometheusRule` CRDs |
| Dashboards | JSON in a directory | A Helm chart of ConfigMaps |
| Storage | Local volumes | Persistent volumes, S3 for long term |

**Three things the Kubernetes version does better:**

**The agent/gateway split.** devboard's `collector-agent-values.yaml` runs a DaemonSet on every node doing host metrics and log collection, forwarding over OTLP to a gateway that handles the heavy processing and exporting. The agent stays small — 100m CPU, 128Mi — and only the gateway needs backend credentials. Single-collector setups do not scale past one node.

**Kubernetes attributes for free.** The `kubernetesAttributes` preset stamps `k8s.namespace.name`, `k8s.pod.name` and `k8s.container.name` onto metrics, logs *and* traces from one place. Here I had to agree the label scheme by hand across three configs and hope they matched.

**Alerts as CRDs.** A `PrometheusRule` object is namespaced, RBAC-controlled and deployed with the application it monitors — so a team owns its own alerts without editing a shared Prometheus config file.

**What the Compose version does better:** it starts in 30 seconds on a laptop and every piece is visible in one file. For learning what the components actually do, that is worth more.

**What I would carry from devboard regardless of platform:**

- **A `runbook` annotation on every alert.** The single best habit in that repository.
- **Encoding the cause in the description.** "EKS does not mark gp2 default, so a PVC that names no class waits forever" — Day 66's trap, living in the alert that detects it.
- **`memory_limiter` on every collector pipeline.**

### Gaps in what I have built

**No long-term storage.** Prometheus holds 15 days locally with no replication. Losing the volume loses the history. Thanos or Mimir with S3 is the answer.

**No authentication anywhere.** Grafana has a password; Prometheus, Alertmanager, Loki and Tempo are wide open on their ports. Fine bound to localhost, unacceptable exposed.

**Alertmanager notifies a webhook that logs.** Real routing means Slack, PagerDuty or email, plus a schedule.

**No sampling on traces.** Every span is kept, which is fine at this volume and ruinous at production rates. Tail sampling — keep all errors and slow requests, 1% of the rest — is the usual approach, and it belongs in the collector.

**Nothing is instrumented.** All of this observes infrastructure. The traces are curl'd by hand because DevBoard has no OTel SDK in it yet. Application instrumentation is what makes traces genuinely useful, and it is what devboard's `gitops/12-instrumentation.md` covers.

---

## Files in this folder

| Path | What it is |
|---|---|
| `observability/docker-compose.yml` | Nine services — metrics, logs, traces, alerting |
| `observability/Makefile` | `up`, `down`, `clean`, `logs`, `validate` |
| `observability/validate.sh` | 21 checks across all three pipelines |
| `observability/grafana/dashboards/production-overview.json` | Unified dashboard, all three datasources |
| `observability/grafana/dashboards/host-overview.json` | Day 74's host dashboard |
| `observability/{prometheus,loki,promtail,tempo,otel,alertmanager}/` | Component configs |

---

## What I learned

**1. "The container is running" is not "the pipeline is working".** All nine services can be `Up` while Promtail ships nothing because its position file is on a lost volume, or Prometheus scrapes nothing because a target name does not resolve. `validate.sh` queries for actual data at each stage, which is the only check that means anything — the same distinction as Day 57's readiness versus liveness.

**2. A consistent label scheme is what makes correlation possible.** The `$container` variable filters metrics and logs together only because cAdvisor's `name` and Promtail's `container` refer to the same thing. That agreement was a decision I had to make manually in three configs; devboard's collector does it from one preset. Decide the scheme once, before instrumenting anything.

**3. Instrumenting traces gives you metrics as a by-product.** One hand-crafted trace produced `traces_spanmetrics_calls_total` in Prometheus, via Tempo's generator and `remote_write`. That reverses the intuitive order — traces look like the advanced thing to do last, and they are arguably the highest-leverage thing to do first.

**Two extras:**

- The stack costs about 720 MB and 8% of two cores at idle, with cAdvisor the most expensive component. Worth knowing before adding it to a small instance.
- Everything except Grafana is unauthenticated. Bound to localhost that is fine; the moment a port is exposed it is a full read of the infrastructure.
