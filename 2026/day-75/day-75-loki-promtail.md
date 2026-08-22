# Day 75 – Log Management with Loki and Promtail

Stack in `observability/` in this folder.

---

## Task 1: The logging pipeline

```
container stdout
      ↓
docker json-file driver → /var/lib/docker/containers/<id>/<id>-json.log
      ↓
   promtail        discovers containers, tails logs, adds labels
      ↓
     loki          stores and indexes
      ↓
   grafana         LogQL queries
```

Day 29 established that containerised apps log to **stdout**, because that is what `docker logs` reads. This is the pipeline that makes those logs searchable across every container at once instead of one `docker logs` at a time.

### Why Loki rather than Elasticsearch

**Loki indexes only labels, not log content.**

Elasticsearch does full-text indexing — every word in every line becomes searchable, which is powerful and expensive. The index frequently ends up larger than the logs, and an ELK stack needs serious memory.

Loki treats a log stream as a set of labels plus a compressed blob of lines. Querying means selecting streams by label, then **grepping** the matching chunks. Much cheaper to store and run; slower for a query that cannot narrow by label first.

**The trade-off shows up as a rule:** a LogQL query must always start with a label selector. `{container="backend"} |= "error"` selects by label then greps. You cannot search all logs everywhere for a word — and that constraint is what keeps it cheap.

It is deliberately "Prometheus, but for logs" — same label model, same query shape, same Grafana integration. Sharing labels between the two is what makes correlation work.

---

## Task 2: Loki

**`observability/loki/loki-config.yml`**

```yaml
auth_enabled: false

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_label_names_per_series: 15
  ingestion_rate_mb: 8
```

**`auth_enabled: false`** means no multi-tenancy. Loki does not authenticate — it reads a tenant ID from a header and expects a proxy in front to handle auth. On a public deployment that is a real gap.

**`schema: v13` with `store: tsdb`** is the current schema. Older examples use `boltdb-shipper` with `v11`, which still works and is slower. Getting this wrong is not fatal but is hard to change later — the schema is dated, so you add a new entry rather than editing the old one.

**`reject_old_samples`** stops a misconfigured shipper backfilling months of history in one go.

**`max_label_names_per_series: 15`** is the guard rail that matters, and it is Day 73's cardinality lesson in a sharper form. In Loki, **every unique label combination is a separate stream with its own chunk**. A label with 1,000 values means 1,000 streams, each with small inefficient chunks. High cardinality in Loki degrades faster than in Prometheus.

The rule: **labels for *where* the log came from, not *what it says*.** Container, namespace, service, level — yes. Request ID, user ID, trace ID — no, those go in the line and are matched at query time.

---

## Task 3: Promtail

**`observability/promtail/promtail-config.yml`**

```yaml
positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 15s

    relabel_configs:
      - source_labels: ["__meta_docker_container_name"]
        regex: "/(.*)"
        target_label: container

      - source_labels: ["__meta_docker_container_log_stream"]
        target_label: stream

      - source_labels: ["__meta_docker_container_label_com_docker_compose_service"]
        target_label: service

    pipeline_stages:
      - regex:
          expression: '(?i)(?P<level>DEBUG|INFO|WARN|WARNING|ERROR|FATAL|CRITICAL)'
      - labels:
          level:
```

**`positions.yaml` is not optional.** It records the byte offset reached in each file. Without it — or with it on a non-persistent path — a Promtail restart re-ships everything it can still see, which duplicates logs and can flood ingestion. Hence the named volume.

**`docker_sd_configs` discovers containers from the socket** rather than tailing files by path. New containers are picked up within `refresh_interval` with no config change. Day 73's service-discovery argument, for logs.

**The `regex: "/(.*)"` relabel** strips the leading slash Docker puts on container names. Without it every label is `/prometheus` rather than `prometheus`, which is ugly in every query.

**Pipeline stages transform lines before shipping.** The regex extracts a log level and promotes it to a label, so `{level="error"}` works without a regex on every query. Worth doing for a *bounded* set of values — level has about six, so it is safe. Doing the same for a request ID would be the cardinality mistake above.

`docker_sd_configs` versus tailing `/var/lib/docker/containers/*/*.log`: the file approach works and gives you a container ID rather than a name, so it needs more relabelling to be useful.

```
devops@testvm:~/day-75/observability$ docker compose up -d
devops@testvm:~$ curl -s http://localhost:3100/ready
ready

devops@testvm:~$ curl -s http://localhost:3100/loki/api/v1/labels | jq -r '.data[]'
compose_project
container
level
service
stream

devops@testvm:~$ curl -s http://localhost:3100/loki/api/v1/label/container/values | jq -r '.data[]'
grafana
loki
prometheus
promtail
```

Labels present, containers discovered. Note Promtail is collecting its own logs — `includeCollectorLogs: false` in devboard's collector values is the equivalent knob for turning that off, and it is worth doing because a collector logging about collecting logs is a feedback loop.

---

## Task 4: Loki as a datasource

**`observability/grafana/provisioning/datasources/datasources.yml`**

```yaml
  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      maxLines: 1000
      derivedFields:
        - name: TraceID
          matcherRegex: 'trace_id=(\w+)'
          url: "$${__value.raw}"
          datasourceUid: tempo
```

**`derivedFields` is the interesting part**, and it is the thing that makes three separate tools feel like one.

Promtail is told not to make `trace_id` a label, because that would be catastrophic cardinality. Instead Grafana runs `matcherRegex` over each **displayed** line, and where it matches it renders a **clickable link** straight to that trace in Tempo.

So the trace ID stays in the log body where it costs nothing, and correlation still works with one click. That is the pattern rather than a trick — Day 76 wires up the other direction.

`$$` is Compose escaping again: `$${__value.raw}` reaches Grafana as `${__value.raw}`.

---

## Task 5: LogQL

**Every query starts with a stream selector in braces.** That is not style, it is required — it is how Loki narrows to a set of chunks before doing anything expensive.

```logql
{container="prometheus"}
{container=~"prom.*"}
{compose_project="observability", level="error"}
```

**Then line filters:**

```logql
{container="grafana"} |= "error"        # contains
{container="grafana"} != "healthcheck"  # does not contain
{container="grafana"} |~ "(?i)err(or)?" # regex
{container="grafana"} !~ "debug|trace"  # regex, negated
```

**Order matters for performance.** `|=` is a substring match and is much faster than `|~`, so put the cheap filter first:

```logql
{container="backend"} |= "error" |~ "user_id=[0-9]+"
```

**Parsers turn a line into fields:**

```logql
{container="backend"} | json                  # parse JSON logs
{container="backend"} | logfmt                # key=value format
{container="backend"} | pattern "<_> <method> <path> <status>"
```

Then filter on the extracted fields:

```logql
{container="backend"} | json | status >= 500
{container="backend"} | logfmt | duration > 1s
```

**This is where structured logging pays off.** A JSON log line can be filtered on any field without a regex, and none of those fields cost cardinality because parsing happens at query time.

**Metric queries — LogQL producing a graph:**

```logql
sum(rate({container=~".+"} |~ "(?i)error" [5m]))
sum by (container) (rate({compose_project="observability"}[5m]))
count_over_time({container="backend"} |= "timeout" [1h])
```

```
devops@testvm:~$ curl -sG http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode 'query=sum by (container) (rate({compose_project="observability"}[5m]))' \
    --data-urlencode "start=$(date -d '15 min ago' +%s)000000000" \
    --data-urlencode "end=$(date +%s)000000000" \
  | jq -r '.data.result[] | "\(.metric.container)  \(.values[-1][1])"'
grafana     0.033
loki        0.267
prometheus  0.011
promtail    0.089
```

**A log-derived metric.** This is what makes "alert when error log rate exceeds X" possible without the application exposing an error counter — Day 76 uses it.

**One thing worth knowing:** `{container=~".+"}` scans everything and is slow, and Loki will refuse a query with no selector at all. `logcli` is the CLI equivalent of these curl calls and is much more pleasant to use.

---

## Task 6: Correlating metrics and logs

The point of one interface.

**In Grafana Explore**, a split view puts a Prometheus query on the left and a Loki query on the right, sharing a time range. Selecting a spike on the metrics panel narrows the log panel to that window.

**A mixed dashboard** does the same permanently — Day 77's Production Overview has metric panels and a log panel side by side.

The workflow that this enables, which is the actual value:

1. **A metric shows the problem.** Container memory climbing towards its limit.
2. **Select the window on the graph.** The log panel follows.
3. **Read what the container was doing** in those two minutes.
4. **Follow the trace link** from a log line into Tempo (Day 76).

Before this, that meant `kubectl top`, then `kubectl logs`, then correlating timestamps by hand across two terminals.

**What makes it work is shared labels.** Prometheus has `name="backend"` from cAdvisor; Loki has `container="backend"` from Promtail. Because they agree, moving between them is mechanical. Where they disagree, correlation becomes manual — which is the argument for deciding a label scheme once and applying it to metrics, logs and traces together.

devboard's Kubernetes setup does this with the collector's `kubernetesAttributes` preset, which stamps `k8s.namespace.name`, `k8s.pod.name` and `k8s.container.name` onto all three signals from one place.

---

## Files in this folder

| Path | What it is |
|---|---|
| `observability/docker-compose.yml` | Prometheus, Loki, Promtail, Grafana |
| `observability/loki/loki-config.yml` | tsdb schema v13, retention, cardinality limits |
| `observability/promtail/promtail-config.yml` | Docker SD, relabelling, level extraction |
| `observability/grafana/provisioning/datasources/datasources.yml` | Both datasources, with `derivedFields` |

---

## What I learned

**1. Loki indexes labels only, and that constraint is the whole design.** Every query must start with a stream selector, because Loki narrows by label and then greps. It is far cheaper than full-text indexing and it means you cannot search everything for a word — which is exactly the trade that keeps it affordable.

**2. Cardinality hurts Loki faster than it hurts Prometheus.** Each unique label combination is a separate stream with its own chunk, so a high-cardinality label produces thousands of tiny inefficient chunks. Labels are for *where the log came from*; anything unique per request stays in the line.

**3. `derivedFields` resolves the tension between those two facts.** A trace ID must not be a label, but it still needs to be clickable. Grafana regexes it out of the displayed line and links to Tempo — the correlation works and costs nothing at ingestion.

**Two extras:**

- Promtail's `positions.yaml` must be on a persistent volume, or a restart re-ships every log it can still see.
- Put `|=` substring filters before `|~` regex filters. Same result, considerably less work.
