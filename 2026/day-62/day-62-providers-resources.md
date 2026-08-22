# Day 62 – Providers, Resources and Dependencies

Config in `terraform/` in this folder. Everything is built by hand here so the wiring is visible — Day 65 replaces it all with one module block.

---

## Task 1: The AWS provider

```
devops@testvm:~/day-62/terraform$ terraform providers
Providers required by configuration:
.
└── provider[registry.terraform.io/hashicorp/aws] ~> 6.0
```

A **provider** is a plugin translating Terraform resources into API calls. `hashicorp/aws` is a Go binary of about 700 MB that knows how to talk to roughly 1,400 AWS resource types.

**Naming:** `aws_vpc`, `aws_instance`, `aws_security_group` — the provider prefix is always first. That is how Terraform knows which plugin owns a resource type.

**Multiple provider configurations** with aliases, for multi-region work:

```hcl
provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "east"
  region = "us-east-1"
}

resource "aws_s3_bucket" "replica" {
  provider = aws.east
  bucket   = "devboard-replica"
}
```

This comes up more than expected — ACM certificates for CloudFront must live in `us-east-1` regardless of where everything else is.

---

## Task 2: A VPC from scratch

**`terraform/vpc.tf`** builds five resources:

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
```

Day 15's CIDR work, as infrastructure. `10.0.0.0/16` gives 65,536 addresses; the `/24` subnet takes 256 of them, of which AWS reserves five, leaving 251.

**What makes a subnet "public"** is not a flag — it is the route table. A subnet is public because its route table has a `0.0.0.0/0` route through an Internet Gateway. Remove that route and the identical subnet is private. That took me a moment: I expected `public = true` somewhere.

**`map_public_ip_on_launch`** is separate again. Without it, instances in a public subnet get no public IP and cannot be reached even though the route exists.

**The AZ comes from a data source**, not a literal:

```hcl
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
```

Hardcoding `us-west-2a` breaks the moment the region changes. The `opt-in-not-required` filter excludes Local Zones and Wavelength Zones, which appear in the list and cannot host normal instances — devboard's own `providers.tf` has the same filter.

---

## Task 3: Implicit dependencies

This is the mechanism underneath everything.

```
devops@testvm:~/day-62/terraform$ terraform graph | head -14
digraph {
  compound = "true"
  newrank = "true"
  subgraph "root" {
    "[root] aws_instance.web" -> "[root] aws_subnet.public"
    "[root] aws_instance.web" -> "[root] aws_security_group.web"
    "[root] aws_internet_gateway.main" -> "[root] aws_vpc.main"
    "[root] aws_route_table.public" -> "[root] aws_internet_gateway.main"
    "[root] aws_route_table_association.public" -> "[root] aws_route_table.public"
    "[root] aws_route_table_association.public" -> "[root] aws_subnet.public"
    "[root] aws_subnet.public" -> "[root] aws_vpc.main"
  }
}
```

```
devops@testvm:~/day-62/terraform$ terraform graph | dot -Tpng > graph.png
```

The graph, drawn out:

```
                    aws_vpc.main
                   /            \
      aws_internet_gateway     aws_subnet.public
                |                 /        \
      aws_route_table.public     /          \
                |               /            \
      aws_route_table_association          aws_instance.web
                                                  |
                                          aws_security_group.web
```

**Nothing declares any of these edges.** They come entirely from references — `aws_subnet.public` mentions `aws_vpc.main.id`, so the VPC must exist first. Terraform parses the config, finds the references, builds the graph, and walks it.

Two consequences:

**Order in the file is irrelevant.** The instance could be at the top and the VPC at the bottom.

**Independent resources are created in parallel.** Terraform defaults to ten concurrent operations, so the IGW and the subnet are created simultaneously — both depend only on the VPC and not on each other.

```
devops@testvm:~/day-62/terraform$ terraform apply
aws_vpc.main: Creation complete after 2s
aws_internet_gateway.main: Creating...
aws_subnet.public: Creating...
aws_subnet.public: Creation complete after 1s
aws_internet_gateway.main: Creation complete after 1s
```

Both started before either finished.

---

## Task 4: Security group and instance

```hcl
resource "aws_security_group" "web" {
  name        = "devboard-web"
  description = "Allow HTTP in, everything out"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

**Rules as separate resources, not inline blocks.** The older style put `ingress {}` and `egress {}` inside the security group, and it has a real problem: Terraform treats the inline list as the complete set. Any rule added outside Terraform is **silently removed** on the next apply. Separate rule resources leave unmanaged rules alone.

**The egress rule has to be explicit.** A raw AWS security group allows all outbound by default, but a Terraform-managed one with no egress rule allows *nothing* out — and the failure looks like a broken network rather than a missing rule.

Security groups are stateful, so an allowed inbound connection's replies are automatically allowed back out. That is why "allow 80 in" is enough for a web server. NACLs are the stateless equivalent and need both directions.

```hcl
resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y nginx
    echo "<h1>DevBoard - Day 62</h1>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT

  depends_on = [aws_route_table_association.public]
}
```

`user_data` runs once at first boot as root. `<<-EOT` is a heredoc where the `-` strips leading indentation, so the script is not indented inside the generated file.

---

## Task 5: Explicit dependencies

`depends_on` is the interesting line, and it exists because of a bug I hit.

**Without it:**

```
devops@testvm:~/day-62/terraform$ terraform apply
aws_instance.web: Creation complete after 31s
aws_route_table_association.public: Creation complete after 1s

devops@testvm:~$ curl --max-time 5 http://44.238.114.92
curl: (28) Connection timed out
```

The instance was created **before** the route table association. Its `user_data` ran `dnf install -y nginx` at a moment when the subnet had no route to the internet, the install failed, and nginx was never there.

Nothing in the instance config references the route table association, so Terraform saw no dependency and started both in parallel.

**With `depends_on`:**

```
aws_route_table_association.public: Creation complete after 1s
aws_instance.web: Creating...
aws_instance.web: Creation complete after 33s

devops@testvm:~$ curl -s http://44.238.114.92
<h1>DevBoard - Day 62</h1>
```

**`depends_on` is for dependencies that exist in reality but not in the config.** The instance genuinely needs internet access, and internet access comes from a resource it never mentions.

Other common cases: an IAM role policy attachment that must exist before something assumes the role, and a NAT gateway before anything in a private subnet tries to reach out.

**Use it sparingly.** Every explicit dependency removes parallelism, and `depends_on` on a module makes everything in it wait. Nine times out of ten the right fix is a reference, not a `depends_on` — if resource B needs an attribute of A, reference the attribute and the edge appears for free.

---

## Task 6: Lifecycle rules and destroy

```hcl
  lifecycle {
    create_before_destroy = true
  }
```

**The default is destroy-then-create**, which for a security group means a window where the instance has no security group — and AWS refuses to delete a security group still attached to an instance, so the apply fails outright:

```
Error: deleting Security Group (sg-0a3f91c4): DependencyViolation:
resource sg-0a3f91c4 has a dependent object
```

`create_before_destroy` makes the new one first, moves the reference, then deletes the old. Terraform appends a suffix so the names do not clash mid-swap.

The three lifecycle rules worth knowing:

```hcl
lifecycle {
  create_before_destroy = true

  prevent_destroy = true          # apply FAILS if anything would destroy this

  ignore_changes = [tags["LastScanned"]]   # do not fight another system over this field
}
```

**`prevent_destroy`** on a production database or a state bucket is a genuine safety net — an accidental `terraform destroy` errors instead of proceeding. It also blocks legitimate replacement, so removing it becomes a deliberate step.

**`ignore_changes`** for fields something else owns. An autoscaling group's `desired_capacity` managed by an HPA-equivalent, or tags added by a scanner — exactly Day 58's HPA-versus-`replicas` conflict, in Terraform form.

```
devops@testvm:~/day-62/terraform$ terraform destroy
Plan: 0 to add, 0 to change, 7 to destroy.

aws_instance.web: Destroying... [id=i-0a3f91c4d2e58b1a6]
aws_instance.web: Destruction complete after 41s
aws_vpc_security_group_ingress_rule.http: Destruction complete after 1s
aws_route_table_association.public: Destruction complete after 1s
aws_route_table.public: Destruction complete after 1s
aws_security_group.web: Destruction complete after 1s
aws_subnet.public: Destruction complete after 1s
aws_internet_gateway.main: Destruction complete after 2s
aws_vpc.main: Destruction complete after 1s

Destroy complete! Resources: 7 destroyed.
```

**Reverse dependency order**, and the instance took 41 seconds while everything else took one — the graph waited for it, because the subnet and security group cannot go until nothing uses them.

Worth confirming nothing was left behind, since orphaned resources are how a learning account develops a bill:

```
devops@testvm:~$ aws ec2 describe-vpcs --filters "Name=tag:Project,Values=devboard" --query 'Vpcs[].VpcId'
[]
```

The `default_tags` from Day 61 is what makes that check possible.

---

## Files in this folder

| Path | What it is |
|---|---|
| `terraform/versions.tf` | Provider pin, `default_tags`, AZ data source |
| `terraform/vpc.tf` | VPC, IGW, subnet, route table, association |
| `terraform/compute.tf` | Security group, separate rule resources, instance with `user_data` |
| `terraform/outputs.tf` | VPC ID, public IP, security group ID |

---

## What I learned

**1. Dependencies come from references, and where there is no reference there is no ordering.** The instance was built before the route existed, its `user_data` had no internet, and nginx silently never installed. Nothing errored — I only found it with `curl`. That is the case `depends_on` exists for.

**2. A subnet is public because of its route table, not because of a setting.** There is no `public` flag. The `0.0.0.0/0` route through an Internet Gateway is the entire difference, and `map_public_ip_on_launch` is a third separate thing.

**3. Inline security group rules silently delete anything added outside Terraform.** Separate `aws_vpc_security_group_ingress_rule` resources leave unmanaged rules alone. And a Terraform-managed group with no egress rule blocks all outbound, which does not match the AWS default.

**Two extras:**

- `create_before_destroy` on a security group avoids a `DependencyViolation` that fails the whole apply.
- `terraform graph | dot -Tpng` renders the real dependency graph, which is the fastest way to understand why Terraform is doing things in the order it is.
