output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "postgres_secret_arn" {
  description = "Set its value with: aws secretsmanager put-secret-value --secret-id ..."
  value       = aws_secretsmanager_secret.postgres.arn
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "estimated_hourly_cost" {
  description = "Rough. Destroy when you are done."
  value = format(
    "~$%.2f/hr : control plane $0.10 + %d x %s + 1 NAT gateway $0.045",
    0.10 + 0.045 + (var.node_desired_size * 0.0832),
    var.node_desired_size,
    var.node_instance_type,
  )
}
