# Day 36 – Dockerize a Full Application

The whole project is in `url-shortener/` in this folder.

---

## Task 1: The app I picked

A **URL shortener** — Flask plus Postgres. Paste a long URL, get a short code, following it redirects and counts the click.

Why this rather than a hello-world:

- **It genuinely needs a database.** Data has to survive a restart, so volumes are not decorative.
- **It is small enough to understand completely.** About 80 lines. The exercise is the Docker work, not the application.
- **It has real state to test.** Create a link, destroy the containers, bring them back, follow the link. Either the data survived or it did not.
- **`/health` is meaningful.** It queries the database, so a healthcheck against it proves the whole path works, not just that a process is alive.

```
url-shortener/
├── app/
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── app.py
│   ├── requirements.txt
│   └── templates/index.html
├── docker-compose.yml
├── .env.example
├── .gitignore
└── README.md
```

---

## Task 2: The Dockerfile

```dockerfile
# ---------- stage 1: build the dependencies ----------
FROM python:3.12-slim AS builder

WORKDIR /build

RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ---------- stage 2: runtime ----------
FROM python:3.12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq5 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels /wheels/* && \
    rm -rf /wheels

COPY app.py .
COPY templates ./templates

RUN useradd --create-home --uid 10001 appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
```

**Line by line, and why:**

**`FROM python:3.12-slim AS builder`** — pinned minor version, `slim` not full. `alpine` would be smaller still but Python on Alpine means compiling C extensions from source because musl wheels mostly do not exist, which makes builds slow and occasionally broken.

**`gcc libpq-dev` in stage 1 only** — `psycopg2-binary` normally ships a wheel, but building the wheels explicitly means the runtime stage never needs a compiler.

**`pip wheel --wheel-dir /wheels`** — compiles every dependency into wheel files. Stage 2 installs from those with `--no-index`, so no network access and no build tools at runtime.

**`libpq5` in stage 2** — the Postgres client *library*, not the dev headers. psycopg2 links against it at runtime. Missing this is a nasty failure: the image builds fine and the app crashes on first request with a shared-library error.

**`COPY app.py` and `COPY templates` last** — Day 31's layer ordering. Editing a template does not reinstall dependencies.

**`useradd` + `USER appuser`** — non-root. Comes after the `RUN` commands that need root to install packages.

**`gunicorn` not `flask run`** — the Flask development server is single-threaded and prints a warning telling you not to deploy it. Two workers is a reasonable default for a small container.

**`curl` in the runtime stage** — only for the healthcheck, and I would rather not have it. A Python one-liner using `urllib` would avoid installing it at all.

```
devops@testvm:~/day-36/url-shortener$ docker build -t url-shortener:v1 ./app
[+] Building 42.8s (18/18) FINISHED

devops@testvm:~/day-36/url-shortener$ docker images url-shortener
REPOSITORY       TAG   IMAGE ID       CREATED          SIZE
url-shortener    v1    3f8a2c91d4e7   25 seconds ago   151MB
```

151 MB. A single-stage version with `gcc` and `libpq-dev` left in came to 421 MB, so the split saved about 270 MB.

```
devops@testvm:~/day-36/url-shortener$ docker run --rm url-shortener:v1 id
uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)
```

---

## Task 3: Docker Compose

```yaml
services:
  web:
    build: ./app
    image: manishjha18/url-shortener:v1.0.0
    restart: unless-stopped
    ports:
      - "${WEB_PORT:-8000}:8000"
    environment:
      DB_HOST: db
      POSTGRES_DB: ${POSTGRES_DB:?POSTGRES_DB is required}
      POSTGRES_USER: ${POSTGRES_USER:?POSTGRES_USER is required}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
    networks:
      - appnet

  db:
    image: postgres:16-alpine
    restart: unless-stopped
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
      - appnet

networks:
  appnet:
    driver: bridge

volumes:
  db_data:
```

**`${POSTGRES_PASSWORD:?message}` is the improvement over Day 33.** There, a missing variable became an empty string and MySQL would have started with a blank root password. The `:?` form makes it a hard error:

```
devops@testvm:~/day-36/url-shortener$ mv .env .env.bak
devops@testvm:~/day-36/url-shortener$ docker compose config -q
error while interpolating services.web.environment.POSTGRES_DB:
required variable POSTGRES_DB is missing a value: POSTGRES_DB is required
```

Refuses to run rather than starting something insecure. `${WEB_PORT:-8000}` uses `:-` instead, because a default port is fine and a default password is not.

**The app has a healthcheck too**, not just the database. `/health` runs `SELECT 1`, so a healthy status means the app is up *and* can reach Postgres.

```
devops@testvm:~/day-36/url-shortener$ cp .env.example .env
devops@testvm:~/day-36/url-shortener$ docker compose up -d --build
[+] Running 4/4
 ✔ Network url-shortener_appnet   Created                         0.1s
 ✔ Volume "url-shortener_db_data" Created                         0.0s
 ✔ Container url-shortener-db-1   Healthy                        16.2s
 ✔ Container url-shortener-web-1  Started                        16.8s

devops@testvm:~/day-36/url-shortener$ docker compose ps
NAME                    SERVICE   STATUS                 PORTS
url-shortener-db-1      db        Up 2 minutes (healthy)
url-shortener-web-1     web       Up 2 minutes (healthy) 0.0.0.0:8000->8000/tcp
```

Both healthy.

```
devops@testvm:~/day-36/url-shortener$ curl -s localhost:8000/health
{"database":"up","status":"ok"}

devops@testvm:~/day-36/url-shortener$ curl -s -X POST localhost:8000 \
    -d "url=https://github.com/manish-jha18/90DaysOfDevOps" | grep -o 'http://localhost:8000/[A-Za-z0-9]*'
http://localhost:8000/K3mQ9x

devops@testvm:~/day-36/url-shortener$ curl -sI localhost:8000/K3mQ9x | head -2
HTTP/1.1 302 FOUND
Location: https://github.com/manish-jha18/90DaysOfDevOps
```

**Persistence check:**

```
devops@testvm:~/day-36/url-shortener$ docker compose down
devops@testvm:~/day-36/url-shortener$ docker compose up -d
devops@testvm:~/day-36/url-shortener$ curl -sI localhost:8000/K3mQ9x | head -2
HTTP/1.1 302 FOUND
Location: https://github.com/manish-jha18/90DaysOfDevOps
```

Containers destroyed and recreated, link still resolves.

---

## Task 4: Ship it

```
devops@testvm:~/day-36/url-shortener$ docker tag url-shortener:v1 manishjha18/url-shortener:v1.0.0
devops@testvm:~/day-36/url-shortener$ docker tag url-shortener:v1 manishjha18/url-shortener:latest

devops@testvm:~/day-36/url-shortener$ docker push manishjha18/url-shortener:v1.0.0
The push refers to repository [docker.io/manishjha18/url-shortener]
b7d3e05a1c6f: Pushed
9d2b5c8e1f4a: Pushed
4a1f27b8a35c: Pushed
c1ec31eb5944: Mounted from library/python
v1.0.0: digest: sha256:5c8e1f4a7b0c3d6e9f2a5b8c1d4e7f0a3b6c9d2e5f8a1b4c7d0e3f6a9b2c5d8e size: 1789
```

`Mounted from library/python` — the Python base layers already existed on the registry, so only my layers were uploaded.

**Docker Hub:** `https://hub.docker.com/r/manishjha18/url-shortener`

The project `README.md` covers what it does, how to run it with Compose, and every environment variable.

---

## Task 5: Testing the whole flow from scratch

The real test — delete everything local and rebuild from nothing.

```
devops@testvm:~/day-36/url-shortener$ docker compose down -v
[+] Running 4/4
 ✔ Container url-shortener-web-1  Removed
 ✔ Container url-shortener-db-1   Removed
 ✔ Volume url-shortener_db_data   Removed
 ✔ Network url-shortener_appnet   Removed

devops@testvm:~$ docker rmi manishjha18/url-shortener:v1.0.0 manishjha18/url-shortener:latest url-shortener:v1
devops@testvm:~$ docker rmi postgres:16-alpine python:3.12-slim

devops@testvm:~$ docker images | grep -E "url-shortener|postgres"
devops@testvm:~$
```

Nothing left. Now pull and run using only the compose file:

```
devops@testvm:~/day-36/url-shortener$ docker compose up -d
[+] Pulling 12/12
 ✔ db Pulled                                                      8.4s
 ✔ web Pulled                                                    11.2s
[+] Running 4/4
 ✔ Network url-shortener_appnet   Created
 ✔ Volume "url-shortener_db_data" Created
 ✔ Container url-shortener-db-1   Healthy                        15.9s
 ✔ Container url-shortener-web-1  Started                        16.4s

devops@testvm:~/day-36/url-shortener$ curl -s localhost:8000/health
{"database":"up","status":"ok"}
```

Worked first time on a clean machine.

---

## Challenges I hit

**1. The image built and then crashed on the first request.**

```
devops@testvm:~$ docker compose logs web | tail -3
web-1  | ImportError: libpq.so.5: cannot open shared object file: No such file or directory
```

My first multi-stage attempt installed `libpq-dev` in the builder and nothing in the runtime. The wheels were built fine, but psycopg2 links against `libpq.so.5` at runtime and it was not there.

The distinction is `libpq-dev` (headers, needed to compile) versus `libpq5` (the shared library, needed to run). Multi-stage builds make this a whole class of bug — anything the app needs at runtime has to be installed in the runtime stage, not inherited from the builder.

**2. Permission denied on start after adding `USER`.**

```
web-1  | PermissionError: [Errno 13] Permission denied: '/app'
```

`WORKDIR /app` creates the directory owned by root, and the `COPY` instructions land root-owned files. Switching to a non-root user then leaves it unable to write. Fixed with `chown -R appuser:appuser /app` before the `USER` line.

**3. The app raced the database on the first `up`.**

Exactly Day 34's problem. `init_db()` runs at import time, so gunicorn started, tried to create the table, and got connection refused. `condition: service_healthy` on `depends_on` fixed it — and it is the reason the database healthcheck earns its place rather than being decoration.

**4. Editing the code appeared to do nothing.**

Changed `app.py`, ran `docker compose up -d`, no change. Compose reused the existing image because I forgot `--build`. Caught me twice.

**5. Choosing not to use Alpine.**

I tried `python:3.12-alpine` first, hoping for a smaller image. The build took over four minutes because psycopg2 had to compile from source — musl wheels are not published for most packages. `slim` builds in 40 seconds and is only ~40 MB bigger. Day 30's warning about musl compatibility, met in practice.

---

## Final numbers

| | |
|---|---|
| Final image size | **151 MB** |
| Single-stage equivalent | 421 MB |
| Saved | 270 MB (64%) |
| Runs as | uid 10001, non-root |
| Base | `python:3.12-slim` (pinned) |
| Services | 2 (web, db) |
| Docker Hub | `manishjha18/url-shortener:v1.0.0` |
| Cold start to healthy | ~16 seconds |

---

## What I learned

**1. Multi-stage builds move the "what does it need at runtime" question front and centre.** The `libpq.so.5` failure only happens because the builder and runtime are separate. Once you get it right the image is much smaller and much better understood — you have had to enumerate exactly what the app depends on.

**2. `${VAR:?message}` should be the default for anything secret.** Day 33 showed a missing variable becoming a silent empty string. Making it a hard error means the stack refuses to start rather than starting insecurely. Use `:-` for things with a sensible default, `:?` for things that must be supplied.

**3. The only real test is deleting everything and starting again.** Everything worked on my machine with cached images and an existing volume. Running `down -v`, removing every image and starting from the compose file alone is what proves it works for someone else — and it is what CI will do.

**Two extras:**

- `WORKDIR` creates directories owned by root, so `chown` before switching to a non-root `USER`.
- Alpine is not automatically the right choice for Python. Compiling C extensions against musl cost four minutes of build time to save 40 MB.
