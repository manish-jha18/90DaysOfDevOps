# Day 73 – Observability and Prometheus

Stack in `observability/` in this folder. Days 74–76 add to it.

---

## Task 1: Observability vs monitoring

**Monitoring answers questions you thought of in advance.** Is CPU above 80%? Is the disk full? Is the service up? You decide the questions, build the dashboards, set the thresholds — and it works well for failure modes you have already seen.

**Observability is about being able to ask questions you did not anticipate.** "Why are requests from this one customer slow, only on Tuesdays, only on the checkout path?" Nobody builds that dashboard in advance.

The practical difference is **cardinality and detail**. Monitoring aggregates early — one number for average latency. Observability keeps enough detail to slice afterwards, by endpoint, by customer, by version.

### The three pillars

| Pillar | Answers | Tool here |
|---|---|---|
| **Metrics** | *What* is happening — how many, how fast, how much | Prometheus |
| **Logs** | *What happened* in one specific event | Loki (Day 75) |
| **Traces** | *Where* time went across services in one request | Tempo (Day 76) |

They are complementary, not alternatives. A metric shows p95 latency jumped at 14:20. A trace shows which of six services caused it. A log shows the actual error from that service.

**Everything before this has been the "what" without the "why".** Day 37's `docker stats`, Day 58's `kubectl top`, Day 05's `vmstat` — all point-in-time snapshots with no history. Metrics Server keeps about a minute. Prometheus is the first tool here that stores a time series you can look backwards through.

### The four golden signals

Worth memorising because they generalise to any service:

| Signal | Measures |
|---|---|
| **Latency** | How long requests take. Split successful from failed — a fast 500 skews the average |
| **Traffic** | Demand. Requests/second |
| **Errors** | Rate of failures |
| **Saturation** | How full the system is. Usually the leading indicator |

Saturation is the one that predicts an outage rather than reporting it. Day 76's `predict_linear` disk alert is exactly that idea.

---

## Task 2: Prometheus in Docker

**`observability/docker-compose.yml`**

```yaml
services:
  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"
      - "--storage.tsdb.retention.size=2GB"
      - "--web.enable-lifecycle"

volumes:
  prometheus_data:
```

`prom/prometheus:v2.54.1` — pinned, per Day 35.

**`--web.enable-lifecycle`** allows `POST /-/reload` so a config change does not need a container restart. Off by default because it is an unauthenticated endpoint that reloads config, which is a real consideration on an exposed instance.

The named volume is the point of the whole exercise: without it, restarting the container loses every metric.

**`observability/prometheus/prometheus.yml`**

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: devboard-local

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: sample-app
    static_configs:
      - targets: ["sample-app:9100"]
        labels:
          service: sample
          env: local
```

**Prometheus scrapes itself.** Always keep that job — it is how you know the scraper is alive, and its own metrics show scrape durations and failures.

**`external_labels`** are stamped on every metric leaving this server. They matter once several Prometheus instances feed one place, or with remote_write — without them you cannot tell which cluster a metric came from.

```
devops@testvm:~/day-73/observability$ docker compose up -d
[+] Running 3/3
 ✔ Volume "observability_prometheus_data"  Created
 ✔ Container prometheus                    Started
 ✔ Container sample-app                    Started

devops@testvm:~$ curl -s http://localhost:9090/-/ready
Prometheus Server is Ready.

devops@testvm:~$ curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | "\(.labels.job)  \(.health)  \(.lastScrapeDuration)"'
prometheus  up  0.002181
sample-app  up  0.004922
```

---

## Task 3: The concepts

### The data model

Every sample is `metric_name{label="value", ...} value @timestamp`.

```
node_cpu_seconds_total{cpu="0", mode="idle", instance="sample-app:9100", job="sample-app"} 88214.32 @1754990400
```

**A metric name plus a unique set of labels is a *time series*.** Change any label value and it is a different series with its own storage.

**That is where cardinality bites.** A label with 10 values multiplies the series count by 10. A label holding a user ID or a request ID multiplies it by the number of users — hundreds of thousands of series from one metric, and Prometheus falls over. The rule: **labels are for things with a small, bounded set of values.** Status code, method, endpoint — yes. Anything unique per request — never.

### The four metric types

| Type | Behaviour | Example |
|---|---|---|
| **Counter** | Only goes up (or resets to 0) | `http_requests_total` |
| **Gauge** | Goes up and down | `node_memory_MemAvailable_bytes` |
| **Histogram** | Buckets of observations, plus sum and count | `http_request_duration_seconds` |
| **Summary** | Pre-computed quantiles, calculated client-side | Less common now |

**Counters are the type people misuse.** `http_requests_total` is not interesting as a raw number — 4,812,003 requests since the process started tells you nothing. `rate()` over it does. **Always wrap a counter in `rate()` or `increase()`.**

The `_total` suffix is the convention for counters, and `rate()` handles the reset when a process restarts, which is why you cannot just subtract.

**Histograms are what give you percentiles**, and the important detail is that the buckets are chosen when the metric is defined. `histogram_quantile()` interpolates within a bucket, so a p99 is only as accurate as the bucket boundaries allow.

### Pull, not push

Prometheus **scrapes** targets over HTTP. Most monitoring systems have agents that push.

Pull means the scraper controls the rate, so a misbehaving app cannot flood it. It also gives `up` for free — a target that cannot be scraped is `up == 0`, which is how you detect a dead service without the service having to tell you.

The exception is short-lived jobs that finish before any scrape. Those push to a **Pushgateway**, which Prometheus then scrapes.

---

## Task 4: PromQL

```
devops@testvm:~$ q() { curl -sG http://localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric | tostring)  \(.value[1])"'; }
```

**An instant vector** — one value per series, at one moment:

```
devops@testvm:~$ q 'up'
{"instance":"localhost:9090","job":"prometheus"}  1
{"instance":"sample-app:9100","job":"sample-app"}  1
```

**Filtering by label:**

```
devops@testvm:~$ q 'up{job="sample-app"}'
{"instance":"sample-app:9100","job":"sample-app"}  1

devops@testvm:~$ q 'up{job!="prometheus"}'
devops@testvm:~$ q 'node_cpu_seconds_total{mode=~"user|system"}'
```

`=` exact, `!=` not, `=~` regex, `!~` regex-negated.

**`rate()` on a counter:**

```
devops@testvm:~$ q 'rate(prometheus_http_requests_total[5m])'
{"code":"200","handler":"/api/v1/query"}  0.13333333333333333
```

`[5m]` makes it a **range vector** — all samples in that window. `rate()` reduces it back to a per-second average.

**The `rate()` window rule:** it must cover at least **four** scrape intervals. With a 15s scrape, `[1m]` is the absolute minimum and `[5m]` is the safe default. Too short and a single missed scrape produces gaps; too long and it smooths away the spike you were looking for.

**Aggregation:**

```
devops@testvm:~$ q 'sum(rate(prometheus_http_requests_total[5m]))'
{}  0.4666666666666667

devops@testvm:~$ q 'sum by (code) (rate(prometheus_http_requests_total[5m]))'
{"code":"200"}  0.4666666666666667
```

`sum by (x)` keeps label `x` and collapses everything else. `sum without (y)` keeps everything except `y`. `by` is usually clearer about intent.

**The CPU query, which is worth understanding in full:**

```promql
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

Read inside out: `node_cpu_seconds_total{mode="idle"}` is a counter of seconds spent idle. `rate(...[5m])` gives idle seconds per second — a number between 0 and 1, effectively the idle fraction. `avg()` across cores. `* 100` to a percentage. `100 -` inverts it to busy.

There is no `cpu_usage_percent` metric. Prometheus exposes raw counters and you derive what you want — which is unfamiliar coming from tools that hand you a percentage.

**Other functions in regular use:**

```promql
increase(http_requests_total[1h])                    # total over the window
irate(node_cpu_seconds_total[5m])                    # instant rate, last two points - spiky
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
topk(5, sum by (name) (container_memory_working_set_bytes))
predict_linear(node_filesystem_avail_bytes[6h], 4*3600) < 0   # will it be full in 4h
absent(up{job="sample-app"})                          # fires when the series VANISHES
```

**`absent()` is the one people forget.** If a target disappears entirely, `up == 0` never fires because there is no series to evaluate. `absent()` catches the metric going missing, which is a different failure from the metric being zero.

---

## Task 5: A scrape target

```yaml
  - job_name: sample-app
    static_configs:
      - targets: ["sample-app:9100"]
        labels:
          service: sample
          env: local
```

**Labels set here are attached to every metric from that target.** That is how you add dimensions the exporter itself does not know about — environment, team, region.

```
devops@testvm:~$ curl -s http://localhost:9101/metrics | head -6
# HELP go_gc_duration_seconds A summary of the wall-time pause duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 3.6791e-05
```

**The exposition format is plain text**, with `# HELP` and `# TYPE` lines. Any application can produce it with no library — though the client libraries handle the counter semantics and concurrency properly.

Reloading without a restart:

```
devops@testvm:~$ curl -X POST http://localhost:9090/-/reload
devops@testvm:~$ curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[].labels.job'
prometheus
sample-app
```

**Static configs do not survive autoscaling**, which is the same problem Day 68's static Ansible inventory had, and the same answer — service discovery:

```yaml
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
    relabel_configs:
      # only scrape containers that opt in with a label
      - source_labels: [__meta_docker_container_label_prometheus_scrape]
        regex: "true"
        action: keep
```

In Kubernetes this is a `ServiceMonitor` — devboard's `gitops/observability/manifests/servicemonitors.yaml` does exactly this, with the Prometheus Operator turning it into scrape config automatically.

---

## Task 6: Retention and storage

```
devops@testvm:~$ docker exec prometheus du -sh /prometheus
41.2M	/prometheus

devops@testvm:~$ docker exec prometheus ls /prometheus | head -5
01J8XQZ4K2H3M5N7P9R1T3V5W7
chunks_head
lock
queries.active
wal
```

Prometheus stores data in two-hour **blocks**, compacted into larger ones over time. `wal/` is the write-ahead log — recent data not yet flushed, which is what survives a crash.

```
- "--storage.tsdb.retention.time=15d"
- "--storage.tsdb.retention.size=2GB"
```

**Whichever limit is hit first wins.** Time-based alone means a traffic spike can fill the disk; size-based alone means retention silently shortens as cardinality grows. Setting both bounds the problem in both directions.

**Estimating storage:** roughly **1–2 bytes per sample** after compression.

```
series × (retention_seconds / scrape_interval) × 2 bytes
```

10,000 series at 15s for 15 days ≈ 10,000 × 86,400 × 2 ≈ **1.7 GB**. Useful because it shows what dominates: doubling the scrape interval halves storage, and **cardinality is linear** — one badly chosen label multiplies everything.

```
devops@testvm:~$ q 'prometheus_tsdb_head_series'
{}  1847

devops@testvm:~$ q 'topk(3, count by (__name__) ({__name__=~".+"}))'
{"__name__":"node_cpu_seconds_total"}  16
```

`prometheus_tsdb_head_series` is the number to watch. A jump usually means someone added a high-cardinality label.

**Prometheus is deliberately not a long-term store.** Local storage only, no clustering, no replication. For longer retention it does `remote_write` to Thanos, Mimir or Cortex — Day 76's Tempo does the same thing in the other direction, pushing derived metrics in.

---

## Files in this folder

| Path | What it is |
|---|---|
| `observability/docker-compose.yml` | Prometheus plus a sample scrape target |
| `observability/prometheus/prometheus.yml` | Global config, two scrape jobs, target labels |

---

## What I learned

**1. Cardinality, not volume, is what kills Prometheus.** A metric name plus a unique label set is one time series, each with its own storage. A label holding a request ID turns one metric into hundreds of thousands of series. Volume you can plan for; cardinality grows multiplicatively and does so without warning.

**2. Counters are meaningless raw and only useful through `rate()`.** `http_requests_total` at 4,812,003 tells you nothing. `rate()` also handles counter resets on restart, which is why subtracting two values by hand is wrong.

**3. Prometheus gives you raw numbers, not answers.** There is no CPU percentage metric — you derive it from an idle-seconds counter with `100 - (avg(rate(...)) * 100)`. That is more work and it is why arbitrary questions can be asked afterwards, which is the whole observability argument from Task 1.

**Two extras:**

- `rate()` needs a window covering at least four scrape intervals. `[5m]` with a 15s scrape is the safe default.
- `up == 0` does not fire when a target disappears entirely, because there is no series left to evaluate. `absent()` is the alert for a metric that vanished.
