# Docker Cheat Sheet

Built from Days 29–36. Ordered by what I reach for most.

---

## Container commands

| Command | What it does |
|---|---|
| `docker run <image>` | Create and start a container |
| `docker run -d <image>` | Detached — run in the background |
| `docker run -it <image> bash` | Interactive shell inside a new container |
| `docker run --rm <image>` | Delete the container when it exits |
| `docker run -p 8080:80 <image>` | Publish host port 8080 to container port 80 |
| `docker run --name web <image>` | Give it a name instead of a random one |
| `docker run -e KEY=value <image>` | Set an environment variable |
| `docker run -v vol:/path <image>` | Attach a named volume |
| `docker run --network mynet <image>` | Attach to a specific network |
| `docker ps` | Running containers |
| `docker ps -a` | All containers, including stopped |
| `docker ps -q` | IDs only — for command substitution |
| `docker stop <c>` | SIGTERM, then SIGKILL after 10s |
| `docker kill <c>` | SIGKILL immediately |
| `docker start` / `restart` / `pause` / `unpause` | Lifecycle control |
| `docker rm <c>` | Remove a stopped container |
| `docker rm -f <c>` | Force remove a running one |
| `docker logs <c>` | Everything the main process wrote to stdout/stderr |
| `docker logs -f --tail 50 <c>` | Follow the last 50 lines |
| `docker exec -it <c> bash` | Shell into a **running** container |
| `docker exec <c> <cmd>` | Run one command inside it |
| `docker inspect <c>` | Full JSON: IP, mounts, ports, state |
| `docker stats` | Live CPU and memory per container |
| `docker cp <c>:/path ./local` | Copy files in or out |
| `docker port <c>` | Show the port mappings |

**`-p` is `host:container`**, in that order.
**`docker run` creates a new container; `docker exec` enters an existing one.**

---

## Image commands

| Command | What it does |
|---|---|
| `docker images` | List local images |
| `docker pull <image>:<tag>` | Download from a registry |
| `docker build -t name:tag .` | Build from the Dockerfile in `.` |
| `docker build -f Dockerfile.dev -t name .` | Use a differently named Dockerfile |
| `docker build --no-cache -t name .` | Ignore the layer cache |
| `docker tag src:tag user/repo:tag` | Add a tag (does not copy the image) |
| `docker push user/repo:tag` | Upload to a registry |
| `docker rmi <image>` | Remove an image |
| `docker image history <image>` | Layers, with the size each one added |
| `docker inspect <image> --format '{{.Config.Cmd}}'` | Read one field |
| `docker save -o img.tar <image>` | Export to a tar file |
| `docker load -i img.tar` | Import from a tar file |
| `docker login` / `docker logout` | Registry authentication |

`docker tag` creates a second name for the same image ID — no extra disk used.

---

## Volume commands

| Command | What it does |
|---|---|
| `docker volume create <name>` | Create a named volume |
| `docker volume ls` | List volumes |
| `docker volume inspect <name>` | Shows the host path under `/var/lib/docker/volumes/` |
| `docker volume rm <name>` | Delete a volume |
| `docker volume prune` | Delete all unused volumes |
| `-v myvol:/data` | Named volume |
| `-v /host/path:/data` | Bind mount |
| `-v /host/path:/data:ro` | Bind mount, read-only |

**`-v mydata:/app` is a volume; `-v ./mydata:/app` is a bind mount.** Forget the `./` and Docker silently creates a volume instead of mounting your folder.

Mounting over a directory **hides** whatever the image had there.

---

## Network commands

| Command | What it does |
|---|---|
| `docker network ls` | List networks |
| `docker network create <name>` | Create a bridge network |
| `docker network inspect <name>` | Subnet, gateway, connected containers |
| `docker network connect <net> <c>` | Attach a running container |
| `docker network disconnect <net> <c>` | Detach it |
| `docker network rm <name>` | Delete |
| `docker network prune` | Delete unused networks |

**Containers on a custom network resolve each other by name. On the default bridge they do not** — only by IP, which changes on restart. Always create a network.

---

## Compose commands

| Command | What it does |
|---|---|
| `docker compose up` | Create and start, attached |
| `docker compose up -d` | Detached |
| `docker compose up -d --build` | Rebuild images first |
| `docker compose down` | Remove containers and network, **keep volumes** |
| `docker compose down -v` | Also delete volumes |
| `docker compose ps` | Service status |
| `docker compose logs -f [service]` | Follow logs, all services or one |
| `docker compose exec <svc> sh` | Shell into a service |
| `docker compose build [--no-cache]` | Build without starting |
| `docker compose stop` / `start` / `restart` | Without removing |
| `docker compose config` | Render the file with variables resolved |
| `docker compose config -q` | Validate only — works with the daemon down |
| `docker compose up -d --scale web=3` | Run 3 replicas (fails if the service publishes a port) |
| `docker compose top` | Processes per service |

`exec` takes the **service** name, not the container name.
Forgetting `--build` after a code change silently reuses the old image.

---

## Cleanup commands

| Command | What it does |
|---|---|
| `docker system df` | How much disk Docker is using, and what is reclaimable |
| `docker container prune` | Remove all stopped containers |
| `docker image prune` | Remove **dangling** (untagged) images only |
| `docker image prune -a` | Remove every image not used by a container |
| `docker volume prune` | Remove unused volumes |
| `docker network prune` | Remove unused networks |
| `docker builder prune` | Clear the build cache |
| `docker system prune` | Containers, networks, dangling images, build cache |
| `docker system prune -a --volumes` | All of it, **including volumes** |
| `docker stop $(docker ps -q)` | Stop everything running |
| `docker rm $(docker ps -aq)` | Remove every container |

**Run `docker system df` before any prune.** `--volumes` deletes database data, and unlike images it cannot be re-downloaded.

---

## Dockerfile instructions

| Instruction | What it does |
|---|---|
| `FROM image:tag` | Base image. Pin the tag, never `latest` |
| `FROM image AS builder` | Named stage for a multi-stage build |
| `WORKDIR /app` | Create and cd into a directory, persists for later instructions |
| `RUN cmd` | Execute at **build** time, result baked into a layer |
| `COPY src dst` | Copy from the build context into the image |
| `COPY --from=builder /src /dst` | Copy from an earlier stage |
| `ADD src dst` | Like COPY, but also unpacks archives and fetches URLs |
| `ENV KEY=value` | Environment variable, available at build and run time |
| `ARG KEY=value` | Build-time variable only, not present at runtime |
| `EXPOSE 8080` | Documentation only — publishes nothing |
| `USER appuser` | Drop from root. Put it after the `RUN`s that need root |
| `VOLUME /data` | Declare a mount point |
| `HEALTHCHECK CMD curl -f localhost/health` | How Docker tests if the container is healthy |
| `CMD ["exec","form"]` | Default command, **replaced** by anything on the command line |
| `ENTRYPOINT ["exec","form"]` | Fixed command, command-line args are **appended** |

**Prefer `COPY` over `ADD`.** ADD's auto-extract and URL fetch are surprising; use COPY unless you specifically want them.

**Always use the JSON array form** for CMD and ENTRYPOINT. Shell form makes `/bin/sh` PID 1, which does not forward SIGTERM, so `docker stop` hangs 10 seconds and then kills the container.

### Layer order

Least-changing first. One cache miss invalidates every layer below it.

```dockerfile
FROM python:3.12-slim      # never changes
RUN apt-get install ...    # rarely
COPY requirements.txt .    # occasionally
RUN pip install -r ...     # only when the line above changes
COPY . .                   # every commit
CMD [...]                  # metadata
```

Copying `requirements.txt` separately turned an 11.8s rebuild into 1.2s.

### Multi-stage template

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app

FROM alpine:3.20
RUN adduser -D -u 10001 appuser
COPY --from=builder /app /usr/local/bin/app
USER appuser
ENTRYPOINT ["/usr/local/bin/app"]
```

Only the last `FROM` becomes the image. 848 MB → 13.4 MB on my Go example.

Anything the app needs **at runtime** must be installed in the runtime stage. Missing `libpq5` cost me an hour on Day 36.

---

## Compose file template

```yaml
services:
  web:
    build: ./app
    image: user/app:v1.0.0
    restart: unless-stopped
    ports:
      - "${WEB_PORT:-8000}:8000"
    environment:
      DB_HOST: db
      DB_PASSWORD: ${DB_PASSWORD:?DB_PASSWORD is required}
    depends_on:
      db:
        condition: service_healthy
    networks: [appnet]

  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    networks: [appnet]

networks:
  appnet:
    driver: bridge

volumes:
  db_data:
```

`${VAR:-default}` for optional. `${VAR:?message}` for required — fails loudly instead of becoming an empty string.

No `version:` key — obsolete, and it warns if present.

### Restart policies

| Policy | Restarts on crash | On clean exit | After daemon restart |
|---|---|---|---|
| `no` | No | No | No |
| `on-failure` | Yes | No | No |
| `always` | Yes | Yes | Yes |
| `unless-stopped` | Yes | Yes | Only if not manually stopped |

`unless-stopped` is the sensible default for services.

---

## Exit codes

| Code | Means |
|---|---|
| 0 | Clean exit |
| 1 | Application error |
| 125 | Docker itself failed (bad flag) |
| 126 | Command found but not executable |
| 127 | Command not found |
| 137 | SIGKILL — `docker kill`, or the OOM killer |
| 143 | SIGTERM — normal `docker stop` |

**137 with no `docker kill` almost always means out of memory.**

---

## Things that have caught me out

- `-p` is host:container. Backwards is the classic mistake.
- `EXPOSE` publishes nothing. You still need `-p`.
- `docker compose up -d` without `--build` silently reuses the old image.
- `uniq`-style trap for volumes: `-v mydata:/app` vs `-v ./mydata:/app` are different things.
- Mounting a folder hides whatever the image had at that path.
- `docker rm` destroys the writable layer; `docker stop` does not. Data survives just long enough to feel safe.
- `docker compose down -v` deletes the database.
- Deleting a file in a later layer does not shrink the image — chain the cleanup into the same `RUN`.
- Containers run as root by default, and it is root on the host kernel.
- `latest` is a name, not a version. Pin your base images.
- `depends_on` alone waits for *started*, not *ready*. Use `condition: service_healthy`.
- Shell-form `CMD` breaks graceful shutdown.
- Alpine + Python means compiling C extensions from source. `slim` is often the better trade.
