locals {
  # terraform.workspace is the whole trick: one config, three environments,
  # three separate state files, selected by which workspace is active.
  env = terraform.workspace

  # per-environment sizing. A workspace not in this map fails at plan time
  # rather than silently building something with default settings.
  env_config = {
    dev = {
      vpc_cidr           = "10.10.0.0/16"
      instance_type      = "t3.micro"
      instance_count     = 1
      az_count           = 2
      enable_nat_gateway = false # dev does not need private egress - saves ~$33/mo
      detailed_monitoring = false
      allowed_http_cidrs = ["0.0.0.0/0"]
    }

    staging = {
      vpc_cidr           = "10.20.0.0/16"
      instance_type      = "t3.small"
      instance_count     = 2
      az_count           = 2
      enable_nat_gateway = true
      detailed_monitoring = false
      allowed_http_cidrs = ["0.0.0.0/0"]
    }

    prod = {
      vpc_cidr           = "10.30.0.0/16"
      instance_type      = "t3.medium"
      instance_count     = 3
      az_count           = 3
      enable_nat_gateway = true
      detailed_monitoring = true
      # prod is not open to the world
      allowed_http_cidrs = ["10.0.0.0/8"]
    }
  }

  # lookup() with no default would return null on an unknown workspace and
  # fail later with a confusing error. This fails immediately and says why.
  cfg = lookup(
    local.env_config,
    local.env,
    null
  )

  name_prefix = "${var.project}-${local.env}"

  tags = {
    Project     = var.project
    Environment = local.env
    ManagedBy   = "terraform"
    Workspace   = terraform.workspace
  }
}

# guard: refuse to run in the "default" workspace or any unknown one
resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = local.cfg != null
      error_message = "Unknown workspace '${terraform.workspace}'. Run: terraform workspace select dev|staging|prod"
    }
  }
}

module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = local.cfg.vpc_cidr
  az_count           = local.cfg.az_count
  enable_nat_gateway = local.cfg.enable_nat_gateway

  tags = local.tags
}

module "compute" {
  source = "./modules/compute"

  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id
  subnet_ids  = module.network.public_subnet_ids

  instance_count             = local.cfg.instance_count
  instance_type              = local.cfg.instance_type
  allowed_http_cidrs         = local.cfg.allowed_http_cidrs
  enable_detailed_monitoring = local.cfg.detailed_monitoring

  tags = local.tags
}
