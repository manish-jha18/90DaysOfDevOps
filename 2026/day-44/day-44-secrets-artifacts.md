# Day 44 – Secrets, Artifacts and Running Real Tests in CI

Four workflow files in this folder. This is the day the pipeline starts doing work that matters, using the DevBoard project's real test suites.

---

## Task 1: GitHub Secrets

Added via the CLI rather than the settings page:

```
devops@testvm:~$ gh secret set MY_SECRET_MESSAGE --body "this-is-the-secret-value"
✓ Set Actions secret MY_SECRET_MESSAGE for manish-jha18/github-actions-practice

devops@testvm:~$ gh secret list
NAME                 UPDATED
MY_SECRET_MESSAGE    less than a minute ago
```

Note what `gh secret list` shows — names and timestamps, never values. **Secrets are write-only.** Once set, nobody can read them back, including me. Losing the value means generating a new one.

**Checking a secret exists without revealing it:**

```yaml
- name: Check the secret exists without revealing it
  env:
    MSG: ${{ secrets.MY_SECRET_MESSAGE }}
  run: |
    if [ -n "$MSG" ]; then
      echo "The secret is set: true"
      echo "Length: ${#MSG} characters"
    else
      echo "The secret is set: false"
    fi
```

```
The secret is set: true
Length: 24 characters
```

**Printing it directly:**

```yaml
- run: echo "${{ secrets.MY_SECRET_MESSAGE }}"
```

```
Run echo "***"
***
```

GitHub **masks** it. Any exact match of a secret value in the log output is replaced with `***`, automatically.

### Why you should never print secrets in CI logs

Masking is a safety net, not a control. It fails in ways that are easy to trigger:

**Transformed values are not masked.** Base64-encode it, split it, print it one character at a time, and the mask does not match:

```yaml
- run: echo "${{ secrets.MY_SECRET_MESSAGE }}" | base64
```

```
dGhpcy1pcy10aGUtc2VjcmV0LXZhbHVl
```

Not masked, and trivially decoded. Worth knowing this is a real exfiltration route, not a hypothetical one.

**Multi-line secrets mask badly.** A private key or JSON blob is masked line by line, and lines that happen to be short or common may slip through.

**Logs are more public than they feel.** On a public repository anyone can read every workflow log. They are retained for 90 days, downloadable, and appear in forks. A secret printed once is a secret to be rotated.

**Errors leak too.** A tool that echoes its arguments on failure — `curl -v`, a stack trace including the connection string — can print a secret without you asking. That is not something masking reliably catches.

The rule I am taking: **use secrets, never display them.** Check length, check non-empty, but never print the value or anything derived from it.

---

## Task 2: Secrets as environment variables

```yaml
- name: Use a secret in a command without hardcoding it
  env:
    DOCKER_USERNAME: ${{ secrets.DOCKER_USERNAME }}
    DOCKER_TOKEN: ${{ secrets.DOCKER_TOKEN }}
  run: |
    echo "$DOCKER_TOKEN" | docker login -u "$DOCKER_USERNAME" --password-stdin
    echo "logged in as $DOCKER_USERNAME"
```

```
devops@testvm:~$ gh secret set DOCKER_USERNAME --body "manishjha18"
devops@testvm:~$ gh secret set DOCKER_TOKEN --body "dckr_pat_..."
✓ Set Actions secret DOCKER_TOKEN for manish-jha18/github-actions-practice
```

**`--password-stdin` rather than `-p "$TOKEN"`** for the reason Day 35 hinted at. A password on the command line appears in the process list, so anything running `ps aux` on the runner during that second can read it. Piping it through stdin avoids that. Docker warns about it explicitly:

```
WARNING! Using --password via the CLI is insecure. Use --password-stdin.
```

**`env:` rather than inline `${{ }}`** for the Day 43 injection reason. It also keeps the secret out of the rendered command shown in the log.

### Secrets vs variables

DevBoard's workflows use both, and the split is deliberate:

```yaml
username: ${{ vars.DOCKERHUB_USERNAME }}    # a variable - not sensitive
password: ${{ secrets.DOCKERHUB_TOKEN }}    # a secret
```

| | `secrets` | `vars` |
|---|---|---|
| Masked in logs | Yes | No |
| Readable after saving | No | Yes |
| For | Tokens, passwords, keys | Usernames, region names, image names |

A Docker Hub username is not a secret — it is on every image page. Making it a variable means it shows in logs, which is genuinely helpful when debugging. Treating everything as a secret makes logs unreadable and hides nothing worth hiding.

Scope order, narrowest wins: environment → repository → organisation.

---

## Task 3: Uploading artifacts

```yaml
- name: Generate a report
  run: |
    mkdir -p reports
    {
      echo "Build report"
      echo "============"
      echo "commit : ${{ github.sha }}"
      echo "branch : ${{ github.ref_name }}"
      echo "run    : ${{ github.run_id }}"
      echo "date   : $(date -u)"
    } > reports/build-report.txt

- name: Upload it
  uses: actions/upload-artifact@v4
  with:
    name: build-report
    path: reports/
    retention-days: 5
```

```
Run actions/upload-artifact@v4
With the provided path, there will be 1 file uploaded
Artifact build-report has been successfully uploaded!
Artifact download URL: https://github.com/.../artifacts/2891044733
```

```
devops@testvm:~$ gh run download 17209884412
devops@testvm:~$ cat build-report/build-report.txt
Build report
============
commit : 8a3f91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d
branch : main
run    : 17209884412
date   : Sun Jul 19 10:14:22 UTC 2026
```

Also downloadable as a zip from the run's summary page.

`retention-days: 5` matters more than it looks. The default is 90 days, and artifacts count against storage quota on private repos. A workflow uploading a 200 MB build on every push fills the quota quickly.

---

## Task 4: Artifacts between jobs

```yaml
  produce:
    steps:
      - ... generate the file ...
      - uses: actions/upload-artifact@v4
        with:
          name: build-report
          path: reports/

  consume:
    needs: produce
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: build-report
          path: incoming/
      - run: |
          ls -la incoming/
          cat incoming/build-report.txt
```

```
✓ produce in 8s
✓ consume in 6s
```

```
Run ls -la incoming/
total 12
drwxr-xr-x 2 runner docker 4096 Jul 19 10:22 .
-rw-r--r-- 1 runner docker  184 Jul 19 10:22 build-report.txt

Build report
============
commit : 8a3f91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d
```

The `consume` job has no `actions/checkout` at all — it does not need the repository, only the artifact. Its runner is a completely different machine that has never seen this code.

Two details worth noting: the artifact **name** is the handle, and `path:` on download is where to put it, which need not match where it came from. Also, `download-artifact@v4` cannot fetch an artifact from a job that is still running — v4 made artifacts immutable once uploaded, which is why `needs:` is required.

### When to use artifacts in a real pipeline

**Build once, deploy many.** Compile in one job, then deploy the identical binary to staging and production. Rebuilding for each environment means deploying something that was never tested.

**Test reports and coverage.** Especially with `if: always()`, so the report survives a failing test run — that is when you actually want it.

**Handing binaries to a release job.** Build the artefact, run security scans, attach it to a GitHub release.

**Debug output from a failed run.** Screenshots from failed browser tests, container logs, `docker compose logs` on a deploy failure.

**Artifacts versus a registry:** DevBoard pushes Docker images to Docker Hub rather than using artifacts, because the deploy runs on a self-hosted runner that pulls with `docker compose pull`. Artifacts only travel between jobs in the same run; a registry is durable and reachable from anywhere. Rough rule: artifacts for CI-internal handoffs, a registry for anything that outlives the run.

---

## Task 5: Real tests in CI

This runs the DevBoard project's actual test suites — Go tests on the backend, vitest on the frontend.

**`.github/workflows/real-tests.yml`**

```yaml
name: Real Tests

on:
  push:
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Check out the code
        uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version-file: backend/go.mod
          cache-dependency-path: backend/go.sum

      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
          cache-dependency-path: frontend/package-lock.json

      - name: Install frontend dependencies
        run: npm ci --legacy-peer-deps
        working-directory: frontend

      - name: Run frontend tests
        run: npm run test
        working-directory: frontend

      - name: Run backend tests
        run: go test -v ./...
        working-directory: backend

      - name: Save the test log as an artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: |
            frontend/coverage/
            backend/*.out
          if-no-files-found: ignore
```

```
Run go test -v ./...
=== RUN   TestEnvReturnsFallbackWhenUnset
--- PASS: TestEnvReturnsFallbackWhenUnset (0.00s)
=== RUN   TestEnvReturnsValueWhenSet
--- PASS: TestEnvReturnsValueWhenSet (0.00s)
PASS
ok      devboard/backend    0.004s

Run npm run test
 ✓ src/components/ui/Button.test.jsx (3 tests) 41ms
 ✓ src/components/ui/Badge.test.jsx (2 tests) 18ms
 ✓ src/components/tasks/TaskCard.test.jsx (4 tests) 62ms
 ✓ src/components/tasks/KanbanBoard.test.jsx (2 tests) 88ms

 Test Files  4 passed (4)
      Tests  11 passed (11)
```

**`working-directory:`** matters here because DevBoard is a monorepo — Go lives in `backend/`, Node in `frontend/`. Without it every command runs at the repo root and finds nothing.

**`go-version-file: backend/go.mod`** takes the Go version from the project instead of hardcoding it in the workflow. One place to change it, and CI cannot drift from local development.

**`npm ci` not `npm install`.** `ci` installs exactly what the lockfile says and fails if `package.json` and `package-lock.json` disagree. `install` may quietly resolve a different version, which defeats the point of testing in CI.

### Breaking it on purpose

```
devops@testvm:~$ cd backend && sed -i 's/want %q", got, "fallback"/want %q", got, "WRONG"/' main_test.go
```

```
Run go test -v ./...
=== RUN   TestEnvReturnsFallbackWhenUnset
    main_test.go:12: env() = "fallback", want "WRONG"
--- FAIL: TestEnvReturnsFallbackWhenUnset (0.00s)
FAIL
FAIL    devboard/backend    0.005s
##[error]Process completed with exit code 1.
```

```
devops@testvm:~$ gh run list --limit 1
STATUS  TITLE               WORKFLOW     BRANCH  EVENT  ID
X       Break a test        Real Tests   main    push   17210114887
```

Red, as it should be. Reverted the change and it went green again.

The artifact step still ran, because of `if: always()`. That is the whole reason for the flag.

---

## Task 6: Caching

`actions/setup-node@v4` with `cache: npm` handles this automatically, but doing it by hand shows what is happening.

**`.github/workflows/manual-cache.yml`**

```yaml
- name: Restore the npm cache
  uses: actions/cache@v4
  with:
    path: ~/.npm
    key: ${{ runner.os }}-npm-${{ hashFiles('frontend/package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-npm-
```

**First run:**

```
Cache not found for input keys: Linux-npm-9f2a5b8c1d4e7f0a3b6c9d2e5f8a1b4c
...
Run npm ci --legacy-peer-deps
added 412 packages in 38s
...
Cache saved with key: Linux-npm-9f2a5b8c1d4e7f0a3b6c9d2e5f8a1b4c
```

**Second run:**

```
Cache restored from key: Linux-npm-9f2a5b8c1d4e7f0a3b6c9d2e5f8a1b4c
...
Run npm ci --legacy-peer-deps
added 412 packages in 9s
```

**38 seconds down to 9.** On a pipeline that runs on every push, that adds up fast.

### What is cached, and where

**`~/.npm`, not `node_modules`.** That is npm's download cache — the tarballs it fetched from the registry. `npm ci` still runs and still deletes and recreates `node_modules`, but it installs from local files instead of the network.

Caching `node_modules` directly is tempting and usually wrong: it is platform-specific, it can hold stale native modules, and it means `npm ci` never validates the lockfile properly.

**Where it lives:** GitHub's own cache storage, not the runner. 10 GB per repository, least-recently-used eviction, and entries are deleted after 7 days without a hit.

**The key is the interesting part:**

```
key: ${{ runner.os }}-npm-${{ hashFiles('frontend/package-lock.json') }}
```

`hashFiles()` produces a hash of the lockfile. Change a dependency, the lockfile changes, the hash changes, and you get a **new cache entry** rather than a stale one. That is what makes it correct rather than merely fast.

`restore-keys:` is the fallback. On an exact miss it takes the newest entry starting with `Linux-npm-`, so a single new dependency still reuses the other 411 packages instead of downloading everything again.

`runner.os` in the key stops a Linux cache being restored on a Windows runner, which would be broken in confusing ways.

**A caveat:** caches are scoped by branch. A feature branch can read the default branch's cache but not another feature branch's. First run on a new branch is usually a partial hit via `restore-keys`.

---

## Files in this folder

| Path | Demonstrates |
|---|---|
| `.github/workflows/secrets.yml` | Using secrets without printing them, `--password-stdin` |
| `.github/workflows/artifacts.yml` | Upload in one job, download in another |
| `.github/workflows/real-tests.yml` | The real DevBoard Go and vitest suites, artifact with `if: always()` |
| `.github/workflows/manual-cache.yml` | `actions/cache` by hand, with `hashFiles` and `restore-keys` |

---

## What I learned

**1. Masking is a safety net, not a control.** GitHub replaces exact matches with `***`, but base64-encoding a secret prints it in full. Logs on a public repo are readable by anyone for 90 days. The rule is to use secrets and never display them, in any form.

**2. Cache the download cache, not the installed dependencies.** `~/.npm` is correct; `node_modules` is platform-specific and can go stale. The key must include a hash of the lockfile, or you get a fast build using the wrong dependencies — which is worse than a slow one.

**3. `if: always()` is what makes a test report useful.** The default `if: success()` means an artifact step is skipped exactly when the tests failed, which is when you needed the report.

**Three extras:**

- Secrets are write-only. `gh secret list` shows names and dates, never values.
- Not everything belongs in `secrets`. A Docker Hub username as a `var` shows in logs and is genuinely easier to debug.
- `npm ci` over `npm install` in CI — it installs exactly the lockfile and fails on a mismatch.
