# Day 40 – My First GitHub Actions Workflow

The workflow file is in `.github/workflows/hello.yml` in this folder. I built it in a separate `github-actions-practice` repo so the runs are isolated from my main work.

---

## Task 1: Set up

```
devops@testvm:~$ gh repo create github-actions-practice --public --clone
✓ Created repository manish-jha18/github-actions-practice on GitHub
Cloning into 'github-actions-practice'...

devops@testvm:~$ cd github-actions-practice
devops@testvm:~/github-actions-practice$ mkdir -p .github/workflows
```

The path is not optional. GitHub only looks in `.github/workflows/`, and the file must end in `.yml` or `.yaml`. A workflow in `.github/` or in `workflows/` is simply ignored, with no error and no warning — the Actions tab just stays empty.

---

## Task 2: The hello workflow

**`.github/workflows/hello.yml`** (first version)

```yaml
name: Hello Actions

on: push

jobs:
  greet:
    runs-on: ubuntu-latest
    steps:
      - name: Check out the code
        uses: actions/checkout@v4

      - name: Say hello
        run: echo "Hello from GitHub Actions!"
```

```
devops@testvm:~/github-actions-practice$ git add .github/workflows/hello.yml
devops@testvm:~/github-actions-practice$ git commit -m "Add first workflow"
devops@testvm:~/github-actions-practice$ git push
```

Watching it from the terminal rather than the browser, using what I learned on Day 26:

```
devops@testvm:~/github-actions-practice$ gh run list
STATUS  TITLE                WORKFLOW       BRANCH  EVENT  ID
✓       Add first workflow   Hello Actions  main    push   17204833901

devops@testvm:~/github-actions-practice$ gh run view 17204833901
✓ main Add first workflow · 17204833901
Triggered via push about 1 minute ago

JOBS
✓ greet in 4s (ID 48291047733)
```

Green on the first try, in four seconds.

```
devops@testvm:~/github-actions-practice$ gh run view 17204833901 --log | tail -12
greet	Say hello	##[group]Run echo "Hello from GitHub Actions!"
greet	Say hello	echo "Hello from GitHub Actions!"
greet	Say hello	shell: /usr/bin/bash -e {0}
greet	Say hello	##[endgroup]
greet	Say hello	Hello from GitHub Actions!
greet	Complete job	Cleaning up orphan processes
```

Reading the full log is worth doing once. There are steps I did not write — `Set up job`, `Complete job`, and the checkout action's own output. GitHub adds those around every run.

Something I noticed: the log shows `shell: /usr/bin/bash -e {0}`. The `-e` means exit on first error, from Day 18. So **any failing command in a `run:` step fails the whole step**, without needing `set -e` myself.

---

## Task 3: The anatomy

| Key | What it does |
|---|---|
| `name:` (top level) | The workflow's name in the Actions tab. Optional — the filename is used otherwise |
| `on:` | The trigger. What event causes this workflow to run |
| `jobs:` | A map of jobs. Each key is a job ID, and jobs run **in parallel** by default |
| `runs-on:` | Which runner executes this job — the OS image, or `self-hosted` |
| `steps:` | An ordered list. Steps run **in sequence**, sharing one filesystem |
| `uses:` | Run a pre-built action from the marketplace or another repo |
| `run:` | Run a shell command on the runner |
| `name:` (on a step) | The label shown in the log. Optional but makes failures far easier to find |

The two that took a moment:

**`jobs` are parallel, `steps` are sequential.** Two jobs run at the same time on different machines unless `needs:` says otherwise. Two steps run one after another on the same machine. This is the Day 39 isolation point, made concrete.

**`uses:` versus `run:`.** `run:` is a shell command. `uses:` pulls in someone else's packaged code. `actions/checkout@v4` is a real repository at `github.com/actions/checkout`, and `@v4` is a git tag.

**Why `actions/checkout` is needed at all:** the runner starts as a bare VM with no copy of my repository. Without that step there is nothing to build. My first instinct was that the code would already be there — it is not.

---

## Task 4: More steps

```yaml
name: Hello Actions

on: push

jobs:
  greet:
    runs-on: ubuntu-latest
    steps:
      - name: Check out the code
        uses: actions/checkout@v4

      - name: Say hello
        run: echo "Hello from GitHub Actions!"

      - name: Print the date and time
        run: date

      - name: Print the branch that triggered this run
        run: echo "Branch is ${{ github.ref_name }}"

      - name: List the files in the repo
        run: ls -la

      - name: Print the runner OS
        run: |
          echo "Runner OS   : $RUNNER_OS"
          echo "Runner arch : $RUNNER_ARCH"
          echo "Kernel      : $(uname -r)"
```

Output from the run:

```
Run date
Thu Jul 16 09:14:22 UTC 2026

Run echo "Branch is main"
Branch is main

Run ls -la
total 20
drwxr-xr-x 4 runner docker 4096 Jul 16 09:14 .
drwxr-xr-x 3 runner docker 4096 Jul 16 09:14 ..
drwxr-xr-x 8 runner docker 4096 Jul 16 09:14 .git
drwxr-xr-x 3 runner docker 4096 Jul 16 09:14 .github
-rw-r--r-- 1 runner docker   34 Jul 16 09:14 README.md

Run echo "Runner OS   : $RUNNER_OS"
Runner OS   : Linux
Runner arch : X64
Kernel      : 6.8.0-1014-azure
```

**Two different kinds of variable, and the difference matters.**

`${{ github.ref_name }}` is a **GitHub expression**. It is substituted *before* the shell ever sees the command — the runner writes the literal text `echo "Branch is main"` into a script file and runs that. It works in any key, not just `run:`.

`$RUNNER_OS` is an **environment variable**, read by the shell at runtime. It only works inside `run:`.

That distinction is not cosmetic. Because `${{ }}` is pasted in as raw text, putting untrusted input inside a `run:` step is a script injection risk — a branch name containing shell metacharacters would be executed. The safe pattern is to pass it through `env:` instead:

```yaml
- run: echo "Branch is $BRANCH"
  env:
    BRANCH: ${{ github.ref_name }}
```

Useful context variables:

| Expression | Value |
|---|---|
| `${{ github.ref_name }}` | Branch or tag name |
| `${{ github.sha }}` | Full commit SHA |
| `${{ github.actor }}` | Who triggered it |
| `${{ github.repository }}` | `owner/repo` |
| `${{ github.event_name }}` | `push`, `pull_request`, … |
| `${{ github.workspace }}` | Checkout directory on the runner |
| `${{ runner.os }}` | `Linux`, `Windows`, `macOS` |

The kernel says `azure` — GitHub-hosted runners are Azure VMs, freshly created for each job and destroyed after.

---

## Task 5: Breaking it on purpose

Added a step that fails:

```yaml
      - name: Break it on purpose
        run: exit 1

      - name: This should never run
        run: echo "unreachable"
```

```
devops@testvm:~/github-actions-practice$ gh run list --limit 1
STATUS  TITLE              WORKFLOW       BRANCH  EVENT  ID
X       Break it           Hello Actions  main    push   17205144208

devops@testvm:~/github-actions-practice$ gh run view 17205144208
X main Break it · 17205144208
Triggered via push about 1 minute ago

JOBS
X greet in 6s (ID 48291552104)
  ✓ Set up job
  ✓ Check out the code
  ✓ Say hello
  ✓ Print the date and time
  ✓ Print the branch that triggered this run
  ✓ List the files in the repo
  ✓ Print the runner OS
  X Break it on purpose
  - This should never run

ANNOTATIONS
X Process completed with exit code 1.
```

**What a failure looks like.** A red X on the run, and every step marked individually — green ticks up to the failure, a red X on the step that failed, and a dash on everything after it, meaning skipped.

The failing step stops the job. Steps after it do not run. That is the default and it is the sensible one — no point building an image from code that failed its tests.

**How to read the error:**

1. `gh run list` or the Actions tab — which run failed.
2. `gh run view <id>` — which **step** failed. The step names are the reason to bother naming them.
3. `gh run view <id> --log-failed` — the log from only the failed step, rather than scrolling through everything.

```
devops@testvm:~/github-actions-practice$ gh run view 17205144208 --log-failed
greet	Break it on purpose	##[group]Run exit 1
greet	Break it on purpose	exit 1
greet	Break it on purpose	shell: /usr/bin/bash -e {0}
greet	Break it on purpose	##[endgroup]
greet	Break it on purpose	##[error]Process completed with exit code 1.
```

`--log-failed` is the useful one. A real pipeline log is thousands of lines and this cuts straight to the part that broke.

Also worth knowing: **the exit code is what decides success.** `exit 1` fails; a misspelled command fails with 127 (Day 37's exit code table); a command that prints "ERROR" to the screen but exits 0 **passes**. A step can look wrong in the logs and still be green.

Removed the failing step, pushed again, back to green.

---

## Files in this folder

| Path | What it is |
|---|---|
| `.github/workflows/hello.yml` | The finished workflow after Task 4 |

---

## What I learned

**1. The runner starts empty.** `actions/checkout` is not boilerplate — without it the VM has no copy of the repository at all. A fresh Azure VM per job, destroyed afterwards, is also why nothing carries over between jobs.

**2. `${{ }}` and `$VAR` are resolved at different times.** GitHub expressions are pasted into the script as text before the shell runs; environment variables are read by the shell. That is why untrusted input inside `${{ }}` in a `run:` step is a script injection risk, and why passing it through `env:` is the safe pattern.

**3. Exit codes decide pass or fail, not output.** A step that prints errors but exits 0 is green. `bash -e` means the first failing command in a multi-line `run:` fails the step, so `set -e` is already done for me.

**Two extras:**

- `gh run view <id> --log-failed` goes straight to the broken step instead of the whole log.
- Naming steps is worth the extra line. `X Break it on purpose` in the job list beats `X Run exit 1`.
