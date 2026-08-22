# Day 46 – Reusable Workflows and Composite Actions

Files are in `.github/workflows/` and `.github/actions/` in this folder.

---

## Task 1: Understanding `workflow_call`

**1. What is a reusable workflow?** A workflow another workflow can call, like a function. Write the build-and-test logic once and call it from a PR pipeline, a main pipeline and a nightly pipeline, instead of copying it three times.

**2. What is the `workflow_call` trigger?** It marks a workflow as callable. A workflow with only `on: workflow_call` never runs by itself — no push, no schedule, nothing. Something has to call it.

**3. How is it different from `uses:` on a regular action?**

The critical difference is **the level it plugs in at**.

```yaml
steps:
  - uses: actions/checkout@v4        # an ACTION replaces a STEP

jobs:
  build:
    uses: ./.github/workflows/x.yml  # a REUSABLE WORKFLOW replaces a JOB
```

A reusable workflow is called at job level, and it brings its own jobs, its own runners and its own `runs-on`. Note there is no `runs-on` and no `steps` in the calling job — the whole job body is the reusable workflow.

**4. Where must the file live?** In `.github/workflows/`, same as any other workflow. Subdirectories are not scanned.

```yaml
uses: ./.github/workflows/reusable-build.yml            # same repo
uses: manish-jha18/shared/.github/workflows/ci.yml@main # another repo
```

Cross-repo requires the calling repo to have access, and the ref (`@main`, a tag, or a SHA) is mandatory.

---

## Task 2: The reusable workflow

**`.github/workflows/reusable-build.yml`**

```yaml
name: Reusable Build

on:
  workflow_call:
    inputs:
      app_name:
        description: 'Name of the app being built'
        required: true
        type: string
      environment:
        description: 'Target environment'
        required: true
        default: staging
        type: string
    secrets:
      docker_token:
        description: 'Docker Hub token'
        required: true
    outputs:
      build_version:
        description: 'The version string this build produced'
        value: ${{ jobs.build.outputs.build_version }}

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      build_version: ${{ steps.version.outputs.build_version }}
    steps:
      - uses: actions/checkout@v4

      - name: Report what we were asked to build
        run: echo "Building ${{ inputs.app_name }} for ${{ inputs.environment }}"

      - name: Confirm the secret arrived without printing it
        env:
          TOKEN: ${{ secrets.docker_token }}
        run: |
          if [ -n "$TOKEN" ]; then
            echo "Docker token is set: true"
          else
            echo "Docker token is set: false"
            exit 1
          fi

      - name: Generate the version string
        id: version
        run: |
          SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          echo "build_version=v1.0-$SHORT_SHA" >> "$GITHUB_OUTPUT"
```

**Inputs must declare a `type:`.** Unlike `workflow_dispatch`, where it is optional, `workflow_call` requires `string`, `boolean` or `number`.

**Secrets must be declared to be received.** A reusable workflow cannot see the caller's secrets unless they are named in its `secrets:` block — or the caller passes `secrets: inherit`, which forwards everything.

Pushing this file alone did nothing, as expected — the Actions tab showed no run. A `workflow_call`-only workflow has no trigger of its own.

---

## Task 3: The caller

**`.github/workflows/call-build.yml`**

```yaml
name: Call Build

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    uses: ./.github/workflows/reusable-build.yml
    with:
      app_name: devboard
      environment: production
    secrets:
      docker_token: ${{ secrets.DOCKER_TOKEN }}

  report:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - run: echo "the reusable workflow produced version: ${{ needs.build.outputs.build_version }}"
```

```
devops@testvm:~$ gh run view 17211448290
✓ main Call Build · 17211448290

JOBS
✓ build / build in 9s
✓ report in 4s
```

The job name is **`build / build`** — the caller's job name, then the reusable workflow's job name. With several jobs inside a reusable workflow you get one line per job, all nested under the caller's job. That nesting is how you tell in the UI that a reusable workflow was involved.

Output:

```
Building devboard for production
Docker token is set: true
version is v1.0-8a3f91c
```

Both inputs arrived and the secret came through.

**`with:` not `env:`, and `secrets:` separately.** Inputs and secrets are deliberately distinct channels — inputs appear in logs, secrets are masked.

---

## Task 4: Outputs

Getting a value out of a reusable workflow takes **four hops**, one more than Day 43's job outputs:

```
step  →  $GITHUB_OUTPUT
job   →  outputs: build_version: ${{ steps.version.outputs.build_version }}
workflow_call → outputs: build_version: value: ${{ jobs.build.outputs.build_version }}
caller →  ${{ needs.build.outputs.build_version }}
```

The extra hop is the `on.workflow_call.outputs` block, which uses `value:` rather than a bare mapping — easy to get wrong, and the failure is a silently empty string rather than an error.

```
the reusable workflow produced version: v1.0-8a3f91c
```

The `report` job needs `needs: build` both to run afterwards and to read the output. Same rule as Day 43.

---

## Task 5: Composite action

**`.github/actions/setup-and-greet/action.yml`**

```yaml
name: 'Setup and Greet'
description: 'Greets in a chosen language and reports the runner details'

inputs:
  name:
    description: 'Who to greet'
    required: true
  language:
    description: 'Language code for the greeting'
    required: false
    default: en

outputs:
  greeted:
    description: 'Whether the greeting ran'
    value: ${{ steps.greet.outputs.greeted }}

runs:
  using: composite
  steps:
    - name: Greet
      id: greet
      shell: bash
      run: |
        case "${{ inputs.language }}" in
          hi) GREETING="Namaste" ;;
          es) GREETING="Hola" ;;
          fr) GREETING="Bonjour" ;;
          *)  GREETING="Hello" ;;
        esac
        echo "$GREETING, ${{ inputs.name }}!"
        echo "greeted=true" >> "$GITHUB_OUTPUT"

    - name: Runner details
      shell: bash
      run: |
        echo "Date       : $(date -u)"
        echo "Runner OS  : ${{ runner.os }}"
        echo "Runner arch: ${{ runner.arch }}"
```

**Using it:**

```yaml
steps:
  - uses: actions/checkout@v4

  - name: Greet in English
    uses: ./.github/actions/setup-and-greet
    with:
      name: Manish

  - name: Greet in Hindi
    id: hindi
    uses: ./.github/actions/setup-and-greet
    with:
      name: Manish
      language: hi

  - name: Read the action output
    run: echo "greeted = ${{ steps.hindi.outputs.greeted }}"
```

```
Hello, Manish!
Date       : Tue Jul 21 09:41:22 UTC 2026
Runner OS  : Linux
Runner arch: X64

Namaste, Manish!
Date       : Tue Jul 21 09:41:23 UTC 2026

greeted = true
```

**Four things that caught me out:**

**The file must be named `action.yml`** and sit in its own directory. `uses:` points at the **directory**, not the file — `./.github/actions/setup-and-greet`, no filename.

**It goes in `.github/actions/`, not `.github/workflows/`.** Putting it in `workflows/` makes GitHub try to parse it as a workflow and fail.

**Every step needs `shell:`.** In a normal workflow the shell is implicit; in a composite action it is mandatory on every `run:` step. Omitting it gives `Required property is missing: shell`, which took me a minute to place.

**`actions/checkout` must come first.** A local action is a file in the repo, so the repo has to be on disk before it can be used. Obvious once stated, easy to miss.

The whole point is visible in the output: the greeting ran twice, from one definition, with different inputs. Three steps collapsed into one line at each call site.

---

## Task 6: Comparison

| | Reusable Workflow | Composite Action |
|---|---|---|
| **Triggered by** | `uses:` at **job** level, with `on: workflow_call` | `uses:` at **step** level |
| **Can contain jobs?** | Yes — multiple, with `needs:` between them | No. Steps only |
| **Can contain multiple steps?** | Yes | Yes |
| **Lives where?** | `.github/workflows/*.yml` | `.github/actions/<name>/action.yml`, or its own repo |
| **Can accept secrets directly?** | Yes — a `secrets:` block, or `secrets: inherit` | No. Secrets must be passed in as ordinary inputs |
| **Can set `runs-on`?** | Yes — it brings its own runners | No. Runs on the caller's runner |
| **Can use a matrix?** | Yes | No |
| **Nesting depth** | Up to 4 levels | Up to 10 |
| **Best for** | A whole pipeline stage: build-and-test, docker-build-and-push, deploy | A sequence of steps repeated inside jobs: setup a toolchain, configure credentials, publish a report |

**The rule I am using:** if it needs its own runner, its own secrets or several jobs, it is a reusable workflow. If it is a handful of steps that always go together inside someone else's job, it is a composite action.

**On secrets specifically** — a composite action cannot read `secrets.*` at all. It has to be passed the value:

```yaml
- uses: ./.github/actions/deploy
  with:
    token: ${{ secrets.DOCKER_TOKEN }}   # explicitly handed over
```

That is arguably safer, since it makes every secret a component touches visible at the call site.

---

## Where this shows up in DevBoard

The project already uses this heavily. `devsecops.yml` is essentially a table of contents:

```yaml
jobs:
  code-quality:
    uses: ./.github/workflows/code-quality.yml
  secret-scanning:
    uses: ./.github/workflows/secret-scanning.yml
  dependency-checks:
    uses: ./.github/workflows/dependency-scan.yml
  docker-checks:
    uses: ./.github/workflows/docker-scans.yml
    secrets: inherit
  ...
  docker-push:
    uses: ./.github/workflows/docker-push.yml
    needs: [code-quality, code-tests, sonar-qube, docker-checks, dependency-checks, secret-scanning]
    secrets: inherit
```

Eight workflows, each doing one job, composed into a pipeline. The orchestration is readable at a glance and each piece can be tested on its own.

`secrets: inherit` appears on the ones that need credentials and is absent from the ones that do not — which is a small but real least-privilege decision. `code-quality` only runs a linter, so it never sees the Docker Hub token.

---

## Files in this folder

| Path | What it is |
|---|---|
| `.github/workflows/reusable-build.yml` | Reusable workflow with inputs, secrets and outputs |
| `.github/workflows/call-build.yml` | Caller, plus a job reading the output |
| `.github/actions/setup-and-greet/action.yml` | Composite action with inputs and an output |
| `.github/workflows/use-composite.yml` | Uses the composite action twice |

---

## What I learned

**1. A reusable workflow replaces a job; a composite action replaces steps.** That single distinction determines everything else — whether it can set `runs-on`, whether it can contain a matrix, whether it can read secrets. Once I saw that the calling job has no `runs-on` and no `steps`, the rest followed.

**2. Composite actions cannot read secrets.** They have to be handed the value as an input. Slightly more verbose, and it makes every credential a component uses visible where it is called.

**3. Getting a value out of a reusable workflow takes four hops.** Step output → job output → `workflow_call` output with `value:` → `needs.<job>.outputs.<name>`. Miss the third and you get an empty string with no error, which is a horrible thing to debug.

**Two extras:**

- Every `run:` step in a composite action needs an explicit `shell:`. Not required in normal workflows.
- `uses:` for a local action points at the **directory**, and `actions/checkout` must run first because the action is a file in your own repo.
