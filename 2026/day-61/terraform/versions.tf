terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-west-2"

  # applied to every resource this provider creates
  default_tags {
    tags = {
      Project   = "devboard"
      ManagedBy = "terraform"
      Day       = "61"
    }
  }
}
