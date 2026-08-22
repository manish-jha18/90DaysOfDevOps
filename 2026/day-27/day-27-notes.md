# Day 27 – GitHub Profile Makeover

Branding day. No new tools, just making the profile say something useful to anyone who lands on it.

---

## Task 1: Audit

Opened my own profile logged out, in a private window, to see what a stranger sees. Uncomfortable exercise, which is the point.

| Question | Honest answer |
|---|---|
| Is the profile picture professional? | No — default grey avatar, no photo at all |
| Is the bio filled in? | Empty |
| Are pinned repos relevant? | Nothing pinned. Just repos in "recently updated" order |
| Do repos have descriptions? | 2 out of 7. The rest blank |
| Would a recruiter understand what I have been working on? | No |

The specific problem: the most visible repo was a fork from months ago with no commits from me. Someone spending fifteen seconds would conclude I fork things and do not finish them, which is the opposite of what the last 27 days show.

Two other things I found:

- One repo called `test2`. No description, three commits, no idea what it was for.
- An old project with a `config.js` containing a hardcoded API key. Dead key for a service I no longer use, but it should never have been committed.

---

## Task 2: Profile README

Created a repo named `manish-jha18` — same as the username, which is what makes GitHub treat its README as the profile page. It has to be **public** and the file has to be `README.md` at the root, or nothing appears.

```
devops@testvm:~$ gh repo create manish-jha18 --public --add-readme \
    --description "My GitHub profile README"
✓ Created repository manish-jha18/manish-jha18 on GitHub

devops@testvm:~$ gh repo clone manish-jha18/manish-jha18
devops@testvm:~$ cd manish-jha18
```

A copy of what I wrote is saved in this folder as `profile-README.md`.

```
devops@testvm:~/manish-jha18$ git commit -am "Add profile README"
devops@testvm:~/manish-jha18$ git push
```

I kept it to about 20 lines. The guidance says do not overload it with badges, and looking at profiles I actually respect, none of them are covered in animated GIFs and streak counters. The ones that read well say what the person is doing right now and link to the work.

What I deliberately left out:

- Visitor counters and trophy widgets — they say nothing about my work.
- A long list of every technology I have heard of. Claiming Kubernetes on day 27 would be dishonest, and it is the kind of thing that falls apart in an interview.
- Animated banners. They slow the page and add nothing.

What I made sure to include: what I am doing **now**, with a link to the repo that proves it.

---

## Task 3: Organising repositories

| Repo | Description | Purpose |
|---|---|---|
| `90DaysOfDevOps` | My daily submissions for the 90 Days of DevOps challenge | The main body of work |
| `shell-scripts` | Reusable bash scripts for backups, log rotation and system reporting | Scripts from Days 16–21, cleaned up |
| `devops-notes` | Cheat sheets and reference notes for Linux, Git and shell scripting | Day 21 cheat sheet, `git-commands.md` |
| `devops-git-practice` | Practice repo for Git branching, merging and rebasing | Working repo from Days 22–26 |

```
devops@testvm:~$ gh repo create shell-scripts --public \
    --description "Reusable bash scripts for backups, log rotation and system reporting"
✓ Created repository manish-jha18/shell-scripts

devops@testvm:~$ gh repo create devops-notes --public \
    --description "Cheat sheets and reference notes for Linux, Git and shell scripting"
✓ Created repository manish-jha18/devops-notes
```

For each one I added a description, a README explaining what is inside and how to run it, and a `.gitignore`.

The `shell-scripts` README lists each script with one line on what it does and how to call it, because a folder of `.sh` files with no explanation is not useful to anyone including me in six months.

**A note on the Python repo:** the task lists a Python scripts repo holding work from Days 7–15. In this cohort those days were Linux file system, cloud deployment, users and permissions, LVM and networking — no Python. So I did not create an empty repo for it. If Python days appear later I will add one then. An empty repo with a hopeful name is exactly the kind of clutter Task 5 is about removing.

```
devops@testvm:~$ gh repo list --limit 10
manish-jha18/90DaysOfDevOps       My daily submissions for the 90 Days...  public
manish-jha18/manish-jha18         My GitHub profile README                 public
manish-jha18/shell-scripts        Reusable bash scripts for backups...     public
manish-jha18/devops-notes         Cheat sheets and reference notes...      public
manish-jha18/devops-git-practice  Practice repo for Git branching...       public
```

---

## Task 4: Pinned repositories

Picked five rather than filling all six slots, because two of the six would have been padding.

1. **90DaysOfDevOps** — the most substantial thing I have, and it shows consistency
2. **shell-scripts** — actual working code rather than notes
3. **devops-notes** — shows I document what I learn
4. **devops-git-practice** — evidence of deliberate Git practice
5. **manish-jha18** — the profile README itself

Ordered so the strongest is first. Every one has a description and a README, since a pinned repo with a blank description wastes the slot.

---

## Task 5: Cleanup

**Deleted:**

```
devops@testvm:~$ gh repo delete manish-jha18/test2
? Type manish-jha18/test2 to confirm deletion: manish-jha18/test2
✓ Deleted repository manish-jha18/test2
```

Also removed two forks I had never committed to. A fork with no commits of mine adds nothing and dilutes the rest.

**Renamed:** `MyScripts` became `shell-scripts`. Hyphens, lower case, and a name that says what it holds.

**Secrets check.** This was the important part. Deleting a file does not remove it — the old version stays in the history and is retrievable by anyone.

```
devops@testvm:~$ cd old-project
devops@testvm:~/old-project$ git log --all --full-history -- "*config.js" | head -5
commit 8a2f91c4d3e05b17a6c8f2914b7d3e05a1c6f8b2
Author: manish-jha18 <manishkumar181999@gmail.com>
Date:   Mon Mar 16 21:14:08 2026 +0530

    Add config

devops@testvm:~/old-project$ git show 8a2f91c:config.js | grep -i "key"
  apiKey: "sk_live_4f8a2b91c7e35d06",
```

Still there, in a public repo. The key was already revoked, but the lesson stands: **the fix is to rotate the credential, not to delete the file.** Anyone could have copied it in the months it was public.

Since the repo had no value, I deleted it outright. Had it mattered, the options would have been `git filter-repo` or BFG to rewrite history, followed by a force push — and rotating the key regardless.

Checked the rest with a quick sweep:

```
devops@testvm:~$ for r in 90DaysOfDevOps shell-scripts devops-notes devops-git-practice; do
>   echo "--- $r ---"
>   git -C "$r" log --all --oneline -- "*.env" "*.pem" "*credentials*" "*secret*" | head -3
> done
--- 90DaysOfDevOps ---
--- shell-scripts ---
--- devops-notes ---
--- devops-git-practice ---
```

All clean. Added a `.gitignore` with `.env`, `*.pem` and `*.key` to each so it stays that way.

---

## Task 6: Before and after

**Before:** default avatar, empty bio, nothing pinned, a fork sitting at the top of the page, two of seven repos described, one repo named `test2`, and a live-looking API key in a public commit history.

**After:** profile photo, one-line bio saying what I do and what I am learning, five pinned repos in a deliberate order, every repo named and described, dead repos gone, the key rotated and its repo deleted.

### Three things I improved and why

**1. Pinned repos, chosen deliberately.** Before, GitHub showed whatever I touched most recently, which happened to be an untouched fork. Pinned repos are the only part of the page I fully control, and they are what a visitor reads first. Now the first thing shown is 27 days of consistent work.

**2. A description on every repo.** Search results and the profile list show the description, not the README. A blank one makes the repo look abandoned even when it is not. One sentence each, and the whole profile becomes scannable in fifteen seconds.

**3. Removed a leaked credential and added `.gitignore` files.** This is the one that actually mattered. Everything else is presentation; a public API key is a real problem. It also taught me that `git rm` is not enough — history keeps the old version, and rotating the secret is the only real fix.

---

## What I learned

- **Deleting a secret from a file does not remove it from the repository.** It stays in the history and stays retrievable. Rotate the credential; treat rewriting history as cleanup, not as the fix.
- **A profile README needs a repo named exactly after the username, and it must be public.** Get either wrong and nothing shows up, with no error to explain why.
- **Fewer, better repos beat more repos.** Deleting `test2` and two dead forks improved the profile more than anything I added, because it removed the impression of starting things and abandoning them.
- **Descriptions are what get read.** A README is one click away; the description is on the page. Blank ones make good work look neglected.
- `gh repo create` and `gh repo delete` made this whole day faster than clicking through settings pages, and `gh repo list` gave me the full picture in one command.
