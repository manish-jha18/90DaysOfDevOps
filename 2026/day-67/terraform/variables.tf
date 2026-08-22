variable "region" {
  description = "AWS region. Same for every environment here; a real setup would often split prod into its own region or account."
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Project name, prefixed onto every resource"
  type        = string
  default     = "devboard"
}
