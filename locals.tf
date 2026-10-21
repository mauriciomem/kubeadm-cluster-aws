locals {
  cluster_name = "${var.name_prefix}-${random_string.suffix.result}"
  # Passed to the modules rather than default_tags; providers.tf explains why.
  cluster_tags = { Cluster = local.cluster_name }

  # Stable keys: scaling worker_count from 2 to 3 adds worker-3 and touches nothing else.
  # init marks the one node that runs kubeadm init. kubelet-csr-approver only accepts
  # names that match node_name_regex in modules/cluster/bootstrap/main.tf; the plan
  # fails if one doesn't.
  cp_keys     = [for i in range(var.control_plane_count) : "cp-${i + 1}"]
  worker_keys = [for i in range(var.worker_count) : "worker-${i + 1}"]
  nodes = merge(
    { for i, k in local.cp_keys : k => { role = "control-plane", index = i, init = i == 0 } },
    { for i, k in local.worker_keys : k => { role = "worker", index = i, init = false } },
  )

  # What the node scripts install and pass to kubeadm. The nodes read it only when they
  # are created (see docs/configuration.md).
  software = {
    k8s_version        = var.k8s_version
    containerd_version = var.containerd_version
    cni                = var.cni
    pod_cidr           = var.pod_cidr
    service_cidr       = var.service_cidr
    calico = {
      version         = var.calico_version
      crds_sha256     = var.calico_crds_sha256
      operator_sha256 = var.calico_operator_sha256
    }
    cilium = {
      version     = var.cilium_version
      cli_version = var.cilium_cli_version
      cli_sha256  = var.cilium_cli_sha256
    }
    helm = {
      enabled = var.helm_enabled
      version = var.helm_version
      sha256  = var.helm_sha256
    }
    csr_approver = {
      version = var.csr_approver_version
      digest  = var.csr_approver_digest
    }
  }
}
