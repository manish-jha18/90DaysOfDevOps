# Day 54 – ConfigMaps and Secrets

Manifests in `manifests/` in this folder. This is the Kubernetes answer to Day 33's `.env` file.

---

## Task 1: A ConfigMap from literals

```
devops@testvm:~/day-54$ kubectl create configmap quick-config -n devboard-dev \
    --from-literal=LOG_LEVEL=debug \
    --from-literal=BACKEND_PORT=8080
configmap/quick-config created

devops@testvm:~/day-54$ kubectl get configmap quick-config -n devboard-dev -o yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: quick-config
  namespace: devboard-dev
data:
  BACKEND_PORT: "8080"
  LOG_LEVEL: debug
```

**`BACKEND_PORT` came back quoted.** ConfigMap values must be strings, so Kubernetes quoted it. Writing `BACKEND_PORT: 8080` unquoted in a manifest is rejected outright:

```
Error: cannot convert int64 to string
```

Day 38's YAML typing rule, enforced by the API server this time.

---

## Task 2: A ConfigMap from a file

```
devops@testvm:~/day-54$ cat app.properties
feature.kanban=true
feature.search=true
page.size=25

devops@testvm:~/day-54$ kubectl create configmap file-config -n devboard-dev \
    --from-file=app.properties
configmap/file-config created

devops@testvm:~/day-54$ kubectl describe configmap file-config -n devboard-dev
Name:         file-config
Namespace:    devboard-dev

Data
====
app.properties:
----
feature.kanban=true
feature.search=true
page.size=25
```

**The filename becomes the key and the whole file becomes the value.** `--from-file=<dir>` does every file in a directory.

The declarative version of both, in **`manifests/configmap.yaml`**:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: devboard-config
  namespace: devboard-dev
data:
  POSTGRES_USER: devboard
  LOG_LEVEL: info
  BACKEND_PORT: "8080"

  app.properties: |
    feature.kanban=true
    feature.search=true
    page.size=25
```

One ConfigMap holding both simple values and a file, using Day 38's `|` literal block so the newlines survive.

---

## Task 3: Using a ConfigMap in a Pod

Three ways, and the difference matters.

**One key at a time** — explicit, and the form DevBoard's manifests use:

```yaml
env:
  - name: POSTGRES_USER
    valueFrom:
      configMapKeyRef:
        name: devboard-config
        key: POSTGRES_USER
```

**Everything at once:**

```yaml
envFrom:
  - configMapRef:
      name: devboard-config
```

Convenient, but it injects **every** key — including `app.properties`, whose value is a multi-line file. That becomes a bizarre environment variable. `envFrom` is only sensible when the ConfigMap holds nothing but simple values.

**As a mounted volume:**

```yaml
volumeMounts:
  - name: config-files
    mountPath: /etc/devboard
    readOnly: true
volumes:
  - name: config-files
    configMap:
      name: devboard-config
      items:
        - key: app.properties
          path: app.properties
```

`items:` picks specific keys. Without it, every key becomes a file in that directory.

```
devops@testvm:~/day-54$ kubectl apply -f manifests/configmap.yaml -f manifests/secret.yaml
devops@testvm:~/day-54$ kubectl apply -f manifests/backend-deployment.yaml
deployment.apps/devboard-backend created

devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- env | grep -E "POSTGRES|PORT"
POSTGRES_USER=devboard
POSTGRES_PASSWORD=devboard
POSTGRES_DB=devboard
POSTGRES_URL=postgres://devboard:devboard@postgres:5432/devboard?sslmode=disable
PORT=8080

devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- cat /etc/devboard/app.properties
feature.kanban=true
feature.search=true
page.size=25
```

### The `$(VAR)` substitution

```yaml
- name: POSTGRES_URL
  value: postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)?sslmode=disable
```

Kubernetes expands `$(VAR)` using env vars **declared earlier in the same list**. Order matters — referencing a variable defined below gives the literal text `$(POSTGRES_USER)` rather than an error, which is a nasty silent failure. Note it is `$(VAR)`, not shell's `${VAR}`.

This is how DevBoard keeps the credentials in one place and assembles the connection string from them.

---

## Task 4: Secrets

**`manifests/secret.yaml`**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: devboard-secrets
  namespace: devboard-dev
type: Opaque
data:
  POSTGRES_PASSWORD: ZGV2Ym9hcmQ=     # devboard
  POSTGRES_DB: ZGV2Ym9hcmQ=
---
apiVersion: v1
kind: Secret
metadata:
  name: devboard-secrets-plain
  namespace: devboard-dev
type: Opaque
stringData:
  POSTGRES_PASSWORD: devboard
  POSTGRES_DB: devboard
```

**`data:` takes base64; `stringData:` takes plain text and encodes it for you.** `stringData` is far better for anything a human reviews — a base64 blob in a pull request is unreviewable.

```
devops@testvm:~/day-54$ echo -n devboard | base64
ZGV2Ym9hcmQ=
```

`-n` matters. Without it `echo` appends a newline and the encoded value contains it, which produces authentication failures that are genuinely hard to trace.

### Base64 is not encryption

```
devops@testvm:~/day-54$ kubectl get secret devboard-secrets -n devboard-dev -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
devboard
```

**Anyone with `get secret` in this namespace can read the value.** Base64 is encoding — it exists so binary data can live in JSON, not to protect anything. Exactly Day 35's point about `~/.docker/config.json`.

By default secrets are also stored **unencrypted in etcd**, so anyone with etcd access or an etcd backup has them all.

What actually helps:

- **RBAC** — restrict `get`/`list` on secrets. This is the main control.
- **Encryption at rest** — an `EncryptionConfiguration` on the API server so etcd holds ciphertext.
- **External secret stores** — Vault, AWS Secrets Manager, with the External Secrets Operator syncing them in.
- **Sealed Secrets or SOPS** — encrypted secrets that *are* safe to commit, which is what GitOps needs.

The two secret manifests here are committed only because the values are throwaway local ones. A real password in `secret.yaml` in git is the Day 27 leak all over again — and worse, because it looks encrypted.

### Other secret types

`type: Opaque` is the generic one. There are purpose-built types:

```
devops@testvm:~/day-54$ kubectl create secret docker-registry regcred -n devboard-dev \
    --docker-server=docker.io \
    --docker-username=manishjha18 \
    --docker-password="$DOCKER_TOKEN"
secret/regcred created
```

That produces `kubernetes.io/dockerconfigjson`, used via `imagePullSecrets` to pull from a private registry. Also `kubernetes.io/tls` for certificates.

---

## Task 5: Secrets in a Pod

Same three mechanisms as ConfigMaps — `secretKeyRef`, `envFrom.secretRef`, or a volume mount.

**Env vars are the convenient option and the weaker one:**

```
devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- env | grep POSTGRES_PASSWORD
POSTGRES_PASSWORD=devboard
```

Anything that can exec into the pod reads it. Worse, an environment variable is inherited by every child process and frequently ends up in crash dumps and error reports — a stack trace that prints the environment leaks the password to a log aggregator.

**A volume mount is better for genuinely sensitive values:**

```yaml
volumeMounts:
  - name: secret-files
    mountPath: /etc/secrets
    readOnly: true
volumes:
  - name: secret-files
    secret:
      secretName: devboard-secrets
      defaultMode: 0400
```

Each key becomes a file, readable only by the owner, and it is not inherited by child processes. It also updates in place when the Secret changes, which env vars do not.

**Secret volumes are `tmpfs`** — held in memory, never written to the node's disk:

```
devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- df -h /etc/secrets
Filesystem   Size  Used Avail Use% Mounted on
tmpfs        2.0G  4.0K  2.0G   1% /etc/secrets
```

---

## Task 6: Updating and propagation

The behaviour differs completely depending on how the value was consumed.

**Update the ConfigMap:**

```
devops@testvm:~/day-54$ kubectl patch configmap devboard-config -n devboard-dev \
    --type merge -p '{"data":{"LOG_LEVEL":"debug"}}'
configmap/devboard-config patched
```

**Mounted as a volume — updates automatically:**

```
devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- cat /etc/devboard/app.properties
feature.kanban=true
feature.search=true
page.size=25

# after patching app.properties and waiting ~70 seconds
devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- cat /etc/devboard/app.properties
feature.kanban=true
feature.search=true
page.size=50
```

Updated in the running pod, no restart. It takes up to about a minute — kubelet syncs on a period, it is not instant.

**As an environment variable — never updates:**

```
devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- env | grep LOG_LEVEL
LOG_LEVEL=info
```

Still `info` after the patch. Environment variables are set once when the container starts, and nothing can change them afterwards.

**This is the single most useful thing from today.** Change a ConfigMap consumed as env vars and *nothing happens* — no error, no restart, no warning. The pods keep the old value indefinitely, and someone eventually notices the config change "did not work".

The fix is to force a rollout:

```
devops@testvm:~/day-54$ kubectl rollout restart deployment/devboard-backend -n devboard-dev
deployment.apps/devboard-backend restarted

devops@testvm:~/day-54$ kubectl exec -n devboard-dev deploy/devboard-backend -- env | grep LOG_LEVEL
LOG_LEVEL=debug
```

The proper solution is an annotation containing a hash of the ConfigMap, so the pod template changes whenever the config does and a rollout happens automatically:

```yaml
template:
  metadata:
    annotations:
      checksum/config: "8a3f91c4d2e58b1a"
```

Helm charts do this as standard, which is Day 59.

| Consumed as | Updates without restart? | Delay |
|---|---|---|
| Volume mount | Yes | Up to ~60s |
| Volume with `subPath` | **No** | — |
| Environment variable | No | Never |

The `subPath` exception is a real trap — mounting a single file with `subPath` looks like a volume mount but behaves like an env var and never updates.

---

## Task 7: Cleanup

```
devops@testvm:~/day-54$ kubectl delete configmap quick-config file-config -n devboard-dev
devops@testvm:~/day-54$ kubectl delete secret devboard-secrets-plain regcred -n devboard-dev
```

Kept `devboard-config` and `devboard-secrets` for the following days.

---

## Files in this folder

| Path | What it is |
|---|---|
| `manifests/configmap.yaml` | Simple values plus a whole file in one ConfigMap |
| `manifests/secret.yaml` | Both `data:` (base64) and `stringData:` (plain) forms |
| `manifests/backend-deployment.yaml` | DevBoard backend consuming both, plus `$(VAR)` substitution |

---

## What I learned

**1. ConfigMap changes reach volume mounts but never reach environment variables.** Patching the ConfigMap left `LOG_LEVEL=info` in the running pod forever, with no error. A rollout restart is the manual fix; a checksum annotation on the pod template is the real one.

**2. Base64 in a Secret is encoding, not protection.** Anyone with `get secret` decodes it in one command, and etcd stores it in plain text by default. RBAC is the actual control, and Sealed Secrets or SOPS is what makes secrets safe to commit.

**3. Secrets as env vars leak more easily than secrets as files.** Environment variables are inherited by child processes and show up in crash dumps. A volume mount is `tmpfs`, mode-restricted, and updates in place.

**Two extras:**

- `echo -n` when base64-encoding. A trailing newline in a password produces auth failures that look like nothing.
- `$(VAR)` in an env value only expands variables declared **earlier** in the same list. Out of order gives the literal string, silently.
