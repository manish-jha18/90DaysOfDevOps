terraform {
  # Partial config on purpose. Bucket names are globally unique, so the
  # values come from backend.hcl at init time:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}
