# Day 25 – Reset vs Revert and Branching Strategies

Reset and revert both undo things, but they work in opposite directions — one rewrites history, the other adds to it.

---

## Task 1: Git reset

Set up three commits, each adding a line to `file.txt`:

```
devops@testvm:~/reset-demo$ git log --oneline
814b01f (HEAD -> main) Commit C
7bc7b72 Commit B
e2331f3 Commit A

devops@testvm:~/reset-demo$ cat file.txt
line A
line B
line C
```

### `--soft`

```
devops@testvm:~/reset-demo$ git reset --soft HEAD~1

devops@testvm:~/reset-demo$ git log --oneline
7bc7b72 (HEAD -> main) Commit B
e2331f3 Commit A

devops@testvm:~/reset-demo$ git status --short
M  file.txt

devops@testvm:~/reset-demo$ cat file.txt
line A
line B
line C
```

Commit C is gone from the log, but `line C` is still in the file **and still staged**. The `M` is in the first column, which means staged.

It is as if I never ran `git commit` — the changes are sitting ready to be committed again. This is the mode for fixing a bad commit message or adding a forgotten file.

### `--mixed` (the default)

```
devops@testvm:~/reset-demo$ git reset --mixed HEAD~1
Unstaged changes after reset:
M	file.txt

devops@testvm:~/reset-demo$ git status --short
 M file.txt

devops@testvm:~/reset-demo$ cat file.txt
line A
line B
line C
```

The commit is gone and the content is still there, but now it is **unstaged**. Note the difference in the status output — ` M` with a leading space, versus `M ` for soft. Easy to miss and it is the whole distinction.

It is as if I never ran `git add`. This is the mode for re-splitting changes into different commits.

### `--hard`

```
devops@testvm:~/reset-demo$ git reset --hard HEAD~1
HEAD is now at 7bc7b72 Commit B

devops@testvm:~/reset-demo$ git status --short

devops@testvm:~/reset-demo$ cat file.txt
line A
line B
```

Commit gone, staging cleared, and **`line C` is gone from the file**. Working tree completely clean. This is the destructive one.

### The three modes side by side

| Mode | Commit | Staging area | Working files |
|---|---|---|---|
| `--soft` | Removed | Kept, staged | Kept |
| `--mixed` | Removed | Cleared | Kept |
| `--hard` | Removed | Cleared | **Overwritten** |

Each one undoes one step further back:

```
--soft   undoes the commit
--mixed  undoes the commit + the add
--hard   undoes the commit + the add + the edit
```

### The safety net

```
devops@testvm:~/reset-demo$ git reflog
7bc7b72 HEAD@{0}: reset: moving to HEAD~1
560a430 HEAD@{1}: commit: Commit C
7bc7b72 HEAD@{2}: reset: moving to HEAD~1
814b01f HEAD@{3}: commit: Commit C
```

`git reflog` records every position `HEAD` has held, including commits nothing points at any more. So `git reset --hard HEAD@{1}` gets Commit C back.

The important caveat: **reflog only covers committed work.** A hard reset that discards uncommitted edits loses them for good, because they were never in a commit for the reflog to point at. Reflog entries also expire, default 90 days.

### Answers

**Difference between the three?** As above — they differ in how much they undo. All three move the branch pointer; only `--hard` touches your files.

**Which is destructive and why?** `--hard`. The other two leave your changes in the working directory, so nothing you typed is lost. `--hard` overwrites the files on disk with the older version, and uncommitted work has no reflog entry to recover from.

**When would I use each?**

- **`--soft`** — wrong commit message, or forgot a file. Reset, fix, commit again. (`git commit --amend` is usually simpler for the last commit.)
- **`--mixed`** — committed too much in one go and want to split it into separate commits.
- **`--hard`** — an experiment that went nowhere and I want the branch back to a known state. Only when I am certain nothing in the working directory matters.

**Should I reset commits that are already pushed?** No. Reset removes commits from my local branch, but the remote still has them, so my next push is rejected as behind. The only way through is `--force`, which rewrites shared history — anyone who pulled the old commits ends up in a conflicting state, and anything they built on top is orphaned.

If it is already pushed, use `revert`.

---

## Task 2: Git revert

Three commits, each adding a separate file:

```
devops@testvm:~/revert-demo$ git log --oneline
28e6dd2 (HEAD -> main) Commit Z: add feature Z
b7342b5 Commit Y: add feature Y
3addd1b Commit X: add feature X

devops@testvm:~/revert-demo$ ls
x.txt  y.txt  z.txt
```

**Revert the middle one:**

```
devops@testvm:~/revert-demo$ git revert b7342b5
[main 4b201aa] Revert "Commit Y: add feature Y"
 1 file changed, 1 deletion(-)
 delete mode 100644 y.txt
```

**After:**

```
devops@testvm:~/revert-demo$ git log --oneline
4b201aa (HEAD -> main) Revert "Commit Y: add feature Y"
28e6dd2 Commit Z: add feature Z
b7342b5 Commit Y: add feature Y
3addd1b Commit X: add feature X

devops@testvm:~/revert-demo$ ls
x.txt  z.txt
```

Two things worth noticing:

1. **Commit Y is still in the history.** Nothing was removed. A fourth commit was added that undoes Y's changes.
2. **`y.txt` is gone but `z.txt` survives.** Revert undid only Y's changes, leaving the later commit alone.

```
devops@testvm:~/revert-demo$ git show --stat HEAD
    Revert "Commit Y: add feature Y"

    This reverts commit b7342b5ecdf92cc486c89cdc8b8eac9fa5bb45ac.

 y.txt | 1 -
 1 file changed, 1 deletion(-)
```

Git wrote the message itself and recorded which commit was reverted.

### Answers

**How is revert different from reset?**

Reset moves the branch pointer backwards and the commits stop being reachable — history is rewritten. Revert leaves history alone and appends a new commit containing the inverse changes — history grows.

Reset is "pretend that never happened". Revert is "that happened, and here is me undoing it".

**Why is revert safer for shared branches?** Because it only adds commits. Everyone else's history stays valid, nothing they pulled disappears, and no force push is needed. It is a normal commit that flows to everyone through a normal pull.

**When to use which?**

| Situation | Use |
|---|---|
| Commit is local only, not pushed | `reset` |
| Commit is pushed to a shared branch | `revert` |
| Want a clean history before opening a PR | `reset` |
| Need an audit trail of what was undone | `revert` |
| Undoing a bad deploy on `main` | `revert` |
| Throwing away a dead-end experiment | `reset --hard` |

One wrinkle: reverting a **merge commit** needs `-m 1` to tell Git which parent to treat as the mainline, since a merge commit has two.

---

## Task 3: Reset vs revert summary

| | `git reset` | `git revert` |
|---|---|---|
| **What it does** | Moves the branch pointer to an earlier commit; optionally changes the staging area and files | Creates a new commit that applies the inverse of an earlier commit |
| **Removes commit from history?** | Yes — it becomes unreachable (recoverable via reflog for a while) | No — the original stays, a new commit is added on top |
| **Safe for shared/pushed branches?** | No — requires a force push and breaks everyone else's history | Yes — it is just another commit |
| **Direction** | Backwards, rewrites | Forwards, appends |
| **Can undo a commit from the middle?** | Not without rewriting everything after it | Yes, directly |
| **Leaves an audit trail?** | No | Yes |
| **When to use** | Local commits not yet pushed; cleaning up before a PR; discarding an experiment | Anything already pushed; production rollbacks; when the history needs to show what was undone |

---

## Task 4: Branching strategies

### GitFlow

Five branch types with strict roles.

```
main       ──●──────────────────●────────●──   (production, tagged releases)
              \                /        /
release        \        ●────●         /       (stabilise, bug fixes only)
                \      /              /
develop    ──●───●────●───────●──────●─────    (integration branch)
              \  /            \     /
feature        ●              ●───●            (one per feature)

hotfix     ────────────────────●──────         (branches from main, merges to both)
```

**How it works:** `main` only ever holds released code. `develop` is where features accumulate. Each feature branches from `develop` and merges back. When enough has built up, a `release` branch is cut for stabilisation, then merged to both `main` and `develop`. Urgent production bugs get a `hotfix` branch straight off `main`.

**Where it is used:** Versioned software with scheduled releases — desktop applications, mobile apps, on-premise products, anything where several versions are supported at once.

| Pros | Cons |
|---|---|
| Clear role for every branch | Heavy — five branch types to keep straight |
| Supports maintaining multiple versions | Long-lived branches drift and conflict badly |
| Release stabilisation has a home | Slow; poor fit for continuous deployment |
| Hotfix path is well defined | Feature branches live for weeks |

Worth knowing: the author of GitFlow added a note to his own 2010 article saying it is not the right choice for web applications with continuous delivery.

### GitHub Flow

One long-lived branch and short feature branches.

```
main  ──●────●────●────●────●──     (always deployable)
         \       /    \    /
feature   ●─────●      ●──●          (branch, PR, review, merge, deploy)
```

**How it works:** Branch from `main`, commit, open a pull request, get review and CI, merge, deploy. That is the whole process. Branches live days, not weeks.

**Where it is used:** Web applications and SaaS — anything with a single production version deployed continuously. GitHub itself, and most startups.

| Pros | Cons |
|---|---|
| Simple enough to explain in one minute | No place to stabilise a release |
| Fast feedback, small changes | Assumes strong CI and test coverage |
| `main` is always deployable | Awkward when supporting multiple released versions |
| Pull requests give natural review points | A bad merge affects production immediately |

### Trunk-Based Development

Everyone commits to one trunk, branches last hours.

```
main  ──●──●──●──●──●──●──●──●──   (everyone, many times a day)
          \/    \/    \/
          tiny short-lived branches (hours)

           feature flags hide incomplete work
```

**How it works:** Developers integrate into `main` at least daily. Branches, if used at all, live for hours. Unfinished features ship to production disabled behind **feature flags**, so incomplete code can be merged without being visible.

**Where it is used:** Google, Facebook, Netflix. Large teams with heavy automated testing and mature CI/CD.

| Pros | Cons |
|---|---|
| Almost no merge conflicts — everything is small | Demands excellent automated tests |
| True continuous integration | Feature flags add real complexity |
| Fastest path from code to production | Discipline required; one bad commit affects everyone |
| No long-lived branches to reconcile | Hard for junior-heavy or distributed teams |

The trade the industry has learned: merge pain scales with how long a branch lives. Trunk-based removes the pain by removing the branches, and pays for it in testing and tooling.

### Answers

**Startup shipping fast?** **GitHub Flow.** Simple enough that a small team can follow it without ceremony, gives review through pull requests, and supports deploying several times a day. GitFlow's release branches solve a problem a startup with one production version does not have. Trunk-based is the natural next step once CI is mature enough to trust.

**Large team with scheduled releases?** **GitFlow**, or something close to it. Scheduled releases mean you need somewhere to stabilise — a place to fix bugs against a release candidate while feature work continues. That is exactly the `release` branch. Supporting more than one released version at a time makes it close to mandatory.

**What does a project I follow use?**

Checked **Kubernetes**:

```
devops@testvm:~$ git ls-remote --heads https://github.com/kubernetes/kubernetes.git | head -6
...  refs/heads/master
...  refs/heads/release-1.29
...  refs/heads/release-1.30
...  refs/heads/release-1.31
...  refs/heads/release-1.32
```

A single `master` plus one long-lived branch per minor release. Not textbook GitFlow — there is no `develop` — but it shares the release-branch idea, because Kubernetes supports the last three minor versions and must backport patches to each.

Contributors work in forks and raise pull requests, so the day-to-day feels like GitHub Flow while the release management resembles GitFlow. Most real projects are a hybrid rather than a pure strategy.

---

## Task 5: Commands reference update

`git-commands.md` (in the day-22 folder) now covers Days 22–25: setup and config, basic workflow, viewing history, undoing, branching, remotes, merging, rebase, stash, cherry-pick and tags.

---

## What I learned

**1. Reset and revert move in opposite directions.** Reset rewrites history by moving a pointer backwards; revert extends history by adding an inverse commit. Once framed that way, "which is safe to push" answers itself — anything that only adds commits is safe, anything that removes them is not.

**2. The three reset modes are three levels of undo, and only `--hard` loses work.** Soft undoes the commit, mixed also undoes the `add`, hard also undoes the edit. Seeing `M ` versus ` M ` in `git status --short` made the soft/mixed distinction concrete in a way the documentation did not.

**3. Branching strategies are about release cadence, not preference.** Ship continuously to one production version and GitHub Flow fits. Support several versions on a schedule and you need release branches. The strategy is a consequence of how the software is delivered.

**Two extras:**

- `git reflog` recovers almost any bad reset, but only for work that was committed. Uncommitted changes destroyed by `--hard` are gone.
- Reverting a merge commit needs `-m 1` to say which parent is the mainline.
