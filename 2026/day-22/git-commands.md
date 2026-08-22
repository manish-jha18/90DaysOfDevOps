# Git Commands Reference

Started on Day 22 and updated each day as I meet new commands. Ordered by what I reach for most.

---

## Setup and config

| Command | What it does |
|---|---|
| `git --version` | Check Git is installed and which version |
| `git config --global user.name "name"` | Set the name stamped on every commit |
| `git config --global user.email "email"` | Set the email stamped on every commit |
| `git config --global init.defaultBranch main` | Make `git init` create `main` instead of `master` |
| `git config --list` | Show all settings currently in effect |
| `git config --list --global` | Only the global ones |
| `git config user.name "name"` | Set identity for this repo only, overrides global |

```bash
git config --global user.name "manish-jha18"
git config --global user.email "manishkumar181999@gmail.com"
```

---

## Starting a repository

| Command | What it does |
|---|---|
| `git init` | Turn the current folder into a Git repo |
| `git clone <url>` | Download a remote repo including all history |
| `git clone <url> <folder>` | Clone into a specific folder name |
| `git clone --depth 1 <url>` | Shallow clone, latest commit only — fast for big repos |

```bash
git clone https://github.com/manish-jha18/devops-git-practice.git
```

---

## Basic workflow

| Command | What it does |
|---|---|
| `git status` | What is changed, staged, and untracked |
| `git status -s` | Short version, two-column format |
| `git add <file>` | Stage one file for the next commit |
| `git add .` | Stage everything below the current directory |
| `git add -p` | Step through each change and choose what to stage |
| `git commit -m "msg"` | Commit what is staged |
| `git commit -am "msg"` | Stage tracked files and commit in one step |
| `git commit --amend` | Rewrite the last commit — only if it is not pushed |
| `git rm <file>` | Delete a file and stage the deletion |
| `git mv old new` | Rename a file and stage it |

`-am` does **not** pick up brand new files. Those still need `git add` first.

---

## Viewing changes and history

| Command | What it does |
|---|---|
| `git diff` | Changes not yet staged |
| `git diff --staged` | Changes that are staged for the next commit |
| `git diff main..feature` | Difference between two branches |
| `git log` | Full history with author, date and message |
| `git log --oneline` | One line per commit |
| `git log --oneline --graph --all` | Visual branch structure — the one I use most |
| `git log -n 5` | Last five commits |
| `git log -p` | History including the diffs |
| `git log --author="manish"` | Filter by author |
| `git show <hash>` | Everything about one commit, including its diff |
| `git blame <file>` | Which commit last touched each line |

```bash
git log --oneline --graph --all
```

---

## Undoing things

| Command | What it does |
|---|---|
| `git restore <file>` | Discard working-directory changes to a file |
| `git restore --staged <file>` | Unstage, keeping the edit |
| `git checkout -- <file>` | Older syntax for discarding changes |
| `git revert <hash>` | New commit that undoes an old one — safe on shared branches |
| `git reset --soft <hash>` | Move the branch pointer, keep everything staged |
| `git reset --mixed <hash>` | Move the pointer, unstage, keep the files |
| `git reset --hard <hash>` | Move the pointer and throw the changes away |
| `git reflog` | Log of everywhere HEAD has been — how to recover a bad reset |

`git reset --hard` is the one command here that genuinely loses work. `git reflog` is the safety net.

---

## Branching

| Command | What it does |
|---|---|
| `git branch` | List local branches, `*` marks the current one |
| `git branch -a` | Include remote branches |
| `git branch <name>` | Create a branch without switching to it |
| `git switch <name>` | Switch to a branch |
| `git switch -c <name>` | Create and switch in one step |
| `git checkout <name>` | Older way to switch |
| `git checkout -b <name>` | Older way to create and switch |
| `git branch -d <name>` | Delete a branch, refuses if unmerged |
| `git branch -D <name>` | Force delete |
| `git branch -m old new` | Rename a branch |
| `git branch -M main` | Force-rename the current branch to main |

`git switch` only changes branches. `git checkout` also restores files, which is why it was split into `switch` and `restore`.

---

## Remotes

| Command | What it does |
|---|---|
| `git remote -v` | List remotes and their URLs |
| `git remote add origin <url>` | Connect a local repo to a remote |
| `git remote add upstream <url>` | Add the original repo when working from a fork |
| `git remote set-url origin <url>` | Change an existing remote's URL |
| `git remote remove <name>` | Disconnect a remote |
| `git push origin main` | Push a branch to the remote |
| `git push -u origin <branch>` | Push and set the upstream so later pushes need no arguments |
| `git push --all origin` | Push every branch |
| `git push origin --delete <branch>` | Delete a remote branch |
| `git fetch` | Download remote changes without touching my files |
| `git pull` | Fetch and merge in one step |
| `git pull --rebase` | Fetch and rebase instead of merging |

`origin` is my own remote. `upstream` is the convention for the repo I forked from.

---

## Merging

| Command | What it does |
|---|---|
| `git merge <branch>` | Merge a branch into the current one |
| `git merge --no-ff <branch>` | Force a merge commit even when fast-forward is possible |
| `git merge --squash <branch>` | Combine all the branch's changes into one staged set |
| `git merge --abort` | Back out of a merge that hit conflicts |
| `git diff --name-only --diff-filter=U` | List the files currently conflicted |

---

## Rebase

| Command | What it does |
|---|---|
| `git rebase <branch>` | Replay my commits on top of another branch |
| `git rebase -i HEAD~3` | Interactive — reorder, squash, reword the last 3 |
| `git rebase --continue` | Carry on after fixing a conflict |
| `git rebase --abort` | Give up and return to where I started |
| `git rebase --skip` | Skip the commit that is conflicting |

Never rebase commits that are already pushed and shared. It rewrites hashes.

---

## Stash

| Command | What it does |
|---|---|
| `git stash` | Shelve uncommitted changes and clean the working tree |
| `git stash push -m "msg"` | Stash with a description |
| `git stash list` | Show all stashes |
| `git stash pop` | Reapply the newest stash and remove it from the list |
| `git stash apply` | Reapply but keep it in the list |
| `git stash apply stash@{1}` | Reapply a specific one |
| `git stash drop stash@{0}` | Delete one stash |
| `git stash clear` | Delete all of them |
| `git stash -u` | Include untracked files |

---

## Cherry-pick

| Command | What it does |
|---|---|
| `git cherry-pick <hash>` | Apply one commit from another branch |
| `git cherry-pick <a>^..<b>` | Apply a range |
| `git cherry-pick -n <hash>` | Apply it but do not commit yet |
| `git cherry-pick --abort` | Back out |

The new commit gets a **different hash**, because the parent is different.

---

## Tags

| Command | What it does |
|---|---|
| `git tag` | List tags |
| `git tag v1.0.0` | Lightweight tag on the current commit |
| `git tag -a v1.0.0 -m "msg"` | Annotated tag, stores author and date |
| `git push origin v1.0.0` | Push one tag |
| `git push origin --tags` | Push all tags |

Tags are not pushed by `git push` on their own — they need to be pushed explicitly.

---

## GitHub CLI

| Command | What it does |
|---|---|
| `gh auth login` | Authenticate |
| `gh auth status` | Check who I am logged in as |
| `gh repo create <name> --public` | Create a repo from the terminal |
| `gh repo clone <owner>/<repo>` | Clone |
| `gh repo view --web` | Open the repo in a browser |
| `gh issue list` | List issues |
| `gh issue create --title "t" --body "b"` | Open an issue |
| `gh pr create --title "t" --body "b"` | Open a pull request |
| `gh pr list` | List pull requests |
| `gh pr checkout <number>` | Check out a PR locally to test it |
| `gh pr merge <number>` | Merge a PR |
| `gh run list` | Recent GitHub Actions runs |

---

## Things worth remembering

- `git status` before and after nearly everything.
- `git log --oneline --graph --all` is the fastest way to understand what state a repo is in.
- `git reflog` can recover almost any mistake, including a hard reset.
- Never rewrite history that has been pushed and shared.
- `git add -p` builds clean commits out of a messy working tree.
