# Day 22 – Introduction to Git

Practice repo for this week is `devops-git-practice`, created locally. `git-commands.md` in this folder is the living reference I will keep adding to.

---

## Task 1: Install and configure Git

```
devops@testvm:~$ git --version
git version 2.34.1

devops@testvm:~$ git config --global user.name "manish-jha18"
devops@testvm:~$ git config --global user.email "manishkumar181999@gmail.com"

devops@testvm:~$ git config --list --global
user.name=manish-jha18
user.email=manishkumar181999@gmail.com
init.defaultbranch=main
```

I also set `init.defaultBranch=main`, because `git init` still creates `master` by default on this version and every tutorial and remote assumes `main`.

The identity is not a login. Git stamps that name and email onto every commit I make, and it is never verified — anyone can set any name. Authentication to GitHub is separate.

---

## Task 2: Create the Git project

```
devops@testvm:~$ mkdir devops-git-practice && cd devops-git-practice

devops@testvm:~/devops-git-practice$ git init
Initialized empty Git repository in /home/devops/devops-git-practice/.git/

devops@testvm:~/devops-git-practice$ git status
On branch main

No commits yet

nothing to commit (create/copy files and use "git add" to track)
```

Reading that output: I am on `main`, nothing has been committed, and there is nothing to commit. Three separate facts, and `git status` almost always tells me exactly what to do next.

**Inside `.git/`:**

```
devops@testvm:~/devops-git-practice$ ls -1 .git
HEAD
config
description
hooks
info
objects
refs
```

| Item | What it holds |
|---|---|
| `HEAD` | A pointer to the branch I am currently on |
| `config` | Repo-specific settings, including the remote URL |
| `objects/` | Every commit, file version and tree, stored by hash |
| `refs/` | Where each branch and tag points |
| `hooks/` | Scripts that can run automatically on commit, push and so on |

```
devops@testvm:~/devops-git-practice$ cat .git/HEAD
ref: refs/heads/main
```

`HEAD` is literally one line of text saying which branch I am on. Everything Git does is files on disk, not a database.

---

## Task 3: Git commands reference

Created `git-commands.md` and started filling it in by category. That file lives in this folder and I will keep adding to it as the week goes on.

---

## Task 4: Stage and commit

```
devops@testvm:~/devops-git-practice$ git add git-commands.md

devops@testvm:~/devops-git-practice$ git status
On branch main

No commits yet

Changes to be committed:
  (use "git rm --cached <file>..." to unstage)
	new file:   git-commands.md

devops@testvm:~/devops-git-practice$ git commit -m "Add git-commands.md with setup commands"
[main (root-commit) 282b145] Add git-commands.md with setup commands
 1 file changed, 4 insertions(+)
 create mode 100644 git-commands.md

devops@testvm:~/devops-git-practice$ git log
commit 282b145a2f8c9e1d4b7a0f36e52c8d914a6b3f07 (HEAD -> main)
Author: manish-jha18 <manishkumar181999@gmail.com>
Date:   Wed Jul 1 09:14:22 2026 +0530

    Add git-commands.md with setup commands
```

`(root-commit)` appears only on the very first commit, because it has no parent.

---

## Task 5: Build up some history

Made three more edits, committing each one separately.

```
devops@testvm:~/devops-git-practice$ git diff
diff --git a/git-commands.md b/git-commands.md
index 8f4a2c1..b91e7d3 100644
--- a/git-commands.md
+++ b/git-commands.md
@@ -2,3 +2,5 @@

 ## Setup
 - git init
+- git status
+- git add
```

`git diff` shows what changed but is *not* staged yet. Lines with `+` are additions. Once I run `git add`, this output goes empty and I need `git diff --staged` instead — that confused me for a minute.

```
devops@testvm:~/devops-git-practice$ git commit -am "Add basic workflow commands"
devops@testvm:~/devops-git-practice$ git commit -am "Add viewing changes commands"
devops@testvm:~/devops-git-practice$ git commit -am "Add compact log command"

devops@testvm:~/devops-git-practice$ git log --oneline
505ed6f (HEAD -> main) Add compact log command
b2d4b62 Add viewing changes commands
b2989f5 Add basic workflow commands
282b145 Add git-commands.md with setup commands
```

Four commits. `-am` stages and commits in one step, but only for files Git is already tracking — a brand new file still needs `git add` first.

---

## Task 6: Understanding the Git workflow

### 1. What is the difference between `git add` and `git commit`?

`git add` copies the current state of a file into the **staging area**. Nothing is saved to history yet.

`git commit` takes whatever is in the staging area and writes it permanently as a snapshot with a message and a hash.

The important detail is that `add` captures the file **as it is at that moment**. If I `git add file.txt`, then edit it again, and then commit, the commit contains the earlier version. Git even shows the file twice in `git status` — once staged, once modified.

### 2. What does the staging area do? Why not commit directly?

The staging area lets me choose *what goes into a commit* separately from *what I have changed*.

Say I fixed a bug and also changed some indentation in the same file. Committing directly means one commit containing two unrelated things. With staging I can commit the bug fix alone, then the formatting separately:

```
git add -p file.py     # step through each change and pick
```

That matters because a clean history is what makes `git log` useful, and it is what lets you revert one change without undoing another. It is also why a script that runs `git add .` and commits everything is usually a bad habit — it is the thing that accidentally commits a `.env` file.

### 3. What does `git log` show?

For every commit, newest first: the full SHA hash, the author name and email, the timestamp, and the message. Also, in brackets, which branch or tag points at that commit.

Useful variants I have found:

```bash
git log --oneline              # one line per commit
git log --oneline --graph      # draws the branch structure
git log -n 5                   # last 5 only
git log --author="manish"      # filter by author
git log -p                     # include the actual diffs
git log --since="2 days ago"   # filter by time
```

### 4. What is `.git/` and what happens if I delete it?

`.git/` **is** the repository. The files in my folder are just the current checkout; all the history, branches, and configuration live in `.git/`.

Deleting it turns the folder back into ordinary files. Every commit, every branch, the remote URL — gone, with no undo. The current files survive because they exist on disk independently, but everything else is unrecoverable unless there is a copy pushed somewhere.

This is also why cloning is enough to get a full backup: a clone copies the entire `.git/` directory, so every developer has the complete history. That is what "distributed" means in "distributed version control".

### 5. Working directory vs staging area vs repository

| Area | What it is | How to inspect |
|---|---|---|
| **Working directory** | The actual files I can open and edit | `ls`, any editor |
| **Staging area** (index) | A list of what will go into the next commit | `git diff --staged` |
| **Repository** | The committed history in `.git/` | `git log` |

Changes flow one way:

```
working directory  --git add-->  staging area  --git commit-->  repository
```

And back the other way when I need to undo:

```bash
git restore --staged file    # staging area -> working directory (unstage)
git restore file             # discard the working directory change entirely
git checkout <commit>        # repository -> working directory
```

The mental model that made it click: the staging area is a **draft of the next commit**. I build it up piece by piece, and committing publishes the draft.

---

## What I learned

- `git status` is the command I should run constantly. It reports the state of all three areas and usually tells me the exact command I need next.
- Staging is not a hoop to jump through. It is what makes it possible to build one clean commit out of a messy working directory.
- `.git/` is the entire repository — plain files, readable with `cat`. `HEAD` is literally one line of text.
- `git add` snapshots the file at that instant, not at commit time.
- `git commit -am` skips staging but only for already-tracked files, which is an easy way to leave a new file out of a commit by accident.
