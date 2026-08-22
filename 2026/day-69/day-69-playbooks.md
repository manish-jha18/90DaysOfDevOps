# Day 69 – Ansible Playbooks and Modules

Playbooks in `ansible/` in this folder.

---

## Task 1: The first playbook

**`ansible/01-first-playbook.yml`**

```yaml
---
- name: Install and start nginx
  hosts: webservers
  become: true

  tasks:
    - name: Install nginx
      ansible.builtin.apt:
        name: nginx
        state: present
        update_cache: true

    - name: Start nginx and enable it at boot
      ansible.builtin.service:
        name: nginx
        state: started
        enabled: true
```

```
devops@testvm:~/day-69/ansible$ ansible-playbook 01-first-playbook.yml

PLAY [Install and start nginx] *************************************************

TASK [Gathering Facts] *********************************************************
ok: [web1]
ok: [web2]

TASK [Install nginx] ***********************************************************
changed: [web1]
changed: [web2]

TASK [Start nginx and enable it at boot] ***************************************
changed: [web1]
changed: [web2]

PLAY RECAP *********************************************************************
web1  : ok=3  changed=2  unreachable=0  failed=0  skipped=0
web2  : ok=3  changed=2  unreachable=0  failed=0  skipped=0
```

Running it again:

```
PLAY RECAP *********************************************************************
web1  : ok=3  changed=0  unreachable=0  failed=0  skipped=0
```

**`changed=0`.** Idempotency in the recap line, which is the number to watch — on a mature playbook, a non-zero `changed` on an unchanged system means something is not idempotent.

**`Gathering Facts` runs automatically** and is not in the file. It collects a few hundred facts about each host. `gather_facts: false` skips it when a play needs none, which saves a few seconds per host.

---

## Task 2: Structure

```
Playbook  = a list of PLAYS
  Play    = hosts + tasks, plus how to run them
    Task  = one module call
      Module = the unit that does the work
```

Play-level keys worth knowing:

```yaml
- name: Human-readable name
  hosts: webservers          # which inventory pattern
  become: true               # sudo
  become_user: postgres      # sudo to a specific user, not root
  gather_facts: true
  serial: 1                  # how many hosts at a time
  max_fail_percentage: 25    # abort if more than a quarter fail
  any_errors_fatal: true     # one host failing stops everything
  vars: {}
  vars_files: []
  roles: []
  pre_tasks: []
  tasks: []
  post_tasks: []
  handlers: []
```

**Execution order is `pre_tasks` → roles → `tasks` → `post_tasks`**, with handlers flushed after each of those sections. This matters — a handler notified in `tasks` has already run before `post_tasks` begins.

**`name:` on every task.** Without it the log shows the module call, which is unreadable in a 40-task run. Same reasoning as naming GitHub Actions steps on Day 40.

**Use fully qualified module names** — `ansible.builtin.apt`, not `apt`. Short names still work but rely on collection search order, and they are ambiguous once several collections are installed. devboard's playbooks use FQCN throughout.

---

## Task 3: The essential modules

**`ansible/02-modules.yml`** covers the ones that do most of the work.

### Packages

```yaml
- name: Install packages
  ansible.builtin.apt:
    name: "{{ common_packages }}"
    state: present
    update_cache: true
    cache_valid_time: 3600
```

**`cache_valid_time: 3600`** skips `apt-get update` if it ran within the hour. Without it every run spends 10–20 seconds refreshing indexes that have not changed.

Passing the whole list to `name:` is much faster than looping — one apt transaction instead of N. Day 70 shows the difference.

`state: present` versus `latest`: **`latest` is not idempotent in any useful sense.** It upgrades whenever upstream publishes, so a playbook that has not changed produces a different result on different days. Pin the version or use `present`.

### Files

```yaml
- name: Copy a static file
  ansible.builtin.copy:
    src: files/index.html
    dest: /var/www/html/index.html
    owner: www-data
    mode: "0644"
    backup: true

- name: Render a config from a template
  ansible.builtin.template:
    src: templates/app.conf.j2
    dest: /etc/devboard/app.conf
    mode: "0644"
```

**`copy` for static files, `template` for anything with variables.** Template runs the file through Jinja2 first — Day 71's topic.

**`mode: "0644"` in quotes.** Unquoted, YAML reads `0644` as a number, and Ansible interprets it as decimal 644 — which is octal 1204, a nonsense permission. This is Day 38's YAML typing rule producing a genuinely confusing bug.

`backup: true` keeps a timestamped copy of whatever was replaced. Cheap insurance on a config file.

### Line-level edits

```yaml
- name: Ensure a setting exists in a config file
  ansible.builtin.lineinfile:
    path: /etc/security/limits.conf
    regexp: '^\*\s+soft\s+nofile'
    line: "*    soft    nofile    65536"

- name: Insert a managed block
  ansible.builtin.blockinfile:
    path: /etc/hosts
    marker: "# {mark} DEVBOARD MANAGED"
    block: |
      10.0.1.10  db1.internal
      10.0.1.11  cache.internal
```

**The `regexp` on `lineinfile` is what makes it idempotent.** It finds an existing matching line and replaces it, rather than appending a duplicate. Omit it and every run adds another copy.

`blockinfile` wraps its content in markers so it can find and update the block later. Better than several `lineinfile` tasks for anything multi-line.

**Both are a compromise.** Managing the whole file with `template` is cleaner when you own it; `lineinfile` is for files something else also writes.

### Users

```yaml
- name: Create the app user
  ansible.builtin.user:
    name: devboard
    shell: /bin/bash
    groups: docker
    append: true
```

**`append: true` is not optional.** Without it, `groups: docker` **replaces** every other group the user is in — including `sudo`. That is Day 23's `usermod -aG` versus `-G` lesson, in a different tool, with the same consequence.

### Commands, as a last resort

```yaml
- name: Run something with no module
  ansible.builtin.command:
    cmd: /usr/local/bin/devboard-init
    creates: /opt/devboard/.initialised

- name: Read something without changing anything
  ansible.builtin.command:
    cmd: nginx -v
  register: nginx_version
  changed_when: false
```

**`creates:` makes a command idempotent** — the task is skipped entirely if that path exists. `removes:` is the inverse. This is the same idea as the `creates:` guards throughout devboard's `01-install-tools.yml`, which is what stops it re-downloading Terraform on every run.

**`changed_when: false` for anything read-only.** Day 68 showed `uptime` reporting CHANGED; this is the fix. It matters because the changed count is the main signal in a run, and a playbook that always reports changes trains you to ignore it.

---

## Task 4: Handlers

**`ansible/03-handlers.yml`**

```yaml
  tasks:
    - name: Deploy the nginx config
      ansible.builtin.template:
        src: templates/nginx.conf.j2
        dest: /etc/nginx/nginx.conf
        validate: "nginx -t -c %s"
      notify: Reload nginx

    - name: Deploy the site config
      ansible.builtin.template:
        src: templates/site.conf.j2
        dest: /etc/nginx/sites-available/devboard
      notify: Reload nginx

    - name: Enable the site
      ansible.builtin.file:
        src: /etc/nginx/sites-available/devboard
        dest: /etc/nginx/sites-enabled/devboard
        state: link
      notify: Reload nginx

  handlers:
    - name: Reload nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded
```

```
TASK [Deploy the nginx config] *************************************************
changed: [web1]

TASK [Deploy the site config] **************************************************
changed: [web1]

TASK [Enable the site] *********************************************************
changed: [web1]

RUNNING HANDLER [Reload nginx] *************************************************
changed: [web1]

PLAY RECAP *********************************************************************
web1  : ok=5  changed=4
```

**Notified three times, ran once.** Handlers are deduplicated and run at the **end of the play**, not where they are notified.

Running again with nothing changed:

```
TASK [Deploy the nginx config] *************************************************
ok: [web1]

PLAY RECAP *********************************************************************
web1  : ok=4  changed=0
```

**No handler at all.** A handler only fires if the notifying task reported `changed`. That is the point — nginx is not reloaded on every run, only when its config actually moved.

### `validate:` is the line worth copying

```yaml
    validate: "nginx -t -c %s"
```

Ansible renders the template to a temporary file, runs `nginx -t -c <tmpfile>`, and **only writes the real file if that exits 0**. A syntax error in the template means the task fails and the existing config is untouched.

Without it, a broken template is written, the handler tries to reload, nginx refuses to start, and the site is down. The failure lands on the running server instead of on the playbook.

`%s` is substituted with the temporary path. `visudo -cf %s` for sudoers, `sshd -t -f %s` for SSH config — the same protection.

### Two handler behaviours to know

**A handler does not run if the play fails first.** Tasks after the failure are skipped, and so are pending handlers, so a config change can be written without the service being reloaded. `force_handlers: true` on the play overrides that.

**`meta: flush_handlers`** runs pending handlers immediately rather than at the end, which is needed when a later task depends on the reload having happened.

---

## Task 5: Dry run, diff and verbosity

```
devops@testvm:~/day-69/ansible$ ansible-playbook 03-handlers.yml --check

TASK [Deploy the nginx config] *************************************************
changed: [web1]

PLAY RECAP *********************************************************************
web1  : ok=4  changed=2
```

**`--check` changes nothing** and reports what would change. Ansible's equivalent of `terraform plan`.

**Its limitation is real:** a task in check mode does not run, so any later task depending on its result sees the old state. A playbook that installs a package and then configures it reports the configure step oddly in check mode, because the package was never installed. Check mode is a good signal, not a guarantee.

```
devops@testvm:~/day-69/ansible$ ansible-playbook 03-handlers.yml --check --diff

TASK [Deploy the site config] **************************************************
--- before: /etc/nginx/sites-available/devboard
+++ after: /home/devops/day-69/ansible/templates/site.conf.j2
@@ -3,7 +3,7 @@
 server {
     listen 80;
-    server_name old.example.com;
+    server_name _;

changed: [web1]
```

**`--check --diff` together is the useful pair** — it shows the actual line-by-line change, not just that something will change. This is what I would run before any config deployment.

```
devops@testvm:~/day-69/ansible$ ansible-playbook 03-handlers.yml -v      # task results
devops@testvm:~/day-69/ansible$ ansible-playbook 03-handlers.yml -vvv    # + module args and SSH
devops@testvm:~/day-69/ansible$ ansible-playbook 03-handlers.yml -vvvv   # + connection debug
```

`-vvv` is the level for "why did this task do that". `-vvvv` is for "why will it not connect".

**`no_log: true` interacts with this.** A task handling a secret should set it, or `-vvv` prints the value. Day 72's Docker login does exactly that.

Other flags in regular use:

```bash
ansible-playbook site.yml --limit web1           # one host
ansible-playbook site.yml --tags nginx           # only tagged tasks
ansible-playbook site.yml --skip-tags slow
ansible-playbook site.yml --start-at-task "Deploy the site config"
ansible-playbook site.yml --step                 # confirm each task
ansible-playbook site.yml --syntax-check         # parse only
```

`--syntax-check` is the CI equivalent of `terraform validate`. `ansible-lint` goes further and catches the things above — unquoted `mode`, missing `changed_when`, short module names.

---

## Task 6: Multiple plays

**`ansible/04-multi-play.yml`** — three plays in one file, each targeting a different group:

```yaml
- name: Common setup on every host
  hosts: devboard
  become: true
  tasks:
    - name: Install the base packages
      ansible.builtin.apt:
        name: "{{ common_packages }}"
        state: present

- name: Database tier
  hosts: dbservers
  become: true
  tasks:
    - name: Install postgres
      ansible.builtin.apt:
        name: postgresql
        state: present

- name: Web tier
  hosts: webservers
  become: true
  serial: 1
  tasks:
    - name: Install nginx
      ansible.builtin.apt:
        name: nginx
        state: present

    - name: Wait for it to answer before moving to the next host
      ansible.builtin.uri:
        url: "http://{{ ansible_host }}:{{ http_port }}"
        status_code: 200
      delegate_to: localhost
      become: false
      retries: 5
      delay: 3
      register: result
      until: result.status == 200
```

```
PLAY [Common setup on every host] **********************************************
changed: [web1]
changed: [web2]
changed: [db1]

PLAY [Database tier] ***********************************************************
changed: [db1]

PLAY [Web tier] ****************************************************************
changed: [web1]
ok: [web1]

PLAY [Web tier] ****************************************************************
changed: [web2]
ok: [web2]
```

**Plays run in order** — everything gets the base packages before the tiers are configured. Within a play, all hosts run in parallel by default.

### `serial: 1` is the rolling update

Notice the web tier play appears **twice** — once per host. `serial: 1` runs the entire play against one host, finishes it, then moves to the next.

**That is a rolling deployment**, and the same shape as Day 52's `maxUnavailable: 0`. Combined with the health check, web2 is not touched until web1 is confirmed serving. If web1 fails the check, the run stops and web2 is left on the old version.

`serial: "25%"` and `serial: [1, 5, 10]` — the latter is a canary: one host, then five, then ten.

### `delegate_to: localhost`

The health check runs **from the control node**, not from the target. Checking from the host itself would only prove nginx is listening locally; checking from outside proves it is actually reachable — the Day 36 lesson about testing from where the user is.

`become: false` on that task because it runs locally and needs no sudo.

---

## Files in this folder

| Path | What it demonstrates |
|---|---|
| `ansible/01-first-playbook.yml` | Minimal play, idempotency in the recap |
| `ansible/02-modules.yml` | apt, copy, template, lineinfile, blockinfile, user, command |
| `ansible/03-handlers.yml` | `notify`, deduplication, `validate:` |
| `ansible/04-multi-play.yml` | Three plays, `serial: 1`, `delegate_to: localhost` |
| `ansible/templates/`, `ansible/files/` | Supporting template and static file |

---

## What I learned

**1. `validate:` is the single most valuable option on the template module.** Ansible renders to a temp file, runs the validator, and only writes the real file if it passes. A broken nginx template fails the playbook instead of taking the site down — the difference between a failed deploy and an outage.

**2. Handlers run once, at the end, and only if something changed.** Three tasks notified the same reload and it fired once. On an unchanged run it did not fire at all. That is what makes it safe to run a config playbook every hour.

**3. `mode: "0644"` must be quoted.** Unquoted, YAML makes it the number 644 and Ansible applies octal 1204. Day 38's typing rule, producing permissions nobody would ever choose.

**Two extras:**

- `--check --diff` together is the pre-deployment check — it shows the actual lines that will change, not just that something will.
- `serial: 1` plus a `delegate_to: localhost` health check is a rolling deployment in about ten lines, and it stops on the first host that fails to come back.
