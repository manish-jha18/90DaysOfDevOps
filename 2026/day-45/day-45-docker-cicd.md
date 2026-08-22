# Day 45 – Docker Build and Push in GitHub Actions

The first pipeline that ships something. Push to `main`, and both DevBoard images end up on Docker Hub with no manual step.

Workflow file is at `.github/workflows/docker-publish.yml` in this folder.

---

## Task 1: Prepare

DevBoard has two Dockerfiles — `backend/Dockerfile` (multi-stage Go build) and `frontend/Dockerfile` (multi-stage Node build serving with vite preview). Both are already what Day 35 taught: builder stage, minimal runtime, non-root user.

Secrets from Day 44:

```
devops@testvm:~$ gh secret list
NAME                 UPDATED
DOCKER_TOKEN         2 days ago
DOCKER_USERNAME      2 days ago
MY_SECRET_MESSAGE    2 days ago
```

The token is a Docker Hub **access token**, not my account password — generated under Account Settings → Personal access tokens with Read/Write scope. It can be revoked on its own without changing the password, and it is scoped to what the pipeline actually needs.

---

## Task 2, 3 and 4: Build, push, and only on main

**`.github/workflows/docker-publish.yml`**

```yaml
name: Docker Publish

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  build-and-push:
    runs-on: ubuntu-latest

    strategy:
      fail-fast: false
      matrix:
        component: [backend, frontend]

    steps:
      - name: Check out the code
        uses: actions/checkout@v4

      - name: Work out the tags
        id: meta
        run: |
          SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          IMAGE="${{ secrets.DOCKER_USERNAME }}/devboard-${{ matrix.component }}"
          echo "image=$IMAGE"                    >> "$GITHUB_OUTPUT"
          echo "sha_tag=$IMAGE:sha-$SHORT_SHA"   >> "$GITHUB_OUTPUT"
          echo "latest_tag=$IMAGE:latest"        >> "$GITHUB_OUTPUT"

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Docker Hub
        if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: ./${{ matrix.component }}
          push: ${{ github.ref == 'refs/heads/main' && github.event_name != 'pull_request' }}
          tags: |
            ${{ steps.meta.outputs.sha_tag }}
            ${{ steps.meta.outputs.latest_tag }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**The matrix builds both components in parallel.** Two jobs, one per folder, roughly halving wall-clock time versus doing them in sequence. This is DevBoard's own pattern from `docker-push.yml`.

**Two tags per image**, and both matter:

| Tag | Why |
|---|---|
| `:sha-8a3f91c` | Immutable. Points at exactly this commit, forever. This is what a rollback targets |
| `:latest` | Moving. Convenient for `docker compose pull`, useless for identifying a version |

Day 35's lesson applied: `latest` is a name, not a version. A production deploy should pin the SHA tag; `latest` exists for convenience.

**`push:` is an expression, not a hardcoded `true`:**

```yaml
push: ${{ github.ref == 'refs/heads/main' && github.event_name != 'pull_request' }}
```

So a PR **builds** the image — proving the Dockerfile is valid and the code compiles — but does not push. That is the right shape: full verification, no side effects.

The `github.event_name != 'pull_request'` half is not redundant. On a `pull_request` event, `github.ref` is `refs/pull/1/merge`, not the branch — but being explicit protects against the case of a PR targeting main where the ref check might behave unexpectedly. More importantly, **a PR from a fork must never receive the credentials.** GitHub does not expose secrets to fork PRs by default, but the login step is also gated so the intent is visible in the file rather than relying on that default.

**`cache-from: type=gha`** stores the Docker layer cache in GitHub's Actions cache, so a rebuild reuses layers from the previous run. Combined with Day 31's layer ordering, that means only the final `COPY` of source code re-runs when only the app code changed.

### Running it

```
devops@testvm:~$ gh run view 17210448821
✓ main Docker Publish · 17210448821

JOBS
✓ build-and-push (backend) in 1m24s
✓ build-and-push (frontend) in 2m11s
```

Backend output:

```
Run docker/build-push-action@v5
#8 [builder 4/5] COPY . .
#8 CACHED
#9 [builder 5/5] RUN CGO_ENABLED=0 go build -o devboard-backend .
#9 DONE 22.4s
#14 pushing manifest for docker.io/manishjha18/devboard-backend:sha-8a3f91c
#14 DONE 1.8s
#15 pushing manifest for docker.io/manishjha18/devboard-backend:latest
#15 DONE 0.9s
```

Second run after a code change:

```
✓ build-and-push (backend) in 38s
✓ build-and-push (frontend) in 52s
```

**1m24s down to 38s** — the layer cache doing its job.

### Testing the main-only condition

```
devops@testvm:~$ git switch -c test-no-push
devops@testvm:~$ echo "// test" >> backend/main.go
devops@testvm:~$ git commit -am "Test that feature branches do not push"
devops@testvm:~$ git push -u origin test-no-push
devops@testvm:~$ gh pr create --title "Test no push" --body "Should build but not push"
```

```
devops@testvm:~$ gh run view 17210502244
✓ test-no-push Docker Publish · 17210502244

JOBS
✓ build-and-push (backend) in 41s
  ✓ Check out the code
  ✓ Work out the tags
  ✓ Set up Buildx
  - Log in to Docker Hub        (skipped)
  ✓ Build and push
  ✓ Say what happened
```

Login **skipped**, build ran. And the output:

```
Run docker/build-push-action@v5
#14 exporting to image
#14 writing image sha256:3f8a2c91d4e7... done
#14 DONE 0.4s
```

`exporting to image` rather than `pushing manifest`. Built locally on the runner, then discarded with the VM.

Confirming nothing new landed on Docker Hub:

```
devops@testvm:~$ docker run --rm curlimages/curl -s \
    "https://hub.docker.com/v2/repositories/manishjha18/devboard-backend/tags?page_size=5" \
    | grep -o '"name":"[^"]*"'
"name":"latest"
"name":"sha-8a3f91c"
```

Only the two tags from the `main` build. The feature branch commit produced no new tag.

---

## Task 5: Status badge

```
devops@testvm:~$ gh workflow view docker-publish.yml --web
```

The badge URL follows a fixed pattern:

```markdown
![Docker Publish](https://github.com/manish-jha18/devboard/actions/workflows/docker-publish.yml/badge.svg)
```

Added to the top of the project README along with a Docker Hub link:

```markdown
# DevBoard

![Docker Publish](https://github.com/manish-jha18/devboard/actions/workflows/docker-publish.yml/badge.svg)
[![Docker Hub](https://img.shields.io/badge/docker-manishjha18%2Fdevboard-blue)](https://hub.docker.com/r/manishjha18/devboard-backend)
```

Green when the last run on the default branch passed, red when it failed.

Two things worth knowing: the badge always reflects the **default branch**, regardless of what is happening on feature branches; and `?branch=develop` can pin it to a different one. It is also the cheapest possible signal that a project is maintained — a red badge on a repo's front page is a strong statement.

---

## Task 6: Pull and run it

Removing everything locally first, so this is a genuine test rather than a cached one:

```
devops@testvm:~$ docker rmi manishjha18/devboard-backend:latest manishjha18/devboard-frontend:latest 2>/dev/null
devops@testvm:~$ docker images | grep devboard
devops@testvm:~$
```

```
devops@testvm:~/devboard$ cp .env.example .env
devops@testvm:~/devboard$ docker compose pull
[+] Pulling 3/3
 ✔ postgres Pulled
 ✔ backend Pulled
 ✔ frontend Pulled

devops@testvm:~/devboard$ docker compose up -d
[+] Running 4/4
 ✔ Network devboard_default  Created
 ✔ Container devboard-postgres-1  Healthy    12.4s
 ✔ Container devboard-backend-1   Started    12.9s
 ✔ Container devboard-frontend-1  Started    13.2s
```

```
devops@testvm:~$ curl -s http://localhost:8081/health
{"status":"ok"}

devops@testvm:~$ curl -s "http://localhost:8080/api/tasks?project_id=1" | head -c 120
[{"id":1,"project_id":1,"title":"Set up CI pipeline","status":"in_progress","created_at":"2026-07-20T...
```

Frontend serving, backend healthy, database returning seeded rows. The images came from Docker Hub, built by CI, never built on this machine.

Pinning the SHA tag also works, which is what a real deploy would do:

```
devops@testvm:~$ IMAGE_TAG=sha-8a3f91c docker compose up -d
```

DevBoard's compose file already supports this — `image: manishjha18/devboard-backend:${IMAGE_TAG:-latest}`.

### The full journey from `git push` to a running container

```
 1. developer   git push origin main
                       │
 2. GitHub      push event matches  on: push: branches: [main]
                       │
 3. Runner      Azure VM allocated, workflow starts
                       │
 4. Checkout    actions/checkout@v4 clones the repo onto the runner
                       │
 5. Tags        short SHA computed → sha-8a3f91c
                       │
 6. Buildx      builder set up, GitHub Actions layer cache restored
                       │
 7. Login       docker/login-action, DOCKER_TOKEN from secrets   (main only)
                       │
 8. Build       docker build for backend and frontend, in parallel
                │       multi-stage: compile in builder, copy binary to runtime
                       │
 9. Push        two tags per image → Docker Hub
                │       manishjha18/devboard-backend:sha-8a3f91c
                │       manishjha18/devboard-backend:latest
                       │
10. Cache       modified layers written back to the Actions cache
                       │
11. Runner      VM destroyed. Nothing survives except what was pushed
                       │
12. Deploy      docker compose pull  →  registry hands over the image
                       │
13. Runtime     docker compose up -d  →  containers running
```

**Step 11 is the one worth pausing on.** The runner is destroyed and the image survives only because it was pushed to a registry. That is the Day 39 point about jobs being separate machines, extended across time — the deploy might happen days later, on different infrastructure, and the registry is the only thing connecting them.

**Steps 8 and 12 are also where the Day 29–36 work pays off.** The pipeline is only this short because the Dockerfiles are already correct: multi-stage so the images are small enough to push quickly, layer-ordered so the cache actually hits, non-root so what ships is safe. A badly written Dockerfile makes every one of these steps slower.

What is still missing before this is a real CD pipeline: nothing tests the built image, nothing deploys it automatically, and nothing scans it for vulnerabilities. Days 48 and 49.

---

## Files in this folder

| Path | What it is |
|---|---|
| `.github/workflows/docker-publish.yml` | Matrix build of both DevBoard components, push only on main |

**Docker Hub:**
- `https://hub.docker.com/r/manishjha18/devboard-backend`
- `https://hub.docker.com/r/manishjha18/devboard-frontend`

---

## What I learned

**1. `push:` as an expression is what separates verification from side effects.** A PR builds the image and proves the Dockerfile works, but pushes nothing. One boolean expression gives full checking on every PR with zero risk of publishing untested images — or of leaking credentials to a fork.

**2. Two tags per image, for two different jobs.** `sha-8a3f91c` is immutable and identifies exactly one commit, which is the only thing a rollback can rely on. `latest` is a moving pointer for convenience. Deploying `latest` means not knowing what is running.

**3. The registry is the only thing that survives the runner.** The VM is destroyed after every job, so an image exists afterwards purely because it was pushed. That reframes the registry as the handoff point between CI and CD, not just storage.

**Two extras:**

- `cache-from: type=gha` cut the backend build from 1m24s to 38s, and it only works because the Dockerfile puts source copying last.
- Use a Docker Hub **access token**, not the account password. Revocable on its own and scoped to what CI needs.
