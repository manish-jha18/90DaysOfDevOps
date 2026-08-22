# Day 26 – GitHub CLI

`gh` commands added to `git-commands.md` in the day-22 folder.

---

## Task 1: Install and authenticate

```
devops@testvm:~$ sudo apt install gh -y

devops@testvm:~$ gh --version
gh version 2.98.0 (2026-06-20)
https://github.com/cli/cli/releases/tag/v2.98.0
```

```
devops@testvm:~$ gh auth login
? What account do you want to log into? GitHub.com
? What is your preferred protocol for Git operations? HTTPS
? Authenticate Git with your GitHub credentials? Yes
? How would you like to authenticate GitHub CLI? Login with a web browser

! First copy your one-time code: A4F2-9C1B
Press Enter to open github.com in your browser...
✓ Authentication complete.
- gh config set -h github.com git_protocol https
✓ Configured git protocol
✓ Logged in as manish-jha18
```

```
devops@testvm:~$ gh auth status
github.com
  ✓ Logged in to github.com account manish-jha18 (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo'
```

The "Authenticate Git with your GitHub credentials? Yes" step matters more than it looks. It runs `gh auth setup-git`, which registers `gh` as Git's credential helper for github.com. Skip it and `gh` works fine while `git push` still asks for a password. If that happens, `gh auth setup-git` fixes it after the fact.

### What authentication methods does `gh` support?

**1. Web browser (OAuth).** The default. You get a one-time code, paste it in the browser, and `gh` receives a token. Best for a personal machine — no token to store or rotate manually.

**2. Personal access token.** Paste a token, or pipe one in:

```bash
gh auth login --with-token < token.txt
echo "$GH_TOKEN" | gh auth login --with-token
```

Needed on a headless server where no browser is available.

**3. `GH_TOKEN` / `GITHUB_TOKEN` environment variable.** If set, `gh` uses it without any login step. This is how `gh` works inside GitHub Actions — the runner provides `GITHUB_TOKEN` automatically.

```bash
export GH_TOKEN="ghp_xxxx"
gh repo list          # just works
```

**4. SSH.** Not authentication for the API, but `gh` can configure Git to use SSH for clone and push while the API still uses a token.

Tokens are stored in the system keyring where one exists (mine says `keyring`), falling back to a plain file in `~/.config/gh/hosts.yml`. Worth knowing which, since a plaintext file on a shared box is a problem.

The DevOps takeaway: methods 2 and 3 are the ones for automation. A pipeline cannot open a browser.

---

## Task 2: Working with repositories

**Create a repo from the terminal:**

```
devops@testvm:~$ gh repo create gh-cli-test --public --add-readme --description "Testing the GitHub CLI"
✓ Created repository manish-jha18/gh-cli-test on GitHub
  https://github.com/manish-jha18/gh-cli-test
```

One command replaces about six clicks. `--clone` would also pull it down immediately.

**Clone with `gh`:**

```
devops@testvm:~$ gh repo clone manish-jha18/gh-cli-test
Cloning into 'gh-cli-test'...
remote: Enumerating objects: 3, done.
Receiving objects: 100% (3/3), done.
```

The advantage over `git clone` is that `owner/repo` is enough — no full URL — and `gh` handles authentication for private repos without prompting.

**View repo details:**

```
devops@testvm:~$ gh repo view manish-jha18/gh-cli-test
manish-jha18/gh-cli-test
Testing the GitHub CLI

  # gh-cli-test
  Testing the GitHub CLI

View this repository on GitHub: https://github.com/manish-jha18/gh-cli-test
```

**List my repos:**

```
devops@testvm:~$ gh repo list --limit 5
manish-jha18/90DaysOfDevOps       My 90 Days of DevOps challenge      public  about 2 hours ago
manish-jha18/gh-cli-test          Testing the GitHub CLI              public  about 5 minutes ago
manish-jha18/devops-git-practice  Git practice repo                   public  about 2 days ago
```

**Open in the browser:**

```
devops@testvm:~$ gh repo view --web
Opening github.com/manish-jha18/gh-cli-test in your browser.
```

**Delete it:**

```
devops@testvm:~$ gh repo delete manish-jha18/gh-cli-test
? Type manish-jha18/gh-cli-test to confirm deletion: manish-jha18/gh-cli-test
✓ Deleted repository manish-jha18/gh-cli-test
```

It made me type the full name to confirm, which is the right amount of friction for something irreversible. Deleting also needs the `delete_repo` scope, which is not granted by default:

```
devops@testvm:~$ gh auth refresh -h github.com -s delete_repo
```

---

## Task 3: Issues

```
devops@testvm:~$ gh issue create --repo manish-jha18/devops-git-practice \
    --title "Add examples to git-commands.md" \
    --body "The reference lists commands but some need a worked example." \
    --label "documentation"

Creating issue in manish-jha18/devops-git-practice
https://github.com/manish-jha18/devops-git-practice/issues/1
```

```
devops@testvm:~$ gh issue list --repo manish-jha18/devops-git-practice
Showing 1 of 1 open issue in manish-jha18/devops-git-practice

ID  TITLE                              LABELS         UPDATED
#1  Add examples to git-commands.md    documentation  about 1 minute ago
```

```
devops@testvm:~$ gh issue view 1 --repo manish-jha18/devops-git-practice
Add examples to git-commands.md
Open • manish-jha18 opened about 2 minutes ago • 0 comments
Labels: documentation

  The reference lists commands but some need a worked example.

View this issue on GitHub: https://github.com/manish-jha18/devops-git-practice/issues/1
```

```
devops@testvm:~$ gh issue close 1 --repo manish-jha18/devops-git-practice --comment "Examples added"
✓ Closed issue #1 (Add examples to git-commands.md)
```

The label has to exist already, or the command fails with `could not add label: 'documentation' not found`. `gh label create` makes one first.

### How could `gh issue` be used in a script or automation?

The key is `--json`, which turns output into structured data instead of text meant for humans:

```
devops@testvm:~$ gh issue list --json number,title,labels --limit 3
[{"labels":[{"name":"bug"}],"number":4,"title":"Login fails on Safari"}]
```

Some things that becomes possible:

**Open an issue automatically when a monitoring check fails:**
```bash
if ! curl -sf https://myapp.com/health; then
    gh issue create --title "Health check failing $(date +%F)" \
                    --body "Endpoint returned non-200." --label "incident"
fi
```

**Report on stale issues:**
```bash
gh issue list --json number,title,updatedAt \
  | jq -r '.[] | select(.updatedAt < "2026-06-01") | "\(.number) \(.title)"'
```

**Close every issue with a given label:**
```bash
gh issue list --label "wontfix" --json number -q '.[].number' \
  | xargs -I{} gh issue close {}
```

**Create issues in bulk from a file** — useful when migrating a backlog.

The general pattern for DevOps work is `gh ... --json ... | jq`, which turns GitHub into something a shell script can query. That is far easier than calling the REST API with `curl` and handling auth headers and pagination yourself.

---

## Task 4: Pull requests

**Whole flow without touching the browser:**

```
devops@testvm:~/devops-git-practice$ git switch -c add-gh-section
Switched to a new branch 'add-gh-section'

devops@testvm:~/devops-git-practice$ echo "- gh pr create" >> git-commands.md
devops@testvm:~/devops-git-practice$ git commit -am "Add gh commands section"
[add-gh-section 8c21f4a] Add gh commands section

devops@testvm:~/devops-git-practice$ git push -u origin add-gh-section
 * [new branch]      add-gh-section -> add-gh-section

devops@testvm:~/devops-git-practice$ gh pr create --title "Add GitHub CLI commands" \
    --body "Adds a gh section to the reference."

Creating pull request for add-gh-section into main in manish-jha18/devops-git-practice
https://github.com/manish-jha18/devops-git-practice/pull/2
```

`gh pr create --fill` skips the title and body and takes them from the commit messages, which is the fastest version when commits are well written. `--web` opens the browser form pre-filled.

```
devops@testvm:~/devops-git-practice$ gh pr list
Showing 1 of 1 open pull request in manish-jha18/devops-git-practice

ID  TITLE                        BRANCH          CREATED AT
#2  Add GitHub CLI commands      add-gh-section  about 1 minute ago
```

```
devops@testvm:~/devops-git-practice$ gh pr view 2
Add GitHub CLI commands #2
Open • manish-jha18 wants to merge 1 commit into main from add-gh-section

  Adds a gh section to the reference.

View this pull request on GitHub: https://github.com/manish-jha18/devops-git-practice/pull/2

devops@testvm:~/devops-git-practice$ gh pr checks 2
No checks reported on the 'add-gh-section' branch
```

No checks because there is no CI on this repo yet — Days 38 onwards.

```
devops@testvm:~/devops-git-practice$ gh pr merge 2 --squash --delete-branch
✓ Squashed and merged pull request #2 (Add GitHub CLI commands)
✓ Deleted local branch add-gh-section and switched to branch main
✓ Deleted remote branch add-gh-section
```

Merged, remote branch deleted, local branch deleted, and switched back to `main` — four things in one command.

### What merge methods does `gh pr merge` support?

| Flag | Result |
|---|---|
| `--merge` | Regular merge commit, keeps every commit from the branch |
| `--squash` | All commits combined into one on the target branch |
| `--rebase` | Commits replayed onto the target, linear history, no merge commit |

Matches Day 24. Useful extras: `--auto` merges as soon as required checks pass, and `--delete-branch` cleans up afterwards.

If the repo restricts which methods are allowed, the others fail with an error from the API rather than from `gh`.

### How would I review someone else's PR using `gh`?

```bash
gh pr list                          # what is waiting
gh pr view 7                        # description and discussion
gh pr diff 7                        # the actual changes, in the terminal
gh pr checks 7                      # is CI green

gh pr checkout 7                    # check it out locally and run it
./run-tests.sh

gh pr review 7 --approve
gh pr review 7 --request-changes --body "Needs a test for the empty input case"
gh pr review 7 --comment --body "Looks reasonable, one question below"
gh pr comment 7 --body "Could you add this to the changelog?"
```

`gh pr checkout 7` is the one that changes how reviewing feels. It fetches the branch and switches to it, so you can actually run the code instead of guessing from a diff. Doing that manually means adding a remote and fetching the right ref.

---

## Task 5: GitHub Actions preview

```
devops@testvm:~$ gh run list --repo cli/cli --limit 5
STATUS  TITLE                          WORKFLOW  BRANCH  EVENT         ID
✓       Merge pull request #9812       CI        trunk   push          16482910337
✓       Bump version to 2.98.0         CI        trunk   push          16482744012
X       Fix flaky integration test     CI        trunk   pull_request  16481553298
✓       Update dependencies            CI        trunk   push          16480119874
-       Nightly build                  Nightly   trunk   schedule      16479002143
```

The status column: `✓` passed, `X` failed, `-` cancelled or skipped.

```
devops@testvm:~$ gh run view 16481553298 --repo cli/cli
X trunk Fix flaky integration test · 16481553298
Triggered via pull_request about 6 hours ago

JOBS
✓ build (ubuntu-latest) in 2m14s
✓ build (macos-latest) in 3m41s
X build (windows-latest) in 4m02s

For more information about a job, try: gh run view --job=<job-id>
```

```
devops@testvm:~$ gh workflow list --repo cli/cli
NAME       STATE   ID
CI         active  1284471
Nightly    active  1284472
Releases   active  1284473
```

### How could `gh run` and `gh workflow` be useful in CI/CD?

**Watch a run without leaving the terminal:**
```bash
gh run watch          # live updates until it finishes
```

**Block a deploy script until CI is green:**
```bash
gh run watch "$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status \
    && ./deploy.sh
```
`--exit-status` returns non-zero if the run failed, so the `&&` does the gating.

**Pull failed logs straight to the terminal** instead of clicking through the web UI:
```bash
gh run view <id> --log-failed
```

**Trigger a workflow manually,** for anything with a `workflow_dispatch` trigger:
```bash
gh workflow run deploy.yml -f environment=staging
```

**Re-run only what failed** after a flaky test:
```bash
gh run rerun <id> --failed
```

**Download build artifacts:**
```bash
gh run download <id>
```

The pattern is that `gh` turns GitHub Actions into something scriptable. A deploy script can wait for CI, check the result, fetch artifacts and act on failure — all without a browser and without hand-writing API calls.

---

## Task 6: Useful tricks

### `gh api` — raw API calls

```
devops@testvm:~$ gh api repos/manish-jha18/90DaysOfDevOps --jq '.stargazers_count'
3

devops@testvm:~$ gh api user --jq '.login, .public_repos'
manish-jha18
7

devops@testvm:~$ gh api repos/manish-jha18/90DaysOfDevOps/commits --jq '.[0].commit.message'
Day 25: reset vs revert and branching strategies
```

This is the escape hatch. Anything the GitHub API can do but `gh` has no subcommand for, `gh api` reaches — and it handles authentication, base URL and pagination (`--paginate`) for you. Much less fiddly than `curl` with a bearer token.

### `gh gist`

```
devops@testvm:~$ gh gist create system_info.sh --public --desc "System info reporter"
- Creating gist system_info.sh
✓ Created public gist system_info.sh
https://gist.github.com/manish-jha18/8f2c91a4b7e3d05c1a6f
```

Good for sharing a single script without creating a repo.

### `gh release`

```
devops@testvm:~$ gh release create v1.0.0 --title "First release" --notes "Initial version"
https://github.com/manish-jha18/devops-git-practice/releases/tag/v1.0.0

devops@testvm:~$ gh release create v1.1.0 --generate-notes
```

`--generate-notes` writes the release notes from merged pull requests, which is a genuine time saver. Files listed after the tag become downloadable assets — that is how binaries get attached in a release pipeline.

### `gh alias`

```
devops@testvm:~$ gh alias set prs 'pr list --author "@me"'
- Adding alias for prs: pr list --author "@me"
✓ Added alias prs

devops@testvm:~$ gh alias set co 'pr checkout'
devops@testvm:~$ gh alias list
co: pr checkout
prs: pr list --author "@me"

devops@testvm:~$ gh prs
Showing 2 of 2 open pull requests in manish-jha18/devops-git-practice that match your search
```

`@me` resolves to the logged-in user, so the alias works in any repo.

### `gh search repos`

```
devops@testvm:~$ gh search repos "kubernetes operator" --language=go --stars=">1000" --limit 3
NAME                              DESCRIPTION                                    STARS
operator-framework/operator-sdk   SDK for building Kubernetes applications       7284
kubernetes-sigs/kubebuilder       SDK for building Kubernetes APIs using CRDs    7891
zalando/postgres-operator         Postgres operator for Kubernetes               4312
```

Better than the web search for narrowing by language and stars quickly.

---

## What I learned

**1. `--json` is what makes `gh` a DevOps tool rather than a convenience.** Without it, output is text meant for a human and parsing it is fragile. With `--json` and `-q`, GitHub becomes something a shell script can query reliably — list PRs, check run status, open issues automatically. That is the difference between saving a few clicks and building automation.

**2. Authentication for automation is a different problem from authentication for me.** The browser flow is right on my laptop and impossible in a pipeline. `GH_TOKEN` as an environment variable is the answer for CI, which is exactly how `gh` works inside GitHub Actions without any login step at all.

**3. `gh pr checkout` changes what reviewing means.** Reading a diff in a browser tells you whether the code looks reasonable. Checking the branch out locally and running it tells you whether it works. One command instead of manually adding a remote and fetching a ref.

**Two extras:**

- `gh auth login` asks whether to configure Git credentials, and saying no leaves `git push` prompting for a password even though `gh` works. `gh auth setup-git` fixes it afterwards.
- `gh api` covers anything without a dedicated subcommand, with auth and pagination already handled.
