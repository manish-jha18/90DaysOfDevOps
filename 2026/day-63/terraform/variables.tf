variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Project name, used as a prefix for every resource"
  type        = string
  default     = "devboard"
}

variable "environment" {
  description = "Environment name"
  type        = string

  # a typo here would otherwise create a whole parallel environment
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "instance_count" {
  description = "How many web instances to run"
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count > 0 && var.instance_count <= 5
    error_message = "instance_count must be between 1 and 5."
  }
}

variable "enable_monitoring" {
  description = "Turn on detailed CloudWatch monitoring (costs extra)"
  type        = bool
  default     = false
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach HTTP"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "extra_tags" {
  description = "Additional tags merged into the defaults"
  type        = map(string)
  default     = {}
}

# an object type documents its own shape and is validated by terraform
variable "backup" {
  description = "Backup settings"
  type = object({
    enabled        = bool
    retention_days = number
  })
  default = {
    enabled        = false
    retention_days = 7
  }
}
