# Day 64 – State Management and Remote Backends

Config in `terraform/` in this folder, structured the way devboard's `mega-project` branch does it — a `bootstrap/` config with local state that creates the bucket, and a main config that uses it.

---

## Task 1: Inspecting current state

```
devops@testvm:~/day-64/terraform$ terraform state list
data.aws_ami.al2023
aws_instance.web[0]
aws_security_group.web
aws_subnet.public[0]
aws_subnet.public[1]
aws_vpc.main

devops@testvm:~/day-64/terraform$ terraform show -json | jq '.values.root_module.resources | length'
9

devops@testvm:~/day-64/terraform$ jq '.serial, .lineage, .terraform_version' terraform.tfstate
14
"8a3f91c4-d2e5-8b1a-6c9e-0d4a1f27b8a3"
"1.11.4"
```

Three fields worth knowing:

- **`serial`** increments on every write. It is how Terraform detects that state changed underneath it.
- **`lineage`** is a UUID identifying this state's history. Two state files with different lineages are unrelated, and Terraform refuses to overwrite one with the other.
- **`terraform_version`** — an older binary refuses to read state written by a newer one.

### Why local state does not survive a team

**One machine.** The state is on my laptop. Nobody else can plan or apply, and if the disk dies the mapping between config and reality is gone. The resources keep running, unmanaged.

**No locking.** Two people applying at once both read, both write, and the second overwrites the first. Terraform has no idea.

**Unencrypted secrets.** Day 61's point — plaintext passwords and keys sitting in the working directory.

**Cannot be automated.** A CI runner is a fresh machine (Day 42), so it has no state and would try to create everything again.

---

## Task 2: The S3 backend

### The chicken-and-egg problem

The backend needs a bucket. Creating the bucket with Terraform needs a backend. The standard answer is a **separate bootstrap config with local state**, run once.

**`terraform/bootstrap/main.tf`** creates the bucket with everything it should have:

```hcl
resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Every one of those has a reason:

- **Versioning** is the recovery path. A truncated or corrupted state file is restored from a previous version, and it is the only real undo.
- **Encryption** because state holds secrets in plain text.
- **Public access block** because a public state bucket is a complete map of the infrastructure plus its credentials.
- **A lifecycle rule** expiring non-current versions after 90 days, or they accumulate forever.
- **A bucket policy denying non-TLS requests**, so state is never transmitted in the clear.

The bucket name is derived, not hardcoded:

```hcl
bucket_name = coalesce(var.bucket_name, "devboard-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}")
```

S3 names are globally unique, so a hardcoded one in a public repo fails for everyone but the author. Deriving it from the account ID makes the config work in any account, which is Day 63's data-source reasoning.

```
devops@testvm:~/day-64/terraform/bootstrap$ terraform init && terraform apply
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:
bucket_name = "devboard-tfstate-381492154712-us-west-2"
backend_hcl = <<EOT
bucket = "devboard-tfstate-381492154712-us-west-2"
key    = "devboard/day-64/terraform.tfstate"
region = "us-west-2"

encrypt = true

use_lockfile = true
EOT
```

**The `backend_hcl` output generates the config file**, which is a neat trick from devboard's bootstrap:

```
devops@testvm:~/day-64/terraform/bootstrap$ terraform output -raw backend_hcl > ../backend.hcl
```

### Partial backend configuration

**`terraform/backend.tf`**

```hcl
terraform {
  backend "s3" {}
}
```

**Empty on purpose.** A backend block cannot use variables or interpolation at all — it is read before Terraform evaluates anything. So the bucket name cannot be `${var.bucket}`.

The partial-config pattern is the way round it: declare the backend type in the file, supply the values at init time.

```
devops@testvm:~/day-64/terraform$ terraform init -backend-config=backend.hcl

Initializing the backend...
Do you want to copy existing state to the new backend?
  Pre-existing state was found while migrating the previous "local" backend
  to the newly configured "s3" backend. Do you want to copy this state?

  Enter a value: yes

Successfully configured the backend "s3"! Terraform will automatically
use this backend unless the backend configuration changes.
```

**Terraform offered to migrate the existing state, which is the important part** — answering yes copies it to S3 and it keeps managing the same resources. Answering no would leave Terraform believing nothing exists, and the next apply would try to build a duplicate of everything.

```
devops@testvm:~/day-64/terraform$ aws s3 ls s3://devboard-tfstate-381492154712-us-west-2/devboard/day-64/
2026-08-07 09:41:22      12841 terraform.tfstate

devops@testvm:~/day-64/terraform$ ls terraform.tfstate*
terraform.tfstate.backup
```

The local file is gone, leaving only a backup. State now lives in S3.

**`use_lockfile = true` is the current locking mechanism.** Until Terraform 1.10 this required a separate DynamoDB table with a `LockID` key — most tutorials still show that. S3-native locking went GA in 1.11 and uses a conditional-write lock object in the same bucket. One less resource, one less thing to pay for.

---

## Task 3: Locking

Starting a long apply in one terminal and a plan in another:

```
devops@testvm:~/day-64/terraform$ terraform plan

Error: Error acquiring the state lock

Error message: operation error S3: PutObject, https response error StatusCode: 412,
PreconditionFailed: At least one of the pre-conditions you specified did not hold

Lock Info:
  ID:        9f2a5b8c-1d4e-7f0a-3b6c-9d2e5f8a1b4c
  Path:      devboard-tfstate-381492154712-us-west-2/devboard/day-64/terraform.tfstate
  Operation: OperationTypeApply
  Who:       devops@testvm
  Version:   1.11.4
  Created:   2026-08-07 09:52:14.882104 +0000 UTC
```

**Blocked, with who holds it and since when.** That is the whole point — two concurrent applies would otherwise produce state describing neither result.

`412 PreconditionFailed` is S3 conditional writes doing the work: the lock object is created with "only if it does not exist".

**Recovering from a stale lock** — a CI job killed mid-apply leaves one behind:

```
devops@testvm:~/day-64/terraform$ terraform force-unlock 9f2a5b8c-1d4e-7f0a-3b6c-9d2e5f8a1b4c
Do you really want to force-unlock?
  Enter a value: yes
Terraform state has been successfully unlocked!
```

**Only after confirming nothing is actually running.** Force-unlocking a live apply is how state gets corrupted.

---

## Task 4: Importing an existing resource

Something created outside Terraform:

```
devops@testvm:~$ aws s3api create-bucket --bucket devboard-manual-8a3f91c4 \
    --region us-west-2 --create-bucket-configuration LocationConstraint=us-west-2
```

**The old way** — write the config, then `terraform import`:

```
devops@testvm:~/day-64/terraform$ terraform import aws_s3_bucket.manual devboard-manual-8a3f91c4
Import successful!
```

**The better way, since Terraform 1.5 — an `import` block:**

```hcl
import {
  to = aws_s3_bucket.manual
  id = "devboard-manual-8a3f91c4"
}

resource "aws_s3_bucket" "manual" {
  bucket = "devboard-manual-8a3f91c4"
}
```

```
devops@testvm:~/day-64/terraform$ terraform plan
  # aws_s3_bucket.manual will be imported
    resource "aws_s3_bucket" "manual" {
        bucket = "devboard-manual-8a3f91c4"
        id     = "devboard-manual-8a3f91c4"
    }

Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.
```

**It shows in the plan before happening.** The `terraform import` command changes state immediately with no preview, so a wrong ID means state surgery to undo. An import block is reviewable, works in CI, and is removed once applied.

Even better, Terraform can write the config for you:

```
devops@testvm:~/day-64/terraform$ terraform plan -generate-config-out=imported.tf
```

**The usual mistake:** importing brings the resource into state but does not write config. If the config does not match reality, the very next apply "corrects" the real resource to match the file — which on an imported production resource means changing settings nobody asked to change. Always `plan` after an import and confirm it says **no changes**.

---

## Task 5: State surgery

**`state mv` — renaming without recreating:**

```hcl
# renaming aws_instance.web to aws_instance.app
```

```
devops@testvm:~/day-64/terraform$ terraform plan
Plan: 1 to add, 0 to change, 1 to destroy.
```

**Terraform would destroy and rebuild the instance**, purely because the address changed. The resource is identical; only its name in state differs.

```
devops@testvm:~/day-64/terraform$ terraform state mv 'aws_instance.web[0]' 'aws_instance.app[0]'
Move "aws_instance.web[0]" to "aws_instance.app[0]"
Successfully moved 1 object(s).

devops@testvm:~/day-64/terraform$ terraform plan
No changes. Your infrastructure matches the configuration.
```

The modern equivalent is a `moved` block, which is committed and reviewable:

```hcl
moved {
  from = aws_instance.web
  to   = aws_instance.app
}
```

**Prefer `moved` blocks.** `state mv` is a manual step someone has to remember to run; a `moved` block travels with the code, so a colleague pulling the change does not get a surprise rebuild.

**`state rm` — forgetting without destroying:**

```
devops@testvm:~/day-64/terraform$ terraform state rm aws_s3_bucket.manual
Removed aws_s3_bucket.manual
Successfully removed 1 resource instance(s).
```

The bucket still exists in AWS; Terraform simply no longer manages it. The reverse of `import`.

Used for handing a resource to another configuration, or removing something that must not be destroyed. **Removing it from state and from the config means it is orphaned** — running, billing, unmanaged, and easy to forget.

**Always back up before surgery:**

```
devops@testvm:~/day-64/terraform$ terraform state pull > backup-$(date +%F-%H%M).tfstate
```

`state pull` works with a remote backend, and `state push` restores it. With versioning enabled the bucket also holds every previous version, which is the other recovery path.

---

## Task 6: Drift

Changing something by hand, the way an incident response often does:

```
devops@testvm:~$ aws ec2 create-tags --resources i-0a3f91c4d2e58b1a6 \
    --tags Key=Name,Value=changed-in-console Key=Owner,Value=someone-else
```

```
devops@testvm:~/day-64/terraform$ terraform plan
Note: Objects have changed outside of Terraform

  # aws_instance.app[0] has been changed
  ~ resource "aws_instance" "app" {
      ~ tags = {
          ~ "Name"  = "devboard-web-1" -> "changed-in-console"
          + "Owner" = "someone-else"
        }
    }

Terraform will perform the following actions:

  # aws_instance.app[0] will be updated in-place
  ~ resource "aws_instance" "app" {
      ~ tags = {
          ~ "Name"  = "changed-in-console" -> "devboard-web-1"
          - "Owner" = "someone-else" -> null
        }
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

**Two sections, and reading both matters.** The first reports what changed outside Terraform. The second is what Terraform intends to do about it — revert to the config.

```
devops@testvm:~/day-64/terraform$ terraform apply
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

**The config is the source of truth**, so drift is corrected back towards it. That is the whole model.

### Detecting drift without changing anything

```
devops@testvm:~/day-64/terraform$ terraform plan -detailed-exitcode
Plan: 0 to add, 0 to change, 0 to destroy.

devops@testvm:~/day-64/terraform$ echo $?
0
```

`-detailed-exitcode` gives **0** for no changes, **1** for an error, **2** for changes pending. That makes drift detection a scheduled CI job:

```yaml
- name: Detect drift
  run: |
    terraform plan -detailed-exitcode -lock=false
    if [ $? -eq 2 ]; then
      echo "::warning::Infrastructure has drifted from configuration"
    fi
```

Day 47's cron trigger, applied to infrastructure. `-lock=false` because a read-only plan should not block someone's apply.

**Three ways to handle drift:**

1. **Revert** — apply and let the config win. The default and usually right.
2. **Adopt** — the manual change was correct, so update the config to match.
3. **Ignore** — `lifecycle { ignore_changes = [tags["LastScanned"]] }` when another system legitimately owns a field. Day 62's rule.

The one to avoid is a permanent plan diff that everyone learns to ignore. Once a team stops reading plans, Terraform's main safety feature is gone.

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/bootstrap/main.tf` | The state bucket, with versioning, encryption, lifecycle and a TLS-only policy |
| `terraform/bootstrap/outputs.tf` | `backend_hcl` output that generates the backend config |
| `terraform/backend.tf` | Empty `backend "s3" {}` — partial config |
| `terraform/backend.hcl.example` | Template; the real `backend.hcl` is gitignored |

---

## What I learned

**1. A backend block cannot use variables, which is why partial configuration exists.** It is read before Terraform evaluates anything, so the bucket name comes from `-backend-config=backend.hcl` at init time. Generating that file from the bootstrap output means the name is never hardcoded.

**2. Importing puts a resource in state but does not write config, and the next apply reconciles reality to the file.** So an import with a mismatched config *changes the real resource*. Always plan after importing and confirm it reports no changes.

**3. Renaming a resource destroys and recreates it unless you tell Terraform otherwise.** Nothing about the resource changed — only its address. A `moved` block is better than `state mv` because it is committed and travels with the code.

**Two extras:**

- `use_lockfile = true` replaced the DynamoDB lock table in Terraform 1.11. Most tutorials still tell you to create one.
- `terraform plan -detailed-exitcode` returns 2 when there are changes, which makes scheduled drift detection a three-line CI job.
