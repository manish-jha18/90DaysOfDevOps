locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --- a PUBLIC REGISTRY module for the networking ---
# 30 lines here replaces roughly 200 lines of hand-written VPC resources,
# and this module handles cases I would not have thought of.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0" # ALWAYS pin - source alone tracks latest

  name = "${local.name_prefix}-vpc"
  cidr = "10.0.0.0/16"
  azs  = local.azs

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # one NAT (~$33/mo) not two. Not production advice.

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.tags
}

# --- MY OWN modules ---
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

  name           = "${local.name_prefix}-web"
  instance_count = 2
  instance_type  = "t3.micro"

  # module-to-module wiring: the output of one is the input of the next.
  # this reference is also what creates the dependency edge.
  subnet_ids         = module.vpc.public_subnets
  security_group_ids = [module.web_sg.id]

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y nginx
    echo "<h1>DevBoard - Day 65 - $(hostname)</h1>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT

  tags = local.tags
}
