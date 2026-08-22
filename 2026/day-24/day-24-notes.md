# Day 24 – Merge, Rebase, Stash and Cherry Pick

All run in `devops-git-practice`. New commands added to `git-commands.md` in the day-22 folder.

---

## Task 1: Git merge

### Fast-forward merge

```
devops@testvm:~/devops-git-practice$ git switch -c feature-login
devops@testvm:~/devops-git-practice$ git commit -am "Add branch command"
devops@testvm:~/devops-git-practice$ git commit -am "Add checkout command"

devops@testvm:~/devops-git-practice$ git switch main
devops@testvm:~/devops-git-practice$ git merge feature-login
Updating 505ed6f..63f0332
Fast-forward
 git-commands.md | 2 ++
 1 file changed, 2 insertions(+)
```

**Fast-forward**, because `main` had not moved since I branched. There was nothing to combine — Git just slid the `main` pointer forward to where `feature-login` already was. No merge commit is created.

### Merge commit

```
devops@testvm:~/devops-git-practice$ git switch -c feature-signup
devops@testvm:~/devops-git-practice$ git commit -am "Add switch command"

devops@testvm:~/devops-git-practice$ git switch main
devops@testvm:~/devops-git-practice$ git commit -am "Add notes section on main"
```

Now both branches have commits the other does not. The history has genuinely forked:

```
devops@testvm:~/devops-git-practice$ git log --oneline --graph --all
* 1d5723d (feature-signup) Add switch command
| * e4edc43 (HEAD -> main) Add notes section on main
|/
* 63f0332 Add checkout command
* 77d766c Add branch command
* 505ed6f Add compact log command
```

The `|/` is where they split.

### The merge conflict

I did not have to engineer this one — both branches appended to the end of the same file:

```
devops@testvm:~/devops-git-practice$ git merge feature-signup
Auto-merging git-commands.md
CONFLICT (content): Merge conflict in git-commands.md
Automatic merge failed; fix conflicts and then commit the result.

devops@testvm:~/devops-git-practice$ git status
On branch main
You have unmerged paths.
  (fix conflicts and run "git commit")
  (use "git merge --abort" to abort the merge)

Unmerged paths:
  (use "git add <file>..." to mark resolution)
	both modified:   git-commands.md
```

What Git wrote into the file:

```
- git log --oneline
- git branch
- git checkout
<<<<<<< HEAD

## Notes
Updated on main
=======
- git switch
>>>>>>> feature-signup
```

Reading the markers:

- `<<<<<<< HEAD` down to `=======` — the version on my current branch (`main`)
- `=======` down to `>>>>>>> feature-signup` — the version coming in

Resolving means editing the file so it says what I actually want, **including deleting all three marker lines**, then:

```
devops@testvm:~/devops-git-practice$ git add git-commands.md
devops@testvm:~/devops-git-practice$ git commit --no-edit
[main d6687b6] Merge branch 'feature-signup'

devops@testvm:~/devops-git-practice$ git log --oneline --graph --all
*   d6687b6 (HEAD -> main) Merge branch 'feature-signup'
|\
| * 1d5723d (feature-signup) Add switch command
* | e4edc43 Add notes section on main
|/
* 63f0332 Add checkout command
```

The `|\` and `|/` show the split and rejoin. That diamond shape is a merge commit — the only kind of commit with two parents.

### Answers

**What is a fast-forward merge?** When the target branch has no commits of its own since the split, Git moves its pointer forward instead of merging. No new commit, perfectly linear history. Use `--no-ff` to force a merge commit anyway, which keeps a visible record that a feature branch existed.

**When does Git create a merge commit?** When both branches have new commits — the histories have diverged and there is no single pointer move that captures both. The merge commit has two parents.

**What is a merge conflict?** When both branches changed the *same lines* of the *same file*, Git cannot decide which version wins, so it stops and asks. Conflicts only happen on overlapping lines — two people editing different parts of the same file merge automatically.

Useful escape hatch: `git merge --abort` puts everything back exactly as it was before the merge started. Worth knowing before you need it.

---

## Task 2: Git rebase

```
devops@testvm:~/devops-git-practice$ git switch -c feature-dashboard
devops@testvm:~/devops-git-practice$ git commit -m "Add first dashboard widget"
devops@testvm:~/devops-git-practice$ git commit -m "Add second dashboard widget"

devops@testvm:~/devops-git-practice$ git switch main
devops@testvm:~/devops-git-practice$ git commit -m "Update readme on main"
```

**Before the rebase — branches diverged:**

```
devops@testvm:~/devops-git-practice$ git log --oneline --graph --all
* 269f9b6 (HEAD -> main) Update readme on main
| * e1ae68c (feature-dashboard) Add second dashboard widget
| * 0a93793 Add first dashboard widget
|/
*   d6687b6 Merge branch 'feature-signup'
```

**The rebase:**

```
devops@testvm:~/devops-git-practice$ git switch feature-dashboard
devops@testvm:~/devops-git-practice$ git rebase main
Successfully rebased and updated refs/heads/feature-dashboard.
```

**After:**

```
devops@testvm:~/devops-git-practice$ git log --oneline --graph --all
* d1cc23a (HEAD -> feature-dashboard) Add second dashboard widget
* 0f4fd90 Add first dashboard widget
* 269f9b6 (main) Update readme on main
*   d6687b6 Merge branch 'feature-signup'
```

The fork is gone. One straight line.

**The detail that matters:** the hashes changed. `0a93793` became `0f4fd90` and `e1ae68c` became `d1cc23a`. Same author, same message, same content — different commits.

### Answers

**What does rebase actually do?** It takes my commits, sets them aside, moves my branch to the tip of the target, then replays each commit on top one at a time. Because a commit's hash is computed from its content *and its parent*, a new parent means a new hash. The originals still exist temporarily in the reflog but nothing points at them.

**How is the history different from a merge?**

| | Merge | Rebase |
|---|---|---|
| Shape | Branching, with diamonds | One straight line |
| Extra commit | Yes, the merge commit | No |
| Hashes | Unchanged | All rewritten |
| Record of the branch | Preserved | Erased |
| Honest about what happened | Yes | No — it looks like sequential work |

**Why never rebase pushed and shared commits?** Because rebasing replaces commits with new ones that have different hashes. If someone else has the originals, their history and mine no longer agree. My push is rejected, and forcing it means their next pull produces duplicated commits or a mess of conflicts — and any commit they made on top of the old ones is orphaned.

The rule I am going with: **rebase before sharing, merge after.** Private local branch, rebase freely. Pushed where someone else might have pulled it, merge.

**When to use which?**
- **Rebase** to tidy up my own branch before opening a pull request, or to pick up `main`'s latest changes without a noisy merge commit.
- **Merge** to bring a finished feature into `main`, and any time the branch is shared.

`git pull --rebase` is worth setting as a default — it stops "Merge branch 'main' of github.com..." commits appearing every time two people work on the same branch.

---

## Task 3: Squash merge vs merge commit

```
devops@testvm:~/devops-git-practice$ git switch -c feature-profile
devops@testvm:~/devops-git-practice$ git log --oneline -4
2b50156 (HEAD -> feature-profile) Remove trailing whitespace
ae91afa Adjust profile formatting
015b60f Fix typo in profile
fff3b3c Add profile page
```

Four commits, three of which are noise nobody will ever want to read.

```
devops@testvm:~/devops-git-practice$ git switch main
devops@testvm:~/devops-git-practice$ git merge --squash feature-profile
Updating 269f9b6..2b50156
Fast-forward
Squash commit -- not updating HEAD
 profile.md | 4 ++++
 1 file changed, 4 insertions(+)
```

Note `Squash commit -- not updating HEAD`. It staged all the changes but did **not** commit — that is left to me:

```
devops@testvm:~/devops-git-practice$ git status --short
A  profile.md

devops@testvm:~/devops-git-practice$ git commit -m "Add profile page"
[main e6d977a] Add profile page

devops@testvm:~/devops-git-practice$ git log --oneline -3
e6d977a (HEAD -> main) Add profile page
269f9b6 Update readme on main
d6687b6 Merge branch 'feature-signup'
```

**One commit added to `main`, not four.** All four commits' changes are in it; the four commits themselves are not.

Compared with a regular merge of `feature-settings`, where all the individual commits appear in `main`'s history plus a merge commit on top.

### Answers

**What does squash merging do?** It applies every change from the branch as a single set of staged edits, discarding the individual commits. The branch's history does not enter `main` at all.

**When to use which?**

| Squash merge | Regular merge |
|---|---|
| Small feature, messy commits | Large feature with meaningful stages |
| "Fix typo", "oops", "wip" commits | Each commit is a coherent step |
| Want one line per feature in `main` | Want the full development record |
| Most pull requests | Long-lived release branches |

**What is the trade-off?** You lose granularity permanently. If the squashed commit turns out to introduce a bug, `git bisect` narrows it down to one large commit rather than one small one, and you cannot revert just the part that broke.

There is also a practical annoyance: after a squash merge, the branch's commits do not exist in `main`, so Git does not consider the branch merged. `git branch -d` refuses and you need `-D`. Merging the same branch again later re-applies everything and conflicts.

The compromise most teams land on: squash-merge pull requests into `main`, but keep the branch's real history visible on the PR page for anyone who wants it.

---

## Task 4: Git stash

**The problem, reproduced:**

```
devops@testvm:~/devops-git-practice$ echo "uncommitted edit" >> readme.md

devops@testvm:~/devops-git-practice$ git switch other-branch
error: Your local changes to the following files would be overwritten by checkout:
	readme.md
Please commit your changes or stash them before you switch branches.
Aborting
```

Git refused rather than destroying my work. Note it only refuses when the file *differs* on the target branch — otherwise the edit comes along with me, which is its own kind of surprise.

**Stash it:**

```
devops@testvm:~/devops-git-practice$ git stash push -m "wip on readme"
Saved working directory and index state On main: wip on readme

devops@testvm:~/devops-git-practice$ git status --short

devops@testvm:~/devops-git-practice$ git status
On branch main
nothing to commit, working tree clean
```

Working tree clean, and I can switch freely.

**Multiple stashes:**

```
devops@testvm:~/devops-git-practice$ echo "another wip" >> profile.md
devops@testvm:~/devops-git-practice$ git stash push -m "wip on profile"
Saved working directory and index state On main: wip on profile

devops@testvm:~/devops-git-practice$ git stash list
stash@{0}: On main: wip on profile
stash@{1}: On main: wip on readme
```

It is a **stack** — newest is always `stash@{0}`, and everything else shifts down as you add more. That is exactly why the `-m` message matters: `stash@{2}` on its own tells you nothing three days later.

**Apply a specific one:**

```
devops@testvm:~/devops-git-practice$ git stash apply stash@{1}
On branch main
Changes not staged for commit:
	modified:   readme.md

devops@testvm:~/devops-git-practice$ git stash list
stash@{0}: On main: wip on profile
stash@{1}: On main: wip on readme
```

Both stashes still listed — `apply` does not remove anything.

**Pop:**

```
devops@testvm:~/devops-git-practice$ git stash pop
On branch main
Changes not staged for commit:
	modified:   readme.md
Dropped refs/stash@{0}

devops@testvm:~/devops-git-practice$ git stash list
```

Empty. `pop` applied it and deleted it.

### Answers

**`pop` vs `apply`:** both restore the changes; `pop` also deletes the stash, `apply` keeps it.

Use `apply` when the changes might need to go onto more than one branch, or when you are not certain they will apply cleanly and want a copy to fall back on. Use `pop` for the normal case of picking work back up.

A detail worth knowing: **if `pop` hits a conflict, the stash is not dropped.** Git keeps it so the work is not lost, which means after resolving you have to `git stash drop` manually or it lingers.

**When to use stash in real work?**

- Halfway through a feature and a production bug needs fixing now.
- Need to `git pull` but have uncommitted changes blocking it.
- Want to check whether a bug exists on `main` without committing half-finished work.
- Started editing on the wrong branch — stash, switch, pop.

The caveat: **`git stash` ignores untracked files by default.** A brand new file is not stashed and stays in the working directory. `git stash -u` includes them. I would rather commit to a scratch branch than leave anything important in a stash — stashes are easy to forget and invisible in `git log`.

---

## Task 5: Cherry-pick

```
devops@testvm:~/devops-git-practice$ git switch -c feature-hotfix
devops@testvm:~/devops-git-practice$ git log --oneline -3
7448707 (HEAD -> feature-hotfix) Hotfix: update error copy
d3f1213 Hotfix: patch null pointer in auth
e68979c Hotfix: fix login redirect
```

**Pick only the second commit:**

```
devops@testvm:~/devops-git-practice$ git switch main
devops@testvm:~/devops-git-practice$ git cherry-pick d3f1213
[main 7a3b523] Hotfix: patch null pointer in auth
 Date: Sat Jul 4 11:26:14 2026 +0530
 1 file changed, 1 insertion(+)

devops@testvm:~/devops-git-practice$ git log --oneline -3
7a3b523 (HEAD -> main) Hotfix: patch null pointer in auth
e6d977a Add profile page
269f9b6 Update readme on main

devops@testvm:~/devops-git-practice$ ls fix-*.md
fix-b.md
```

Only that one commit landed, and only its file exists on `main`. The other two are still only on the branch.

**Note the hash: `d3f1213` became `7a3b523`.** Same content and message, different parent, so a different commit — the same rewriting that happens during a rebase.

### The failure I hit first

My first attempt had all three commits editing the same file, and picking the second one failed:

```
devops@testvm:~/devops-git-practice$ git cherry-pick 496b72d
CONFLICT (modify/delete): hotfix.md deleted in HEAD and modified in 496b72d
error: could not apply 496b72d... Hotfix commit two - the important one
```

The reason is worth writing down. Commit two *modified* `hotfix.md`, but the commit that *created* that file was commit one, which I did not pick. On `main` the file did not exist, so there was nothing to modify. Cherry-picking a commit that depends on an earlier commit does not work.

`git cherry-pick --abort` backed it out cleanly.

### Answers

**What does cherry-pick do?** Takes the diff introduced by one commit and applies it to the current branch as a new commit.

**When to use it in a real project?**

- A hotfix committed to `develop` that needs to go to `main` right now, without shipping everything else on `develop`.
- Backporting a security fix onto an older release branch.
- Recovering one useful commit from a branch that is otherwise being abandoned.
- A commit made on the wrong branch — cherry-pick it across, then drop it from the original.

**What can go wrong?**

1. **Dependent commits**, as above. Picking a commit whose context is missing gives a conflict or, worse, applies cleanly and produces broken code.
2. **Duplicate commits.** The same change now exists as two different hashes. Merging the branch properly later can conflict or apply it twice.
3. **It hides where the change came from.** The new commit has no link back to the original, so tracing history gets harder.
4. **Easy to overuse.** Repeatedly cherry-picking between long-lived branches usually means the branching strategy is wrong. Merging is the tool for combining branches; cherry-pick is for the single-commit exception.

---

## What I learned

**1. Rebase and cherry-pick both create new commits with new hashes.** They copy the *changes*, not the commits. Once I understood that a hash is derived from the content plus the parent, the "never rebase shared history" rule stopped being a rule to memorise and became obvious — the commits other people have are gone.

**2. The tool choice is about what you want the history to say.** Merge records what actually happened, including the branching. Rebase and squash produce a tidier story that never literally occurred. Neither is right in general, but rewriting is only safe before anyone else has seen it.

**3. Git works quite hard not to lose your work.** It refused to switch branches over an uncommitted change, refused to delete an unmerged branch, and kept the stash when `pop` conflicted. Every destructive operation needs an explicit override — `-D`, `--hard`, `--force`. Those flags are the ones to slow down on.

**Two smaller things:**

- `git merge --squash` stages the changes without committing, so you write the message yourself.
- `git merge --abort` and `git cherry-pick --abort` restore the previous state exactly. Knowing they exist makes experimenting much less nerve-wracking.
