# Day 47 – Advanced Triggers

Seven workflow files in `.github/workflows/` in this folder.

---

## Task 1: Pull request event types

**`.github/workflows/pr-lifecycle.yml`**

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  lifecycle:
    runs-on: ubuntu-latest
    steps:
      - name: Which event fired
        run: |
          echo "action       : ${{ github.event.action }}"
          echo "PR title     : ${{ github.event.pull_request.title }}"
          echo "PR author    : ${{ github.event.pull_request.user.login }}"
          echo "source branch: ${{ github.head_ref }}"
          echo "target branch: ${{ github.base_ref }}"
          echo "merged?      : ${{ github.event.pull_request.merged }}"

      - name: Only when the PR was actually merged
        if: github.event.action == 'closed' && github.event.pull_request.merged == true
        run: echo "PR #${{ github.event.number }} was MERGED into ${{ github.base_ref }}"

      - name: Closed without merging
        if: github.event.action == 'closed' && github.event.pull_request.merged == false
        run: echo "PR #${{ github.event.number }} was closed without merging"
```

Opening a PR, pushing to it, then merging:

```
devops@testvm:~$ gh run list --workflow=pr-lifecycle.yml --limit 3
STATUS  TITLE            WORKFLOW        BRANCH             EVENT         ID
✓       Test lifecycle   PR Lifecycle    feature/lifecycle  pull_request  17211882104
✓       Update the PR    PR Lifecycle    feature/lifecycle  pull_request  17211844733
✓       Test lifecycle   PR Lifecycle    feature/lifecycle  pull_request  17211802991
```

Three runs, one per event:

```
# opened
action       : opened
PR title     : Test the lifecycle workflow
PR author    : manish-jha18
source branch: feature/lifecycle
target branch: main
merged?      : false

# synchronize (pushed another commit)
action       : synchronize
merged?      : false

# closed, after merging
action       : closed
merged?      : true
PR #3 was MERGED into main
```

**`closed` fires whether the PR was merged or abandoned.** The only way to distinguish them is `github.event.pull_request.merged`, and that is exactly why the two conditional steps exist. Anything doing "on merge" cleanup — deleting a preview environment, posting to Slack — has to check that flag or it also fires when someone abandons a PR.

Other useful types: `ready_for_review` (draft PR marked ready), `labeled`, `assigned`, `edited`.

---

## Task 2: PR validation gate

**`.github/workflows/pr-checks.yml`** — three independent jobs running in parallel.

### File size check

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Fail on any file over 1 MB
        run: |
          LIMIT=1048576
          FAILED=0
          git diff --name-only --diff-filter=d \
            "origin/${{ github.base_ref }}...HEAD" > changed.txt
          while IFS= read -r f; do
            [ -f "$f" ] || continue
            SIZE=$(stat -c%s "$f")
            if [ "$SIZE" -gt "$LIMIT" ]; then
              echo "TOO BIG: $f ($((SIZE / 1024)) KB)"
              FAILED=1
            fi
          done < changed.txt
          if [ "$FAILED" -eq 1 ]; then
            echo "::error::One or more files exceed 1 MB"
            exit 1
          fi
          echo "All changed files are under 1 MB"
```

**`fetch-depth: 0` is required.** By default `actions/checkout` does a shallow clone with one commit, so `git diff` against the base branch has nothing to compare with. This is a very common CI stumble.

**Only checks files the PR touched**, using `origin/main...HEAD`. Scanning the whole repo would fail on a large file that was already there, which is not this PR's problem.

`--diff-filter=d` excludes deleted files — otherwise `stat` fails on a path that no longer exists.

### Branch name check

```yaml
      - name: Enforce the branch naming convention
        run: |
          BRANCH="${{ github.head_ref }}"
          case "$BRANCH" in
            feature/*|fix/*|docs/*)
              echo "Branch name is valid" ;;
            *)
              echo "::error::Branch must start with feature/, fix/ or docs/ (got '$BRANCH')"
              exit 1 ;;
          esac
```

Testing it from a badly named branch:

```
devops@testvm:~$ git switch -c my-random-branch
devops@testvm:~$ gh pr create --title "Bad branch name" --body "Testing"
```

```
X branch-name-check in 3s
##[error]Branch must start with feature/, fix/ or docs/ (got 'my-random-branch')
```

The PR page shows a red X and "Some checks were not successful". With branch protection requiring this check, the PR cannot be merged.

### PR body check

```yaml
      - name: Warn on an empty description
        env:
          BODY: ${{ github.event.pull_request.body }}
        run: |
          if [ -z "$BODY" ]; then
            echo "::warning::This PR has no description"
          else
            echo "PR description present (${#BODY} characters)"
          fi
```

**`::warning::` versus `::error::`** is the whole point of this job. A warning appears in the run summary and on the file in the diff view, but the job stays green. An error fails the step.

The distinction matters for adoption: a hard failure on an empty description annoys people into writing "." to get past it. A visible warning nudges without blocking.

Workflow commands worth knowing:

| Command | Effect |
|---|---|
| `::error::msg` | Red annotation, does **not** fail on its own — `exit 1` does |
| `::warning::msg` | Yellow annotation, job stays green |
| `::notice::msg` | Blue annotation |
| `::group::name` … `::endgroup::` | Collapsible log section |
| `::add-mask::value` | Mask a value in the logs from here on |

`::error::` printing red but not failing the step surprised me — the `exit 1` is doing the failing, the annotation is just the display.

---

## Task 3: Scheduled workflows

**`.github/workflows/scheduled-tasks.yml`**

```yaml
on:
  schedule:
    - cron: '30 2 * * 1'      # Mondays 02:30 UTC
    - cron: '0 */6 * * *'     # every 6 hours
  workflow_dispatch:

jobs:
  scheduled:
    runs-on: ubuntu-latest
    steps:
      - name: Which schedule triggered this
        run: |
          echo "event    : ${{ github.event_name }}"
          echo "schedule : ${{ github.event.schedule }}"
          if [ "${{ github.event.schedule }}" = "30 2 * * 1" ]; then
            echo "This is the weekly Monday run"
          elif [ "${{ github.event.schedule }}" = "0 */6 * * *" ]; then
            echo "This is the six-hourly run"
          else
            echo "Triggered manually"
          fi
```

**Two cron entries in one workflow**, and `github.event.schedule` says which one fired — it contains the literal cron string. That is how one workflow does a light six-hourly check and a heavier weekly one without duplicating the file.

### Cron answers

**Every weekday at 9 AM IST:**

IST is UTC+5:30, so 9:00 IST is **03:30 UTC**:

```
30 3 * * 1-5
```

The half-hour offset is the part that catches people. There is no timezone option — GitHub cron is always UTC, so the conversion has to be done by hand. And it does not follow daylight saving anywhere, so a workflow scheduled for someone's local 9 AM drifts by an hour twice a year in most countries. India has no DST, so this one is stable.

**First day of every month at midnight:**

```
0 0 1 * *
```

### Why scheduled workflows are delayed or skipped

**Delayed** because scheduled runs go into a shared queue across all of GitHub. The top of the hour, and `0 0 * * *` especially, are heavily contested — delays of 10 to 30 minutes are normal, and GitHub explicitly does not guarantee timing. Scheduling at `'7 3 * * *'` rather than `'0 0 * * *'` genuinely helps.

**Skipped** because GitHub disables scheduled workflows on public repositories after **60 days of no commit activity**. It sends an email first, but a nightly job that quietly stops after two quiet months is a real trap. Any commit resets the clock.

Two more rules: scheduled runs always execute on the **default branch** regardless of where the file was added; and a schedule only starts working once the file is on the default branch.

Adding `workflow_dispatch` alongside every schedule is a habit worth having — otherwise the feedback loop on a typo is a day.

---

## Task 4: Path and branch filters

**`.github/workflows/smart-triggers.yml`**

```yaml
on:
  push:
    branches:
      - main
      - 'release/*'
    paths:
      - 'backend/**'
      - 'frontend/**'
  pull_request:
    paths-ignore:
      - '**.md'
      - 'docs/**'
```

**`paths` and `paths-ignore` cannot both be used on the same trigger** — GitHub rejects the workflow. That is why the include-list is on `push` and the exclude-list on `pull_request`.

Testing the filter:

```
devops@testvm:~$ echo "docs change" >> README.md
devops@testvm:~$ git commit -am "Update README" && git push
devops@testvm:~$ gh run list --workflow=smart-triggers.yml --limit 1
STATUS  TITLE              WORKFLOW        BRANCH  EVENT  ID
✓       Add smart triggers Smart Triggers  main    push   17212104882
```

No new run. The README push matched neither `backend/**` nor `frontend/**`, so nothing was queued.

```
devops@testvm:~$ echo "// change" >> backend/main.go
devops@testvm:~$ git commit -am "Touch the backend" && git push
devops@testvm:~$ gh run list --workflow=smart-triggers.yml --limit 1
✓       Touch the backend  Smart Triggers  main    push   17212118440
```

Ran, as expected.

**Glob patterns:** `**` matches any depth including none, `*` matches within one path segment. `'backend/**'` covers `backend/main.go` and `backend/internal/db/pg.go`. `'*.md'` only matches at the root — `'**.md'` is needed for markdown anywhere.

### `paths` vs `paths-ignore`

**`paths`** — an allow-list. Use when a workflow cares about a specific area. In a monorepo, the backend test suite runs only on `backend/**`, the frontend suite only on `frontend/**`. Independent and cheap.

**`paths-ignore`** — a deny-list. Use when a workflow cares about almost everything, with a few exceptions. A full build should run for any code change but not for a typo fix in a README.

Rough rule: allow-list when the relevant set is small and well defined, deny-list when it is nearly everything.

**One serious caveat.** A skipped workflow reports **no status at all**, not a passing one. If that check is *required* by branch protection, the PR is blocked forever waiting for a check that will never run. The standard workaround is a companion workflow with the inverse filter that reports success immediately.

---

## Task 5: `workflow_run` — chaining workflows

**`.github/workflows/tests.yml`** — an ordinary workflow named `Run Tests`.

**`.github/workflows/deploy-after-tests.yml`**

```yaml
on:
  workflow_run:
    workflows: ["Run Tests"]
    types: [completed]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Check how the triggering run finished
        run: |
          echo "triggering workflow : ${{ github.event.workflow_run.name }}"
          echo "conclusion          : ${{ github.event.workflow_run.conclusion }}"
          echo "head branch         : ${{ github.event.workflow_run.head_branch }}"

      - name: Stop if the tests failed
        if: github.event.workflow_run.conclusion != 'success'
        run: |
          echo "::warning::Tests did not succeed - skipping deploy"
          exit 1

      - name: Deploy
        if: github.event.workflow_run.conclusion == 'success'
        run: echo "Deploying commit ${{ github.event.workflow_run.head_sha }}"
```

```
devops@testvm:~$ git commit -am "Trigger the chain" && git push
devops@testvm:~$ gh run list --limit 2
STATUS  TITLE               WORKFLOW             BRANCH  EVENT         ID
✓       Trigger the chain   Deploy After Tests   main    workflow_run  17212244871
✓       Trigger the chain   Run Tests            main    push          17212233104
```

Two runs. The push triggered `Run Tests`, and its completion triggered `Deploy After Tests`.

**`types: [completed]` means completed, not succeeded.** The second workflow fires whether the first passed or failed, which is why the conditional check is mandatory. Without it, a failing test suite would still deploy — the exact opposite of the intent. This caught me out on the first attempt.

**`workflows: ["Run Tests"]` matches the `name:` field**, not the filename. Renaming a workflow silently breaks every `workflow_run` pointing at it, with no error anywhere.

### `workflow_run` vs `workflow_call`

The names are similar and the mechanisms are completely different.

**`workflow_call`** is a **function call**. The caller invokes the reusable workflow as one of its own jobs, they appear in a single run, the caller can pass inputs and read outputs, and it is synchronous.

**`workflow_run`** is an **event listener**. Workflow B watches for workflow A finishing and starts a **separate run**. No inputs, no outputs — only what is in the `workflow_run` event payload. Asynchronous, and the two are only connected by name.

| | `workflow_call` | `workflow_run` |
|---|---|---|
| Same run? | Yes, jobs nested under the caller | No, two separate runs |
| Pass inputs? | Yes | No |
| Read outputs? | Yes | No — artifacts or the payload only |
| Knows if the other failed? | Yes, `needs.<job>.result` | Yes, `workflow_run.conclusion` |
| Runs on a fork PR? | Follows the caller | Runs with **write** permissions in the base repo |

**That last row is a genuine security concern.** `workflow_run` executes in the context of the base repository with access to secrets, even when triggered by a fork's pull request. It exists so that PR workflows can do privileged things safely — but checking out and running the PR's code inside a `workflow_run` handler is a known attack pattern that hands a stranger your secrets.

**When to use which:** `workflow_call` almost always — it is simpler, synchronous and passes data. `workflow_run` when you genuinely cannot use `workflow_call`: reacting to a workflow in another repository, or doing something privileged after an untrusted PR build.

---

## Task 6: `repository_dispatch` — external triggers

**`.github/workflows/external-trigger.yml`**

```yaml
on:
  repository_dispatch:
    types: [deploy-request]

jobs:
  handle:
    runs-on: ubuntu-latest
    steps:
      - name: Read the payload the caller sent
        run: |
          echo "event type  : ${{ github.event.action }}"
          echo "environment : ${{ github.event.client_payload.environment }}"
          echo "requested by: ${{ github.event.client_payload.requested_by }}"

      - name: Refuse an unknown environment
        run: |
          ENV="${{ github.event.client_payload.environment }}"
          case "$ENV" in
            staging|production) echo "Deploying to $ENV" ;;
            *) echo "::error::Unknown environment '$ENV'"; exit 1 ;;
          esac
```

```
devops@testvm:~$ gh api repos/manish-jha18/github-actions-practice/dispatches \
    --input - <<< '{"event_type":"deploy-request","client_payload":{"environment":"production","requested_by":"manish"}}'

devops@testvm:~$ gh run list --workflow=external-trigger.yml --limit 1
STATUS  TITLE              WORKFLOW           BRANCH  EVENT                  ID
✓       External Trigger   External Trigger   main    repository_dispatch    17212388104
```

```
event type  : deploy-request
environment : production
requested by: manish
Deploying to production
```

The `types:` filter means one workflow can respond to `deploy-request` while another handles `rebuild-docs`, both through the same API endpoint.

`client_payload` is arbitrary JSON — up to 10 top-level properties.

Note the payload is **untrusted input from outside GitHub**. The validation step is not decoration: without it, an arbitrary string would flow into a deploy command. Same reasoning as Day 43's commit message, and the reason it goes through a `case` rather than straight into a shell command.

### When would an external system trigger a pipeline?

**A ChatOps bot.** Someone types `/deploy staging` in Slack, the bot calls the dispatch API, the pipeline runs. Deploys become visible and auditable in a channel instead of happening on someone's laptop.

**A monitoring tool reacting to an incident.** Prometheus alerts on high error rates, Alertmanager fires a webhook, the pipeline rolls back to the previous image tag. Day 45's immutable SHA tags are what make an automated rollback possible.

**A cross-repository dependency.** A shared library repo publishes a new version and dispatches to every consuming repo to rebuild and test against it.

**A CMS or external content system.** Content is published in a headless CMS, a webhook triggers a static site rebuild and deploy.

**An external scheduler.** When GitHub's cron is too imprecise or its 60-day inactivity rule is a problem, an external scheduler dispatches on an exact cadence.

The common thread: something outside GitHub knows it is time to run the pipeline. `repository_dispatch` is the front door.

A PAT with `repo` scope is required — the default `GITHUB_TOKEN` cannot dispatch, which is deliberate, since it prevents a workflow from triggering itself in a loop.

---

## Files in this folder

| Path | Trigger |
|---|---|
| `pr-lifecycle.yml` | `pull_request` — opened, synchronize, reopened, closed |
| `pr-checks.yml` | PR gate: file size, branch name, PR body |
| `scheduled-tasks.yml` | Two cron schedules plus manual |
| `smart-triggers.yml` | `paths`, `paths-ignore`, branch filters |
| `tests.yml` | Ordinary push workflow, named "Run Tests" |
| `deploy-after-tests.yml` | `workflow_run` chained off it |
| `external-trigger.yml` | `repository_dispatch` |

---

## What I learned

**1. `workflow_run: types: [completed]` means finished, not succeeded.** My first version would have deployed after a failing test run. Checking `workflow_run.conclusion == 'success'` is not optional — the trigger fires either way.

**2. A skipped workflow reports no status, which can block a PR forever.** Path filters look free until one of the filtered workflows is a required check. The PR then waits for a check that will never report.

**3. `::error::` prints red but does not fail anything.** The `exit 1` fails the step; the annotation is presentation. Understanding the split is what makes the warning-versus-error choice in the PR body check deliberate rather than accidental.

**Three extras:**

- `fetch-depth: 0` is required for any `git diff` against the base branch — the default checkout is shallow.
- GitHub cron is UTC with no DST handling, and 9 AM IST is `30 3 * * 1-5`. The half-hour offset is easy to get wrong.
- `workflow_run` runs with write permissions in the base repo even for fork PRs, which is exactly why checking out untrusted PR code inside one is dangerous.
