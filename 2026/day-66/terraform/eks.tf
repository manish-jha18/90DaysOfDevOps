module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true

  # without this the creating identity has NO kubectl access to its own cluster
  enable_cluster_creator_admin_permissions = true

  # audit + authenticator only. "api" and "controllerManager" are the expensive
  # ones for CloudWatch ingest on a learning cluster.
  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  vpc_id = module.vpc.vpc_id
  # worker nodes go in PRIVATE subnets - they reach out via NAT,
  # nothing reaches in except through a load balancer
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  addons = {
    coredns    = {}
    kube-proxy = {}

    # before_compute: the CNI must exist before nodes join, or they
    # register NotReady with no pod networking
    vpc-cni = {
      before_compute = true
    }

    eks-pod-identity-agent = {
      before_compute = true
    }

    metrics-server     = {}
    aws-ebs-csi-driver = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # disk_size is silently ignored in module v21 - the root volume
      # has to be set through block_device_mappings instead
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  tags = local.tags
}
