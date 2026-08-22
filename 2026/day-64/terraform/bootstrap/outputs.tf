output "bucket_name" {
  description = "Name of the S3 bucket holding the main config's state"
  value       = aws_s3_bucket.state.id
}

output "backend_hcl" {
  description = "Ready-to-use backend config: terraform output -raw backend_hcl > ../backend.hcl"

  value = <<-EOT
    bucket = "${aws_s3_bucket.state.id}"
    key    = "devboard/day-64/terraform.tfstate"
    region = "${var.region}"

    encrypt = true

    # S3-native locking, GA since terraform 1.11. Replaced the DynamoDB table.
    use_lockfile = true
  EOT
}
