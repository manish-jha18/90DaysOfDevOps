# Day 72 – Ansible Project: Automate Docker and Nginx Deployment

The full project is in `ansible/` in this folder. It deploys the DevBoard stack — React frontend, Go API, Postgres — onto a bare EC2 instance, with nginx on the host as a reverse proxy.

---

## Task 1: Project structure

```
ansible/
├── ansible.cfg
├── inventory.ini
├── requirements.yml
├── site.yml
├── group_vars/
│   ├── webservers.yml       plain text, references the vault names
│   └── vault.yml.example    template for the encrypted file
└── roles/
    ├── common/              packages, timezone, app user
    ├── docker/              engine, compose stack, Docker Hub login
    └── nginx/               reverse proxy on the host
```

**Three roles, each doing one thing.** Day 65's module rule applied to Ansible — `common` is reusable on any host, `docker` on any Docker host, `nginx` only where a proxy is wanted.

The architecture:

```
        internet
           │  :80
    ┌──────▼──────────────────────────────┐
    │  nginx  (on the HOST, not a container) │
    │    /api/  → 127.0.0.1:8081           │
    │    /      → 127.0.0.1:4173           │
    └──────┬───────────────────┬───────────┘
           │                   │
    ┌──────▼─────┐      ┌──────▼──────┐
    │  backend   │      │  frontend   │   docker compose
    │  :8081     │      │  :4173      │
    └──────┬─────┘      └─────────────┘
           │
    ┌──────▼─────┐
    │  postgres  │  named volume
    └────────────┘
```

**The containers bind to `127.0.0.1` only.** Nothing is reachable from outside except through nginx on port 80 — a single entry point, which means one place to add TLS, rate limiting or access logging later.

---

## Task 2: The common role

```yaml
- name: Install the base packages
  ansible.builtin.apt:
    name: "{{ common_packages }}"
    state: present

- name: Set the timezone
  community.general.timezone:
    name: "{{ common_timezone }}"

- name: Create the application user
  ansible.builtin.user:
    name: "{{ common_app_user }}"
    shell: /bin/bash
    create_home: true
```

Deliberately small. Anything every host needs regardless of its job goes here; anything role-specific does not.

`community.general.timezone` rather than a `command` — it is idempotent and reports `ok` on a second run.

---

## Task 3: The docker role

The largest of the three, and the one with the most that can go wrong.

### Installing the engine

```yaml
- name: Add the docker repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [arch={{ 'arm64' if ansible_architecture == 'aarch64' else 'amd64' }}
      signed-by=/etc/apt/keyrings/docker.asc]
      https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable
    filename: docker
```

**Two facts doing real work.** `ansible_architecture` translated to Docker's naming — the same `x86_64` → `amd64` conversion devboard's `01-install-tools.yml` needs. And `ansible_distribution_release` gives `jammy` or `noble` automatically, so the same playbook works on both.

Hardcoding either means a playbook that works on exactly one AMI.

### The group membership trap

```yaml
- name: Add users to the docker group
  ansible.builtin.user:
    name: "{{ item }}"
    groups: docker
    append: true
  loop: "{{ docker_users }}"
  notify: Reset connection
```

```yaml
# handlers/main.yml
- name: Reset connection
  ansible.builtin.meta: reset_connection
```

**Two separate problems here.**

`append: true`, or the task **replaces** every other group the user is in — including `sudo`. Day 23 and Day 69's lesson, and locking yourself out of a remote host is a realistic outcome.

And group membership is read at login (Day 08, Day 29), so the *current* SSH session does not have it. A later task using `community.docker` would fail with permission denied on the socket. `meta: reset_connection` drops and reopens the SSH connection so the new group applies.

Without that handler the playbook works on the second run and fails on the first, which is exactly the sort of bug that gets diagnosed as "flaky".

### Secrets

```yaml
- name: Log in to Docker Hub
  community.docker.docker_login:
    username: "{{ dockerhub_username }}"
    password: "{{ dockerhub_token }}"
  no_log: true
  when: dockerhub_token is defined and dockerhub_token | length > 0
```

**`no_log: true`**, or `-vvv` prints the token (Day 71). And the `when` guard means the role still works for public images with no credentials configured.

### The compose file

```yaml
- name: Deploy the compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ docker_compose_dir }}/docker-compose.yml"
    mode: "0644"
  notify: Restart the stack

- name: Deploy the env file
  ansible.builtin.template:
    src: env.j2
    dest: "{{ docker_compose_dir }}/.env"
    mode: "0600"
  no_log: true
  notify: Restart the stack
```

**`mode: "0600"` on the `.env`** — it holds the database password. And `no_log: true` because the diff would otherwise print its contents.

The template itself is Day 33's compose file with variables substituted:

```jinja
  backend:
    image: {{ docker_backend_image }}
    environment:
      POSTGRES_URL: "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable"
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:{{ docker_backend_port }}:8080"
```

**Two levels of substitution, deliberately.** `{{ docker_backend_image }}` is Jinja and is resolved by Ansible at render time. `${POSTGRES_USER}` is left alone by Jinja and resolved by Docker Compose from the `.env` file at runtime. Mixing them up is easy and produces a compose file with literal `{{ }}` in it.

`condition: service_healthy` is Day 34's fix for the startup race.

### Bringing it up

```yaml
- name: Bring the stack up
  community.docker.docker_compose_v2:
    project_src: "{{ docker_compose_dir }}"
    state: present
    pull: always

- name: Wait for the backend to answer
  ansible.builtin.uri:
    url: "http://localhost:{{ docker_backend_port }}/health"
    status_code: 200
  register: backend_health
  until: backend_health.status == 200
  retries: 20
  delay: 3
```

**`docker_compose_v2`, not the old `docker_compose` module** — the latter drives the deprecated Python `docker-compose` v1 (Day 33) and fails on a modern host.

`pull: always` means a re-run picks up a new `:latest`, which is what makes redeployment work.

The `until` loop is Day 70's retry pattern. Postgres initialising plus the Go app starting takes 20–40 seconds on a cold boot, and without it the next role proxies to something that is not listening yet.

---

## Task 4: The nginx role

```jinja
upstream devboard_frontend {
    server {{ nginx_frontend_upstream }};
}

upstream devboard_backend {
    server {{ nginx_backend_upstream }};
}

server {
    listen {{ nginx_port }};

    location /api/ {
        proxy_pass http://devboard_backend/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://devboard_frontend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

**The trailing slash on `proxy_pass http://devboard_backend/;` is load-bearing.** With it, nginx strips the `/api` prefix — a request to `/api/tasks` reaches the backend as `/tasks`, which is what the Go API serves. Without it the backend receives `/api/tasks` and returns 404.

That one character is the difference between a working proxy and an app where every API call fails, and the error gives no hint about the cause.

**The `X-Forwarded-*` headers** are not optional either. Without them the backend sees every request as coming from `127.0.0.1`, so rate limiting, audit logs and anything IP-based are all wrong.

**`Upgrade` and `Connection` on the frontend location** because vite's preview server uses websockets. Missing them means the page loads and live updates silently do not work.

```yaml
- name: Validate the full nginx configuration
  ansible.builtin.command:
    cmd: nginx -t
  changed_when: false
```

**`validate:` on a template only checks that one file.** This checks the whole assembled config including the symlink — a config that is individually valid can still be broken in combination, for instance two sites both claiming `default_server`.

The handler uses `state: reloaded`, not `restarted` — reload re-reads the config without dropping in-flight connections.

---

## Task 5: Vault

```
devops@testvm:~/day-72/ansible$ cp group_vars/vault.yml.example group_vars/vault.yml
devops@testvm:~/day-72/ansible$ ansible-vault encrypt group_vars/vault.yml
Encryption successful
```

Day 71's indirection: `vault.yml` (encrypted) holds `vault_*` names, `webservers.yml` (plain) maps them to what the roles use. Which values are secret is visible without decrypting anything.

---

## Task 6: Deploying

```yaml
- name: Deploy DevBoard
  hosts: webservers
  become: true

  vars_files:
    - group_vars/vault.yml

  roles:
    - role: common
      tags: [common]
    - role: docker
      tags: [docker]
    - role: nginx
      tags: [nginx]

  post_tasks:
    - name: Check the app through nginx
      ansible.builtin.uri:
        url: "http://{{ ansible_host }}/health"
        status_code: 200
        return_content: true
      delegate_to: localhost
      become: false
      register: public_health
      retries: 5
      delay: 3
      until: public_health.status == 200
```

**The final check runs from the control node** (`delegate_to: localhost`), so it tests the path an actual user takes — through the security group, through nginx, to the container. Checking from the host itself would pass even with port 80 closed.

```
devops@testvm:~/day-72/ansible$ ansible-galaxy collection install -r requirements.yml
devops@testvm:~/day-72/ansible$ ansible-playbook site.yml --ask-vault-pass
Vault password:

PLAY [Deploy DevBoard] *********************************************************

TASK [common : Install the base packages] **************************************
changed: [web1]

TASK [docker : Install docker engine and the compose plugin] *******************
changed: [web1]

RUNNING HANDLER [docker : Reset connection] ************************************

TASK [docker : Log in to Docker Hub] *******************************************
changed: [web1]

TASK [docker : Bring the stack up] *********************************************
changed: [web1]

TASK [docker : Wait for the backend to answer] *********************************
FAILED - RETRYING: Wait for the backend to answer (20 retries left).
FAILED - RETRYING: Wait for the backend to answer (19 retries left).
FAILED - RETRYING: Wait for the backend to answer (18 retries left).
ok: [web1]

TASK [nginx : Deploy the reverse proxy config] *********************************
changed: [web1]

RUNNING HANDLER [nginx : Reload nginx] *****************************************
changed: [web1]

TASK [Check the app through nginx] *********************************************
ok: [web1]

TASK [Report] ******************************************************************
ok: [web1] =>
  msg: web1 is live at http://44.238.114.92 (health: ok)

PLAY RECAP *********************************************************************
web1  : ok=28  changed=19  unreachable=0  failed=0
```

**Three retries on the health check**, which is the Postgres and Go startup time. Without the `until` loop the nginx role would have configured a proxy to a dead backend and the final check would have failed.

```
devops@testvm:~$ curl -s http://44.238.114.92/health
ok

devops@testvm:~$ curl -s "http://44.238.114.92/api/tasks?project_id=1" | head -c 100
[{"id":1,"project_id":1,"title":"Set up CI pipeline","status":"in_progress",...

devops@testvm:~$ curl -sI http://44.238.114.92/ | head -1
HTTP/1.1 200 OK
```

Frontend, API through the proxy, and the health endpoint. A bare EC2 instance to a running three-tier application in one command.

**Re-running it:**

```
PLAY RECAP *********************************************************************
web1  : ok=28  changed=0  unreachable=0  failed=0
```

**`changed=0`.** Everything already in the desired state — nothing reinstalled, no containers restarted, nginx not reloaded. That is the whole property, and it is what makes the playbook safe to run on a schedule as drift correction.

**Tags for partial runs:**

```
devops@testvm:~/day-72/ansible$ ansible-playbook site.yml --ask-vault-pass --tags nginx
web1  : ok=8  changed=1
```

Only the proxy config, in about 8 seconds instead of 3 minutes.

---

## Task 7: Redeploying a new version

```
devops@testvm:~/day-72/ansible$ ansible-playbook site.yml --ask-vault-pass \
    -e "docker_backend_image=manishjha18/devboard-backend:sha-8a3f91c" --tags docker

TASK [docker : Deploy the compose file] ****************************************
changed: [web1]

RUNNING HANDLER [docker : Restart the stack] ***********************************
changed: [web1]

PLAY RECAP *********************************************************************
web1  : ok=16  changed=2
```

**`-e` beats every other variable source** (Day 70), so this overrides the image without editing anything. The template changed, the handler fired, the stack restarted.

**Using the immutable SHA tag rather than `latest`** is Day 45's point, and it matters more here than it did in Kubernetes: `pull: always` would fetch a new `latest` but the compose file would be unchanged, so **the template task reports `ok` and the handler never fires**. With a SHA tag the file genuinely changes and the restart happens. Same failure mode as Day 52's `kubectl set image` reporting `unchanged`.

**Where this fits against everything else:**

| Approach | Day | Good for |
|---|---|---|
| `docker compose up` by hand | 33 | One machine, you are sitting at it |
| Ansible + compose | 72 | A handful of VMs, no orchestrator |
| Kubernetes | 50–60 | Many machines, self-healing, autoscaling |

Ansible plus compose is genuinely the right answer for a small number of long-lived servers. It gives repeatability and version control without a cluster to operate. Beyond about ten hosts, or when self-healing and rolling updates matter, the Kubernetes work from Days 50–60 wins.

**What Ansible still owns even with Kubernetes:** the nodes themselves, the bastion hosts, the CI runners from Day 42, and the workstation setup — which is exactly what devboard's own `ansible/` directory does.

---

## Files in this folder

| Path | What it is |
|---|---|
| `ansible/site.yml` | Three roles plus a post-task health check from the control node |
| `ansible/roles/common/` | Packages, timezone, app user |
| `ansible/roles/docker/` | Engine install, group fix with connection reset, compose stack |
| `ansible/roles/docker/templates/docker-compose.yml.j2` | Jinja and compose substitution side by side |
| `ansible/roles/nginx/` | Reverse proxy, full-config validation |
| `ansible/roles/nginx/templates/devboard.conf.j2` | `/api` prefix strip, forwarded headers, websocket upgrade |
| `ansible/group_vars/` | Vault indirection |

---

## What I learned

**1. Adding a user to the docker group does not affect the current SSH session.** Group membership is read at login, so a later task using the Docker socket fails on the *first* run and works on the second. `meta: reset_connection` in a handler is the fix, and without it the bug looks like flakiness rather than ordering.

**2. The trailing slash on `proxy_pass` decides whether the path prefix is stripped.** `proxy_pass http://backend/;` sends `/api/tasks` as `/tasks`; without the slash the backend gets `/api/tasks` and 404s every call. One character, and the error message points nowhere near it.

**3. Idempotency is what makes this a source of truth rather than a script.** The second run reported `changed=0` across 28 tasks — nothing reinstalled, no containers bounced. That is the property that lets the playbook run on a schedule and correct drift, which a shell script doing the same work could never do safely.

**Two extras:**

- Jinja `{{ }}` and Compose `${ }` in the same template are resolved at different times by different tools. Confusing them produces a compose file with literal braces in it.
- Deploy with an immutable SHA tag. With `:latest` the compose template never changes, so the restart handler never fires and the new image is never used — the same silent no-op as `kubectl set image` with an unchanged tag.
