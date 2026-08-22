variable "region" {
  description = "AWS region for the cluster"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the VPC name and an IAM role prefix."
  type        = string
  default     = "devboard"
}

variable "kubernetes_version" {
  description = "EKS control plane version. Pinned, not floating."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Worker instance type. t3.medium is the practical floor for anything real."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Nodes to run"
  type        = number
  default     = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_disk_size" {
  description = "Root volume per node in GiB"
  type        = number
  default     = 30
}
