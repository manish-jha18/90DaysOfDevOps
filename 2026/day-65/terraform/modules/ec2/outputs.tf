output "instance_ids" {
  description = "IDs of all created instances"
  value       = aws_instance.this[*].id
}

output "public_ips" {
  description = "Public IPs"
  value       = aws_instance.this[*].public_ip
}

output "private_ips" {
  description = "Private IPs"
  value       = aws_instance.this[*].private_ip
}
