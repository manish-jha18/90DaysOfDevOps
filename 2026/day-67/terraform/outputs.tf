output "workspace" {
  description = "Which workspace produced this"
  value       = terraform.workspace
}

output "environment_config" {
  description = "The sizing this workspace resolved to"
  value       = local.cfg
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "instance_ips" {
  value = module.compute.public_ips
}

output "summary" {
  value = format(
    "%s: %d x %s across %d AZs, NAT=%t, CIDR=%s",
    local.name_prefix,
    local.cfg.instance_count,
    local.cfg.instance_type,
    local.cfg.az_count,
    local.cfg.enable_nat_gateway,
    local.cfg.vpc_cidr,
  )
}
