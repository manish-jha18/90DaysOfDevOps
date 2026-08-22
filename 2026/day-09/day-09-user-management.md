# Day 09 – Linux User and Group Management Challenge

All five tasks done on my Ubuntu 22.04 VM. Everything needed `sudo`, since user and group changes are root-only.

---

## Task 1: Create users

```
devops@testvm:~$ sudo useradd -m -s /bin/bash tokyo
devops@testvm:~$ sudo useradd -m -s /bin/bash berlin
devops@testvm:~$ sudo useradd -m -s /bin/bash professor
```

`-m` creates the home directory, `-s /bin/bash` gives a real shell. Without `-m` the user exists but has nowhere to live, and without `-s` they get `/bin/sh`.

**Set passwords:**

```
devops@testvm:~$ sudo passwd tokyo
New password:
Retype new password:
passwd: password updated successfully
```

Repeated for `berlin` and `professor`.

**Verify in /etc/passwd:**

```
devops@testvm:~$ tail -n 3 /etc/passwd
tokyo:x:1001:1001::/home/tokyo:/bin/bash
berlin:x:1002:1002::/home/berlin:/bin/bash
professor:x:1003:1003::/home/professor:/bin/bash
```

Reading the fields: username, `x` (password is in `/etc/shadow`, not here), UID, GID, comment, home, shell. UIDs start at 1001 because my own account took 1000.

**Verify home directories:**

```
devops@testvm:~$ ls -l /home
total 16
drwxr-x--- 3 berlin    berlin    4096 Jun 17 08:14 berlin
drwxr-x--- 5 devops    devops    4096 Jun 17 08:02 devops
drwxr-x--- 3 professor professor 4096 Jun 17 08:14 professor
drwxr-x--- 3 tokyo     tokyo     4096 Jun 17 08:13 tokyo
```

Each user owns their own home at `750`, so users cannot read each other's files.

---

## Task 2: Create groups

```
devops@testvm:~$ sudo groupadd developers
devops@testvm:~$ sudo groupadd admins
```

**Verify in /etc/group:**

```
devops@testvm:~$ grep -E "developers|admins" /etc/group
developers:x:1004:
admins:x:1005:
```

Both exist with no members yet — the field after the GID is empty. That gets filled in the next task.

Something worth noticing: `useradd` already created a personal group for each user (`tokyo:x:1001:`). Ubuntu gives every user their own group by default, which is why a new file is `user:user` rather than `user:users`.

---

## Task 3: Assign users to groups

```
devops@testvm:~$ sudo usermod -aG developers tokyo
devops@testvm:~$ sudo usermod -aG developers,admins berlin
devops@testvm:~$ sudo usermod -aG admins professor
```

The `-a` matters. `usermod -G developers berlin` would **replace** all of berlin's secondary groups instead of adding to them. `-aG` appends. Leaving out the `-a` is the classic way to accidentally remove someone from `sudo`.

**Verify:**

```
devops@testvm:~$ groups tokyo berlin professor
tokyo : tokyo developers
berlin : berlin developers admins
professor : professor admins
```

```
devops@testvm:~$ grep -E "developers|admins" /etc/group
developers:x:1004:tokyo,berlin
admins:x:1005:berlin,professor
```

Two views of the same thing. `groups <user>` answers "what groups is this user in", `/etc/group` answers "who is in this group".

The first group listed for each user is their primary group. The rest are secondary.

---

## Task 4: Shared directory

```
devops@testvm:~$ sudo mkdir /opt/dev-project
devops@testvm:~$ sudo chgrp developers /opt/dev-project
devops@testvm:~$ sudo chmod 775 /opt/dev-project

devops@testvm:~$ ls -ld /opt/dev-project
drwxrwxr-x 2 root developers 4096 Jun 17 08:31 /opt/dev-project
```

Breaking down `775`: owner `root` gets `rwx` (7), group `developers` gets `rwx` (7), everyone else gets `r-x` (5). So developers can create files and others can only look.

**Test as tokyo:**

```
devops@testvm:~$ sudo -u tokyo touch /opt/dev-project/tokyo-file.txt
```

**Test as berlin:**

```
devops@testvm:~$ sudo -u berlin touch /opt/dev-project/berlin-file.txt
```

**Test as professor, who is not in developers:**

```
devops@testvm:~$ sudo -u professor touch /opt/dev-project/professor-file.txt
touch: cannot touch '/opt/dev-project/professor-file.txt': Permission denied
```

That denial is the proof the permissions actually work. I would not have known the setup was correct without testing a user who should fail.

**Result:**

```
devops@testvm:~$ ls -l /opt/dev-project
total 0
-rw-rw-r-- 1 berlin berlin 0 Jun 17 08:34 berlin-file.txt
-rw-rw-r-- 1 tokyo  tokyo  0 Jun 17 08:33 tokyo-file.txt
```

One catch here: each file is owned by `tokyo:tokyo` and `berlin:berlin`, not by the `developers` group. So berlin can enter the directory but cannot write to tokyo's file. Setting the setgid bit with `sudo chmod g+s /opt/dev-project` would make new files inherit the `developers` group, which is what a real shared project directory needs.

---

## Task 5: Team workspace

```
devops@testvm:~$ sudo useradd -m -s /bin/bash nairobi
devops@testvm:~$ sudo passwd nairobi
New password:
Retype new password:
passwd: password updated successfully

devops@testvm:~$ sudo groupadd project-team
devops@testvm:~$ sudo usermod -aG project-team nairobi
devops@testvm:~$ sudo usermod -aG project-team tokyo

devops@testvm:~$ sudo mkdir /opt/team-workspace
devops@testvm:~$ sudo chgrp project-team /opt/team-workspace
devops@testvm:~$ sudo chmod 775 /opt/team-workspace
```

**Verify:**

```
devops@testvm:~$ ls -ld /opt/team-workspace
drwxrwxr-x 2 root project-team 4096 Jun 17 08:41 /opt/team-workspace

devops@testvm:~$ groups nairobi tokyo
nairobi : nairobi project-team
tokyo : tokyo developers project-team
```

`tokyo` is now in three groups. A user can belong to as many as needed.

**Test:**

```
devops@testvm:~$ sudo -u nairobi touch /opt/team-workspace/nairobi-notes.txt

devops@testvm:~$ sudo -u berlin touch /opt/team-workspace/berlin-notes.txt
touch: cannot touch '/opt/team-workspace/berlin-notes.txt': Permission denied

devops@testvm:~$ ls -l /opt/team-workspace
total 0
-rw-rw-r-- 1 nairobi nairobi 0 Jun 17 08:43 nairobi-notes.txt
```

`nairobi` works, `berlin` is correctly blocked because berlin is not in `project-team`.

---

## Users and Groups Created

| User | UID | Primary group | Secondary groups |
|---|---|---|---|
| tokyo | 1001 | tokyo | developers, project-team |
| berlin | 1002 | berlin | developers, admins |
| professor | 1003 | professor | admins |
| nairobi | 1004 | nairobi | project-team |

| Group | GID | Members |
|---|---|---|
| developers | 1004 | tokyo, berlin |
| admins | 1005 | berlin, professor |
| project-team | 1007 | nairobi, tokyo |

---

## Directories Created

| Directory | Owner | Group | Permissions | Who can write |
|---|---|---|---|---|
| `/opt/dev-project` | root | developers | 775 (`drwxrwxr-x`) | tokyo, berlin |
| `/opt/team-workspace` | root | project-team | 775 (`drwxrwxr-x`) | nairobi, tokyo |

---

## Commands Used

| Command | Purpose |
|---|---|
| `useradd -m -s /bin/bash <user>` | Create a user with a home directory and bash shell |
| `passwd <user>` | Set the password |
| `groupadd <group>` | Create a group |
| `usermod -aG <group> <user>` | Add a user to a group without removing existing ones |
| `groups <user>` | Show which groups a user belongs to |
| `id <user>` | UID, GID and all groups with their numbers |
| `chgrp <group> <dir>` | Change the group owner |
| `chmod 775 <dir>` | Set read/write/execute for owner and group, read/execute for others |
| `ls -ld <dir>` | Show the directory's own permissions, not its contents |
| `sudo -u <user> <command>` | Run a command as another user to test access |
| `getent group <group>` | Look up a group, works with LDAP too, unlike grepping `/etc/group` |

---

## What I Learned

- `usermod -aG` versus `usermod -G` is the dangerous one. Forgetting `-a` wipes every other secondary group, including `sudo`.
- Testing with a user who *should* fail is the only way to know the permissions are right. A successful write proves nothing on its own.
- `775` on a shared directory is not the whole answer. Files still get the creator's personal group, so setgid (`chmod g+s`) is needed for genuine collaboration.
- `ls -ld` shows the directory itself. Plain `ls -l` lists what is inside it, which is not what I wanted here.
- Ubuntu gives every user a private group with the same name, which is why default file ownership looks like `tokyo:tokyo`.
- `sudo -u <user>` is the fastest way to test access without logging in and out.
