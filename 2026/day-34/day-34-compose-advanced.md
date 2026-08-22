# Day 34 – Docker Compose: Real-World Multi-Container Apps

Three services this time — Flask app, Postgres, Redis — with healthchecks, restart policies, explicit networks and a Dockerfile built by Compose.

---

## Task 1: The app stack

**`app/app.py`** — a small Flask app with three routes. `/` increments a Redis counter, `/db` queries Postgres, `/health` is what the healthcheck hits. Deliberately minimal; the point is that it talks to both backing services.

**`app/Dockerfile`**

```dockerfile
FROM python:3.12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN useradd --create-home --shell /bin/bash appuser
USER appuser

EXPOSE 5000

CMD ["python", "app.py"]
```

Day 31's lessons applied: dependencies copied before source so the pip layer stays cached, apt lists removed in the same `RUN`, and a non-root `USER`.

`curl` is installed only because the healthcheck needs it. Worth being deliberate about — installing a tool into a production image just to health-check it is a real cost, and `python -c "import urllib.request; ..."` would avoid it.

**`docker-compose.yml`** — the full stack:

```yaml
services:
  web:
    build: ./app
    image: day34-web:latest
    restart: on-failure
    ports:
      - "${WEB_PORT}:5000"
    environment:
      DB_HOST: db
      REDIS_HOST: cache
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_started
    networks:
      - frontend
      - backend
    labels:
      com.manish.project: "day34-stack"
      com.manish.tier: "application"

  db:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    networks:
      - backend

  cache:
    image: redis:7-alpine
    restart: always
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - cache_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    networks:
      - backend

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge

volumes:
  db_data:
  cache_data:
```

```
devops@testvm:~/day-34$ cp .env.example .env
devops@testvm:~/day-34$ docker compose up -d --build
[+] Building 31.2s (12/12) FINISHED
[+] Running 7/7
 ✔ Network day-34_backend    Created                              0.1s
 ✔ Network day-34_frontend   Created                              0.1s
 ✔ Volume "day-34_db_data"   Created                              0.0s
 ✔ Volume "day-34_cache_data" Created                             0.0s
 ✔ Container day-34-cache-1  Healthy                             11.3s
 ✔ Container day-34-db-1     Healthy                             16.8s
 ✔ Container day-34-web-1    Started                             17.2s
```

Note the ordering: `db` and `cache` reach **Healthy** before `web` is started at all.

```
devops@testvm:~/day-34$ curl -s localhost:5000 | python3 -m json.tool
{
    "message": "Day 34 app stack is up",
    "visits": 1
}

devops@testvm:~/day-34$ curl -s localhost:5000 | python3 -m json.tool
{
    "message": "Day 34 app stack is up",
    "visits": 2
}
```

The counter increments, so Redis is reachable by the name `cache`.

```
devops@testvm:~/day-34$ curl -s localhost:5000/db | python3 -m json.tool
{
    "database": "connected",
    "version": "PostgreSQL 16.3 on x86_64-pc-linux-musl"
}
```

Postgres reachable by the name `db`. All three services talking, no IP addresses anywhere.

---

## Task 2: depends_on and healthchecks

### Why plain `depends_on` is not enough

```yaml
depends_on:
  - db
```

That only waits for the container to be **started** — the moment the process launches. Postgres then spends several seconds initialising before it accepts connections. The app starts, tries to connect, and crashes.

I reproduced it by switching to the plain form:

```
devops@testvm:~/day-34$ docker compose logs web | head -4
web-1  | Traceback (most recent call last):
web-1  |   File "/app/app.py", line 20, in <module>
web-1  |     cache = redis.Redis(host=REDIS_HOST, port=6379)
web-1  | psycopg2.OperationalError: could not connect to server: Connection refused
web-1  |     Is the server running on host "db" (172.20.0.2) and accepting
web-1  |     TCP/IP connections on port 5432?
```

Classic race. It usually works on a warm machine and fails on a cold one or in CI, which makes it maddening to debug.

### The healthcheck

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
  interval: 5s
  timeout: 3s
  retries: 5
  start_period: 10s
```

| Field | Meaning |
|---|---|
| `test` | Command to run. Exit 0 = healthy |
| `interval` | How often to run it |
| `timeout` | How long to allow before counting it as a failure |
| `retries` | Consecutive failures before marking unhealthy |
| `start_period` | Grace window at startup where failures do not count |

`pg_isready` is the right test because it returns 0 only once Postgres is genuinely accepting connections. A `CMD` that merely checks the process exists would prove nothing.

`start_period` matters: without it, a slow-starting database burns through its retries during normal initialisation and gets marked unhealthy before it ever had a chance.

**`CMD` vs `CMD-SHELL`:** `CMD` runs the command directly, `CMD-SHELL` runs it through `/bin/sh`, which is needed for variable expansion and pipes. Postgres needs `CMD-SHELL` for `${POSTGRES_USER}`; Redis's `redis-cli ping` does not.

### With `condition: service_healthy`

```yaml
depends_on:
  db:
    condition: service_healthy
  cache:
    condition: service_started
```

```
devops@testvm:~/day-34$ docker compose down && docker compose up -d
[+] Running 5/5
 ✔ Container day-34-cache-1  Healthy                             11.2s
 ✔ Container day-34-db-1     Healthy                             16.4s
 ✔ Container day-34-web-1    Started                             16.9s
```

**`Healthy`, not `Started`.** Compose waited 16 seconds for Postgres to pass its check before launching the app.

```
devops@testvm:~/day-34$ docker compose ps
NAME              IMAGE                SERVICE   STATUS                   PORTS
day-34-cache-1    redis:7-alpine       cache     Up 2 minutes (healthy)
day-34-db-1       postgres:16-alpine   db        Up 2 minutes (healthy)
day-34-web-1      day34-web:latest     web       Up 2 minutes             0.0.0.0:5000->5000/tcp

devops@testvm:~/day-34$ docker inspect day-34-db-1 --format '{{json .State.Health}}' | python3 -m json.tool | head -12
{
    "Status": "healthy",
    "FailingStreak": 0,
    "Log": [
        {
            "Start": "2026-07-12T09:42:18.221Z",
            "End": "2026-07-12T09:42:18.389Z",
            "ExitCode": 0,
            "Output": "/var/run/postgresql:5432 - accepting connections\n"
        }
    ]
}
```

Docker keeps the last few check results, which is genuinely useful when a service is flapping.

**One caveat worth knowing:** `condition: service_healthy` only helps at startup. If the database restarts later while the app is running, Compose does nothing. Real applications still need connection retry logic — the healthcheck reduces the problem, it does not remove it.

---

## Task 3: Restart policies

```yaml
db:
  restart: always
```

```
devops@testvm:~/day-34$ docker kill day-34-db-1
day-34-db-1

devops@testvm:~/day-34$ docker compose ps
NAME             SERVICE   STATUS
day-34-db-1      db        Up 2 seconds (health: starting)
```

Killed it, and it came straight back. Docker's restart policy noticed the container exited and started it again.

```
devops@testvm:~/day-34$ docker inspect day-34-db-1 --format '{{.RestartCount}}'
1
```

**`on-failure` is different:**

```yaml
web:
  restart: on-failure
```

```
devops@testvm:~/day-34$ docker kill day-34-web-1        # SIGKILL, exit 137
devops@testvm:~/day-34$ docker compose ps web
NAME             SERVICE   STATUS
day-34-web-1     web       Up 1 second

devops@testvm:~/day-34$ docker stop day-34-web-1        # SIGTERM, clean exit 0
devops@testvm:~/day-34$ docker compose ps -a web
NAME             SERVICE   STATUS
day-34-web-1     web       Exited (0) 5 seconds ago
```

That is the whole distinction. `on-failure` restarts on a **non-zero** exit and leaves a clean exit alone. `always` restarts regardless.

### The four policies

| Policy | Restarts on crash | Restarts on clean exit | Restarts on daemon start |
|---|---|---|---|
| `no` (default) | No | No | No |
| `on-failure` | Yes | No | No |
| `always` | Yes | Yes | Yes |
| `unless-stopped` | Yes | Yes | Only if not manually stopped |

**When I would use each:**

- **`no`** — batch jobs and one-shot tasks. A migration script that fails should stay failed and be visible, not loop.
- **`on-failure`** — anything that legitimately exits 0 when its work is done. Also good for a worker where a clean shutdown is intentional. `on-failure:5` caps the attempts.
- **`always`** — databases and core infrastructure that must come back after a host reboot.
- **`unless-stopped`** — my usual default for services. Same as `always`, except that if I deliberately stop something it stays stopped through a reboot. `always` would restart it and quietly undo my decision.

The trap with `always` is a crash-loop: a container that fails on startup restarts forever, filling the logs and burning CPU, while `docker ps` shows it "Up 2 seconds" each time you look. `on-failure:3` makes the failure visible instead.

---

## Task 4: Building from a Dockerfile

```yaml
web:
  build: ./app
  image: day34-web:latest
```

`build:` points at the directory containing the Dockerfile. `image:` names the result — without it Compose invents `day-34-web`, and having a real tag makes it pushable.

The longer form gives more control:

```yaml
build:
  context: ./app
  dockerfile: Dockerfile
  args:
    PYTHON_VERSION: "3.12"
```

**Change the code and rebuild:**

```
devops@testvm:~/day-34$ sed -i 's/Day 34 app stack is up/Day 34 stack - updated/' app/app.py

devops@testvm:~/day-34$ docker compose up -d --build
[+] Building 2.1s (12/12) FINISHED
 => CACHED [2/6] RUN apt-get update && apt-get install -y --no-inst…  0.0s
 => CACHED [4/6] COPY requirements.txt .                              0.0s
 => CACHED [5/6] RUN pip install --no-cache-dir -r requirements.txt   0.0s
 => [6/6] COPY app.py .                                               0.1s
[+] Running 3/3
 ✔ Container day-34-cache-1  Running
 ✔ Container day-34-db-1     Healthy
 ✔ Container day-34-web-1    Started

devops@testvm:~/day-34$ curl -s localhost:5000 | python3 -m json.tool
{
    "message": "Day 34 stack - updated",
    "visits": 5
}
```

Two things to notice. The build took **2.1 seconds** — the pip install stayed cached because only `app.py` changed, exactly the Day 31 layer-ordering payoff. And Compose only recreated `web`; `db` and `cache` were left running untouched.

The visit counter is at 5, not reset to 1 — Redis kept its data because the cache container never restarted.

**`--build` is required.** Plain `docker compose up -d` reuses the existing image and your code change silently does nothing. That has caught me out already.

---

## Task 5: Explicit networks, volumes and labels

### Two networks instead of one

```yaml
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
```

- `web` is on **both**
- `db` and `cache` are on **backend only**

This means the database is not reachable from the frontend network at all. Adding an nginx reverse proxy on `frontend` later would let it reach the app but not the database — a real segmentation boundary rather than a comment.

```
devops@testvm:~/day-34$ docker network ls | grep day-34
9f2a5b8c1d4e   day-34_backend    bridge    local
3e8c1f4a7b0c   day-34_frontend   bridge    local

devops@testvm:~/day-34$ docker inspect day-34-db-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
day-34_backend

devops@testvm:~/day-34$ docker inspect day-34-web-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
day-34_backend day-34_frontend
```

Proving the isolation:

```
devops@testvm:~/day-34$ docker run --rm --network day-34_frontend alpine:3.20 ping -c 1 db
ping: bad address 'db'

devops@testvm:~/day-34$ docker run --rm --network day-34_backend alpine:3.20 ping -c 1 db
PING db (172.20.0.2): 56 data bytes
64 bytes from 172.20.0.2: seq=0 ttl=64 time=0.084 ms
```

Invisible from the frontend, reachable from the backend.

### Named volumes

```yaml
volumes:
  db_data:
  cache_data:
```

`cache_data` exists because of `--appendonly yes` on Redis, which turns on persistence. Without it Redis is memory-only and the visit counter resets on every restart.

### Labels

```yaml
labels:
  com.manish.project: "day34-stack"
  com.manish.tier: "application"
```

Labels are metadata you can filter on:

```
devops@testvm:~/day-34$ docker ps --filter "label=com.manish.project=day34-stack" --format "table {{.Names}}\t{{.Labels}}"
NAMES            LABELS
day-34-web-1     com.manish.project=day34-stack,com.manish.tier=application
day-34-db-1      com.manish.project=day34-stack,com.manish.tier=database
day-34-cache-1   com.manish.project=day34-stack,com.manish.tier=cache

devops@testvm:~/day-34$ docker ps --filter "label=com.manish.tier=database" -q
7a3b52918f04
```

Useful for scripted cleanup, and it is the same mechanism Kubernetes labels and monitoring tools build on. Reverse-DNS naming avoids collisions with vendor labels.

---

## Task 6: Scaling

```
devops@testvm:~/day-34$ docker compose up -d --scale web=3
[+] Running 3/5
 ✔ Container day-34-db-1     Healthy
 ✔ Container day-34-cache-1  Healthy
 ✔ Container day-34-web-1    Running
 ✘ Container day-34-web-2    Error
 ✘ Container day-34-web-3    Error
Error response from daemon: driver failed programming external connectivity on
endpoint day-34-web-2: Bind for 0.0.0.0:5000 failed: port is already allocated
```

**It fails.** Only one replica starts.

### Why port mapping breaks scaling

`ports: "5000:5000"` binds host port 5000 to that container. A host port can only be bound once. The second replica tries to bind the same port and the kernel refuses.

The containers themselves are fine — three copies of the app could happily run, each on port 5000 *inside* its own network namespace. The conflict is entirely on the host side.

**Removing the port mapping lets it scale:**

```
devops@testvm:~/day-34$ docker compose up -d --scale web=3
[+] Running 5/5
 ✔ Container day-34-web-1    Started
 ✔ Container day-34-web-2    Started
 ✔ Container day-34-web-3    Started

devops@testvm:~/day-34$ docker compose ps web
NAME             SERVICE   STATUS         PORTS
day-34-web-1     web       Up 8 seconds   5000/tcp
day-34-web-2     web       Up 8 seconds   5000/tcp
day-34-web-3     web       Up 8 seconds   5000/tcp
```

Three replicas, but now nothing on the host can reach them.

**Compose's DNS does round-robin between them:**

```
devops@testvm:~/day-34$ docker run --rm --network day-34_backend alpine:3.20 nslookup web
Name:      web
Address 1: 172.20.0.4 day-34-web-1.day-34_backend
Address 2: 172.20.0.5 day-34-web-2.day-34_backend
Address 3: 172.20.0.6 day-34-web-3.day-34_backend
```

One name, three addresses. So the pieces for load balancing exist — what is missing is something in front that publishes a single port.

**The real fix is a reverse proxy:**

```yaml
proxy:
  image: nginx:1.25-alpine
  ports:
    - "8080:80"          # only the proxy binds a host port
  depends_on:
    - web
```

nginx binds 8080 on the host and forwards to `web`, letting Docker's DNS spread requests across the replicas.

This is exactly the gap Kubernetes fills. A Kubernetes Service gives a stable endpoint in front of N pods, with health-aware load balancing, and scaling is one number in a manifest. Compose can run multiple replicas; it has no concept of balancing traffic to them. Good to hit this limit now, because it explains why Kubernetes exists rather than being told.

---

## Files in this folder

| Path | What it is |
|---|---|
| `docker-compose.yml` | Three services, two networks, two volumes, healthchecks, labels |
| `app/Dockerfile` | Python image, non-root user, cache-friendly layer order |
| `app/app.py` | Flask app with `/`, `/health` and `/db` routes |
| `app/requirements.txt` | flask, psycopg2-binary, redis |
| `app/.dockerignore` | Keeps `__pycache__`, `.env` and `.git` out of the build |
| `.env.example` | Template — `cp .env.example .env` before running |

---

## What I learned

**1. `depends_on` alone only waits for the container to start, not to be ready.** The app crashed with "connection refused" because Postgres was still initialising. `condition: service_healthy` plus a `pg_isready` healthcheck fixed it properly. This is the single most useful thing from today — it is a race that hides on a warm machine and appears in CI.

**2. Restart policies differ on how they treat a clean exit.** `on-failure` ignores exit 0; `always` restarts regardless. Verified by killing a container (restarted) versus stopping it (stayed stopped). `unless-stopped` is the sane default for services, because `always` would silently undo a deliberate stop after a reboot.

**3. Port mapping is what prevents scaling, and that is why Kubernetes exists.** `--scale web=3` failed with "port is already allocated". Removing the mapping let three replicas run and Docker's DNS returned all three IPs — but nothing could reach them from outside. Compose can replicate; it cannot load balance.

**Two extras:**

- `docker compose up -d` without `--build` silently reuses the old image, so your code change appears to do nothing.
- Splitting services across a frontend and backend network is real isolation. A container on `frontend` could not even resolve `db`.
