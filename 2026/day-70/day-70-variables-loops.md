# Day 70 – Variables, Facts, Conditionals and Loops

Playbooks in `ansible/` in this folder.

---

## Task 1: Variables

**`ansible/01-variables.yml`** shows the sources in one place:

```yaml
- name: Variable precedence, demonstrated
  hosts: webservers
  become: true

  vars:
    app_name: devboard
    app_version: "1.0.0"

  vars_files:
    - vars/app.yml

  tasks:
    - name: Show where each value came from
      ansible.builtin.debug:
        msg:
          - "app_name         : {{ app_name }}"
          - "timezone         : {{ timezone }}"
          - "app_port         : {{ app_port }}"
          - "nginx_worker_conn: {{ nginx_worker_connections }}"

    - name: A task-scoped variable
      ansible.builtin.debug:
        msg: "app_version here is {{ app_version }}"
      vars:
        app_version: "override-for-this-task-only"
```

```
TASK [Show where each value came from] *****************************************
ok: [web1] =>
  msg:
  - 'app_name         : devboard'
  - 'timezone         : Asia/Kolkata'
  - 'app_port         : 8080'
  - 'nginx_worker_conn: 512'

ok: [web2] =>
  msg:
  - 'nginx_worker_conn: 1024'
```

**web1 got 512 and web2 got 1024** from the same playbook — `host_vars/web1.yml` beats `group_vars/webservers.yml`.

### Precedence, in the order that matters

Ansible documents 22 levels. In practice these are the ones you meet:

| | Source | Beats |
|---|---|---|
| 1 | Role `defaults/` | everything else loses to nothing — lowest |
| 2 | `group_vars/all.yml` | |
| 3 | `group_vars/<group>.yml` | more specific group wins |
| 4 | `host_vars/<host>.yml` | |
| 5 | Play `vars:` | |
| 6 | `vars_files:` | |
| 7 | Task `vars:` | |
| 8 | Role `vars/` | very high, hard to override |
| 9 | `-e` on the command line | **wins over everything** |

**Two ends of that list are the practically important ones.**

`defaults/` is lowest, which is why a role's tunable knobs go there — a caller overriding them is the expected case (Day 71).

`-e` beats everything, which makes it right for a one-off:

```
devops@testvm:~/day-70/ansible$ ansible-playbook 01-variables.yml -e "app_version=2.0.0"
```

And `role vars/` at level 8 is the trap — putting something there means a caller effectively cannot change it. Only use it for values that genuinely must be fixed.

**The `default` filter for anything that may not exist:**

```yaml
msg: "server_role is {{ server_role | default('secondary') }}"
```

`server_role` is only in `host_vars/web1.yml`. Without the filter, web2 fails with `'server_role' is undefined`.

---

## Task 2: group_vars and host_vars

```
ansible/
├── group_vars/
│   ├── all.yml           every host, lowest of the group_vars
│   └── webservers.yml
├── host_vars/
│   └── web1.yml
└── vars/
    └── app.yml           loaded explicitly with vars_files
```

**`group_vars/` and `host_vars/` load automatically** by filename. `vars/` does not — it needs `vars_files:`.

The distinction is worth using deliberately: `group_vars` for anything tied to *which host this is*, `vars_files` for anything tied to *what this playbook does*.

**`group_vars/webservers.yml`** also holds the structures the loops use:

```yaml
web_packages:
  - nginx
  - curl
  - jq

app_users:
  deploy:
    shell: /bin/bash
    groups: sudo
  monitoring:
    shell: /usr/sbin/nologin
    groups: adm
```

Keeping data out of the playbook is the point. The playbook says *what to do with users*; the group_vars says *which users*. Adding one is a data change, not a logic change.

---

## Task 3: Facts

**`ansible/02-facts-conditionals.yml`**

```
TASK [A few of the useful facts] ***********************************************
ok: [web1] =>
  msg:
  - 'distro   : Ubuntu 22.04'
  - 'family   : Debian'
  - 'arch     : x86_64'
  - 'cpus     : 2'
  - 'memory   : 3919 MB'
  - 'ip       : 10.0.1.204'
  - 'hostname : ip-10-0-1-204'
```

Facts are gathered automatically at the start of every play — a few hundred of them.

```
devops@testvm:~/day-70/ansible$ ansible web1 -m setup | jq -r '.ansible_facts | keys[]' | wc -l
287
```

The ones that come up constantly:

| Fact | Use |
|---|---|
| `ansible_os_family` | `Debian` / `RedHat` — branch on this, not distribution |
| `ansible_distribution_release` | `jammy`, `noble` — for apt repository lines |
| `ansible_architecture` | `x86_64` / `aarch64` |
| `ansible_default_ipv4.address` | The primary IP |
| `ansible_memtotal_mb`, `ansible_processor_vcpus` | Sizing decisions |
| `ansible_date_time.iso8601` | Timestamps in templates |

**`ansible_architecture` needs translating for downloads.** Ansible says `x86_64` and `aarch64`; most release URLs say `amd64` and `arm64`. devboard's `01-install-tools.yml` handles it with a one-line fact:

```yaml
go_arch: "{{ 'arm64' if ansible_architecture == 'aarch64' else 'amd64' }}"
```

Small thing, and it is the difference between a playbook that works on Graviton instances and one that does not.

**Fact gathering costs a few seconds per host.** `gather_facts: false` on a play that needs none, and the fact caching from Day 68's `ansible.cfg` for everything else.

---

## Task 4: Conditionals

```yaml
- name: Install on Debian family
  ansible.builtin.apt:
    name: nginx
    state: present
  when: ansible_os_family == "Debian"

- name: Install on RedHat family
  ansible.builtin.dnf:
    name: nginx
    state: present
  when: ansible_os_family == "RedHat"
```

**`os_family`, not `distribution`.** One branch covers Ubuntu, Debian and Mint; the other covers RHEL, CentOS, Rocky and Amazon Linux. Branching on `ansible_distribution` means a new case for every derivative.

**A list of conditions is an implicit AND:**

```yaml
  when:
    - ansible_distribution == "Ubuntu"
    - ansible_memtotal_mb > 3000
```

More readable than `and` on one line, and it diffs better.

**Order matters when a variable might not exist:**

```yaml
  when: server_role is defined and server_role == "primary"
```

Reversing those two clauses fails on web2, because Jinja evaluates both sides. `is defined` has to come first.

**No `{{ }}` in `when:`.** The condition is already an expression, so `when: {{ x == 1 }}` is wrong and Ansible warns about it. Exactly the same rule as GitHub Actions' `if:` on Day 43.

```
TASK [Install on Debian family] ************************************************
changed: [web1]

TASK [Install on RedHat family] ************************************************
skipping: [web1]

TASK [Only on the primary] *****************************************************
ok: [web1]
skipping: [web2]
```

`skipping` rather than failing. A skipped task is normal, and `--list-tasks` will not tell you which will skip — only a run does.

---

## Task 5: Loops

**`ansible/03-loops.yml`**

```yaml
- name: Install a list of packages
  ansible.builtin.apt:
    name: "{{ item }}"
    state: present
  loop: "{{ web_packages }}"
```

Works, and is the wrong way to do it:

```yaml
- name: Install them all at once instead
  ansible.builtin.apt:
    name: "{{ web_packages }}"
    state: present
```

**The apt module takes a list.** One transaction instead of three, and dependency resolution happens once.

```
# looping
TASK [Install a list of packages] **********************************************
changed: [web1] => (item=nginx)
changed: [web1] => (item=curl)
changed: [web1] => (item=jq)
   real 0m18.4s

# passing the list
TASK [Install them all at once instead] ****************************************
changed: [web1]
   real 0m6.2s
```

Three times faster, and it scales worse the longer the list gets. `apt`, `dnf`, `yum` and `pip` all take lists.

**Loop over a list of dicts** when the items genuinely differ:

```yaml
- name: Create directories with different owners
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    mode: "{{ item.mode }}"
  loop:
    - { path: /opt/devboard, owner: ubuntu, mode: "0755" }
    - { path: /var/log/devboard, owner: syslog, mode: "0750" }
    - { path: /etc/devboard, owner: root, mode: "0700" }
```

**`dict2items` for a mapping:**

```yaml
- name: Create users from a dict
  ansible.builtin.user:
    name: "{{ item.key }}"
    shell: "{{ item.value.shell }}"
    groups: "{{ item.value.groups }}"
    append: true
  loop: "{{ app_users | dict2items }}"
  loop_control:
    label: "{{ item.key }}"
```

**`loop_control.label` is worth having.** Without it, the output prints the entire dict for each item:

```
changed: [web1] => (item={'key': 'deploy', 'value': {'shell': '/bin/bash', 'groups': 'sudo'}})
```

With it:

```
changed: [web1] => (item=deploy)
changed: [web1] => (item=monitoring)
```

On a loop over anything containing a password, `label` also keeps the value out of the log.

**`until` for retrying:**

```yaml
- name: Wait for the app to answer
  ansible.builtin.uri:
    url: "http://localhost:{{ app_port }}/health"
    status_code: 200
  register: health
  until: health.status == 200
  retries: 10
  delay: 3
```

Same shape as Day 34's healthcheck and Day 47's CI wait loop. Thirty seconds of patience instead of a race.

**`loop`, not `with_items`.** `with_*` still works but is the older syntax; `loop` plus filters is the current form.

---

## Task 6: Register and putting it together

**`ansible/04-register.yml`**

```yaml
- name: Check whether the app is already deployed
  ansible.builtin.stat:
    path: /opt/devboard/.deployed
  register: deploy_marker

- name: Deploy only if it is not there
  ansible.builtin.debug:
    msg: "deploying for the first time"
  when: not deploy_marker.stat.exists
```

**`stat` plus `register` plus `when` is the idiom for "only if".** More flexible than `creates:` because the check and the action can be different things.

```yaml
- name: Get the running kernel
  ansible.builtin.command:
    cmd: uname -r
  register: kernel
  changed_when: false
```

A registered command result carries `stdout`, `stderr`, `rc`, `changed` and `failed`. `stdout_lines` is the pre-split version, which avoids a `| split('\n')`.

```yaml
- name: Report
  ansible.builtin.debug:
    msg: >-
      {{ inventory_hostname }} is running kernel {{ kernel.stdout }}
      and {{ 'NEEDS A REBOOT' if reboot_required.stat.exists else 'is up to date' }}
```

```
ok: [web1] =>
  msg: web1 is running kernel 6.8.0-1014-aws and NEEDS A REBOOT
ok: [web2] =>
  msg: web2 is running kernel 6.8.0-1014-aws and is up to date
```

`>-` is Day 38's folded block scalar with the trailing newline stripped — the right tool for a long single-line message.

**`failed_when: false` for something allowed to fail:**

```yaml
- name: Something allowed to fail
  ansible.builtin.command:
    cmd: /usr/local/bin/optional-check
  register: optional
  failed_when: false
  changed_when: false
```

Without it, a non-zero exit aborts the play **for that host** — remaining tasks are skipped and the recap shows `failed=1`. This is Day 43's `continue-on-error` in Ansible form.

`failed_when` can also be a condition rather than a flag, which is how you handle a command whose exit code does not mean what you want:

```yaml
  failed_when: "'ERROR' in result.stdout"
```

**Failing deliberately, with a useful message:**

```yaml
- name: Refuse to continue on an unsupported OS
  ansible.builtin.fail:
    msg: "This playbook supports Debian-family systems only. Found {{ ansible_os_family }}."
  when: ansible_os_family != "Debian"
```

Failing early with an explanation beats failing on task 30 with `dnf: command not found`. Same reasoning as Day 67's Terraform precondition and Day 63's variable validation — three tools, one idea.

`ansible.builtin.assert` is the tidier form when checking several conditions at once.

---

## Files in this folder

| Path | What it demonstrates |
|---|---|
| `ansible/01-variables.yml` | Precedence across play, file, group, host and task scope |
| `ansible/02-facts-conditionals.yml` | Facts, `os_family` branching, `is defined` ordering |
| `ansible/03-loops.yml` | `loop`, list-to-module, `dict2items`, `loop_control.label`, `until` |
| `ansible/04-register.yml` | `register`, `stat`, `changed_when`, `failed_when`, `fail` |
| `ansible/group_vars/`, `host_vars/`, `vars/` | The three variable locations |

---

## What I learned

**1. Looping a package module is three times slower than passing it the list.** `loop: "{{ web_packages }}"` runs three apt transactions; `name: "{{ web_packages }}"` runs one. The loop version looks more idiomatic and is the wrong instinct for anything that accepts a list.

**2. `when: x is defined and x == 'y'` only works in that order.** Jinja evaluates both sides, so testing the value first fails on any host where the variable is absent. It reads like short-circuit evaluation and is not.

**3. `changed_when: false` and `failed_when: false` are what make `command` usable.** Without them every read-only command reports CHANGED and every non-zero exit aborts the play for that host. The `command` module gives you no idempotency and no error tolerance by default — you supply both.

**Two extras:**

- `loop_control.label` keeps loop output readable, and keeps secrets out of the log when looping over structures that contain them.
- Branch on `ansible_os_family`, not `ansible_distribution`. One branch covers every Debian derivative rather than one per distro.
