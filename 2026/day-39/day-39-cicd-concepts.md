# Day 39 – What is CI/CD?

Concepts day. No pipelines yet, but I have my own project — **DevBoard**, a React frontend, Go API and Postgres database — to reason about instead of a hypothetical one.

---

## Task 1: The problem

### What can go wrong with five developers deploying manually?

**Integration debt.** Everyone works on their own branch for a week. Each branch is fine in isolation. Merging them at the end produces conflicts nobody can untangle, and the longer the branches live the worse it gets — the pain grows faster than the number of days.

**Nobody knows if `main` works.** Without an automatic build on every push, `main` is broken from the moment someone merges something untested until the next person happens to notice. In DevBoard's case a Go compile error in the backend would sit there silently until someone tried to build it.

**Deployments depend on one person's memory.** Steps like "build the frontend, build the backend, copy the `.env`, restart in the right order, wait for Postgres" work fine when the person who wrote them is doing them. When that person is on holiday, they do not.

**Every deploy is different.** Someone forgets to rebuild the frontend. Someone deploys from a branch. Someone skips the tests because it is late. Nothing records what actually happened, so a broken production has no obvious cause.

**No rollback.** Manual deploys usually overwrite. When it breaks at 6pm on a Friday, "go back to the previous version" means rebuilding from an older commit and hoping.

**Nobody wants to deploy.** Deploys become scary, so they get batched up. Bigger batches mean more risk, which makes them scarier still. That loop is the actual disease; the tooling is just the symptom.

### "It works on my machine"

It means the code depends on something present on the developer's machine that is not present anywhere else. A Go version, a Node version, an environment variable, a running Postgres, a file created by hand months ago.

It is a real problem because the developer's machine is not what serves users. If the code only works there, it does not work.

Containers fix a large part of it — DevBoard's frontend and backend both build into images, so the runtime is identical everywhere. But the **build** can still differ: my laptop has Go 1.23 and Node 20 with a warm npm cache, while a clean machine may resolve dependencies differently. CI closes that gap by building on a fresh runner every time, with no history and no local state.

### How many times a day can a team deploy manually?

Realistically **once or twice**, and it is a bad idea.

Each manual deploy is 20–40 minutes of somebody's careful attention, and the risk per deploy is constant because a human runs the steps. Doing it five times a day means five chances to skip a step while tired.

So manual deploys push teams towards batching, and a batch of thirty changes that breaks gives you thirty suspects. Automated pipelines invert this: deploy one small change at a time, and when something breaks you already know what caused it.

---

## Task 2: CI vs CD vs CD

### Continuous Integration

Every developer merges into a shared branch frequently — at least daily — and each merge automatically triggers a build and a test run. It catches compile errors, failing tests, lint violations and merge conflicts within minutes of the change being made.

The point is the **frequency**. Integrating daily means conflicts are small. Integrating monthly means they are enormous.

**Real example:** I push a change to DevBoard's Go backend. GitHub Actions checks out the code, runs `go vet`, `go test` in `backend/` and `npm run lint` and `npm run test` in `frontend/`. If any fails, I know in about two minutes — before anyone else pulls it.

### Continuous Delivery

CI plus everything needed to make the build **releasable**. The pipeline builds the artefact, tests it, and puts it somewhere a deploy could pull it from — but the final push to production is a human decision.

The difference from CI: CI proves the code is good, delivery proves it is *shippable* and keeps it permanently ready.

**Real example:** after DevBoard's tests pass, the pipeline builds both Docker images and pushes them to Docker Hub as `manishjha18/devboard-backend:latest` and `manishjha18/devboard-frontend:latest`. They are ready to deploy. Deploying them is a separate, deliberate step.

### Continuous Deployment

The same as delivery with the manual gate removed. Every commit that passes the pipeline goes to production automatically. No human clicks anything.

**Real example:** the DevBoard `deploy` job runs automatically after the images are pushed — it logs in to Docker Hub on a self-hosted runner, pulls the new images and runs `docker compose up -d`. Merging to `master` puts the change live.

Teams do this when their test coverage is genuinely trusted and changes are small enough that an automatic rollback is a real option. It requires the most confidence and gives the fastest feedback.

### The distinction in one line

```
CI                    build + test on every commit
Continuous Delivery   ... + always ready to release   (human approves the release)
Continuous Deployment ... + released automatically    (no human in the loop)
```

Both CDs abbreviate to "CD", which is why the term is ambiguous in conversation. Delivery is the common one; deployment is the ambitious one.

---

## Task 3: Pipeline anatomy

| Part | What it does |
|---|---|
| **Trigger** | The event that starts a run — a push, a pull request, a schedule, a manual click |
| **Stage** | A logical phase such as build, test or deploy. Groups related work and usually gates what comes after |
| **Job** | A unit of work inside a stage, running on its own runner. Jobs run in parallel unless told otherwise |
| **Step** | A single command or action inside a job. Steps run in order and share the same filesystem |
| **Runner** | The machine executing a job — a GitHub-hosted VM, or your own server |
| **Artifact** | Output produced by a job: a compiled binary, a Docker image, a test report. How one job hands work to the next |

The distinction that took a moment to settle: **jobs are isolated, steps are not.**

Two steps in the same job share a working directory, so step 2 can use the file step 1 created. Two jobs run on different machines with nothing in common — which is why passing anything between them needs an artifact or a registry. That is exactly why DevBoard's pipeline pushes images to Docker Hub before the deploy job: the deploy runs on a different machine and cannot see the build job's disk.

"Stage" is not a GitHub Actions keyword. It expresses the same thing with `needs:`, which makes one job wait for another.

---

## Task 4: Pipeline diagram

The scenario: a developer pushes, the app is tested, built into a Docker image, and deployed to staging. This is DevBoard's actual shape.

```
   developer
       │  git push origin master
       ▼
┌──────────────────────────────────────────────────────────────┐
│  TRIGGER   on: push: branches: [master]                      │
└──────────────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────────┐
│  STAGE 1 — VERIFY            (jobs run in parallel)          │
│                                                              │
│   ┌────────────────┐  ┌────────────────┐  ┌───────────────┐  │
│   │ code-quality   │  │ code-tests     │  │ secret-scan   │  │
│   │ eslint, go vet │  │ vitest, go test│  │ gitleaks      │  │
│   │ ubuntu-latest  │  │ ubuntu-latest  │  │ ubuntu-latest │  │
│   └────────┬───────┘  └────────┬───────┘  └───────┬───────┘  │
└────────────┼───────────────────┼──────────────────┼──────────┘
             └───────────────────┼──────────────────┘
                                 │  all must pass  (needs:)
                                 ▼
┌──────────────────────────────────────────────────────────────┐
│  STAGE 2 — BUILD                                             │
│                                                              │
│   ┌────────────────────────────────────────────────────┐     │
│   │ docker-push   (matrix: backend, frontend)          │     │
│   │  1. checkout                                       │     │
│   │  2. docker login                                   │     │
│   │  3. build image                                    │     │
│   │  4. push  ──────────▶  ARTIFACT: Docker Hub        │     │
│   │       manishjha18/devboard-backend:latest          │     │
│   │       manishjha18/devboard-frontend:latest         │     │
│   └────────────────────────┬───────────────────────────┘     │
└────────────────────────────┼─────────────────────────────────┘
                             │  needs: [docker-push]
                             ▼
┌──────────────────────────────────────────────────────────────┐
│  STAGE 3 — DEPLOY                                            │
│                                                              │
│   ┌────────────────────────────────────────────────────┐     │
│   │ deploy        runs-on: self-hosted  (staging EC2)  │     │
│   │  1. checkout                                       │     │
│   │  2. cp .env.example .env                           │     │
│   │  3. docker login                                   │     │
│   │  4. docker compose pull   ◀── pulls the artifacts  │     │
│   │  5. docker compose up -d                           │     │
│   └────────────────────────┬───────────────────────────┘     │
└────────────────────────────┼─────────────────────────────────┘
                             ▼
                   staging: frontend :8080
                            backend  :8081
                            postgres :5432
```

**Why it is shaped this way:**

- **Stage 1 runs three jobs in parallel** because they are independent. Total time is the slowest job, not the sum. Running them in sequence would triple the wait for no benefit.
- **Stage 2 waits for all of stage 1.** No point building an image from code that fails its tests.
- **Docker Hub is the handoff.** The build job and the deploy job are different machines, so the registry is what carries the artefact between them.
- **Deploy runs on a self-hosted runner** because it needs to be *on* the staging server to run `docker compose up`. A GitHub-hosted runner is a throwaway VM with no access to my infrastructure.

---

## Task 5: A workflow in the wild

Looked at **`cli/cli`** — the GitHub CLI, the tool I have been using since Day 26.

```
devops@testvm:~$ gh api repos/cli/cli/contents/.github/workflows --jq '.[].name'
codeql.yml
deployment.yml
go.yml
govulncheck.yml
lint.yml
...
```

Opened `lint.yml`:

```yaml
name: Lint
on:
  push:
    branches:
      - trunk
    paths:
      - "**.go"
      - go.mod
      - go.sum
      - ".github/workflows/lint.yml"
  pull_request:
    paths:
      - "**.go"
      - go.mod
      - go.sum
permissions:
  contents: read
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Check out code
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Set up Go
        uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e # v7.0.0
        with:
          go-version-file: 'go.mod'

      - name: Ensure go.mod and go.sum are up to date
        run: |
          ...
```

**What triggers it?** A push to `trunk`, or any pull request — but only when a `.go` file, `go.mod`, `go.sum` or the workflow itself changed.

**How many jobs?** One, called `lint`.

**What does it do?** Checks out the code, installs Go using the version from `go.mod`, then verifies `go.mod` and `go.sum` are tidy and runs the linter.

**Three things I would not have thought of:**

**1. The `paths:` filter.** The workflow does not run when only documentation changes. On a repo this busy that saves an enormous amount of runner time, and it keeps the PR checks relevant to what actually changed.

**2. Actions pinned to a commit SHA**, not a tag:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

A tag like `@v7` is mutable — whoever owns the action can move it. A SHA cannot be moved. Since an action runs arbitrary code with access to your repository, a compromised action is a supply chain attack, and this is the defence. The trailing comment keeps it readable. My own workflows use `@v7`, which is the common trade-off between safety and convenience.

**3. `permissions: contents: read`.** The default `GITHUB_TOKEN` can write to the repo. This workflow only needs to read, so it drops everything else. Least privilege, applied to CI.

**`go-version-file: 'go.mod'`** is also neat — the Go version comes from the project rather than being duplicated in the workflow, so it cannot drift.

---

## What I learned

**1. The real problem CI/CD solves is batch size, not typing.** Manual deploys are slow and risky, so teams do them rarely, so each one carries more change, so they are riskier still. Automation breaks the loop by making a deploy small and boring. The time saved on commands is almost incidental.

**2. Jobs are isolated; steps are not.** Steps in one job share a filesystem, jobs do not — they are separate machines. That single fact explains why DevBoard pushes to Docker Hub between building and deploying, and why artifacts exist at all.

**3. The three terms differ only in where the human is.** CI stops at "the code is good". Delivery adds "and it is ready to ship". Deployment removes the approval step. Same pipeline, different amount of trust.

**Two extras from reading real workflows:**

- `paths:` filters stop a workflow running for changes it does not care about. Free speed on a busy repo.
- Pinning actions to a commit SHA rather than a tag closes a genuine supply chain hole, since a tag can be moved by whoever owns the action.
