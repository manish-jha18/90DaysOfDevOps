output "vpc_id" {
  description = "VPC identifier"
  value       = aws_vpc.main.id
}

output "subnet_ids" {
  description = "All public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "subnet_cidrs" {
  description = "CIDR blocks cidrsubnet() calculated"
  value       = local.public_subnet_cidrs
}

output "instance_public_ips" {
  description = "Public IPs of every web instance"
  value       = aws_instance.web[*].public_ip
}

output "instance_urls" {
  description = "Ready-to-click URLs"
  value       = [for ip in aws_instance.web[*].public_ip : "http://${ip}"]
}

output "account_id" {
  description = "AWS account this was deployed into"
  value       = data.aws_caller_identity.current.account_id

  # hides it from CLI output. NOTE: the value is still plain text in state.
  sensitive = true
}

output "effective_instance_type" {
  description = "What the conditional in locals.tf actually chose"
  value       = local.effective_instance_type
}

output "summary" {
  description = "One-line description of what was built"
  value = format(
    "%s: %d instance(s) of %s across %d AZs in %s",
    local.name_prefix,
    var.instance_count,
    local.effective_instance_type,
    length(local.azs),
    data.aws_region.current.name,
  )
}
