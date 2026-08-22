output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_ip" {
  description = "Browse to http://<this ip>"
  value       = aws_instance.web.public_ip
}

output "security_group_id" {
  value = aws_security_group.web.id
}
