# Day 42 – Runners: GitHub-Hosted and Self-Hosted

Workflow files are in `.github/workflows/` in this folder.

---

## Task 1: GitHub-hosted runners

**`.github/workflows/os-matrix.yml`**

```yaml
name: Runner Info

on: workflow_dispatch

jobs:
  info:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - name: Who and where am I
        shell: bash
        run: |
          echo "OS       : ${{ runner.os }}"
          echo "Arch     : ${{ runner.arch }}"
          echo "Hostname : $(hostname)"
          echo "User     : $(whoami)"
          echo "Workdir  : $(pwd)"
```

`shell: bash` is doing real work here. Without it the Windows runner uses PowerShell, where `whoami` behaves differently and `$(pwd)` is not the same thing. Forcing bash means one script works on all three — Windows runners ship Git Bash for exactly this.

**Ubuntu:**
```
OS       : Linux
Arch     : X64
Hostname : fv-az1129-472
User     : runner
Workdir  : /home/runner/work/github-actions-practice/github-actions-practice
```

**Windows:**
```
OS       : Windows
Arch     : X64
Hostname : fv-az842-113
User     : runneradmin
Workdir  : /d/a/github-actions-practice/github-actions-practice
```

**macOS:**
```
OS       : macOS
Arch     : ARM64
Hostname : Mac-1721304551
User     : runner
Workdir  : /Users/runner/work/github-actions-practice/github-actions-practice
```

Three different machines, three different paths. Anything hardcoding `/home/runner` breaks on the other two — `${{ github.workspace }}` is the portable form.

The `fv-az...` hostnames give it away: these are **Azure VMs**. macOS is ARM64 now, since GitHub moved to Apple silicon.

Timings: Ubuntu 14s, Windows 48s, macOS 39s. Linux is not just cheaper, it starts faster.

### What is a GitHub-hosted runner, and who manages it?

A fresh virtual machine that GitHub creates for a single job and destroys afterwards. GitHub manages the hardware, the OS, the patching and the pre-installed software. I manage nothing.

Two consequences worth internalising:

**It is clean every time.** No leftover state from the previous run — which is exactly what makes CI trustworthy, and also why anything you want to keep has to become an artifact or be pushed to a registry.

**It is destroyed afterwards.** Nothing written to disk survives. That is a feature, not a limitation.

**Billing:** free for public repositories. Private repos get a monthly allowance, and minutes are multiplied — Linux ×1, Windows ×2, macOS ×10. A matrix across all three costs 13 minutes of quota for every minute of wall-clock time.

---

## Task 2: What is pre-installed

```
docker : Docker version 27.1.1, build 6312585
python : Python 3.12.3
node   : v20.15.1
git    : git version 2.45.2
go     : go version go1.22.5 linux/amd64
```

The `ubuntu-latest` image also carries Java, .NET, Ruby, PHP, the AWS and Azure CLIs, Terraform, kubectl, Helm, and several versions of most languages. GitHub publishes the full manifest at `actions/runner-images`, and the image itself is around 25 GB.

### Why does pre-installed software matter?

**Speed, mostly.** If Docker were not already there, every single run would spend two minutes installing it. Multiply by every push from every developer and it becomes the dominant cost of the pipeline.

**But it is also a trap.** A workflow that runs `python script.py` without `actions/setup-python` works — using whatever Python the image happens to ship. When GitHub bumps the image, that version changes underneath you and the build breaks with no code change.

This is why real workflows pin their toolchain explicitly:

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: '20'
```

The setup actions do not usually download anything — the version is already cached in the image and the action just puts it on the PATH. So you get pinning for free. It is the same lesson as Day 35's `FROM node:latest`: relying on the default means relying on something that moves.

DevBoard's own workflows go further and use `go-version-file: 'go.mod'`, so the CI version comes from the project itself and cannot drift.

---

## Task 3: Setting up a self-hosted runner

Registered a runner on my Ubuntu VM. GitHub generates the exact commands under **Settings → Actions → Runners → New self-hosted runner**, with a registration token embedded.

```
devops@testvm:~$ mkdir actions-runner && cd actions-runner

devops@testvm:~/actions-runner$ curl -o actions-runner-linux-x64-2.319.1.tar.gz -L \
    https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-linux-x64-2.319.1.tar.gz
  % Total    % Received % Xferd  Average Speed   Time
100  190M  100  190M    0     0  18.2M      0  0:00:10

devops@testvm:~/actions-runner$ tar xzf ./actions-runner-linux-x64-2.319.1.tar.gz

devops@testvm:~/actions-runner$ ./config.sh --url https://github.com/manish-jha18/github-actions-practice --token AXXXXXXXXXXXXXXXXXXXXXXXXX

--------------------------------------------------------------------------------
|        ____ _ _   _   _       _          _        _   _                      |
|       / ___(_) |_| | | |_   _| |__      / \   ___| |_(_) ___  _ __  ___      |
|      | |  _| | __| |_| | | | | '_ \    / _ \ / __| __| |/ _ \| '_ \/ __|     |
|      | |_| | | |_|  _  | |_| | |_) |  / ___ \ (__| |_| | (_) | | | \__ \     |
|       \____|_|\__|_| |_|\__,_|_.__/  /_/   \_\___|\__|_|\___/|_| |_|___/     |
|                                                                              |
|                       Self-hosted runner registration                        |
--------------------------------------------------------------------------------

# Authentication
√ Connected to GitHub

# Runner Registration
Enter the name of the runner group to add this runner to: [press Enter for Default]
Enter the name of runner: [press Enter for testvm] devboard-runner
This runner will have the following labels: 'self-hosted', 'Linux', 'X64'
Enter any additional labels (ex. label-1,label-2): [press Enter to skip] devboard-runner
√ Runner successfully added
√ Runner connection is good

# Runner settings
Enter name of work folder: [press Enter for _work]
√ Settings Saved.
```

Running it as a service, so it survives a reboot and a logout:

```
devops@testvm:~/actions-runner$ sudo ./svc.sh install
Creating launch runner in /etc/systemd/system/actions.runner.manish-jha18-github-actions-practice.devboard-runner.service
Run as user: devops
√ Created symlink /etc/systemd/system/multi-user.target.wants/...

devops@testvm:~/actions-runner$ sudo ./svc.sh start
√ Started

devops@testvm:~/actions-runner$ sudo ./svc.sh status
● actions.runner.manish-jha18-github-actions-practice.devboard-runner.service
     Loaded: loaded (/etc/systemd/system/...; enabled; vendor preset: enabled)
     Active: active (running) since Sat 2026-07-18 10:14:33 UTC; 12s ago
```

It is a systemd unit, which is Day 02 material showing up again. `./run.sh` runs it in the foreground and stops when the terminal closes; `svc.sh install` is what makes it persistent.

```
devops@testvm:~$ gh api repos/manish-jha18/github-actions-practice/actions/runners \
    --jq '.runners[] | "\(.name)  \(.status)  [\(.labels[].name)]"'
devboard-runner  online  [self-hosted]
devboard-runner  online  [Linux]
devboard-runner  online  [X64]
devboard-runner  online  [devboard-runner]
```

Green dot, **Idle** in the UI.

---

## Task 4: Using it

**`.github/workflows/self-hosted.yml`**

```yaml
jobs:
  on-my-machine:
    runs-on: [self-hosted, linux, devboard-runner]
    steps:
      - uses: actions/checkout@v4

      - name: Prove which machine this is
        run: |
          echo "Hostname : $(hostname)"
          echo "User     : $(whoami)"
          echo "Workdir  : $(pwd)"
          echo "Uptime   : $(uptime -p)"

      - name: Write a file that will survive the run
        run: |
          echo "written by run ${{ github.run_id }} at $(date -u)" \
            >> "$HOME/actions-proof.txt"
          cat "$HOME/actions-proof.txt"
```

```
Hostname : testvm
User     : devops
Workdir  : /home/devops/actions-runner/_work/github-actions-practice/github-actions-practice
Uptime   : up 4 hours, 22 minutes
```

**My hostname, my user, my uptime.** Not `fv-az1129-472` and not `runner`. The job genuinely ran on my VM.

Checking the machine after the run finished:

```
devops@testvm:~$ cat ~/actions-proof.txt
written by run 17208441209 at Sat Jul 18 10:31:02 UTC 2026

devops@testvm:~$ gh workflow run self-hosted.yml
devops@testvm:~$ sleep 20 && cat ~/actions-proof.txt
written by run 17208441209 at Sat Jul 18 10:31:02 UTC 2026
written by run 17208467744 at Sat Jul 18 10:34:18 UTC 2026
```

**The file persisted and the second run appended to it.** That is the fundamental difference — a hosted runner is destroyed after every job, a self-hosted runner is not.

Which cuts both ways. The workspace is not cleaned between runs either, so a build can succeed because of a file left behind by a previous run and then fail on a fresh machine. `actions/checkout` does clean the repo directory, but anything written outside it stays. That is a whole class of "works in CI, fails elsewhere" bug that hosted runners simply cannot have.

---

## Task 5: Labels

The runner automatically has `self-hosted`, `Linux` and `X64`. I added `devboard-runner` during setup.

```yaml
runs-on: [self-hosted, linux, devboard-runner]
```

An array means **AND** — the job needs a runner carrying *all* of those labels. Not "any of them", which is the natural first reading.

```
devops@testvm:~$ gh run view 17208467744
✓ main Self Hosted · 17208467744
JOBS
✓ on-my-machine in 6s
```

Picked up immediately.

Testing a label that does not exist:

```yaml
runs-on: [self-hosted, gpu]
```

```
devops@testvm:~$ gh run list --limit 1
STATUS   TITLE          WORKFLOW      BRANCH  EVENT              ID
*        Self Hosted    Self Hosted   main    workflow_dispatch  17208502117
```

**Queued indefinitely.** No error, no failure — it waits for a matching runner to appear. This is the confusing failure mode of self-hosted runners: a typo in a label produces a job that hangs forever rather than one that fails. A GitHub-hosted job with a bad `runs-on` fails immediately; a self-hosted one just sits there.

### Why labels matter with multiple runners

Once there is more than one runner, `runs-on: self-hosted` picks an arbitrary one, which is rarely what you want. Labels let you route work to the machine that can actually do it:

```yaml
runs-on: [self-hosted, linux, gpu]        # ML training
runs-on: [self-hosted, linux, arm64]      # ARM builds
runs-on: [self-hosted, linux, staging]    # deploy to staging
runs-on: [self-hosted, linux, production] # deploy to production
```

That last pair is the one that matters most. DevBoard's `deploy.yml` uses `runs-on: self-hosted` because there is exactly one runner and it lives on the staging box — the deploy has to run *on* the target to execute `docker compose up`. The moment a production runner is added, that unlabelled `runs-on` becomes a coin flip between staging and production. Labels are what stop a staging deploy going to production.

---

## Task 6: Comparison

| | GitHub-hosted | Self-hosted |
|---|---|---|
| **Who manages it?** | GitHub — hardware, OS, patching, pre-installed tools | Me. Provisioning, updates, disk space, the runner agent |
| **Cost** | Free for public repos; metered for private, with Linux ×1, Windows ×2, macOS ×10 | No GitHub charge, but I pay for the machine whether it is busy or idle |
| **Pre-installed tools** | Huge image — Docker, several language runtimes, cloud CLIs, ~25 GB | Only what I install. A bare VM has nothing |
| **State between runs** | None. Fresh VM every job, destroyed after | Everything persists. Faster caches, but state can leak between runs |
| **Speed** | ~10–30s to start; downloads dependencies every time | Starts instantly; warm Docker layer cache and package cache |
| **Network access** | Public internet only. Cannot reach a private VPC | Can sit inside my network and reach private databases and internal services |
| **Good for** | Open source, standard build and test, anything needing a clean environment | Deploys that must run on the target, special hardware, private-network access, very large builds |
| **Security concern** | Secrets exist briefly on a VM I do not control; GitHub is a trusted third party | **Never use on a public repo.** Anyone can open a PR, and `pull_request` workflows would execute their code on my machine — with persistent state, my network, and whatever credentials that machine holds |

That last cell is the one to take seriously. GitHub's own documentation warns against self-hosted runners on public repositories. A hosted runner is destroyed after a malicious PR runs; my VM is not.

Practical mitigations: keep self-hosted runners on private repos, or restrict which workflows can use them; require approval for PRs from first-time contributors; and run the runner as an unprivileged user on a machine that holds nothing else.

The common arrangement is both — hosted runners for build and test, a self-hosted runner only for the deploy step, which is exactly DevBoard's layout.

---

## Files in this folder

| Path | What it does |
|---|---|
| `.github/workflows/os-matrix.yml` | Same job on Ubuntu, Windows and macOS |
| `.github/workflows/self-hosted.yml` | Runs on my labelled runner, writes a file that persists |

---

## What I learned

**1. Hosted runners are destroyed; self-hosted runners are not.** My `actions-proof.txt` survived and the second run appended to it. That persistence is the speed advantage and the correctness hazard at the same time — a build can pass because of something left behind by an earlier run.

**2. A wrong label queues forever instead of failing.** `runs-on: [self-hosted, gpu]` with no GPU runner produced a job stuck in "queued" with no error. Worth knowing before spending twenty minutes wondering why nothing is happening.

**3. Self-hosted runners on public repos are a genuine security hole.** Any stranger's pull request would execute on my machine, with my network access and whatever state is lying around. This is the reason deploys use a self-hosted runner and everything else uses hosted ones.

**Two extras:**

- `runs-on: [a, b, c]` means AND, not OR. All labels must match.
- `shell: bash` makes one script work across Linux, Windows and macOS runners, since Windows runners ship Git Bash.
