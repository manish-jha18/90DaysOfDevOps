# Day 48 – GitHub Actions Capstone: End-to-End CI/CD Pipeline

Everything from Days 40–47 assembled into one pipeline for **DevBoard** — React frontend, Go API, Postgres. Five workflow files in `.github/workflows/` in this folder.

---

## Task 1: The project

DevBoard is the app I have been building through the Docker days. It fits this exercise well because it is a genuine monorepo — two components in two languages, each with its own Dockerfile and its own test suite — so the pipeline has to handle more than one thing.

```
devboard/
├── backend/          Go API + Dockerfile + main_test.go
├── frontend/         React (Vite) + Dockerfile + vitest tests
├── docker-compose.yml
├── .env.example
└── .github/workflows/
```

Real tests already exist: `backend/main_test.go` (Go) and four `*.test.jsx` files (vitest). The pipeline runs those, not placeholders.

---

## Task 2: Reusable build and test

**`.github/workflows/reusable-build-test.yml`**

```yaml
name: Reusable Build and Test

on:
  workflow_call:
    inputs:
      go_version_file:
        required: false
        type: string
        default: backend/go.mod
      node_version:
        required: false
        type: string
        default: '20'
      run_tests:
        required: false
        type: boolean
        default: true
    outputs:
      test_result:
        value: ${{ jobs.build-test.outputs.test_result }}

permissions:
  contents: read

jobs:
  build-test:
    runs-on: ubuntu-latest
    outputs:
      test_result: ${{ steps.result.outputs.test_result }}
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version-file: ${{ inputs.go_version_file }}
          cache-dependency-path: backend/go.sum

      - uses: actions/setup-node@v4
        with:
          node-version: ${{ inputs.node_version }}
          cache: npm
          cache-dependency-path: frontend/package-lock.json

      - name: Install frontend dependencies
        run: npm ci --legacy-peer-deps
        working-directory: frontend

      - name: Build frontend
        run: npm run build
        working-directory: frontend

      - name: Build backend
        run: go build ./...
        working-directory: backend

      - name: Run frontend tests
        if: inputs.run_tests
        run: npm run test
        working-directory: frontend

      - name: Run backend tests
        if: inputs.run_tests
        run: go test -v ./...
        working-directory: backend

      - name: Record the result
        id: result
        if: always()
        run: |
          if [ "${{ job.status }}" = "success" ]; then
            echo "test_result=passed" >> "$GITHUB_OUTPUT"
          else
            echo "test_result=failed" >> "$GITHUB_OUTPUT"
          fi
```

**This workflow cannot deploy.** No Docker login, no registry credentials, no `secrets:` block at all. That is deliberate — a component that only builds and tests should not be able to ship anything, even by mistake.

**`if: inputs.run_tests`** with a boolean input works cleanly here because `workflow_call` inputs are genuinely typed, unlike the `workflow_dispatch` string problem from Day 41.

**`go-version-file: backend/go.mod`** takes the version from the project, so CI cannot drift from local development.

---

## Task 3: Reusable Docker build and push

**`.github/workflows/reusable-docker.yml`**

```yaml
    steps:
      - uses: actions/checkout@v4

      - name: Work out the image reference
        id: meta
        run: |
          IMAGE="${{ secrets.docker_username }}/devboard-${{ inputs.component }}"
          echo "image=$IMAGE" >> "$GITHUB_OUTPUT"
          echo "image_url=$IMAGE:${{ inputs.tag }}" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.docker_username }}
          password: ${{ secrets.docker_token }}

      - name: Build the image locally
        uses: docker/build-push-action@v5
        with:
          context: ./${{ inputs.component }}
          load: true
          tags: ${{ steps.meta.outputs.image_url }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Scan the image
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ${{ steps.meta.outputs.image_url }}
          format: table
          exit-code: '1'
          ignore-unfixed: true
          severity: CRITICAL,HIGH

      - name: Push only after the scan passed
        uses: docker/build-push-action@v5
        with:
          context: ./${{ inputs.component }}
          push: true
          tags: |
            ${{ steps.meta.outputs.image_url }}
            ${{ steps.meta.outputs.image }}:latest
          cache-from: type=gha
```

**The `load: true` then scan then push sequence is the part worth explaining** — it is the brownie-point task from the README, done properly.

`load: true` builds the image into the runner's local Docker daemon instead of pushing it. Trivy then scans that local image. Only if the scan exits 0 does the push step run. The second `build-push-action` is nearly instant because every layer is already in the cache.

The obvious alternative — push first, then scan — means a vulnerable image is already public by the time you find out. Anyone pulling `latest` in that window gets it. Scanning before pushing makes the gate real.

`ignore-unfixed: true` suppresses CVEs with no available patch. Without it the scan fails on things nobody can fix, and a gate that always fails gets disabled.

---

## Task 4: PR pipeline

**`.github/workflows/pr-pipeline.yml`**

```yaml
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize]

permissions:
  contents: read

jobs:
  build-test:
    uses: ./.github/workflows/reusable-build-test.yml
    with:
      run_tests: true

  dependency-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: critical

  pr-summary:
    runs-on: ubuntu-latest
    needs: [build-test, dependency-review]
    if: always()
    steps:
      - name: Summary
        run: |
          echo "PR checks for branch: ${{ github.head_ref }}"
          {
            echo "## PR Checks"
            echo "- branch: ${{ github.head_ref }}"
            echo "- tests: ${{ needs.build-test.outputs.test_result }}"
            echo "- dependency review: ${{ needs.dependency-review.result }}"
          } >> "$GITHUB_STEP_SUMMARY"
```

**No Docker job at all.** Not a disabled one, not one behind an `if:` — simply absent. The credentials are never referenced in this file, so a PR from a fork cannot reach them regardless of what it contains.

```
devops@testvm:~$ gh pr checks 5
NAME                              DESCRIPTION  ELAPSED  URL
build-test / build-test           Successful   1m18s    .../runs/48294118440
dependency-review                 Successful   14s      .../runs/48294118441
pr-summary                        Successful   6s       .../runs/48294122104
```

Tests ran, no image was built or pushed.

---

## Task 5: Main branch pipeline

**`.github/workflows/main-pipeline.yml`**

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build-test:
    uses: ./.github/workflows/reusable-build-test.yml
    with:
      run_tests: true

  tag:
    runs-on: ubuntu-latest
    needs: build-test
    outputs:
      sha_tag: ${{ steps.t.outputs.sha_tag }}
    steps:
      - id: t
        run: echo "sha_tag=sha-$(echo ${{ github.sha }} | cut -c1-7)" >> "$GITHUB_OUTPUT"

  docker-backend:
    needs: tag
    uses: ./.github/workflows/reusable-docker.yml
    with:
      component: backend
      tag: ${{ needs.tag.outputs.sha_tag }}
    secrets:
      docker_username: ${{ secrets.DOCKER_USERNAME }}
      docker_token: ${{ secrets.DOCKER_TOKEN }}

  docker-frontend:
    needs: tag
    uses: ./.github/workflows/reusable-docker.yml
    with:
      component: frontend
      tag: ${{ needs.tag.outputs.sha_tag }}
    secrets:
      docker_username: ${{ secrets.DOCKER_USERNAME }}
      docker_token: ${{ secrets.DOCKER_TOKEN }}

  deploy:
    runs-on: ubuntu-latest
    needs: [docker-backend, docker-frontend]
    environment: production
    steps:
      - name: Deploy
        run: |
          echo "  backend : ${{ needs.docker-backend.outputs.image_url }}"
          echo "  frontend: ${{ needs.docker-frontend.outputs.image_url }}"
```

**The separate `tag` job exists so the tag is computed exactly once.** Both Docker jobs receive the identical `sha-8a3f91c`. Computing it inside each job would work today and would produce mismatched tags the moment anything about the calculation changed — and a frontend and backend tagged differently is a genuinely confusing thing to debug at deploy time.

**`docker-backend` and `docker-frontend` run in parallel.** Both depend on `tag`, neither depends on the other.

**`environment: production`** ties the job to a GitHub Environment. With required reviewers configured under Settings → Environments, the job pauses:

```
devops@testvm:~$ gh run view 17212884733
* main Main Pipeline · 17212884733

JOBS
✓ build-test / build-test in 1m22s
✓ tag in 3s
✓ docker-backend / docker in 2m04s
✓ docker-frontend / docker in 2m41s
*  deploy  (waiting for approval)
```

Everything built, scanned and pushed, and the deploy is held. Approving it from the UI, or:

```
devops@testvm:~$ gh run view 17212884733
✓ deploy in 8s
  backend : manishjha18/devboard-backend:sha-8a3f91c
  frontend: manishjha18/devboard-frontend:sha-8a3f91c
```

This is the Day 39 distinction made concrete: with the approval gate it is **Continuous Delivery**; remove it and it is **Continuous Deployment**. One setting.

---

## Task 6: Scheduled health check

**`.github/workflows/health-check.yml`**

```yaml
on:
  schedule:
    - cron: '0 */12 * * *'
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Pull the latest published image
        run: docker pull ${{ secrets.DOCKER_USERNAME }}/devboard-backend:latest

      - name: Run it
        run: |
          docker run -d --name healthcheck -p 8080:8080 \
            ${{ secrets.DOCKER_USERNAME }}/devboard-backend:latest
          sleep 5

      - name: Curl the health endpoint
        id: probe
        run: |
          CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health || echo "000")
          echo "code=$CODE" >> "$GITHUB_OUTPUT"
          if [ "$CODE" = "200" ]; then
            echo "status=PASSED" >> "$GITHUB_OUTPUT"
          else
            echo "status=FAILED" >> "$GITHUB_OUTPUT"
          fi

      - name: Write the run summary
        if: always()
        run: |
          {
            echo "## Health Check Report"
            echo "- Image: ${{ secrets.DOCKER_USERNAME }}/devboard-backend:latest"
            echo "- HTTP status: ${{ steps.probe.outputs.code }}"
            echo "- Result: ${{ steps.probe.outputs.status }}"
            echo "- Time: $(date -u)"
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Clean up
        if: always()
        run: docker rm -f healthcheck || true

      - name: Fail the run if the probe failed
        if: steps.probe.outputs.status != 'PASSED'
        run: exit 1
```

`$GITHUB_STEP_SUMMARY` renders markdown on the run's summary page — a readable report instead of buried log lines:

> ## Health Check Report
> - Image: manishjha18/devboard-backend:latest
> - HTTP status: 200
> - Result: PASSED
> - Time: Sat Jul 25 12:00:14 UTC 2026

**`|| echo "000"`** on the curl matters. Without it, a connection refused makes curl exit non-zero, `bash -e` kills the step, and the summary and cleanup steps never run — so you get a failure with no report explaining it.

**The cleanup uses `if: always()`** so a failing probe still removes the container.

**The failure is a separate final step** rather than an `exit 1` inside the probe. That way the summary is written and the container removed *before* the job goes red. Ordering the "fail" last is a small pattern worth reusing.

This is genuinely useful: it proves the published image still starts and responds, catching a broken `latest` even during a quiet week with no commits. Its weakness is that it tests the image in isolation, not the deployed stack — the backend runs without Postgres, so `/health` only confirms the process is up.

---

## Task 7: Badges and architecture

```markdown
# DevBoard

![Main Pipeline](https://github.com/manish-jha18/devboard/actions/workflows/main-pipeline.yml/badge.svg)
![PR Pipeline](https://github.com/manish-jha18/devboard/actions/workflows/pr-pipeline.yml/badge.svg)
![Health Check](https://github.com/manish-jha18/devboard/actions/workflows/health-check.yml/badge.svg)
```

### Pipeline architecture

```
┌─ PULL REQUEST ─────────────────────────────────────────────────┐
│                                                                │
│  pull_request → main  (opened, synchronize)                    │
│                                                                │
│   ┌──────────────────────┐   ┌────────────────────┐            │
│   │ build-test           │   │ dependency-review  │  parallel  │
│   │ (reusable workflow)  │   │ fail on critical   │            │
│   │  build FE + BE       │   └─────────┬──────────┘            │
│   │  vitest + go test    │             │                       │
│   └──────────┬───────────┘             │                       │
│              └──────────┬──────────────┘                       │
│                         ▼                                      │
│                  ┌─────────────┐                               │
│                  │ pr-summary  │  → $GITHUB_STEP_SUMMARY       │
│                  └─────────────┘                               │
│                                                                │
│   NO Docker build. NO push. Credentials never referenced.      │
└────────────────────────────────────────────────────────────────┘

┌─ MAIN BRANCH ──────────────────────────────────────────────────┐
│                                                                │
│  push → main                                                   │
│         │                                                      │
│         ▼                                                      │
│   ┌──────────────────────┐                                     │
│   │ build-test           │  same reusable workflow as the PR   │
│   └──────────┬───────────┘                                     │
│              ▼                                                 │
│   ┌──────────────────────┐                                     │
│   │ tag  → sha-8a3f91c   │  computed ONCE                      │
│   └──────────┬───────────┘                                     │
│              ├────────────────────────┐                        │
│              ▼                        ▼                        │
│   ┌────────────────────┐   ┌────────────────────┐              │
│   │ docker-backend     │   │ docker-frontend    │   parallel   │
│   │  build (load)      │   │  build (load)      │              │
│   │  trivy scan  ◀─────┼───┼──── GATE           │              │
│   │  push if clean     │   │  push if clean     │              │
│   └─────────┬──────────┘   └─────────┬──────────┘              │
│             └───────────┬────────────┘                         │
│                         ▼                                      │
│                ┌──────────────────┐                            │
│                │ deploy           │  environment: production   │
│                │ ⏸ manual approval│                            │
│                └──────────────────┘                            │
└────────────────────────────────────────────────────────────────┘

┌─ SCHEDULED ────────────────────────────────────────────────────┐
│  cron '0 */12 * * *'  →  pull latest → run → curl /health      │
│                          → $GITHUB_STEP_SUMMARY → clean up     │
└────────────────────────────────────────────────────────────────┘
```

Three entry points, one shared build-and-test workflow, and the difference between them is entirely about **what is allowed to happen**, not about duplicated logic.

### What I would add next

**Deploy to a real environment.** The `deploy` job currently prints image names. Making it real means either the self-hosted runner from Day 42 running `docker compose pull && up -d`, or SSH to the target. Days 50+ replace this with Kubernetes.

**Staging before production.** Deploy to staging automatically, run smoke tests against it, then require approval for production. Right now there is one environment.

**Rollback.** Immutable SHA tags make this possible but nothing uses them yet. A `workflow_dispatch` taking a tag and redeploying it would turn a bad release into a two-minute fix — and Day 47's `repository_dispatch` means monitoring could trigger it automatically.

**Notifications.** A Slack message on a failed main-branch run. A red badge nobody looks at is not an alert.

**Concurrency control.** Two quick merges currently start two overlapping deploys. `concurrency: group: deploy, cancel-in-progress: false` would queue them.

**Test the deployed stack, not just the image.** The health check runs the backend alone. Bringing up `docker compose` and hitting the frontend would exercise the real path — which is what Day 49's DAST scan starts to do.

---

## Files in this folder

| Path | Role |
|---|---|
| `reusable-build-test.yml` | Build and test. No deploy capability |
| `reusable-docker.yml` | Build, scan, push one component |
| `pr-pipeline.yml` | PR entry point — verify only |
| `main-pipeline.yml` | Main entry point — full path to deploy |
| `health-check.yml` | Twelve-hourly probe of the published image |

**Docker Hub:** `manishjha18/devboard-backend`, `manishjha18/devboard-frontend`

---

## What I learned

**1. Scan between build and push, using `load: true`.** Building into the local daemon, scanning, then pushing only on a clean result is what makes the security gate real. Pushing first and scanning after means the vulnerable image is already public when you find out.

**2. The PR and main pipelines differ by what they can do, not by conditionals.** The PR pipeline has no Docker job and never references the credentials. A missing capability is a stronger guarantee than an `if:` that could be wrong.

**3. Compute shared values once, in their own job.** The `tag` job exists so both images carry the same SHA tag. It looks like unnecessary ceremony until you imagine a frontend and backend tagged differently in production.

**Two extras:**

- Put the "fail the run" step last, after the summary and cleanup, so those still execute.
- `environment: production` with required reviewers is the single switch between Continuous Delivery and Continuous Deployment.
