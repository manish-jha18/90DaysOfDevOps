# Day 68 – Introduction to Ansible and Inventory

Config in `ansible/` in this folder.

---

## Task 1: What Ansible is

**Agentless.** Ansible connects over plain SSH and runs Python on the far end. Nothing is installed on the managed hosts. Puppet and Chef need an agent daemon on every node plus a central server; Ansible needs SSH, which every Linux box already has.

**Push, not pull.** I run a command and it reaches out. Puppet agents poll a master on a timer. Push means changes happen when I say so, which is right for deployments and worse for keeping 5,000 nodes continuously in a known state.

**Where it sits against everything else so far:**

| Tool | Owns |
|---|---|
| **Terraform** | Cloud resources — VPCs, instances, clusters. Creates the servers |
| **Ansible** | What is *on* a server — packages, config, services |
| **Docker** | Packaging one application and its dependencies |
| **Kubernetes** | Running containers across a fleet |

Terraform builds the EC2 instance; Ansible installs Docker on it. Day 66's Terraform ended at a running cluster — Ansible is the tool for the machines that are not clusters.

**Idempotency is the design principle**, exactly as in Day 17. `state: present` means "make sure nginx is installed", not "run apt install". Run it twice and the second run reports `ok` rather than `changed`. That is what makes it safe to run repeatedly, which is the whole basis of using it as a source of truth.

The catch is that idempotency comes from the **modules**, not from Ansible. `ansible.builtin.apt` is idempotent; `ansible.builtin.command` running a shell script is not, unless you help it. Day 69 covers that.

---

## Task 2 and 3: Lab and installation

```
devops@testvm:~$ sudo apt update && sudo apt install -y pipx
devops@testvm:~$ pipx install --include-deps ansible
devops@testvm:~$ ansible --version
ansible [core 2.17.4]
  config file = /home/devops/day-68/ansible/ansible.cfg
  python version = 3.10.12
  jinja version = 3.1.4
```

**pipx rather than apt.** Ubuntu's `ansible` package is frequently a major version behind, and pipx keeps it in its own virtualenv rather than fighting the system Python.

Three EC2 instances from Day 65's module — two web, one database. **Ansible needs nothing installed on them**, only SSH access and Python 3, which the Ubuntu AMI already has.

```
devops@testvm:~/day-68/ansible$ ansible --version | grep "config file"
  config file = /home/devops/day-68/ansible/ansible.cfg
```

**`ansible.cfg` in the current directory wins**, which is what makes a project self-contained.

**`ansible/ansible.cfg`:**

```ini
[defaults]
inventory = ./inventory.ini
host_key_checking = False
stdout_callback = yaml
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600
callbacks_enabled = profile_tasks
interpreter_python = auto_silent

[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
```

The settings that actually matter:

**`pipelining = True`** is the biggest single speed win. Without it Ansible copies a Python script to the remote host, runs it, and deletes it — for **every task**. Pipelining executes it over the existing SSH connection instead. On a 40-task playbook that is minutes.

**`ControlPersist=60s`** reuses one SSH connection across tasks rather than reconnecting each time.

**`stdout_callback = yaml`** makes multi-line output readable. The default crams a failed task's stderr onto one line as a JSON blob.

**`fact_caching`** — gathering facts hits every host on every run and takes a few seconds each. Caching for an hour removes that from iterative work.

**`host_key_checking = False`** is a convenience with a real cost: it disables SSH host key verification, so a man-in-the-middle is undetectable. Acceptable on ephemeral lab instances whose fingerprints change constantly, not on anything real.

---

## Task 4: The inventory

**`ansible/inventory.ini`:**

```ini
[webservers]
web1 ansible_host=44.238.114.92
web2 ansible_host=35.164.201.77

[dbservers]
db1 ansible_host=52.10.44.187

[devboard:children]
webservers
dbservers

[devboard:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/devboard-key.pem
ansible_python_interpreter=/usr/bin/python3

[webservers:vars]
http_port=80
app_env=production
```

**`web1` is an alias, not a hostname.** `ansible_host` holds the real address, so hosts can be referred to by meaningful names and the IP changes in one place.

**`[devboard:children]` is a group of groups** — targeting `devboard` hits all three hosts. Group variables set there apply to every child.

**`ansible_python_interpreter` prevents a real annoyance.** Ansible tries to discover Python on the remote host and can pick the wrong one, or warn on every run. Stating it explicitly is what devboard's own `inventory.ini` does.

The same thing in YAML, which scales better:

```yaml
all:
  children:
    devboard:
      children:
        webservers:
          hosts:
            web1:
              ansible_host: 44.238.114.92
            web2:
              ansible_host: 35.164.201.77
          vars:
            http_port: 80
```

```
devops@testvm:~/day-68/ansible$ ansible-inventory --graph
@all:
  |--@devboard:
  |  |--@dbservers:
  |  |  |--db1
  |  |--@webservers:
  |  |  |--web1
  |  |  |--web2
  |  |--@ungrouped:
```

```
devops@testvm:~/day-68/ansible$ ansible-inventory --host web1
{
    "ansible_host": "44.238.114.92",
    "ansible_python_interpreter": "/usr/bin/python3",
    "ansible_ssh_private_key_file": "~/.ssh/devboard-key.pem",
    "ansible_user": "ubuntu",
    "app_env": "production",
    "http_port": 80,
    "nginx_worker_connections": 512,
    "server_role": "primary"
}
```

**Every variable that applies to `web1`, from every source, already merged.** This is the command for working out where a value came from — `nginx_worker_connections: 512` is from `host_vars/web1.yml`, overriding the 1024 in `group_vars/webservers.yml`.

### group_vars and host_vars

Ansible loads these automatically by filename — no include needed:

```
ansible/
├── group_vars/
│   ├── devboard.yml      → every host in the devboard group
│   └── webservers.yml    → only the webservers group
└── host_vars/
    └── web1.yml          → only web1
```

**More specific wins.** `host_vars/web1.yml` beats `group_vars/webservers.yml`, which beats `group_vars/devboard.yml`.

Keeping variables in files rather than inline in the inventory means the inventory stays a list of machines, and the configuration lives somewhere reviewable.

### Dynamic inventory

Static inventory does not survive autoscaling. The AWS plugin queries EC2 instead:

```yaml
# aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions:
  - us-west-2
filters:
  tag:Project: devboard
  instance-state-name: running
keyed_groups:
  - key: tags.Role
    prefix: role
```

That builds groups from **instance tags** — which is where Day 61's `default_tags` on the Terraform provider pays off a second time. Terraform tags the instances; Ansible groups by those tags; neither needs to know the IPs.

---

## Task 5: Ad-hoc commands

```
devops@testvm:~/day-68/ansible$ ansible all -m ping
web1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
web2 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
db1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

**`-m ping` is not ICMP.** It connects over SSH, runs a Python module and gets a reply — so it tests SSH, authentication, Python and permissions in one command. A host that answers ICMP but fails this has a real problem.

```
devops@testvm:~/day-68/ansible$ ansible webservers -m command -a "uptime"
web1 | CHANGED | rc=0 >>
 10:14:22 up 2 days,  4:18,  0 users,  load average: 0.04, 0.09, 0.06

web2 | CHANGED | rc=0 >>
 10:14:22 up 2 days,  4:18,  0 users,  load average: 0.02, 0.05, 0.01
```

**`CHANGED` for `uptime`, which changed nothing.** The `command` module cannot know whether a command modified anything, so it always reports changed. That is a genuine problem — Day 69's `changed_when: false` is the fix, and it matters because "did anything change?" is the main signal you read from a run.

```
devops@testvm:~/day-68/ansible$ ansible webservers -m apt -a "name=htop state=present" --become
web1 | CHANGED => {
    "changed": true,
    "stdout": "Setting up htop (3.2.1-1) ..."
}

devops@testvm:~/day-68/ansible$ ansible webservers -m apt -a "name=htop state=present" --become
web1 | SUCCESS => {
    "changed": false
}
```

**Second run: `changed: false`.** Idempotency, visible. That is the difference between the `apt` module and `command: apt install htop`.

```
devops@testvm:~/day-68/ansible$ ansible all -m setup -a "filter=ansible_distribution*"
web1 | SUCCESS => {
    "ansible_facts": {
        "ansible_distribution": "Ubuntu",
        "ansible_distribution_major_version": "22",
        "ansible_distribution_release": "jammy",
        "ansible_distribution_version": "22.04"
    }
}
```

`-m setup` dumps everything Ansible knows about a host — several hundred facts. Day 70 uses them.

Useful ones in practice:

```bash
ansible all -m ping                                    # connectivity
ansible all -a "df -h /"                               # command is the default module
ansible webservers -m service -a "name=nginx state=restarted" --become
ansible all -m copy -a "src=./file dest=/tmp/file" --become
ansible all -m shell -a "ps aux | grep nginx"          # shell for pipes and redirects
ansible all -m setup --tree /tmp/facts                 # one JSON file per host
```

**`command` versus `shell`:** `command` runs the binary directly, so no pipes, redirects or globs. `shell` runs it through `/bin/sh`. Prefer `command` — it is safer against injection — and reach for `shell` only when you genuinely need shell features.

**Where ad-hoc commands belong:** investigating, one-off fixes, checking whether a fleet is reachable. Anything you would do twice becomes a playbook, because an ad-hoc command is not recorded, reviewed or repeatable.

---

## Task 6: Groups and patterns

```
devops@testvm:~/day-68/ansible$ ansible all --list-hosts
  hosts (3):
    web1
    web2
    db1

devops@testvm:~/day-68/ansible$ ansible 'webservers' --list-hosts
  hosts (2):
    web1
    web2

devops@testvm:~/day-68/ansible$ ansible 'webservers:!web1' --list-hosts
  hosts (1):
    web2

devops@testvm:~/day-68/ansible$ ansible 'webservers:&devboard' --list-hosts
  hosts (2):
    web1
    web2

devops@testvm:~/day-68/ansible$ ansible 'web*' --list-hosts
  hosts (2):
    web1
    web2
```

| Pattern | Means |
|---|---|
| `all` or `*` | Everything |
| `webservers` | One group |
| `webservers:dbservers` | Union — either group |
| `webservers:&devboard` | Intersection — in both |
| `webservers:!web1` | Exclusion — the group, minus that host |
| `web*` | Glob on the name |
| `~web[0-9]+` | Regex, with the `~` prefix |

**`--list-hosts` before anything destructive.** The exclusion syntax in particular is easy to get subtly wrong, and `ansible 'webservers:!web1' -m command -a "reboot"` on a mis-typed pattern reboots the wrong box. This is the same instinct as `terraform plan` and `kubectl config current-context`.

Two more that matter at scale:

```
ansible webservers --limit web1          # restrict a playbook run to one host
ansible webservers --limit @/tmp/retry   # rerun only what failed last time
```

---

## Files in this folder

| Path | What it is |
|---|---|
| `ansible/ansible.cfg` | Pipelining, connection reuse, fact caching, readable output |
| `ansible/inventory.ini` | Two groups plus a group-of-groups, with group vars |
| `ansible/inventory.yml` | The same thing in YAML |
| `ansible/group_vars/` | Variables for `devboard` and `webservers` |
| `ansible/host_vars/web1.yml` | Host-specific overrides |

---

## What I learned

**1. `ansible -m ping` tests far more than connectivity.** It opens SSH, authenticates, runs Python on the remote host and gets a reply. A host that answers ICMP but fails this has a real problem — a wrong user, a missing key, or no Python.

**2. Ad-hoc `command` always reports CHANGED, even for `uptime`.** The module cannot know whether the command modified anything. That makes the changed/ok signal useless unless you fix it, and it is why idempotency comes from choosing the right module rather than from Ansible itself.

**3. `ansible-inventory --host <name>` is the answer to "where did this value come from".** It prints every variable applying to a host with the precedence already resolved, which is much faster than reasoning about which of four files wins.

**Two extras:**

- `pipelining = True` is the single biggest performance setting. Without it every task copies a script to the remote host, runs it and deletes it.
- Dynamic inventory built from EC2 tags means Terraform's `default_tags` and Ansible's grouping line up automatically, and nothing has to know an IP address.
