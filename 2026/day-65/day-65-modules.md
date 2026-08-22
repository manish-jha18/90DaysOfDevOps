# Day 65 – Terraform Modules

Config in `terraform/` in this folder: two modules I wrote, plus one from the public registry.

```
terraform/
├── main.tf              root: calls all three modules
├── variables.tf
├── outputs.tf
├── versions.tf
└── modules/
    ├── ec2/             { main, variables, outputs }.tf
    └── security-group/  { main, variables, outputs }.tf
```

---

## Task 1: Module structure

A module is **any directory containing `.tf` files**. That is the whole definition — the config in Days 61–64 was already a module, the *root* module.

The standard three files:

| File | Holds |
|---|---|
| `variables.tf` | Inputs — the module's interface |
| `main.tf` | Resources |
| `outputs.tf` | What callers can read back |

That split is a convention, not a rule, and it matters because **a module's variables and outputs are its public API**. Everything else is implementation detail a caller cannot reach.

**A module cannot reach into another module.** `module.web.aws_instance.this[0].id` is not valid — only declared outputs are accessible. That constraint is what makes modules composable rather than a way of hiding a mess.

---

## Task 2: The EC2 module

**`modules/ec2/variables.tf`** — the interface:

```hcl
variable "name"               { type = string }
variable "instance_count"     { type = number, default = 1 }
variable "instance_type"      { type = string, default = "t3.micro" }
variable "subnet_ids"         { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "user_data"          { type = string, default = null }
variable "ami_id"             { type = string, default = null }
variable "tags"               { type = map(string), default = {} }
```

**Required versus optional is decided by whether there is a `default`.** `name`, `subnet_ids` and `security_group_ids` have none, so a caller must supply them. Everything else has a sensible default.

That is the main design decision in a module: what must the caller decide, and what can it decide for them?

**`modules/ec2/main.tf`** — the interesting part:

```hcl
data "aws_ami" "al2023" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

locals {
  ami_id = coalesce(var.ami_id, try(data.aws_ami.al2023[0].id, null))
}
```

**`count = var.ami_id == null ? 1 : 0`** is the conditional-resource pattern. If the caller supplied an AMI, the data source is not created at all — no wasted API call, and no dependency on an AMI lookup that might behave differently in another region.

`try()` handles indexing into a list that may be empty.

**The whole point is defaults that do not become constraints.** A module that hardcodes the AMI forces every caller to accept it; one that has no default forces every caller to look one up. This does neither.

```hcl
resource "aws_instance" "this" {
  count = var.instance_count

  ami           = local.ami_id
  instance_type = var.instance_type

  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids = var.security_group_ids

  tags = merge(var.tags, {
    Name = "${var.name}-${count.index + 1}"
  })
}
```

**`count.index % length(var.subnet_ids)`** cycles instances across subnets — 4 instances over 2 subnets gives 2 in each.

**`merge(var.tags, {...})`** lets the caller pass any tags while the module still sets `Name`. The module's value wins on a conflict, which is right for something the module owns.

**`resource "aws_instance" "this"`** — naming the single main resource `this` is the registry convention. Inside a module called `ec2`, `aws_instance.ec2` would stutter.

---

## Task 3: The security group module

The interesting problem here is the input type:

```hcl
variable "ingress_rules" {
  type = map(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = {}
}
```

**A map keyed by rule name, not a list.** Day 63's `count` versus `for_each` lesson applied to a module interface — a list means removing the first rule shifts every index and recreates all of them. A map keyed by name means removing `ssh` touches only `ssh`.

The implementation has to flatten a map of rules crossed with a list of CIDRs, because one rule resource takes exactly one `cidr_ipv4`:

```hcl
locals {
  ingress_pairs = merge([
    for rule_name, rule in var.ingress_rules : {
      for cidr in rule.cidr_blocks :
      "${rule_name}-${cidr}" => {
        description = rule.description
        from_port   = rule.from_port
        to_port     = rule.to_port
        protocol    = rule.protocol
        cidr        = cidr
      }
    }
  ]...)
}
```

The `...` at the end is the **spread operator** — `merge()` takes maps as separate arguments, and the comprehension produces a list of maps, so the spread unpacks them.

The result is one resource per rule-and-CIDR pair, keyed stably:

```
aws_vpc_security_group_ingress_rule.this["http-0.0.0.0/0"]
aws_vpc_security_group_ingress_rule.this["ssh-10.0.0.0/16"]
```

Add a third CIDR to `http` and only that one new resource is created. Nothing else moves.

**The egress rule is unconditional**, because Day 62's finding still applies: a Terraform-managed security group with no egress rule blocks all outbound traffic, unlike a raw AWS one.

---

## Task 4: Wiring them together

**`terraform/main.tf`**

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"
  # ...
}

module "web_sg" {
  source = "./modules/security-group"

  name   = "${local.name_prefix}-web"
  vpc_id = module.vpc.vpc_id

  ingress_rules = {
    http = {
      description = "HTTP from anywhere"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
    ssh = {
      description = "SSH from the VPC only"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/16"]
    }
  }

  tags = local.tags
}

module "web" {
  source = "./modules/ec2"

  name               = "${local.name_prefix}-web"
  instance_count     = 2
  subnet_ids         = module.vpc.public_subnets
  security_group_ids = [module.web_sg.id]
  # ...
}
```

**`module.vpc.vpc_id` and `module.web_sg.id` are the wiring.** The output of one module is the input of the next, and those references create the dependency edges exactly as Day 62's resource references did.

```
devops@testvm:~/day-65/terraform$ terraform init
Initializing modules...
- vpc in .terraform/modules/vpc
- web in modules/ec2
- web_sg in modules/security-group

Downloading registry.terraform.io/terraform-aws-modules/vpc/aws 6.1.0 for vpc...
```

**Local modules are referenced in place; registry modules are downloaded** to `.terraform/modules/`.

**`terraform init` is required after adding or changing a module source.** Editing a local module's contents does not need it, but adding a new `module` block does — and the error if you forget is `Module not installed`, which is at least clear.

```
devops@testvm:~/day-65/terraform$ terraform apply
Apply complete! Resources: 27 added, 0 changed, 0 destroyed.

Outputs:
instance_ips = ["44.238.114.92", "35.164.201.77"]
security_group_id = "sg-0a3f91c4d2e58b1a6"
urls = ["http://44.238.114.92", "http://35.164.201.77"]
vpc_id = "vpc-08b1a6c9e0d4a1f27"
```

**27 resources from about 90 lines of root config.** The VPC module alone created 21 — subnets, route tables, associations, a NAT gateway, an Elastic IP, an internet gateway.

Addresses are namespaced by module:

```
devops@testvm:~/day-65/terraform$ terraform state list | head -8
module.vpc.aws_vpc.this[0]
module.vpc.aws_subnet.public[0]
module.vpc.aws_nat_gateway.this[0]
module.web.aws_instance.this[0]
module.web.aws_instance.this[1]
module.web_sg.aws_security_group.this
module.web_sg.aws_vpc_security_group_ingress_rule.this["http-0.0.0.0/0"]
module.web_sg.aws_vpc_security_group_ingress_rule.this["ssh-10.0.0.0/16"]
```

Same module used twice is trivial:

```hcl
module "web"    { source = "./modules/ec2", name = "web",    instance_count = 2 }
module "worker" { source = "./modules/ec2", name = "worker", instance_count = 1 }
```

Two independent sets of instances, one definition.

---

## Task 5: The registry module

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.name_prefix}-vpc"
  cidr = "10.0.0.0/16"
  azs  = local.azs

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}
```

**Thirty lines replaced roughly two hundred.** Day 62 built a VPC by hand and that was one public subnet with no NAT gateway. This gets two public subnets, two private, a NAT gateway, an Elastic IP, route tables and every association.

**`single_nat_gateway = true` is a cost decision worth naming.** One NAT gateway is about $33/month; one per AZ is three times that. The trade is availability — lose that AZ and all private-subnet egress dies. devboard's own `vpc.tf` makes the same choice with a comment saying not to copy it to production, which is the honest way to record a deliberate compromise.

**Why use the registry module:**

- It handles cases I would not think of. IPv6, VPC endpoints, flow logs, per-AZ NAT, the subnet tags load balancer controllers look for.
- Thousands of users have already found the bugs.
- It is maintained as AWS adds features.

**What you give up:** you are reading someone else's abstraction when something breaks, and the AWS VPC module has around 3,000 lines and 200 variables. Debugging inside it is not fun.

**My rule:** registry modules for standard infrastructure everyone builds the same way — VPC, EKS, RDS. Own modules for anything specific to how *this* organisation does things.

devboard's `mega-project` config is exactly this shape — `terraform-aws-modules/vpc/aws`, `terraform-aws-modules/eks/aws` and `terraform-aws-modules/eks-pod-identity/aws` from the registry, with the project's own opinions in the root config.

---

## Task 6: Versioning and best practice

### Always pin

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"     # 6.x, never 7.0
}
```

**Without `version`, Terraform takes the latest at init time.** A colleague running `init` next month gets a different module, and a major version bump renames variables and rebuilds resources. This is Day 45's `latest` problem, with the blast radius of infrastructure.

Constraint styles:

| Constraint | Allows |
|---|---|
| `= 6.1.0` | Exactly that |
| `~> 6.1` | 6.1 and above, below 7.0 |
| `~> 6.1.0` | 6.1.x only |
| `>= 6.0, < 7.0` | The same as `~> 6.0`, written out |

`~> 6.0` is the usual choice — patches and minor releases, no majors.

Git sources need a ref for the same reason:

```hcl
source = "git::https://github.com/manish-jha18/tf-modules.git//ec2?ref=v1.2.0"
```

**`?ref=v1.2.0`, never `?ref=main`.** A module tracking `main` means someone else's merge changes your infrastructure. Same reasoning as Day 39's SHA-pinned GitHub Actions.

### What I would take forward

**Keep modules small and single-purpose.** An "application" module that creates a VPC, a database, a cluster and DNS is impossible to reuse. Small modules compose; large ones only fit the one case they were written for.

**No provider blocks inside a module.** Providers are configured in the root and inherited. A module with its own provider block cannot be used with `for_each` or `count`, and cannot be aliased for multi-region work.

**Output everything a caller might plausibly need.** Outputs are the only way out, and adding one later is a breaking-change-free improvement.

**Description on every variable and output.** `terraform-docs` generates a README from them, and a module without descriptions is one nobody else can use.

**Version modules like software.** Semver, tags, a changelog. A module is a dependency and behaves like one.

```
devops@testvm:~/day-65/terraform$ terraform destroy
Destroy complete! Resources: 27 destroyed.
```

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/main.tf` | Root config calling all three modules |
| `terraform/modules/ec2/` | Conditional AMI lookup, subnet cycling, tag merge |
| `terraform/modules/security-group/` | Map-keyed rules flattened into per-CIDR resources |
| `terraform/outputs.tf` | Re-exports the modules' outputs |

---

## What I learned

**1. A module's variables and outputs are the whole API.** Nothing else is reachable — `module.web.aws_instance.this[0].id` is invalid. That constraint is what makes modules genuinely composable, and it means designing the interface is the actual work.

**2. Map-keyed inputs beat list inputs for anything with identity.** Day 63's `count` versus `for_each` shows up again at the module boundary: `ingress_rules` as a list means removing one rule recreates all of them. As a map keyed by name, only the removed one moves.

**3. Registry modules earn their keep for standard infrastructure, and the cost is debuggability.** Thirty lines produced a better VPC than the two hundred I wrote by hand on Day 62 — with NAT, private subnets and the load balancer tags. But when it breaks, I am reading 3,000 lines of someone else's HCL.

**Two extras:**

- `count = var.x == null ? 1 : 0` makes a data source conditional, so a module can have a default without forcing it on callers.
- No provider blocks inside modules. A module that configures its own provider cannot be used with `count`, `for_each`, or a provider alias.
