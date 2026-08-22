# Day 49 – DevSecOps: Security in the Pipeline

Two workflow files in this folder: `security.yml` gathers the checks, `devsecops.yml` wires them into Day 48's pipeline as blocking gates.

---

## What DevSecOps means

Security checks running automatically in the pipeline, on every change, instead of being a separate review that happens later. The same idea as automated testing — a machine checks every commit so nobody has to remember to.

The practical shift is **when** a problem is found. A vulnerable dependency caught in a pull request costs five minutes: bump the version, push again. The same dependency found in production costs an incident, a hotfix and a postmortem. Nothing about the fix changed — only the cost of finding it late.

It is not a separate process or a separate team. It is a few more jobs in the pipeline that already exists.

---

## Task 1: Scanning the Docker image

Day 48 already positions the scan correctly — build with `load: true`, scan, push only if clean:

```yaml
      - name: Build the image locally
        uses: docker/build-push-action@v5
        with:
          context: ./${{ inputs.component }}
          load: true
          tags: ${{ steps.meta.outputs.image_url }}

      - name: Scan the image
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ${{ steps.meta.outputs.image_url }}
          format: table
          exit-code: '1'
          ignore-unfixed: true
          vuln-type: os,library
          severity: CRITICAL,HIGH

      - name: Push only after the scan passed
        uses: docker/build-push-action@v5
        with:
          push: true
```

### The first run failed

```
devops@testvm:~$ gh run view 17213144882 --log-failed | tail -20

manishjha18/devboard-frontend:sha-8a3f91c (debian 12.6)
======================================================
Total: 3 (HIGH: 2, CRITICAL: 1)

┌────────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│    Library     │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
├────────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ libexpat1      │ CVE-2024-45491 │ CRITICAL │ fixed  │ 2.5.0-1           │ 2.5.0-1+deb12 │
│ libssl3        │ CVE-2024-5535  │ HIGH     │ fixed  │ 3.0.11-1~deb12u2  │ 3.0.13-1~deb1 │
│ zlib1g         │ CVE-2023-45853 │ HIGH     │ fixed  │ 1:1.2.13.dfsg-1   │ 1:1.2.13.dfsg │
└────────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘

##[error]Process completed with exit code 1
```

**The pipeline went red and nothing was pushed.** That is the gate working.

**What was found:** three CVEs, all in **operating system packages** from the base image, not in my code. `libexpat1`, `libssl3` and `zlib1g` — libraries the Node base image installs, that my app never calls directly.

**The base image was the problem.** The frontend Dockerfile used a Node image built on Debian 12, and that particular tag was a few weeks behind on security updates.

**Two ways to fix it:**

```dockerfile
# 1. rebuild against a fresher base
FROM node:20.17-bookworm-slim

# 2. or patch during the build
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
```

I used the first. Rebuilding on a current base tag cleared all three:

```
manishjha18/devboard-frontend:sha-c2f8b41 (debian 12.7)
======================================================
Total: 0 (HIGH: 0, CRITICAL: 0)
```

**What this taught me:** most container CVEs come from the base image, not from application code. The Go backend scanned clean from the start — it is a static binary on Alpine with almost nothing installed, which is Day 35's small-image argument turning out to be a security argument too. Fewer packages, fewer CVEs.

**`ignore-unfixed: true`** is important for keeping the gate credible. Without it, the scan fails on CVEs where no patch exists yet — nothing anyone can do, so the pipeline fails permanently and people start bypassing it. A gate that cannot be satisfied gets disabled.

**`severity: CRITICAL,HIGH`** and not MEDIUM/LOW for the same reason. Failing on hundreds of low-severity findings trains people to ignore the output.

---

## Task 2: Secret scanning and push protection

Enabled under **Settings → Code security and analysis**:

```
devops@testvm:~$ gh api repos/manish-jha18/devboard \
    --jq '.security_and_analysis | {secret_scanning: .secret_scanning.status, push_protection: .secret_scanning_push_protection.status}'
{
  "secret_scanning": "enabled",
  "push_protection": "enabled"
}
```

No workflow changes needed — GitHub does this itself.

### The difference between them

**Secret scanning** looks at what is **already in the repository**, including the full history. It runs continuously, and when it finds something that matches a known credential pattern it raises an alert. Reactive: the secret is already committed by the time you hear about it.

**Push protection** checks **at push time** and rejects the push. The secret never enters the repository at all. Preventive.

```
devops@testvm:~$ echo 'aws_key = "AKIAIOSFODNN7EXAMPLE"' > config.py
devops@testvm:~$ git add config.py && git commit -m "Add config"
devops@testvm:~$ git push
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote:
remote: - GITHUB PUSH PROTECTION
remote:   —————————————————————————————————————————
remote:     Resolve the following violations before pushing again
remote:
remote:       - Push cannot contain secrets
remote:
remote:      —— Amazon AWS Access Key ID ————————————————————
remote:       locations:
remote:         - commit: 4f8a2b91c7e35d06a1b4c7d0e3f6a9b2c5d8e1f4
remote:           path: config.py:1
```

**The push was rejected.** The key never reached GitHub.

The difference matters enormously, because **removing a secret from git history is hard and rotating it is mandatory anyway**. Day 27 covered this — `git rm` does not remove it from earlier commits, and by then it may already have been cloned. Push protection makes the whole problem not happen.

### What happens if GitHub detects a leaked AWS key

For supported providers, GitHub **notifies the provider directly** through its secret scanning partner programme. AWS receives the key and typically applies a quarantine policy within minutes, before the repository owner has even read the alert.

In parallel: an alert appears in the repo's Security tab, and admins are emailed.

**None of that removes the secret.** The alert says it exists; the key is still in the commit. The required response is always:

1. **Rotate the credential immediately.** Assume it is compromised — public repos are scraped continuously by bots looking for exactly this.
2. Then clean history if the repo has value, with `git filter-repo` or BFG.
3. Then work out how it got committed — usually a missing `.gitignore` entry.

Rotation first. Everything else is cleanup.

`gitleaks` in `security.yml` covers the same ground for patterns GitHub does not know about, and works on any host:

```yaml
  secret-scanning:
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
```

**`fetch-depth: 0` is essential here.** A shallow clone only has the latest commit, so a secret that was committed and later deleted would be invisible — which is precisely the case you most want to catch.

---

## Task 3: Dependency scanning

**In the PR pipeline** (Day 48's `pr-pipeline.yml`):

```yaml
  dependency-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: critical
```

Testing it by adding a package with a known CVE:

```
devops@testvm:~$ git switch -c fix/add-old-package
devops@testvm:~$ cd frontend && npm install lodash@4.17.15 && cd ..
devops@testvm:~$ git commit -am "Add lodash" && git push -u origin fix/add-old-package
devops@testvm:~$ gh pr create --title "Add lodash" --body "Testing dependency review"
```

```
devops@testvm:~$ gh pr checks 7
NAME                        DESCRIPTION  ELAPSED  URL
build-test / build-test     Successful   1m14s    ...
dependency-review           Failing      11s      ...
```

```
Dependency review detected vulnerable packages.

lodash@4.17.15  –  CRITICAL
  Prototype Pollution in lodash  (GHSA-p6mc-m468-83gg)
  Patched in 4.17.21
```

**Tests passed, dependency review failed.** The code is fine; the dependency is not. Bumping to `4.17.21` cleared it.

**Dependency review only works on `pull_request` events** — it compares the base and head of a PR, so there is nothing to diff on a push. That is why it lives in the PR pipeline and not the main pipeline.

**It only flags what the PR *adds*.** An existing vulnerable dependency is not reported. That is deliberate — a PR should be blocked for what it introduces, not for pre-existing debt. Catching the existing set needs a full scan, which is `security.yml`:

```yaml
      - name: Scan Go dependencies
        run: govulncheck ./...
        working-directory: backend

      - name: Scan npm dependencies
        run: npm audit --audit-level=critical
        working-directory: frontend
```

`govulncheck` is notably better than a plain manifest scan: it only reports vulnerabilities in code paths **actually reachable** from your program. A CVE in a function nothing calls is not flagged. That cuts the noise dramatically compared with `npm audit`, which reports on the dependency tree regardless of whether the affected code is used.

### The three layers, and what each one catches

| Layer | Tool | Catches |
|---|---|---|
| New dependencies in a PR | `dependency-review-action` | A vulnerable package being added |
| All dependencies | `govulncheck`, `npm audit` | Existing vulnerable packages |
| OS packages in the image | `trivy` | CVEs in the base image |

The Task 1 findings were all in layer three — none of the dependency scanners would have seen `libssl3`, because it is not in `package.json` or `go.mod`. Three layers because they genuinely see different things.

---

## Task 4: Permissions

Every workflow in Days 47–49 opens with:

```yaml
permissions:
  contents: read
```

And where more is genuinely needed, only that:

```yaml
permissions:
  contents: read
  security-events: write     # to upload SARIF to the Security tab
```

```yaml
permissions:
  contents: read
  pull-requests: write       # to comment on a PR
```

### Why limit workflow permissions

The default `GITHUB_TOKEN` has **write access to almost everything** in the repository — code, issues, packages, releases. Every workflow gets that whether it needs it or not.

**What could go wrong with a compromised action:** a third-party action runs arbitrary code in my job, with my token. With write access it could push a commit to `main`, create a release pointing at a malicious artefact, close issues, or modify workflow files to exfiltrate secrets on every future run.

This is not hypothetical. Compromised actions and typosquatted action names are a known supply chain attack, and the `tj-actions/changed-files` compromise in 2025 hit thousands of repositories through exactly this path.

**`permissions: contents: read` means a compromised action can read the code — which it can see anyway on a public repo — and nothing else.** It cannot write. The blast radius collapses.

Two things worth setting at the organisation or repository level, once:

- **Default permissions to read-only** under Settings → Actions → Workflow permissions, so a workflow that forgets the block is still safe.
- **Restrict which actions can run** to verified creators plus an explicit allowlist.

The brownie-point item is worth doing too:

```yaml
uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
```

A tag can be moved by whoever owns the action; a commit SHA cannot. This is what `cli/cli` does throughout, as I noticed on Day 39.

---

## Task 5: The full secure pipeline

```
┌─ PULL REQUEST ─────────────────────────────────────────────────────┐
│  pull_request → main                                               │
│                                                                    │
│   ┌──────────────┐  ┌────────────────────┐  ┌──────────────────┐   │
│   │ build-test   │  │ dependency-review  │  │ security.yml     │   │
│   │ build + test │  │ NEW deps, critical │  │  gitleaks        │   │
│   └──────┬───────┘  └─────────┬──────────┘  │  govulncheck     │   │
│          │                    │             │  npm audit       │   │
│          │                    │             │  hadolint        │   │
│          │                    │             │  trivy fs → SARIF│   │
│          │                    │             └────────┬─────────┘   │
│          └────────────────────┴──────────────────────┘             │
│                               ▼                                    │
│                        ┌─────────────┐                             │
│                        │ pr-summary  │                             │
│                        └─────────────┘                             │
│   No Docker build. No credentials referenced.                      │
└────────────────────────────────────────────────────────────────────┘

┌─ MAIN BRANCH ──────────────────────────────────────────────────────┐
│  push → main                                                       │
│         │                                                          │
│    ┌────┴─────────────────────┐                                    │
│    ▼                          ▼                                    │
│  build-test              security.yml         (parallel)           │
│    │                          │                                    │
│    └────────────┬─────────────┘   both must pass                   │
│                 ▼                                                  │
│               tag  → sha-8a3f91c                                   │
│                 ├──────────────────────┐                           │
│                 ▼                      ▼                           │
│        docker-backend          docker-frontend                     │
│         build (load)            build (load)                       │
│         trivy scan  ◀── GATE ──▶ trivy scan                        │
│         push if clean           push if clean                      │
│                 └──────────┬───────────┘                           │
│                            ▼                                       │
│                    deploy (manual approval)                        │
│                            ▼                                       │
│                    dast — OWASP ZAP against the RUNNING app        │
└────────────────────────────────────────────────────────────────────┘

┌─ ALWAYS ON ────────────────────────────────────────────────────────┐
│  GitHub secret scanning   — alerts on secrets already committed    │
│  Push protection          — rejects the push before it lands       │
│  permissions: contents: read on every workflow                     │
└────────────────────────────────────────────────────────────────────┘
```

### Where each check sits, and why

| Check | Stage | Type | Blocks? |
|---|---|---|---|
| Push protection | Before the push | Prevention | Yes — rejects the push |
| gitleaks | PR + main | Secrets in history | Yes |
| dependency-review | PR only | New vulnerable deps | Yes, on critical |
| govulncheck / npm audit | PR + main | All vulnerable deps | Yes, on critical |
| hadolint | PR + main | Dockerfile lint (SAST) | Yes, on error |
| trivy fs | PR + main | Code and manifests | No — reports to Security tab |
| trivy image | Before push | Image CVEs | **Yes — the key gate** |
| OWASP ZAP | After deploy | DAST | No — reports only |

**SAST versus DAST** is the distinction the last row draws out. Everything above the ZAP line reads **code and images at rest**. ZAP attacks the **running application** — it sends real requests looking for missing security headers, injection points, exposed endpoints. It finds a completely different class of problem: a misconfigured CORS policy or a debug endpoint left enabled is invisible to a static scan and obvious to a dynamic one.

It runs after deploy because it needs something running to attack, and it does not block, because a baseline scan produces findings that need human judgement rather than an automatic gate.

---

## Files in this folder

| Path | What it does |
|---|---|
| `.github/workflows/security.yml` | Callable: gitleaks, govulncheck, npm audit, hadolint, trivy fs → SARIF |
| `.github/workflows/devsecops.yml` | The full pipeline with security as blocking gates |

---

## What I learned

**1. Most container CVEs come from the base image, not from your code.** All three findings were OS packages — `libexpat1`, `libssl3`, `zlib1g` — that my application never calls. The Go backend on Alpine scanned clean because there is barely anything installed. Day 35's argument for small images turns out to be a security argument, not just a size one.

**2. Push protection beats secret scanning, because prevention beats detection.** Scanning tells you a secret is already in the history, and by then rotation is mandatory and history rewriting is painful. Push protection rejected my test AWS key before it ever reached GitHub. Both are worth having; only one avoids the incident.

**3. `permissions: contents: read` collapses the blast radius of a compromised action.** The default token can write to almost everything, and every third-party action runs with it. Two lines at the top of a workflow is the cheapest security control in the whole pipeline.

**Three extras:**

- `ignore-unfixed: true` keeps a scan gate credible. A gate that fails on unpatchable CVEs gets switched off.
- `dependency-review` only sees what a PR **adds**, and only on `pull_request` events. Existing debt needs a separate full scan.
- `fetch-depth: 0` for secret scanning — a shallow clone hides exactly the deleted-but-still-in-history secrets you are looking for.
