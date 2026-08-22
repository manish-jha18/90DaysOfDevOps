locals {
  # computed once, used everywhere - changing the pattern is a one-line edit
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.extra_tags,
  )

  # prod gets a bigger box regardless of what the tfvars says
  effective_instance_type = var.environment == "prod" ? "t3.medium" : var.instance_type

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # carve /24s out of whatever vpc_cidr is, rather than hardcoding them.
  # cidrsubnet("10.0.0.0/16", 8, 0) -> "10.0.0.0/24"
  public_subnet_cidrs = [
    for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, i)
  ]
}
