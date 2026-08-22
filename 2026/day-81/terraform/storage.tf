# EKS ships the gp2 storage class but marks nothing as default, so any PVC
# without an explicit storageClassName hangs Pending. This makes gp3 default.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"

  allow_volume_expansion = true

  # WaitForFirstConsumer, or the EBS volume is created in an AZ the pod
  # cannot be scheduled into and the pod hangs forever (day 55)
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [module.eks]
}
