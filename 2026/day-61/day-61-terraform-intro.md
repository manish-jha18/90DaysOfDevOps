# Day 61 – Introduction to Terraform

Config in `terraform/` in this folder.

---

## Task 1: What Infrastructure as Code is

**The problem it solves** is the same one Day 39 described for deployments, applied to infrastructure. Clicking through the AWS console to build a VPC works once. It is not repeatable, nobody can review it, there is no record of why anything is the way it is, and rebuilding it in another region means doing the whole thing again from memory.

**Declarative, not imperative.** This is the same distinction as Day 51's `kubectl apply`. I do not write "create a bucket"; I write "a bucket with these properties exists", and Terraform works out the difference between that and reality.

That difference is the **plan**, and it is the thing that makes Terraform useful. Nothing else in my toolchain shows me exactly what is about to change before it changes.

**Terraform against the alternatives:**

| | Terraform | CloudFormation | Ansible | Helm |
|---|---|---|---|---|
| Scope | Any provider with an API | AWS only | Servers, config | Kubernetes only |
| Model | Declarative, state-based | Declarative, state in AWS | Mostly imperative | Declarative templates |
| Tracks what it built | Yes, a state file | Yes, in the stack | No | Yes, release secrets |

**The state file is the defining feature.** Terraform records what it created, which is how it knows the difference between "create this" and "this already exists, leave it alone" — and how `destroy` knows what to remove. Ansible has no equivalent, which is why it is good at configuring servers and awkward at owning their lifecycle.

---

## Task 2: Install and configure

```
devops@testvm:~$ wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
devops@testvm:~$ echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
devops@testvm:~$ sudo apt update && sudo apt install terraform -y

devops@testvm:~$ terraform version
Terraform v1.11.4
on linux_amd64
```

```
devops@testvm:~$ aws configure
AWS Access Key ID [None]: AKIA****************
AWS Secret Access Key [None]: ****************************************
Default region name [None]: us-west-2
Default output format [None]: json

devops@testvm:~$ aws sts get-caller-identity
{
    "UserId": "AIDA4XVXXXXXXXXXXXXXX",
    "Account": "381492154712",
    "Arn": "arn:aws:iam::381492154712:user/manish-terraform"
}
```

`aws sts get-caller-identity` is the check worth running first — it proves the credentials work and shows *which* identity Terraform will act as. Terraform picks up the same credential chain as the AWS CLI, so there is nothing to configure in the provider block.

Autocomplete:

```
devops@testvm:~$ terraform -install-autocomplete
```

---

## Task 3: The first config

**`terraform/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      Project   = "devboard"
      ManagedBy = "terraform"
      Day       = "61"
    }
  }
}
```

**Pin the provider version.** `~> 6.0` allows 6.x but not 7.0. Unpinned, a major provider release changes resource behaviour and breaks a config that worked yesterday — Day 45's `latest` problem, in a different tool.

**`default_tags` applies tags to every resource this provider creates.** Without it you tag each resource by hand and eventually forget one, and untagged resources are how a cloud bill becomes unattributable.

**`terraform/main.tf`**

```hcl
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "demo" {
  bucket = "devboard-day61-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}
```

**S3 bucket names are globally unique across all of AWS**, so a fixed name collides with a stranger's bucket. `random_id` produces something unique per apply — the same trick as the devboard bootstrap config, which uses the account ID instead.

**Versioning is a separate resource, not a field.** Recent AWS provider versions split most bucket settings into their own resources — versioning, encryption, public access block, lifecycle. Older tutorials show them as inline blocks, which no longer works.

```
devops@testvm:~/day-61/terraform$ terraform init
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 6.0"...
- Installing hashicorp/aws v6.4.0...
- Installed hashicorp/aws v6.4.0 (signed by HashiCorp)

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above.

Terraform has been successfully initialized!
```

`init` downloads providers into `.terraform/` and writes `.terraform.lock.hcl`, which records the exact versions and their checksums. **That lock file should be committed** — it is what makes a build reproducible, the same role as `package-lock.json`.

```
devops@testvm:~/day-61/terraform$ terraform fmt
main.tf
devops@testvm:~/day-61/terraform$ terraform validate
Success! The configuration is valid.
```

`validate` checks syntax and references without contacting AWS. `fmt` is canonical formatting — worth running in CI, since it removes formatting from code review entirely.

```
devops@testvm:~/day-61/terraform$ terraform plan
Terraform will perform the following actions:

  # aws_s3_bucket.demo will be created
  + resource "aws_s3_bucket" "demo" {
      + bucket                      = (known after apply)
      + arn                         = (known after apply)
      + force_destroy               = false
      + tags_all                    = {
          + "Day"       = "61"
          + "ManagedBy" = "terraform"
          + "Project"   = "devboard"
        }
    }

Plan: 4 to add, 0 to change, 0 to destroy.
```

**`(known after apply)`** marks values AWS assigns, which Terraform cannot know in advance. The bucket name shows that way because it depends on `random_id`, which has not been generated yet.

```
devops@testvm:~/day-61/terraform$ terraform apply
Do you want to perform these actions?
  Enter a value: yes

random_id.suffix: Creating...
aws_s3_bucket.demo: Creating...
aws_s3_bucket.demo: Creation complete after 3s [id=devboard-day61-8a3f91c4]
aws_s3_bucket_versioning.demo: Creating...
aws_s3_bucket_public_access_block.demo: Creating...

Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
```

**The order was not random.** `random_id` first, then the bucket, then the two settings that reference it. Terraform built a dependency graph from the references and worked out the order itself — that is Task 3 of Day 62.

---

## Task 4: An EC2 instance

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "demo" {
  ami           = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  tags = {
    Name = "devboard-day61"
  }
}
```

**`data` reads; `resource` creates.** A data source queries something that already exists and never changes anything.

**Hardcoding an AMI ID is the mistake this avoids.** AMI IDs are region-specific, so `ami-0abcd1234` works in `us-west-2` and does not exist in `eu-west-1`. They are also replaced whenever Amazon publishes a new build, so a hardcoded ID slowly becomes an unpatched image.

`most_recent = true` has a trade-off worth naming: it means a fresh AMI can appear between plan and apply, and a later apply may want to **replace** the instance because the AMI changed. Pinning a specific version is the alternative when stability matters more than patches.

```
devops@testvm:~/day-61/terraform$ terraform apply
aws_instance.demo: Creating...
aws_instance.demo: Still creating... [10s elapsed]
aws_instance.demo: Creation complete after 32s [id=i-0a3f91c4d2e58b1a6]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:
ami_id             = "ami-0c2ab3b8efb09f272"
bucket_name        = "devboard-day61-8a3f91c4"
instance_id        = "i-0a3f91c4d2e58b1a6"
instance_public_ip = "44.238.114.92"
```

**Only 1 added.** The bucket already existed and matched the config, so Terraform left it alone. That is the state file doing its job.

---

## Task 5: The state file

```
devops@testvm:~/day-61/terraform$ terraform state list
data.aws_ami.al2023
aws_instance.demo
aws_s3_bucket.demo
aws_s3_bucket_public_access_block.demo
aws_s3_bucket_versioning.demo
random_id.suffix

devops@testvm:~/day-61/terraform$ terraform state show aws_instance.demo | head -12
# aws_instance.demo:
resource "aws_instance" "demo" {
    ami                          = "ami-0c2ab3b8efb09f272"
    arn                          = "arn:aws:ec2:us-west-2:381492154712:instance/i-0a3f91c4d2e58b1a6"
    availability_zone            = "us-west-2a"
    id                           = "i-0a3f91c4d2e58b1a6"
    instance_type                = "t3.micro"
    private_ip                   = "10.0.1.204"
    public_ip                    = "44.238.114.92"
```

**What state is for:**

- **Mapping config to reality.** `aws_instance.demo` in my file corresponds to instance `i-0a3f91c4...` in AWS. Without that, Terraform could not tell an existing resource from one it should create.
- **Knowing what to destroy.** `terraform destroy` removes what is in state, not everything in the account.
- **Detecting drift.** `plan` compares config → state → reality.
- **Performance.** Without it, every plan would have to enumerate every resource in the account.

### Why state must never be committed

```
devops@testvm:~/day-61/terraform$ grep -c "" terraform.tfstate
284
devops@testvm:~/day-61/terraform$ ls -l terraform.tfstate
-rw------- 1 devops devops 12841 Aug  6 09:41 terraform.tfstate
```

**It contains secrets in plain text.** An RDS instance's `password`, a generated private key, the contents of a secret — Terraform stores the whole resource attributes, marked-sensitive or not. The `sensitive` flag only redacts *output*; the state file has the raw value.

It also holds every resource ID, IP and ARN in the environment — a useful map for anyone attacking it.

Hence the `.gitignore`:

```
*.tfstate
*.tfstate.*
.terraform/
*.tfvars
!*.tfvars.example
```

`*.tfvars` too, since that is where credentials usually end up. Day 64 moves state to S3 with encryption, which is the real answer.

---

## Task 6: Modify, plan, destroy

Changing the instance type:

```
devops@testvm:~/day-61/terraform$ sed -i 's/t3.micro/t3.small/' main.tf
devops@testvm:~/day-61/terraform$ terraform plan
  # aws_instance.demo will be updated in-place
  ~ resource "aws_instance" "demo" {
        id            = "i-0a3f91c4d2e58b1a6"
      ~ instance_type = "t3.micro" -> "t3.small"
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

**`~` means update in place.** Terraform stops and starts the instance; it keeps the same ID and the same disk.

Changing something immutable is very different:

```
devops@testvm:~/day-61/terraform$ terraform plan
  # aws_s3_bucket.demo must be replaced
-/+ resource "aws_s3_bucket" "demo" {
      ~ bucket = "devboard-day61-8a3f91c4" -> "devboard-renamed" # forces replacement
    }

Plan: 1 to add, 0 to change, 1 to destroy.
```

**`-/+` and `forces replacement`** — destroy then create. On a bucket that means deleting the data; on an RDS instance it means deleting the database.

**Reading the symbols is the skill:**

| Symbol | Means |
|---|---|
| `+` | Create |
| `-` | Destroy |
| `~` | Update in place |
| `-/+` | Destroy then create — **read this one carefully** |
| `+/-` | Create then destroy (`create_before_destroy`) |

`forces replacement` in a plan against a stateful resource is the moment to stop and think. It is the single most valuable habit Terraform teaches, and it is why `plan` before `apply` is not optional.

Saving a plan so apply cannot do something different:

```
devops@testvm:~/day-61/terraform$ terraform plan -out=tfplan
devops@testvm:~/day-61/terraform$ terraform apply tfplan
```

Applying a saved plan skips the prompt and guarantees exactly what was reviewed. That is the CI pattern — plan on the PR, apply the saved plan on merge.

```
devops@testvm:~/day-61/terraform$ terraform destroy
Plan: 0 to add, 0 to change, 5 to destroy.

Do you really want to destroy all resources?
  Enter a value: yes

aws_instance.demo: Destroying... [id=i-0a3f91c4d2e58b1a6]
aws_s3_bucket_versioning.demo: Destroying...
aws_s3_bucket.demo: Destroying... [id=devboard-day61-8a3f91c4]

Destroy complete! Resources: 5 destroyed.
```

**Destroyed in reverse dependency order** — the settings before the bucket, the bucket before nothing depends on it. Same graph, reversed.

```
devops@testvm:~/day-61/terraform$ terraform state list
devops@testvm:~/day-61/terraform$
```

Empty. Nothing left running, and nothing left billing — which for a learning account is the point.

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/versions.tf` | Version pins, provider, `default_tags` |
| `terraform/main.tf` | S3 bucket with versioning, AMI data source, EC2 instance |
| `terraform/outputs.tf` | Bucket name, instance ID, public IP |
| `terraform/.gitignore` | Keeps state and tfvars out of git |

---

## What I learned

**1. The plan is the product.** Nothing else I use shows exactly what will change before it changes. Reading `-/+ forces replacement` and understanding that it means destroy-then-create is the difference between a routine change and deleting a database.

**2. State is a secret.** It holds passwords and keys in plain text regardless of any `sensitive` flag, plus a complete map of the environment. `.gitignore` is the minimum; remote encrypted state is the real answer.

**3. Terraform derives ordering from references, not from file order.** `random_id` ran before the bucket because the bucket's name interpolates it. Nothing declares that dependency — it comes from the reference itself.

**Two extras:**

- Pin provider versions with `~>` and commit `.terraform.lock.hcl`. An unpinned major release is Day 45's `latest` problem again.
- Look AMIs up with a data source. Hardcoded IDs are region-specific and go stale, which quietly means running an unpatched image.
