variable "name" {
  description = "Base name for the instances"
  type        = string
}

variable "instance_count" {
  description = "How many instances to create"
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "subnet_ids" {
  description = "Subnets to spread instances across"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups to attach"
  type        = list(string)
}

variable "user_data" {
  description = "Cloud-init script. Null means none."
  type        = string
  default     = null
}

variable "ami_id" {
  description = "AMI to use. Null looks up the latest Amazon Linux 2023."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply"
  type        = map(string)
  default     = {}
}
