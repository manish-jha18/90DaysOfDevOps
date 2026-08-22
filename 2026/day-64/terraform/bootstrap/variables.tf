variable "region" {
  description = "AWS region for the state bucket. Keep it the same as the cluster region."
  type        = string
  default     = "us-west-2"
}

variable "bucket_name" {
  description = "Override the bucket name. Null derives devboard-tfstate-<account>-<region>."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Let terraform destroy delete the bucket even with state in it. Right for a learning account, never in production."
  type        = bool
  default     = true
}
