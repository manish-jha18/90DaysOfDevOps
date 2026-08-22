# Day 41 – Triggers and Matrix Builds

Four workflow files in `.github/workflows/` in this folder, one per trigger type.

---

## Task 1: Pull request trigger

**`.github/workflows/pr-check.yml`**

```yaml
name: PR Check

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Check out the code
        uses: actions/checkout@v4

      - name: Announce the PR
        run: |
          echo "PR check running for branch: ${{ github.head_ref }}"
          echo "Merging into              : ${{ github.base_ref }}"
          echo "PR number                 : ${{ github.event.number }}"
          echo "Opened by                 : ${{ github.actor }}"
```

`branches: [main]` filters on the **target** branch, not the source. So a PR from `feature-x` into `main` triggers it; a PR into `develop` does not.

`types:` chooses which PR events count. The defaults are `opened`, `synchronize` and `reopened`, so writing them out changes nothing — but it makes the behaviour explicit, and `synchronize` is the one worth knowing: it fires on **every new commit pushed to an open PR**. That is what re-runs the checks as you address review comments.

```
devops@testvm:~/github-actions-practice$ git switch -c feature-triggers
devops@testvm:~/github-actions-practice$ echo "trigger test" >> README.md
devops@testvm:~/github-actions-practice$ git commit -am "Test the PR trigger"
devops@testvm:~/github-actions-practice$ git push -u origin feature-triggers

devops@testvm:~/github-actions-practice$ gh pr create --title "Test PR triggers" --body "Checking the pr-check workflow"
https://github.com/manish-jha18/github-actions-practice/pull/1
```

```
devops@testvm:~/github-actions-practice$ gh pr checks 1
NAME       DESCRIPTION  ELAPSED  URL
check      Successful   5s       https://github.com/.../runs/48292118440
```

It appears on the PR page under "All checks have passed". The workflow output:

```
PR check running for branch: feature-triggers
Merging into              : main
PR number                 : 1
Opened by                 : manish-jha18
```

**`github.head_ref` and `github.base_ref` only exist on pull request events.** On a push they are empty. `github.ref_name` from Day 40 is the general one, but on a PR it gives something like `1/merge` rather than the branch name, which is not what you want.

Pushing another commit to the branch:

```
devops@testvm:~/github-actions-practice$ git commit -am "Another commit" && git push
devops@testvm:~/github-actions-practice$ gh run list --limit 2
STATUS  TITLE            WORKFLOW   BRANCH            EVENT         ID
✓       Another commit   PR Check   feature-triggers  pull_request  17205992104
✓       Test PR triggers PR Check   feature-triggers  pull_request  17205881133
```

Ran again automatically — that is `synchronize`.

One thing that caught me: because the trigger is `pull_request` only, pushing to a branch with **no open PR** runs nothing at all. Most real repos use both:

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
```

Check every PR before merge, and check `main` after.

---

## Task 2: Scheduled trigger

**`.github/workflows/scheduled.yml`**

```yaml
name: Nightly Check

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

jobs:
  nightly:
    runs-on: ubuntu-latest
    steps:
      - name: Report
        run: |
          echo "Nightly run at $(date -u)"
          echo "Triggered by: ${{ github.event_name }}"
```

I added `workflow_dispatch` alongside the schedule so it can be tested immediately instead of waiting until midnight. Every scheduled workflow should have this — otherwise the feedback loop on a typo is 24 hours.

### Cron syntax

Same five fields as Day 19's crontab:

```
┌───────────── minute (0-59)
│ ┌─────────── hour (0-23)
│ │ ┌───────── day of month (1-31)
│ │ │ ┌─────── month (1-12)
│ │ │ │ ┌───── day of week (0-6, Sunday = 0)
│ │ │ │ │
* * * * *
```

| Expression | Means |
|---|---|
| `0 0 * * *` | Every day at midnight |
| `0 9 * * 1` | **Every Monday at 9 AM** — the Task 2 answer |
| `*/15 * * * *` | Every 15 minutes |
| `0 3 * * 1-5` | 3 AM on weekdays only |
| `0 0 1 * *` | Midnight on the first of the month |

**Three things about GitHub's cron that differ from a normal crontab:**

**It is always UTC.** No timezone setting exists. `0 9 * * 1` is 9 AM UTC, which is 2:30 PM in India. Working out the offset yourself is the only option.

**It is not punctual.** Scheduled runs are queued and can be delayed, sometimes by 10–30 minutes at busy times such as the top of the hour. Fine for a nightly build, useless for anything time-critical. Scheduling at `0 3` rather than `0 0` avoids the worst congestion.

**It gets disabled on inactive repos.** After 60 days with no commits, GitHub stops running scheduled workflows in public repos. A nightly job that silently stops after two quiet months is a real trap.

Scheduled runs always use the default branch, regardless of where the file was added.

---

## Task 3: Manual trigger with inputs

**`.github/workflows/manual.yml`**

```yaml
name: Manual Deploy

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Which environment to target'
        required: true
        default: 'staging'
        type: choice
        options:
          - staging
          - production
      dry_run:
        description: 'Print what would happen without doing it'
        required: false
        default: true
        type: boolean

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Show the inputs
        run: |
          echo "Environment : ${{ inputs.environment }}"
          echo "Dry run     : ${{ inputs.dry_run }}"
          echo "Started by  : ${{ github.actor }}"

      - name: Pretend to deploy
        if: ${{ inputs.dry_run == false }}
        run: echo "Deploying to ${{ inputs.environment }}..."

      - name: Dry run notice
        if: ${{ inputs.dry_run == true }}
        run: echo "Dry run - nothing was deployed."
```

`type: choice` renders a dropdown rather than a free text box, which removes a whole class of typo. `type: boolean` gives a checkbox.

Running it from the terminal:

```
devops@testvm:~/github-actions-practice$ gh workflow run manual.yml -f environment=production -f dry_run=false
✓ Created workflow_dispatch event for manual.yml at main

devops@testvm:~/github-actions-practice$ gh run list --workflow=manual.yml --limit 1
STATUS  TITLE           WORKFLOW       BRANCH  EVENT              ID
✓       Manual Deploy   Manual Deploy  main    workflow_dispatch  17206244871
```

Output:

```
Environment : production
Dry run     : false
Started by  : manish-jha18

Run echo "Deploying to production..."
Deploying to production...
```

The dry-run notice step was skipped, because its `if:` was false. In the UI it shows greyed out with a dash rather than being hidden.

With defaults:

```
devops@testvm:~/github-actions-practice$ gh workflow run manual.yml
Environment : staging
Dry run     : true
Dry run - nothing was deployed.
```

**One gotcha with boolean inputs:** they arrive as **strings** when triggered through the API or CLI, not real booleans. `${{ inputs.dry_run == false }}` works from the UI checkbox but can behave unexpectedly via `gh workflow run`. Comparing to the string is the safer form:

```yaml
if: ${{ inputs.dry_run == 'false' }}
```

Same class of bug as Day 38's `"true"` versus `true`.

`workflow_dispatch` only appears in the Actions tab once the file is on the **default branch**. Adding it on a feature branch and wondering why the Run workflow button is missing is a common first stumble.

---

## Task 4: Matrix builds

**`.github/workflows/matrix.yml`**

```yaml
name: Matrix Build

on:
  workflow_dispatch:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        python-version: ['3.10', '3.11', '3.12']
        os: [ubuntu-latest, windows-latest]
        exclude:
          - os: windows-latest
            python-version: '3.10'

    runs-on: ${{ matrix.os }}

    steps:
      - name: Check out the code
        uses: actions/checkout@v4

      - name: Set up Python ${{ matrix.python-version }}
        uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}

      - name: Print the version
        run: python --version

      - name: Show which combination this is
        run: echo "Running Python ${{ matrix.python-version }} on ${{ matrix.os }}"
```

**Note the quotes on `'3.10'`.** This is Day 38's lesson biting for real — unquoted, YAML reads `3.10` as a float and turns it into `3.1`, and `actions/setup-python` then fails looking for a version that does not exist. `'3.11'` would survive unquoted but quoting all of them keeps it consistent.

**Started with just the Python versions** — three jobs in parallel:

```
devops@testvm:~/github-actions-practice$ gh run view 17206481250
✓ main Matrix Build · 17206481250

JOBS
✓ test (3.10) in 18s
✓ test (3.11) in 17s
✓ test (3.12) in 19s
```

All three finished in about 19 seconds, not 54 — they ran at the same time on three separate runners. That is the whole point of a matrix.

**Adding the OS dimension:**

3 Python versions × 2 operating systems = **6 combinations**. Matrix dimensions multiply, they do not add.

```
JOBS
✓ test (ubuntu-latest, 3.10) in 18s
✓ test (ubuntu-latest, 3.11) in 17s
✓ test (ubuntu-latest, 3.12) in 19s
✓ test (windows-latest, 3.11) in 71s
✓ test (windows-latest, 3.12) in 68s
```

Five, because of the exclusion in Task 5.

Windows runners took about four times as long. They are slower to start and consume **2× the billing minutes** of Linux (macOS is 10×). A careless matrix gets expensive quickly.

---

## Task 5: Exclude and fail-fast

### Exclude

```yaml
exclude:
  - os: windows-latest
    python-version: '3.10'
```

Removes exactly that one combination, taking 6 down to 5. Useful when one pairing is unsupported or known-broken, and much cleaner than restructuring the whole matrix.

`include` does the opposite — adds a combination outside the grid, or adds an extra variable to specific ones:

```yaml
include:
  - os: ubuntu-latest
    python-version: '3.13'
    experimental: true
```

### fail-fast

**`fail-fast: true` is the default.** When any job in the matrix fails, GitHub **cancels every other job** immediately.

Made one combination fail on purpose:

```yaml
- name: Fail on one combination
  if: ${{ matrix.python-version == '3.11' }}
  run: exit 1
```

**With `fail-fast: true`:**

```
JOBS
X test (ubuntu-latest, 3.11) in 12s
- test (ubuntu-latest, 3.10)   (cancelled)
- test (ubuntu-latest, 3.12)   (cancelled)
- test (windows-latest, 3.11)  (cancelled)
- test (windows-latest, 3.12)  (cancelled)
```

One failure, everything else cancelled mid-run.

**With `fail-fast: false`:**

```
JOBS
X test (ubuntu-latest, 3.11) in 12s
✓ test (ubuntu-latest, 3.10) in 18s
✓ test (ubuntu-latest, 3.12) in 19s
X test (windows-latest, 3.11) in 64s
✓ test (windows-latest, 3.12) in 68s
```

Everything ran to completion. The run is still marked failed, but now I can see that **3.11 fails on both operating systems while 3.12 passes on both**. That tells me it is a Python version problem, not an OS problem.

### When to use which

| | Use |
|---|---|
| `fail-fast: true` (default) | Saving runner minutes matters more than full information. Big matrices, or paid runners |
| `fail-fast: false` | You want the complete picture of what passes and what fails |

For a test matrix I want `false`. Knowing "3.11 is broken everywhere" in one run beats fixing one failure, re-running, and discovering the next.

DevBoard's own workflows use `fail-fast: false` on both the Go linter matrix and the Docker build matrix — with only two or three combinations the extra minutes are trivial, and seeing whether the backend *and* frontend both fail is worth far more.

`max-parallel: 2` is the middle ground: run everything, but throttle how many at once.

---

## Files in this folder

| Path | Trigger |
|---|---|
| `.github/workflows/pr-check.yml` | `pull_request` into main |
| `.github/workflows/scheduled.yml` | `schedule` cron, plus manual |
| `.github/workflows/manual.yml` | `workflow_dispatch` with choice and boolean inputs |
| `.github/workflows/matrix.yml` | Matrix over 3 Python versions × 2 OSes, one excluded |

---

## What I learned

**1. Matrix dimensions multiply.** Three Python versions plus two operating systems is six jobs, not five. Easy to write a two-line change that quadruples your CI bill — especially since Windows costs 2× and macOS 10× the minutes of Linux.

**2. `fail-fast: false` is usually what you want for test matrices.** The default cancels every remaining job on the first failure, which hides whether the problem is one version or all of them. Letting them finish turned a single red X into a diagnosis.

**3. Quote version numbers in YAML.** `python-version: 3.10` becomes the float `3.1` and setup-python fails on a version that does not exist. Day 38's trap, met in the wild within two days.

**Three extras:**

- GitHub cron is always UTC, is often delayed by 10–30 minutes, and is auto-disabled after 60 days of inactivity on a public repo.
- `workflow_dispatch` only shows a Run button once the file is on the default branch.
- Boolean inputs arrive as strings via the CLI and API, so compare against `'false'` rather than `false`.
