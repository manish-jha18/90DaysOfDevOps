# Day 37 – Docker Revision

Nine days of Docker. Same approach as Day 12 and Day 28 — mark honestly, then redo whatever is shaky.

---

## Self-assessment

| Skill | Status |
|---|---|
| Run a container from Docker Hub (interactive + detached) | Can do |
| List, stop, remove containers and images | Can do |
| Explain image layers and how caching works | Can do |
| Write a Dockerfile with FROM, RUN, COPY, WORKDIR, CMD | Can do |
| Explain CMD vs ENTRYPOINT | Can do |
| Build and tag a custom image | Can do |
| Create and use named volumes | Can do |
| Use bind mounts | Can do |
| Create custom networks and connect containers | Can do |
| Write a docker-compose.yml for a multi-container app | Can do |
| Use environment variables and .env files in Compose | Can do |
| Write a multi-stage Dockerfile | Can do |
| Push an image to Docker Hub | Can do |
| Use healthchecks and depends_on | **Shaky** |

Plus two more I would add to the list:

| | |
|---|---|
| Debug a container that will not start | **Shaky** |
| Explain what `docker system prune` will actually delete | Can do |

14 can-do, 2 shaky. Better than Day 28's ratio, mostly because Days 29–36 were hands-on throughout — there was very little I read about without also running.

The two shaky ones have the same cause: I got healthchecks working by following the pattern, and when the Day 36 app would not start I fixed it by reading the error rather than by having a method.

---

## Quick-fire questions

Answered from memory, then checked.

**1. Difference between an image and a container?**

An image is a read-only template made of stacked layers. A container is a running instance of one, with a thin writable layer on top. One image, many containers — like a class and its instances. ✓

**2. What happens to data inside a container when you remove it?**

Gone. It lived in the container's writable layer, which is created with the container and destroyed with it. `docker stop` keeps it; `docker rm` destroys it. Volumes are how you keep anything. ✓

**3. How do two containers on the same custom network communicate?**

By container or service name. Custom networks get Docker's embedded DNS at `127.0.0.11`, which resolves container names to their current IPs. The default bridge has no DNS, so only IPs work there — and those change on restart. ✓

**4. What does `docker compose down -v` do differently from `docker compose down`?**

`down` removes containers and the network but keeps named volumes. `-v` deletes the volumes too, which means the database. ✓

**5. Why are multi-stage builds useful?**

Only the final `FROM` becomes the image, so build tools stay behind. `COPY --from=builder` takes just the artefact. My Go example went 848 MB → 13.4 MB. Smaller means faster pulls, less storage, and fewer packages to be vulnerable. ✓

**6. Difference between `COPY` and `ADD`?**

Both copy from the build context. `ADD` additionally auto-extracts local tar archives and can fetch URLs. Prefer `COPY` — `ADD`'s extra behaviour is surprising, and fetching a URL with ADD means you cannot verify a checksum. ✓

**7. What does `-p 8080:80` mean?**

Publish host port 8080 to container port 80. Host first. Without it the container is unreachable from outside, regardless of `EXPOSE`. ✓

**8. How do you check how much disk space Docker is using?**

`docker system df`, which breaks it down into images, containers, volumes and build cache with a reclaimable column. `docker system df -v` gives it per item. ✓

**8 out of 8**, though answer 6 was thinner than the others — I knew to prefer COPY without being able to say clearly why until I checked.

---

## Revisiting the weak spots

### 1. Healthchecks

I could copy a healthcheck that worked. I could not have written one for an arbitrary service, so I worked through what each field actually does.

```
devops@testvm:~/day-37$ docker run -d --name hc-test \
    --health-cmd="curl -fsS http://localhost/ || exit 1" \
    --health-interval=5s \
    --health-timeout=3s \
    --health-retries=3 \
    --health-start-period=5s \
    nginx:1.25-alpine
```

Watching it move through the states:

```
devops@testvm:~/day-37$ docker ps --format "{{.Names}}: {{.Status}}"
hc-test: Up 2 seconds (health: starting)

devops@testvm:~/day-37$ sleep 12 && docker ps --format "{{.Names}}: {{.Status}}"
hc-test: Up 14 seconds (healthy)
```

Then breaking it deliberately, by stopping nginx inside the container while leaving the container running:

```
devops@testvm:~/day-37$ docker exec hc-test nginx -s stop
devops@testvm:~/day-37$ sleep 20 && docker ps --format "{{.Names}}: {{.Status}}"
hc-test: Up 35 seconds (unhealthy)

devops@testvm:~/day-37$ docker inspect hc-test --format '{{json .State.Health}}' | python3 -m json.tool | head -14
{
    "Status": "unhealthy",
    "FailingStreak": 3,
    "Log": [
        {
            "Start": "2026-07-14T10:22:41.118Z",
            "End": "2026-07-14T10:22:41.284Z",
            "ExitCode": 1,
            "Output": "curl: (7) Failed to connect to localhost port 80: Connection refused\n"
        }
    ]
}
```

**Three states: `starting`, `healthy`, `unhealthy`.** `FailingStreak` counts consecutive failures and resets on any success, which is what stops a single blip flipping the status.

What I had genuinely misunderstood: **Docker does not restart an unhealthy container.** I assumed it would. The container above sat `unhealthy` indefinitely, still running, still accepting traffic on its published port. The healthcheck only reports; something else has to act on it — Compose's `depends_on`, or an orchestrator like Kubernetes or Swarm.

That reframes what a healthcheck is for. In plain Docker it is information. In Compose it gates startup ordering. Only in an orchestrator does it drive restarts and remove a pod from a load balancer.

The other thing worth writing down: **the healthcheck runs inside the container**, so the test command has to exist there. That is why Day 34's Dockerfile installs `curl` purely for the check — and why a Python one-liner using `urllib` is often the better choice, since it adds nothing to the image.

`start_period` is the field that fixes the most confusion: failures during that window do not count towards `retries`, so a slow database is not marked unhealthy while it is legitimately still starting.

### 2. Debugging a container that will not start

I had been fixing these ad hoc. Turning it into a method.

**Deliberately breaking something:**

```
devops@testvm:~/day-37$ docker run -d --name broken alpine:3.20 /bin/nonexistent
devops@testvm:~/day-37$ docker ps
CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
```

Nothing. The `docker ps` that shows nothing is the confusing part for a beginner — the container was created, it just is not running.

**Step 1 — `docker ps -a`, always:**

```
devops@testvm:~/day-37$ docker ps -a --filter name=broken
CONTAINER ID   IMAGE          COMMAND              CREATED         STATUS                     NAMES
4a7b0c3d6e9f   alpine:3.20    "/bin/nonexistent"   8 seconds ago   Exited (127) 7 seconds ago broken
```

`Exited (127)` — command not found, from the exit code table.

**Step 2 — the logs:**

```
devops@testvm:~/day-37$ docker logs broken
exec /bin/nonexistent: no such file or directory
```

**Step 3 — when the logs are empty, override the entrypoint and look around:**

```
devops@testvm:~/day-37$ docker run --rm -it --entrypoint sh alpine:3.20
/ # ls /bin/nonexistent
ls: /bin/nonexistent: No such file or directory
```

This is the technique I was missing. If a container dies instantly, `--entrypoint sh` gives a shell in the same image so you can check whether the file exists, whether it is executable, and what the environment looks like.

**Step 4 — for a crash loop, check the restart count and the OOM flag:**

```
devops@testvm:~/day-37$ docker inspect broken --format '{{.RestartCount}} restarts, OOMKilled={{.State.OOMKilled}}, exit={{.State.ExitCode}}'
0 restarts, OOMKilled=false, exit=127
```

`OOMKilled=true` with exit 137 is the memory case, and it is invisible from the logs alone.

**My checklist now:**

1. `docker ps -a` — did it exit, and with what code
2. `docker logs <c>` — what did it say before dying
3. `docker inspect <c> --format '{{.State.ExitCode}} {{.State.OOMKilled}}'`
4. `docker run --rm -it --entrypoint sh <image>` — poke around the image itself
5. `docker compose config` — if using Compose, check the resolved variables

Codes worth knowing cold: **125** Docker itself failed, **126** not executable, **127** not found, **137** SIGKILL or OOM, **143** SIGTERM.

---

## Where I stand after nine days of Docker

**What stuck, and why:** the same pattern as every revision day. The things I remember are the things that broke.

- `libpq.so.5: cannot open shared object file` on Day 36 taught me more about multi-stage builds than the Day 35 exercise did.
- `--scale web=3` failing with "port is already allocated" explains why Kubernetes exists better than any diagram.
- The app crashing with "connection refused" because Postgres was still initialising is why `condition: service_healthy` means something to me rather than being a line I copy.

**What I would still get wrong under pressure:** writing a healthcheck for an unfamiliar service, and choosing between Alpine and slim for a language I have not containerised before. Both need more repetitions.

**The three things I would tell someone starting Docker:**

1. **A container is a process.** Not a small VM. `ps aux` inside Ubuntu showing two processes, and `uname -r` showing the host kernel, made everything else make sense.
2. **Layers are additive.** Deleting a file in a later layer does not shrink the image. That one fact explains the long chained `RUN` commands in every real Dockerfile.
3. **Data lives in volumes or it does not live.** `docker stop` keeping your data and `docker rm` destroying it is exactly the wrong way round for building good instincts.

**Going into YAML and CI/CD on Day 38,** the compose files from Days 33–36 are already the YAML practice — indentation, lists, nested maps, variable substitution. And the Day 36 image is what a pipeline would build and push, so the Docker Hub work should slot straight in.
