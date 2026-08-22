output "bucket_name" {
  description = "Name of the created S3 bucket"
  value       = aws_s3_bucket.demo.id
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.demo.id
}

output "instance_public_ip" {
  description = "Public IP of the instance"
  value       = aws_instance.demo.public_ip
}

output "ami_id" {
  description = "AMI the data source resolved to"
  value       = data.aws_ami.al2023.id
}
