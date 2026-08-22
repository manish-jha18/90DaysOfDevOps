# Day 74 – Node Exporter, cAdvisor and Grafana Dashboards

Stack in `observability/` in this folder — Day 73's Prometheus plus two exporters and Grafana.

---

## Task 1: Node Exporter

Prometheus scrapes HTTP endpoints. A Linux host does not have one, so an **exporter** translates system state into the exposition format.

```yaml
  node-exporter:
    image: prom/node-exporter:v1.8.2
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|rootfs/var/lib/docker)($$|/)"
    network_mode: host
    pid: host
```

**The mounts are the whole thing.** Node Exporter reads `/proc` and `/sys` — Day 02's kernel interfaces. In a container those are the *container's* view, showing one process and the container's cgroup limits. Mounting the host's versions read-only and pointing the collectors at them is what makes it report the host.

**`network_mode: host` and `pid: host`** for the same reason. Without them it sees one veth interface and one process instead of the host's real network and process table.

**The filesystem exclusion matters more than it looks.** Every container has its own overlay mount, so without it a host running 20 containers reports 20-odd extra filesystems and the disk panel becomes unreadable.

The `$$` is Compose escaping — `$$` in a compose file becomes a literal `$` in the container. A single `$` would be interpreted as variable substitution.

```
devops@testvm:~$ curl -s http://localhost:9100/metrics | grep -c "^[a-z]"
1247

devops@testvm:~$ curl -s http://localhost:9100/metrics | grep "^node_memory_MemAvailable"
node_memory_MemAvailable_bytes 2.147483648e+09
```

Around 1,200 metrics from the default collectors — CPU, memory, disk, network, filesystem, load, systemd units.

**A wrinkle from `network_mode: host`:**

```yaml
  - job_name: node-exporter
    static_configs:
      - targets: ["host.docker.internal:9100"]
```

Because it uses the host's network stack it is **not on the Compose network**, so `node-exporter:9100` does not resolve. `host.docker.internal` reaches the host from inside another container. On Linux that needs `extra_hosts: ["host.docker.internal:host-gateway"]`; on Docker Desktop it works out of the box.

That cost me a few minutes of a target showing `DOWN` with `no such host` while the exporter was plainly working.

---

## Task 2: cAdvisor

Node Exporter reports the host. cAdvisor reports **per container**.

```yaml
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    ports:
      - "8081:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    privileged: true
```

Port 8081 on the host because 8080 is already the DevBoard backend's.

**`privileged: true` is a real cost.** cAdvisor needs it to read cgroup and container runtime state. A privileged container can largely escape to the host — Day 35's non-root argument, and the reason cAdvisor should not run on a host that also runs untrusted workloads. In Kubernetes it is unnecessary, because cAdvisor is built into kubelet.

```
devops@testvm:~$ curl -s http://localhost:8081/metrics | grep 'container_memory_working_set_bytes{.*name="prometheus"' | head -1
container_memory_working_set_bytes{id="/docker/...",image="prom/prometheus:v2.54.1",name="prometheus"} 8.6274048e+07
```

**`container_memory_working_set_bytes`, not `container_memory_usage_bytes`.** Usage includes page cache, which the kernel reclaims under pressure, so it looks alarmingly high and is not. Working set is what the OOM killer actually considers — the number that matters, and the one Day 57's OOMKilled section is about.

The `name` label is the container name, which is what makes `sum by (name)` readable.

---

## Task 3: Grafana

```yaml
  grafana:
    image: grafana/grafana:11.2.0
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD:-admin}
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
```

Every `GF_*` variable maps to a config file setting — `GF_SECURITY_ADMIN_PASSWORD` is `[security] admin_password`. Useful because it means the whole config can come from the environment.

`${GRAFANA_PASSWORD:-admin}` is Day 33's default-value syntax, and it is the wrong way round for anything real — Day 36's `${VAR:?}` would refuse to start without one. Acceptable locally; a public Grafana with `admin/admin` is a genuine incident.

**Grafana stores nothing itself.** It queries datasources live. The volume holds users, dashboards created through the UI and settings — not metrics.

---

## Task 4: The dashboard

**`observability/grafana/dashboards/host-overview.json`** — six panels covering the host and containers.

```json
{
  "title": "CPU usage",
  "type": "timeseries",
  "targets": [{
    "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
    "legendFormat": "cpu used %"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "percent",
      "min": 0, "max": 100,
      "thresholds": {
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 70 },
          { "color": "red", "value": 90 }
        ]
      }
    }
  }
}
```

**Three things that make a panel useful rather than decorative:**

**`unit`.** Without it Grafana prints `86274048`. With `unit: "bytes"` it prints `82.3 MiB`. The single highest-value field.

**`min` and `max` on a percentage.** Otherwise the axis autoscales and 3% CPU fills the panel, which reads as a crisis at a glance.

**Thresholds.** Green/yellow/red means the panel is readable without reading the numbers — which is the entire point of a wall dashboard.

**`legendFormat: "{{name}}"`** turns an unreadable full label set into just the container name.

### The queries

```promql
# CPU
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory
100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))

# Disk
100 * (1 - (node_filesystem_avail_bytes{mountpoint="/rootfs"} / node_filesystem_size_bytes{mountpoint="/rootfs"}))

# Container CPU
sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])) * 100

# Container memory
sum by (name) (container_memory_working_set_bytes{name!=""})
```

**`MemAvailable`, not `MemFree`.** Day 05's lesson — `MemFree` excludes reclaimable page cache and looks alarming on a healthy machine.

**`{name!=""}` on the cAdvisor queries** filters out the aggregate cgroup series cAdvisor also emits, which otherwise appear as an unnamed line dominating the chart.

`mountpoint="/rootfs"` because that is where the host root is mounted into the exporter.

---

## Task 5: Provisioning

The important part of the day, and the reason a dashboard built by clicking is a liability.

**`grafana/provisioning/datasources/prometheus.yml`**

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 15s
```

**`uid: prometheus`** fixed explicitly. Dashboards reference datasources by UID, so an auto-generated one means a dashboard JSON exported from one Grafana does not work on another. Setting it makes dashboards portable.

**`access: proxy`** means Grafana's backend makes the query, so the browser never contacts Prometheus. `direct` would require Prometheus to be reachable from every user's browser and to handle CORS.

**`timeInterval: 15s`** must match the scrape interval or `$__rate_interval` picks a window shorter than the scrape and graphs show gaps.

**`editable: false`** so nobody edits it in the UI and creates a difference between what is running and what is in git.

**`grafana/provisioning/dashboards/default.yml`**

```yaml
providers:
  - name: devboard
    folder: DevBoard
    type: file
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
```

`updateIntervalSeconds: 30` rescans the directory, so editing a JSON file updates Grafana without a restart — which makes dashboard development tolerable.

```
devops@testvm:~/day-74/observability$ docker compose up -d
devops@testvm:~$ curl -s -u admin:admin http://localhost:3000/api/datasources | jq -r '.[] | "\(.name)  \(.type)  \(.url)"'
Prometheus  prometheus  http://prometheus:9090

devops@testvm:~$ curl -s -u admin:admin 'http://localhost:3000/api/search?query=Host' | jq -r '.[] | "\(.title)  (\(.uid))"'
Host Overview  (devboard-host)
```

Datasource and dashboard both present on first boot, with nothing clicked.

**Why this matters:** `docker compose down -v` deletes the Grafana volume and every UI-built dashboard with it. Provisioned ones come back on the next start, because they are files in git — reviewable, diffable, and identical across environments. Same argument as Day 51's declarative-versus-imperative.

---

## Task 6: A community dashboard

Grafana.com hosts thousands. **1860 (Node Exporter Full)** is the standard one.

```
devops@testvm:~$ curl -s https://grafana.com/api/dashboards/1860/revisions/37/download \
    -o grafana/dashboards/node-exporter-full.json
```

**It needs an edit before it works.** Community dashboards use a datasource *variable*, typically `${DS_PROMETHEUS}`, and provisioning cannot fill it in:

```
devops@testvm:~$ sed -i 's/\${DS_PROMETHEUS}/prometheus/g' grafana/dashboards/node-exporter-full.json
```

Substituting the fixed UID from Task 5 is what makes it load. This is the most common reason an imported dashboard shows "Datasource not found".

**Community versus hand-built:**

Dashboard 1860 has ~200 panels and covers things I would not have thought of — per-core CPU, network errors, context switches, entropy. Free, and better than anything I would write.

The costs are real though: it is exhaustive rather than focused, so finding the one number you want takes longer than a purpose-built panel; a big dashboard fires a lot of queries and can load slowly; and none of it is tailored to what actually breaks in *your* system.

**The split I would use:** a community dashboard for deep-dive investigation, and a small hand-built one — six panels, the golden signals — as the thing that stays on screen. Day 77 builds that.

---

## Files in this folder

| Path | What it is |
|---|---|
| `observability/docker-compose.yml` | Prometheus, node-exporter, cAdvisor, Grafana |
| `observability/prometheus/prometheus.yml` | Three scrape jobs |
| `observability/grafana/provisioning/datasources/prometheus.yml` | Datasource as code, fixed UID |
| `observability/grafana/provisioning/dashboards/default.yml` | Dashboard file provider |
| `observability/grafana/dashboards/host-overview.json` | Six panels, host and containers |

---

## What I learned

**1. An exporter in a container reports the container unless you mount the host in.** Node Exporter reads `/proc` and `/sys`; without the host mounts plus `network_mode: host` and `pid: host` it reports one process and the container's own limits. The metrics look plausible and are about the wrong thing.

**2. Provisioning is the difference between a dashboard and a liability.** Anything built by clicking lives in a volume and dies with `docker compose down -v`. Datasources and dashboards as files are in git, reviewable, and identical everywhere — and pinning the datasource `uid` is what makes a dashboard portable at all.

**3. `container_memory_working_set_bytes`, not `container_memory_usage_bytes`.** Usage includes reclaimable page cache and looks alarming on a healthy container. Working set is what the OOM killer counts, which makes it the one that matches Day 57's OOMKilled behaviour.

**Two extras:**

- A container using `network_mode: host` is not on the Compose network, so other containers cannot reach it by service name. `host.docker.internal` instead.
- Community dashboards need `${DS_PROMETHEUS}` replaced with a real datasource UID before provisioning will load them.
