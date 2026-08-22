# Day 71 – Roles, Galaxy, Templates and Vault

Everything in `ansible/` in this folder.

---

## Task 1: Jinja2 templates

Day 69 used `template` without explaining the language. Jinja2 is what turns one file into per-host configuration.

**`roles/webserver/templates/site.conf.j2`**

```jinja
# {{ ansible_managed }}

upstream devboard_backend {
    server {{ webserver_upstream_host }}:{{ webserver_upstream_port }};
}

server {
    listen {{ webserver_port }};
    server_name {{ webserver_server_name }};
{% for loc in webserver_extra_locations %}

    location {{ loc.path }} {
        {{ loc.directive }}
    }
{% endfor %}

    location /health {
        access_log off;
        return 200 "ok\n";
    }
}
```

Three constructs cover almost everything:

| Syntax | Does |
|---|---|
| `{{ expression }}` | Substitute a value |
| `{% statement %}` | Control flow — `for`, `if`, `set` |
| `{# comment #}` | Not rendered at all |

**`{{ ansible_managed }}` at the top of every generated file.** It renders to something like `Ansible managed`, and it is the note that stops someone editing the file by hand and losing the change on the next run.

```
devops@testvm:~$ head -2 /etc/nginx/sites-available/devboard
# Ansible managed
```

### Whitespace control

The thing that makes templates fiddly. `{% for %}` on its own line leaves a blank line in the output. `{%- ... -%}` strips whitespace before and after:

```jinja
{% for pkg in packages %}
  {{ pkg }}
{% endfor %}
```

produces blank lines between entries; `{%- for ... -%}` does not. For a config file it rarely matters; for something whitespace-sensitive it matters a lot.

### Filters

```jinja
{{ (ansible_memtotal_mb / 1024) | round(1) }} GiB
{{ webserver_port | default(80) }}
{{ app_name | upper }}
{{ package_list | join(', ') }}
{{ some_dict | to_nice_json }}
{{ secret | password_hash('sha512') }}
```

`default()` is the one used constantly, for the Day 70 reason. `password_hash` matters because the `user` module wants a hash, not a plaintext password.

**Conditionals in a template** keep the playbook simpler than branching in tasks:

```jinja
{% if server_role is defined %}
    <li>Role: {{ server_role }}</li>
{% endif %}
```

**Facts are available in templates**, which is what makes them per-host:

```jinja
<p>Served by <strong>{{ ansible_hostname }}</strong> ({{ ansible_default_ipv4.address }})</p>
<li>CPUs: {{ ansible_processor_vcpus }}</li>
```

One template, a different rendered file on every machine.

---

## Task 2 and 3: The role

```
roles/webserver/
├── defaults/main.yml     tunable knobs, LOWEST precedence
├── vars/main.yml         internal constants, very HIGH precedence
├── tasks/main.yml        what it does
├── handlers/main.yml     notified restarts
├── templates/            .j2 files
├── files/                static files
└── meta/main.yml         metadata and dependencies
```

Ansible finds these by convention — no include statements. `tasks/main.yml` is the entry point.

### `defaults/` versus `vars/` is the design decision

```yaml
# defaults/main.yml - a caller is EXPECTED to override these
webserver_port: 80
webserver_root: /var/www/devboard
webserver_worker_connections: 1024
webserver_upstream_port: 8080
webserver_extra_locations: []
```

```yaml
# vars/main.yml - a caller should NOT need to change these
webserver_config_path: /etc/nginx/nginx.conf
webserver_site_path: /etc/nginx/sites-available/devboard
webserver_service: nginx
```

**`defaults/` is the lowest precedence in Ansible and `vars/` is nearly the highest.** So anything in `defaults/` can be overridden by group_vars, host_vars or the caller; anything in `vars/` effectively cannot.

The rule that follows: **`defaults/` for the role's interface, `vars/` for its implementation details.** Putting `webserver_port` in `vars/` would make the role unusable on a host that needs port 8080.

**Prefix every variable with the role name.** `webserver_port`, not `port`. Ansible has one flat variable namespace across all roles in a play — two roles both defining `port` silently collide, and the resulting bug is very hard to find.

### `tasks/main.yml`

```yaml
- name: Fail early on an unsupported OS
  ansible.builtin.fail:
    msg: "The webserver role supports Debian-family systems only. Found {{ ansible_os_family }}."
  when: ansible_os_family != "Debian"
```

**A guard as the first task.** Day 70's reasoning — fail with an explanation rather than on task 12 with `apt: command not found`.

```yaml
- name: Deploy the main config
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: "{{ webserver_config_path }}"
    mode: "0644"
    validate: "nginx -t -c %s"
  notify: Reload webserver
```

Day 69's `validate:` again — a broken template fails the task rather than the website.

Note `src: nginx.conf.j2` with no path. **Inside a role, Ansible looks in `templates/` automatically.** Same for `files/` with `copy:`.

### `meta/main.yml`

```yaml
galaxy_info:
  author: manish-jha18
  description: Installs and configures nginx as a reverse proxy for DevBoard
  license: MIT
  min_ansible_version: "2.15"
  platforms:
    - name: Ubuntu
      versions: [jammy, noble]

dependencies: []
```

**Roles in `dependencies:` run automatically before this one.** Useful, and easy to overuse — a dependency chain three deep makes execution order hard to reason about. Listing roles explicitly in the play is usually clearer.

### Using it

```yaml
- name: Configure the web tier
  hosts: webservers
  become: true

  roles:
    - role: webserver
      vars:
        webserver_port: 80
        webserver_upstream_port: 8080
        webserver_extra_locations:
          - path: /metrics
            directive: "deny all;"
```

```
devops@testvm:~/day-71/ansible$ ansible-playbook site.yml

TASK [webserver : Install the web server] **************************************
changed: [web1]

TASK [webserver : Deploy the main config] **************************************
changed: [web1]

RUNNING HANDLER [webserver : Reload webserver] *********************************
changed: [web1]

TASK [Confirm it answers] ******************************************************
ok: [web1]

TASK [Report] ******************************************************************
ok: [web1] =>
  msg: web1 health check: ok
```

Task names are prefixed with the role, which is exactly what you want in a run touching five roles.

**`ansible-galaxy init` scaffolds the whole structure:**

```
devops@testvm:~$ ansible-galaxy init roles/webserver
- Role roles/webserver was created successfully
```

It also creates `tests/` and a `README.md`, which are worth filling in for anything shared.

---

## Task 4: Galaxy

**`ansible/requirements.yml`**

```yaml
roles:
  - name: geerlingguy.docker
    version: 7.4.1
  - name: geerlingguy.pip
    version: 2.2.0

collections:
  - name: community.general
    version: ">=9.0.0"
  - name: community.docker
    version: ">=3.10.0"
```

```
devops@testvm:~/day-71/ansible$ ansible-galaxy install -r requirements.yml
Starting galaxy role install process
- downloading role 'docker', owned by geerlingguy
- extracting geerlingguy.docker to /home/devops/.ansible/roles/geerlingguy.docker
- geerlingguy.docker (7.4.1) was installed successfully

devops@testvm:~/day-71/ansible$ ansible-galaxy collection install -r requirements.yml
Installing 'community.general:9.5.1' to '/home/devops/.ansible/collections/...'
```

**Always pin the version.** Unpinned, `ansible-galaxy install` takes the latest, and someone else's push changes what your playbook does to your servers. This is Day 45's `latest` and Day 65's unpinned Terraform module — third instance of the same lesson, now with the ability to reconfigure production.

**Roles versus collections:** a role is one unit of automation; a collection is a bundle of roles, modules, plugins and filters. `community.docker` is a collection providing `docker_login` and `docker_compose_v2`, which Day 72 uses.

**Using a community role rather than writing one:**

```yaml
  roles:
    - role: geerlingguy.docker
      vars:
        docker_users: [ubuntu]
        docker_install_compose_plugin: true
```

`geerlingguy.docker` handles the GPG key, the repository for the right distribution release, the architecture, the service, and the group membership. Day 72 writes that role by hand deliberately, to see what it involves — but for real work this is the sensible choice, for the same reason Day 65 used the registry VPC module.

**The trade is the same as any dependency:** you inherit maintenance and you inherit someone else's abstraction when debugging. Community roles also run with root on every managed host, so the supply-chain question is a real one — pin the version, and read what a role does before running it on anything that matters.

---

## Task 5: Vault

```
devops@testvm:~/day-71/ansible$ cp group_vars/vault.yml.example group_vars/vault.yml
devops@testvm:~/day-71/ansible$ ansible-vault encrypt group_vars/vault.yml
New Vault password:
Confirm New Vault password:
Encryption successful

devops@testvm:~/day-71/ansible$ head -3 group_vars/vault.yml
$ANSIBLE_VAULT;1.1;AES256
39643866656231623430663832303966393735646166383966333865373461323461653164653236
6635353330343132386264633264353862363737383735640a396462373836646233396563663835
```

**AES256, and unlike Day 54's Kubernetes Secret this is actually encrypted.** Base64 is reversible by anyone; this needs the password.

That difference matters practically: **an encrypted vault file is safe to commit**. A `.env` file is not, a Kubernetes Secret manifest is not, but this is. That is the whole reason vault exists — secrets can live in git with everything else and go through the same review.

```
devops@testvm:~/day-71/ansible$ ansible-vault view group_vars/vault.yml
Vault password:
vault_dockerhub_username: manishjha18
vault_dockerhub_token: dckr_pat_...

devops@testvm:~/day-71/ansible$ ansible-vault edit group_vars/vault.yml   # decrypt, edit, re-encrypt
devops@testvm:~/day-71/ansible$ ansible-vault rekey group_vars/vault.yml  # change the password
```

**Running a playbook that uses it:**

```
devops@testvm:~/day-71/ansible$ ansible-playbook site.yml --ask-vault-pass
Vault password:

devops@testvm:~/day-71/ansible$ ansible-playbook site.yml --vault-password-file .vault_pass
```

The password file is for CI, and it must be gitignored and `chmod 600`. In a pipeline the password comes from a secret (Day 44) and is written to a temp file, or `ANSIBLE_VAULT_PASSWORD_FILE` points at a script that fetches it.

### The indirection pattern

**`group_vars/vault.yml`** (encrypted) holds only prefixed values:

```yaml
vault_dockerhub_username: manishjha18
vault_dockerhub_token: dckr_pat_...
vault_postgres_password: ...
```

**`group_vars/webservers.yml`** (plain text) maps them to the names the playbook uses:

```yaml
dockerhub_username: "{{ vault_dockerhub_username }}"
dockerhub_token: "{{ vault_dockerhub_token }}"
postgres_password: "{{ vault_postgres_password }}"
```

**This looks like pointless indirection and is not.** With everything inside the encrypted file, a reader has to decrypt it to know *which* variables exist. With the mapping in plain text, the structure is reviewable and only the values are hidden — you can see at a glance that `postgres_password` is a secret and `app_port` is not.

The `vault_` prefix also makes it obvious in a diff when something secret is being referenced.

**Encrypting a single string** rather than a whole file:

```
devops@testvm:~$ ansible-vault encrypt_string 'dckr_pat_xxx' --name 'dockerhub_token'
dockerhub_token: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          62313365396662343061393464336163383634653933316234653839616533...
```

That block pastes directly into a normal YAML file — a mostly-plaintext file with one encrypted value. devboard's `group_vars/devboard.yml` suggests exactly this for the AWS keys.

**`no_log: true` on any task handling a secret**, or `-vvv` prints it:

```yaml
- name: Log in to Docker Hub
  community.docker.docker_login:
    username: "{{ dockerhub_username }}"
    password: "{{ dockerhub_token }}"
  no_log: true
```

Same reasoning as Day 44 — the secret is protected at rest and then leaked through the log.

**The `.gitignore`:**

```
group_vars/vault.yml
.vault_pass
```

Note this repository commits `vault.yml.example` and ignores `vault.yml`, because the exercise cannot ship a real vault password. **In a real project the encrypted `vault.yml` is committed** — that is the point of it.

---

## Task 6: All three together

`site.yml` combines them: a role, with templates rendering per-host, reading vault-encrypted values through the indirection layer, and a post-task confirming the result from the control node.

```
devops@testvm:~/day-71/ansible$ ansible-playbook site.yml --ask-vault-pass --check --diff
Vault password:

TASK [webserver : Deploy the site config] **************************************
--- before: /etc/nginx/sites-available/devboard
+++ after: rendered from site.conf.j2
@@ -18,6 +18,11 @@
+    location /metrics {
+        deny all;
+    }

changed: [web1]

PLAY RECAP *********************************************************************
web1  : ok=9  changed=2
```

**`--check --diff` works with vault** — it decrypts, renders, and shows the diff without writing anything.

```
devops@testvm:~/day-71/ansible$ curl -s http://44.238.114.92/health
ok
devops@testvm:~$ curl -s -o /dev/null -w "%{http_code}\n" http://44.238.114.92/metrics
403
```

The `/metrics` deny rule came from the extra-locations loop in the template, driven by a variable set in the play. One template, behaviour chosen by data.

---

## Files in this folder

| Path | What it is |
|---|---|
| `ansible/roles/webserver/defaults/main.yml` | The role's interface — overridable |
| `ansible/roles/webserver/vars/main.yml` | Internal paths — not meant to be overridden |
| `ansible/roles/webserver/tasks/main.yml` | OS guard, install, template with `validate:`, service |
| `ansible/roles/webserver/templates/*.j2` | Loops, conditionals, facts, `ansible_managed` |
| `ansible/site.yml` | Calls the role with overrides, then verifies |
| `ansible/requirements.yml` | Pinned Galaxy roles and collections |
| `ansible/group_vars/vault.yml.example` | Template for the encrypted file |

---

## What I learned

**1. `defaults/` and `vars/` sit at opposite ends of the precedence list, and that is the whole role design decision.** `defaults/` is overridable by anything, so it is the role's public interface. `vars/` is nearly impossible to override, so it is for implementation details. Putting a tunable value in `vars/` makes the role unusable somewhere it would otherwise fit.

**2. An encrypted vault file is safe to commit, and that is genuinely different from every other secret mechanism so far.** `.env` files are gitignored, Kubernetes Secrets are base64 not encryption — a vault file is AES256 and goes into git with the code. Secrets get reviewed and versioned like everything else.

**3. Prefix every role variable with the role name.** Ansible has one flat namespace across all roles in a play, so two roles defining `port` collide silently. `webserver_port` costs nothing and prevents a bug that is very hard to trace.

**Two extras:**

- Keeping the vault-to-usable-name mapping in a plain-text file means the *structure* is reviewable while the values stay hidden. Which variables are secret becomes visible without decrypting anything.
- Pin Galaxy roles by version. A community role runs as root on every managed host, so an unpinned dependency is a supply-chain risk, not just a reproducibility one.
