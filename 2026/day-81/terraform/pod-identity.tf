# EKS Pod Identity, not IRSA.
#
# IRSA needs an OIDC provider, a trust policy referencing it, and an
# annotation on the ServiceAccount. Pod Identity replaces all of that with
# an association resource - no annotation, and the association may name a
# namespace or service account that does not exist yet, which matters when
# ArgoCD creates them later.

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                      = "${var.cluster_name}-ebs-csi"
  attach_aws_ebs_csi_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }

  tags = local.tags
}

module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                           = "${var.cluster_name}-external-secrets"
  attach_external_secrets_policy = true

  # read only - the operator must never be able to create or modify secrets
  external_secrets_create_permission = false

  external_secrets_ssm_parameter_arns = []

  # scoped to devboard/* rather than every secret in the account
  external_secrets_secrets_manager_arns = [
    "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${var.postgres_secret_name}-*",
  ]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }

  tags = local.tags
}
