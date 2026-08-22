# Day 23 – Git Branching and Working with GitHub

Continued in the `devops-git-practice` repo. All new commands added to `git-commands.md` in the day-22 folder.

---

## Task 1: Understanding branches

### 1. What is a branch in Git?

A branch is a **movable pointer to a commit**. That is the whole thing.

I expected branches to be copies of the project. They are not — a branch is a file in `.git/refs/heads/` containing a single 40-character hash:

```
devops@testvm:~/devops-git-practice$ cat .git/refs/heads/main
505ed6f2bd20803a1b4a44823d117be2989b5c2f
```

That is the entire branch. Creating one writes a 41-byte file, which is why branching in Git is instant no matter how large the project is. When I commit, the pointer moves forward to the new commit.

### 2. Why branches instead of committing everything to `main`?

- **`main` stays deployable.** Half-finished work never touches the branch that goes to production.
- **Isolation.** My broken experiment cannot break anyone else's work.
- **Parallel work.** Several people build different features at once without stepping on each other.
- **Review.** A branch becomes a pull request, which is where the discussion and approval happen.
- **Cheap to abandon.** An experiment that does not work out is deleted with one command and leaves no trace.

Since branches cost nothing, the sensible default is a branch per piece of work.

### 3. What is `HEAD`?

`HEAD` is a pointer to **where I am right now** — normally the name of the current branch.

```
devops@testvm:~/devops-git-practice$ cat .git/HEAD
ref: refs/heads/main
```

So `HEAD` points at `main`, and `main` points at a commit. Two hops.

Switching branches rewrites that one line. If instead I check out a specific commit, `HEAD` holds a raw hash rather than a branch name — that is **detached HEAD**. Commits made there belong to no branch, and switching away loses them unless I create a branch first.

`HEAD~1` means one commit back, `HEAD~3` three back. Used constantly with `reset` and `rebase`.

### 4. What happens to my files when I switch branches?

Git rewrites the files in my working directory to match the target branch. Files added on the other branch appear, files that do not exist there are removed, and changed files are swapped to that branch's version.

Two things it does **not** touch:

- **Uncommitted changes.** They come with me if there is no conflict. If the branch I am switching to has different content in a file I have edited, Git refuses to switch rather than overwrite my work.
- **Untracked files.** They stay put regardless.

That refusal is what Day 24's stash exercise is about.

---

## Task 2: Branching commands

**List branches:**

```
devops@testvm:~/devops-git-practice$ git branch
* main
```

The `*` marks the current branch.

**Create a branch:**

```
devops@testvm:~/devops-git-practice$ git branch feature-1
devops@testvm:~/devops-git-practice$ git branch
  feature-1
* main
```

Created but not switched to — still on `main`.

**Switch to it:**

```
devops@testvm:~/devops-git-practice$ git switch feature-1
Switched to branch 'feature-1'
```

**Create and switch in one command:**

```
devops@testvm:~/devops-git-practice$ git switch -c feature-2
Switched to a new branch 'feature-2'
```

### `git switch` vs `git checkout`

`git checkout` does two unrelated jobs: switching branches *and* restoring files. That overloading caused real accidents — `git checkout file.txt` silently discards your changes to that file, and it looks almost identical to switching branches.

Git 2.23 split it in two:

| Old | New | Job |
|---|---|---|
| `git checkout <branch>` | `git switch <branch>` | Change branch |
| `git checkout -b <branch>` | `git switch -c <branch>` | Create and change |
| `git checkout -- <file>` | `git restore <file>` | Discard file changes |

`checkout` still works and is everywhere in older documentation, but `switch` and `restore` say what they do. Using `switch` also means a typo gives a clean error instead of destroying a file.

**Commit on `feature-1` only:**

```
devops@testvm:~/devops-git-practice$ git switch feature-1
Switched to branch 'feature-1'

devops@testvm:~/devops-git-practice$ echo "- git branch" >> git-commands.md
devops@testvm:~/devops-git-practice$ git commit -am "Add branch command"
[feature-1 77d766c] Add branch command
 1 file changed, 1 insertion(+)

devops@testvm:~/devops-git-practice$ git log --oneline -2
77d766c (HEAD -> feature-1) Add branch command
505ed6f (main) Add compact log command
```

`(HEAD -> feature-1)` and `(main)` on different lines shows the branches have diverged.

**Switch back and verify:**

```
devops@testvm:~/devops-git-practice$ git switch main
Switched to branch 'main'

devops@testvm:~/devops-git-practice$ git log --oneline -1
505ed6f (HEAD -> main) Add compact log command

devops@testvm:~/devops-git-practice$ tail -1 git-commands.md
- git log --oneline
```

The commit is not in `main`'s log and the line is gone from the file. Git physically rewrote the file on disk when I switched.

**Delete a branch:**

```
devops@testvm:~/devops-git-practice$ git branch -d feature-2
Deleted branch feature-2 (was 505ed6f).

devops@testvm:~/devops-git-practice$ git branch -d feature-1
error: The branch 'feature-1' is not fully merged.
If you are sure you want to delete it, run 'git branch -D feature-1'.
```

`feature-2` deleted cleanly because it had no unique commits. `feature-1` was refused, because deleting it would orphan the commit. `-D` forces it, and that is how you lose work — the safety check exists for a reason.

---

## Task 3: Push to GitHub

Created `devops-git-practice` on GitHub with no README, no `.gitignore`, no licence. Initialising it with any file would give the remote a commit my local repo does not have, and the first push would be rejected as unrelated histories.

```
devops@testvm:~/devops-git-practice$ git remote add origin https://github.com/manish-jha18/devops-git-practice.git

devops@testvm:~/devops-git-practice$ git remote -v
origin	https://github.com/manish-jha18/devops-git-practice.git (fetch)
origin	https://github.com/manish-jha18/devops-git-practice.git (push)
```

Two lines because Git allows fetching and pushing to different URLs, though they are almost always the same.

```
devops@testvm:~/devops-git-practice$ git push -u origin main
Enumerating objects: 15, done.
Counting objects: 100% (15/15), done.
Delta compression using up to 2 threads
Compressing objects: 100% (8/8), done.
Writing objects: 100% (15/15), 1.42 KiB | 1.42 MiB/s, done.
Total 15 (delta 3), reused 0 (delta 0), pack-reused 0
remote: Resolving deltas: 100% (3/3), completed with 0 local objects.
To https://github.com/manish-jha18/devops-git-practice.git
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

That last line is what `-u` did. It records that local `main` tracks `origin/main`, so from now on a bare `git push` or `git pull` knows where to go. Without `-u` I would have to name the remote and branch every time.

```
devops@testvm:~/devops-git-practice$ git push -u origin feature-1
Total 3 (delta 1), reused 0 (delta 0), pack-reused 0
remote:
remote: Create a pull request for 'feature-1' on GitHub by visiting:
remote:      https://github.com/manish-jha18/devops-git-practice/pull/new/feature-1
remote:
To https://github.com/manish-jha18/devops-git-practice.git
 * [new branch]      feature-1 -> feature-1
```

```
devops@testvm:~/devops-git-practice$ git branch -a
* main
  feature-1
  remotes/origin/main
  remotes/origin/feature-1
```

`-a` shows remote-tracking branches too. Those `remotes/origin/*` entries are Git's local record of where the remote was **the last time I talked to it** — they do not update on their own.

### `origin` vs `upstream`

Both are just names for remote URLs. Neither is special to Git; the meaning is convention.

| Name | Usually points at | I can push? |
|---|---|---|
| `origin` | My own repo, or my fork | Yes |
| `upstream` | The original repo I forked from | No, usually read-only |

Working on my own project there is only `origin`. Contributing to someone else's, the pattern is:

```bash
git clone https://github.com/manish-jha18/some-project.git      # origin = my fork
git remote add upstream https://github.com/original/some-project.git
git fetch upstream
git merge upstream/main
```

Pull from `upstream` to stay current, push to `origin`, then raise a pull request from `origin` back to `upstream`.

---

## Task 4: Pull from GitHub

Edited `git-commands.md` in the GitHub web editor and committed directly on `main`, so the remote was ahead of my local copy.

```
devops@testvm:~/devops-git-practice$ git status
On branch main
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean
```

Git says "up to date" — but it is wrong. It is comparing against `origin/main` as cached locally, and it has not checked the server. That is a genuinely misleading message until you understand it.

```
devops@testvm:~/devops-git-practice$ git fetch
remote: Enumerating objects: 5, done.
Unpacking objects: 100% (3/3), 312 bytes | 104.00 KiB/s, done.
From https://github.com/manish-jha18/devops-git-practice
   505ed6f..a91c4e2  main       -> origin/main

devops@testvm:~/devops-git-practice$ git status
On branch main
Your branch is behind 'origin/main' by 1 commit, and can be fast-forwarded.
  (use "git pull" to update your local branch)
```

After fetching, the truth appears: one commit behind.

```
devops@testvm:~/devops-git-practice$ git pull
Updating 505ed6f..a91c4e2
Fast-forward
 git-commands.md | 1 +
 1 file changed, 1 insertion(+)
```

### `git fetch` vs `git pull`

**`git fetch`** downloads new commits and updates the `origin/*` pointers. It does not touch my branch or my files. Completely safe — it cannot cause a conflict.

**`git pull`** is `git fetch` followed immediately by `git merge origin/<branch>`. It changes my working files and can produce a conflict.

```
git pull  ==  git fetch  +  git merge origin/main
```

Fetching first is the safer habit, because it lets me look before anything changes:

```bash
git fetch
git log --oneline HEAD..origin/main    # what is coming
git diff HEAD origin/main              # exactly what will change
git pull                               # now apply it
```

`git pull --rebase` replays my local commits on top of the remote instead of creating a merge commit, which keeps history linear.

---

## Task 5: Clone vs Fork

**Clone** — copied a public repo straight down:

```
devops@testvm:~$ git clone https://github.com/LondheShubham153/90DaysOfDevOps.git
Cloning into '90DaysOfDevOps'...
remote: Enumerating objects: 4218, done.
remote: Total 4218 (delta 112), reused 98 (delta 87), pack-reused 4031
Receiving objects: 100% (4218/4218), 18.64 MiB | 4.21 MiB/s, done.
Resolving deltas: 100% (2104/2104), done.

devops@testvm:~$ cd 90DaysOfDevOps && git remote -v
origin	https://github.com/LondheShubham153/90DaysOfDevOps.git (fetch)
origin	https://github.com/LondheShubham153/90DaysOfDevOps.git (push)
```

`origin` points at somebody else's repo. Committing locally works fine; pushing fails with a 403, because I have no write access.

**Fork** — used the Fork button on GitHub, then cloned my copy:

```
devops@testvm:~$ git clone https://github.com/manish-jha18/90DaysOfDevOps.git
devops@testvm:~$ cd 90DaysOfDevOps && git remote -v
origin	https://github.com/manish-jha18/90DaysOfDevOps.git (fetch)
origin	https://github.com/manish-jha18/90DaysOfDevOps.git (push)
```

Same content, but now `origin` is mine and I can push.

### Difference between clone and fork

**Clone is a Git operation.** It copies a repository from a server to my machine. Works with any Git host, or no host at all.

**Fork is a GitHub feature.** It makes a server-side copy of a repository under my account. Git itself has no concept of a fork — the result is just another repository that GitHub remembers is related to the original.

| | Clone | Fork |
|---|---|---|
| Where the copy lives | My machine | My GitHub account |
| Part of Git or GitHub | Git | GitHub |
| Can I push to it | Only with write access | Yes, it is mine |
| Typical use | Get a copy to work on | Contribute to a project I cannot write to |

### When to clone vs fork

**Clone** when I already have write access — my own repos, or my team's.

**Fork** when I want to contribute to a project I do not have write access to, which covers most open source. Fork, clone the fork, branch, push, then open a pull request back to the original.

Forking is also useful for keeping a personal copy of something I want to modify heavily without any intention of contributing back.

### Keeping a fork in sync

A fork does not update by itself. Once the original moves ahead, mine goes stale:

```bash
# once
git remote add upstream https://github.com/LondheShubham153/90DaysOfDevOps.git

# each time
git fetch upstream
git switch main
git merge upstream/main        # or: git rebase upstream/main
git push origin main
```

```
devops@testvm:~/90DaysOfDevOps$ git remote -v
origin	https://github.com/manish-jha18/90DaysOfDevOps.git (fetch)
origin	https://github.com/manish-jha18/90DaysOfDevOps.git (push)
upstream	https://github.com/LondheShubham153/90DaysOfDevOps.git (fetch)
upstream	https://github.com/LondheShubham153/90DaysOfDevOps.git (push)
```

GitHub also has a "Sync fork" button that does the same thing in the browser, and `gh repo sync` from the CLI.

The reason this matters: raising a pull request from a fork that is 200 commits behind produces a diff full of unrelated changes, and it will not merge cleanly.

---

## What I learned

- A branch is one file containing one hash. That is why branching is instant, and why deleting a branch does not delete commits — it deletes a pointer.
- **`git status` can say "up to date" while being out of date.** It compares against a cached `origin/main`, not the server. `git fetch` first.
- `git pull` is `fetch` plus `merge`. Fetching separately means I can see what is coming before it touches my files.
- Fork is GitHub, clone is Git. The distinction matters because a fork needs an `upstream` remote configured manually to stay current.
- `git branch -d` refusing to delete an unmerged branch is a real safety net. `-D` overrides it and is how commits get lost.
- `git switch` and `git restore` exist because `git checkout` did two very different jobs, one of which silently destroys work.
