output "vpc_id" {
  description = "From the registry module"
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "security_group_id" {
  description = "From my security-group module"
  value       = module.web_sg.id
}

output "instance_ips" {
  description = "From my ec2 module"
  value       = module.web.public_ips
}

output "urls" {
  value = [for ip in module.web.public_ips : "http://${ip}"]
}
