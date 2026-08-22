# Day 11 – File Ownership Challenge (chown and chgrp)

Six tasks on ownership. Day 10 was about *what* you can do to a file; today is about *who* the file belongs to. Worked in `~/day-11`.

---

## Task 1: Understanding ownership

```
devops@testvm:~$ ls -l
total 24
drwxrwxr-x 2 devops devops 4096 Jun 13 11:02 day-06
drwxrwxr-x 3 devops devops 4096 Jun 19 09:34 day-10
-rw-r--r-- 1 devops devops  214 Jun 14 09:44 backup.sh
-rw-rw-r-- 1 devops devops   91 Jun 19 09:14 notes.txt
```

Reading the columns:

```
-rw-r--r--  1  devops  devops  214  Jun 14 09:44  backup.sh
    ↑       ↑    ↑        ↑
permissions │  owner    group
          links
```

**Owner vs group:**

The **owner** is one specific user, normally whoever created the file. They get the first `rwx` block.

The **group** is a set of users, and every member gets the second `rwx` block. This is how several people share access without making a file world-readable.

A user who is neither the owner nor in the group falls into "others" and gets the third block. Linux checks in that order and stops at the first match — so if I am the owner, my owner permissions apply even if the group has more access. That order matters: being in a group with `rw` does not help if the owner block says `r--` and I am the owner.

---

## Task 2: Basic chown operations

```
devops@testvm:~/day-11$ touch devops-file.txt

devops@testvm:~/day-11$ ls -l devops-file.txt
-rw-rw-r-- 1 devops devops 0 Jun 20 10:02 devops-file.txt
```

**Change owner to tokyo:**

```
devops@testvm:~/day-11$ sudo chown tokyo devops-file.txt

devops@testvm:~/day-11$ ls -l devops-file.txt
-rw-rw-r-- 1 tokyo devops 0 Jun 20 10:02 devops-file.txt
```

Owner changed, group stayed as `devops`. `chown` on its own only touches the owner.

**Change owner to berlin:**

```
devops@testvm:~/day-11$ sudo chown berlin devops-file.txt

devops@testvm:~/day-11$ ls -l devops-file.txt
-rw-rw-r-- 1 berlin devops 0 Jun 20 10:02 devops-file.txt
```

I tried it without `sudo` first:

```
devops@testvm:~/day-11$ chown tokyo devops-file.txt
chown: changing ownership of 'devops-file.txt': Operation not permitted
```

Even as the owner of the file I cannot give it away. Only root can. That is deliberate — otherwise anyone could dump a huge file into someone else's disk quota, or hand off a file with the setuid bit set.

---

## Task 3: Basic chgrp operations

```
devops@testvm:~/day-11$ touch team-notes.txt

devops@testvm:~/day-11$ ls -l team-notes.txt
-rw-rw-r-- 1 devops devops 0 Jun 20 10:11 team-notes.txt

devops@testvm:~/day-11$ sudo groupadd heist-team

devops@testvm:~/day-11$ sudo chgrp heist-team team-notes.txt

devops@testvm:~/day-11$ ls -l team-notes.txt
-rw-rw-r-- 1 devops heist-team 0 Jun 20 10:11 team-notes.txt
```

Group changed, owner untouched. `sudo chown :heist-team team-notes.txt` does exactly the same job — the colon with nothing before it means "group only".

What happens with a group that does not exist:

```
devops@testvm:~/day-11$ sudo chgrp ghost-team team-notes.txt
chgrp: invalid group: 'ghost-team'
```

The group has to exist first. Same rule for users with `chown`.

---

## Task 4: Combined owner and group change

```
devops@testvm:~/day-11$ touch project-config.yaml

devops@testvm:~/day-11$ sudo chown professor:heist-team project-config.yaml

devops@testvm:~/day-11$ ls -l project-config.yaml
-rw-rw-r-- 1 professor heist-team 0 Jun 20 10:19 project-config.yaml
```

One command, both changed. The `owner:group` form is what I will use most.

```
devops@testvm:~/day-11$ mkdir app-logs

devops@testvm:~/day-11$ sudo chown berlin:heist-team app-logs

devops@testvm:~/day-11$ ls -ld app-logs
drwxrwxr-x 2 berlin heist-team 4096 Jun 20 10:22 app-logs
```

`ls -ld` again, because plain `ls -l app-logs` would list what is inside instead of showing the directory itself.

---

## Task 5: Recursive ownership

```
devops@testvm:~/day-11$ mkdir -p heist-project/vault
devops@testvm:~/day-11$ mkdir -p heist-project/plans
devops@testvm:~/day-11$ touch heist-project/vault/gold.txt
devops@testvm:~/day-11$ touch heist-project/plans/strategy.conf

devops@testvm:~/day-11$ sudo groupadd planners
```

**Before:**

```
devops@testvm:~/day-11$ ls -lR heist-project/
heist-project/:
total 8
drwxrwxr-x 2 devops devops 4096 Jun 20 10:31 plans
drwxrwxr-x 2 devops devops 4096 Jun 20 10:31 vault

heist-project/plans:
total 0
-rw-rw-r-- 1 devops devops 0 Jun 20 10:31 strategy.conf

heist-project/vault:
total 0
-rw-rw-r-- 1 devops devops 0 Jun 20 10:31 gold.txt
```

**Recursive change:**

```
devops@testvm:~/day-11$ sudo chown -R professor:planners heist-project/
```

**After:**

```
devops@testvm:~/day-11$ ls -lR heist-project/
heist-project/:
total 8
drwxrwxr-x 2 professor planners 4096 Jun 20 10:31 plans
drwxrwxr-x 2 professor planners 4096 Jun 20 10:31 vault

heist-project/plans:
total 0
-rw-rw-r-- 1 professor planners 0 Jun 20 10:31 strategy.conf

heist-project/vault:
total 0
-rw-rw-r-- 1 professor planners 0 Jun 20 10:31 gold.txt
```

```
devops@testvm:~/day-11$ ls -ld heist-project
drwxrwxr-x 4 professor planners 4096 Jun 20 10:31 heist-project
```

Everything changed in one go — the top directory, both subdirectories and both files. Without `-R` only `heist-project` itself would have changed and the contents would still be `devops:devops`.

`-R` is worth respecting. `sudo chown -R user:group /` would rewrite ownership across the whole system and break the box. Always check `pwd` before running it, and a trailing slash on the wrong variable in a script is a genuine outage.

---

## Task 6: Practice challenge

Users `tokyo`, `berlin` and `nairobi` already exist from Day 09, so only the groups were new.

```
devops@testvm:~/day-11$ sudo groupadd vault-team
devops@testvm:~/day-11$ sudo groupadd tech-team

devops@testvm:~/day-11$ mkdir bank-heist
devops@testvm:~/day-11$ touch bank-heist/access-codes.txt
devops@testvm:~/day-11$ touch bank-heist/blueprints.pdf
devops@testvm:~/day-11$ touch bank-heist/escape-plan.txt
```

**Set the ownership:**

```
devops@testvm:~/day-11$ sudo chown tokyo:vault-team bank-heist/access-codes.txt
devops@testvm:~/day-11$ sudo chown berlin:tech-team bank-heist/blueprints.pdf
devops@testvm:~/day-11$ sudo chown nairobi:vault-team bank-heist/escape-plan.txt
```

**Verify:**

```
devops@testvm:~/day-11$ ls -l bank-heist/
total 0
-rw-rw-r-- 1 tokyo   vault-team 0 Jun 20 10:44 access-codes.txt
-rw-rw-r-- 1 berlin  tech-team  0 Jun 20 10:44 blueprints.pdf
-rw-rw-r-- 1 nairobi vault-team 0 Jun 20 10:44 escape-plan.txt
```

Three files in one directory, three different owners, two different groups. Ownership is per file, not per folder.

One thing that stands out: all three are still `-rw-rw-r--`, so **others** can read every one of them. Ownership decides *who* the permissions apply to, but the permission bits decide *what* they allow. For something called `access-codes.txt` I would also want `chmod 640` so it is not world-readable.

```
devops@testvm:~/day-11$ sudo chmod 640 bank-heist/access-codes.txt

devops@testvm:~/day-11$ ls -l bank-heist/access-codes.txt
-rw-r----- 1 tokyo vault-team 0 Jun 20 10:44 access-codes.txt
```

---

## Files and Directories Created

| Path | Type |
|---|---|
| `devops-file.txt` | File |
| `team-notes.txt` | File |
| `project-config.yaml` | File |
| `app-logs/` | Directory |
| `heist-project/vault/gold.txt` | File |
| `heist-project/plans/strategy.conf` | File |
| `bank-heist/access-codes.txt` | File |
| `bank-heist/blueprints.pdf` | File |
| `bank-heist/escape-plan.txt` | File |

**Groups created:** `heist-team`, `planners`, `vault-team`, `tech-team`

---

## Ownership Changes

| File | Before | After | Command |
|---|---|---|---|
| `devops-file.txt` | `devops:devops` | `tokyo:devops` | `sudo chown tokyo devops-file.txt` |
| `devops-file.txt` | `tokyo:devops` | `berlin:devops` | `sudo chown berlin devops-file.txt` |
| `team-notes.txt` | `devops:devops` | `devops:heist-team` | `sudo chgrp heist-team team-notes.txt` |
| `project-config.yaml` | `devops:devops` | `professor:heist-team` | `sudo chown professor:heist-team project-config.yaml` |
| `app-logs/` | `devops:devops` | `berlin:heist-team` | `sudo chown berlin:heist-team app-logs` |
| `heist-project/` and all contents | `devops:devops` | `professor:planners` | `sudo chown -R professor:planners heist-project/` |
| `bank-heist/access-codes.txt` | `devops:devops` | `tokyo:vault-team` | `sudo chown tokyo:vault-team ...` |
| `bank-heist/blueprints.pdf` | `devops:devops` | `berlin:tech-team` | `sudo chown berlin:tech-team ...` |
| `bank-heist/escape-plan.txt` | `devops:devops` | `nairobi:vault-team` | `sudo chown nairobi:vault-team ...` |

---

## Commands Used

| Command | Purpose |
|---|---|
| `ls -l file` | Show owner and group |
| `ls -ld dir` | Show the directory's own ownership |
| `ls -lR dir/` | Recursive listing, used to verify `-R` worked |
| `sudo chown user file` | Change owner only |
| `sudo chgrp group file` | Change group only |
| `sudo chown :group file` | Change group only, using chown |
| `sudo chown user:group file` | Change both at once |
| `sudo chown -R user:group dir/` | Change everything underneath |
| `sudo groupadd group` | Create a group before using it |
| `mkdir -p a/b` | Create nested directories |
| `stat file` | Full detail including numeric UID and GID |

---

## What I Learned

- Only root can change a file's owner. Even owning the file is not enough, which stops people dumping files into someone else's quota.
- `chown user:group` in one command is the practical form. `chgrp` still exists but `chown :group` does the same thing.
- `-R` changes everything underneath, and there is no undo. Checking `pwd` before running it is a cheap habit.
- The user or group must exist first, or the command fails with `invalid group`.
- Ownership and permissions are two separate things. Setting the right owner does nothing if the file is still world-readable — I had to add `chmod 640` on top.
- Permission checks stop at the first matching category. Owner beats group, group beats others, so being in a privileged group does not help if the owner bits are restrictive and I am the owner.
