variable "name" {
  description = "Name for the security group"
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the group in"
  type        = string
}

variable "ingress_rules" {
  description = "Inbound rules. Keyed by name so adding or removing one does not disturb the others."
  type = map(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = {}
}

variable "tags" {
  description = "Tags to apply"
  type        = map(string)
  default     = {}
}
