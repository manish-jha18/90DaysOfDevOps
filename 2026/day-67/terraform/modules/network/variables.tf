variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  description = "How many AZs to spread across"
  type        = number
  default     = 2
}

variable "enable_nat_gateway" {
  description = "Private subnets need this for egress. Costs ~$33/mo each."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
