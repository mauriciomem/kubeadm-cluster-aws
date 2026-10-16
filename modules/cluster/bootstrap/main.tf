# Renders per-node bootstrap content. No providers, so scripts/render-templates.sh can
# evaluate it offline for shellcheck and size checks.
locals {
  sw        = var.software
  k8s_minor = join(".", slice(split(".", local.sw.k8s_version), 0, 2))

  control_plane_names = sort([for k, n in var.nodes : k if n.role == "control-plane"])
  worker_count        = length(var.nodes) - length(local.control_plane_names)

  files_dir     = "${path.module}/files"
  templates_dir = "${path.module}/templates"

  env = {
    for k, n in var.nodes : k => templatefile("${local.templates_dir}/cluster.env.tftpl", {
      node_name = k
      role      = n.role
      init      = n.init
      # cp-N joins only after cp-(N-1) reports in; see join_cluster in lib.sh.
      previous_control_plane = n.role == "control-plane" && n.index > 0 ? "cp-${n.index}" : ""
      expected_nodes         = length(var.nodes)
      cluster_name           = var.cluster_name
      region                 = var.region
      ssm_prefix             = var.ssm_prefix
      api_endpoint           = var.api_endpoint
      k8s_version            = local.sw.k8s_version
      k8s_minor              = local.k8s_minor
      containerd_version     = local.sw.containerd_version
      cni                    = local.sw.cni
      calico_version         = local.sw.calico.version
      calico_crds_sha256     = local.sw.calico.crds_sha256
      calico_operator_sha256 = local.sw.calico.operator_sha256
      cilium_version         = local.sw.cilium.version
      cilium_cli_version     = local.sw.cilium.cli_version
      cilium_cli_sha256      = local.sw.cilium.cli_sha256
      metrics_server_version = local.sw.metrics_server.version
      metrics_server_sha256  = local.sw.metrics_server.sha256
    })
  }

  init_node = one([for k, n in var.nodes : k if n.init])

  kubeadm_init = templatefile("${local.templates_dir}/kubeadm-init.yaml.tftpl", {
    node_name                 = local.init_node
    k8s_version               = local.sw.k8s_version
    cluster_name              = var.cluster_name
    api_endpoint              = var.api_endpoint
    api_host                  = var.api_host
    pod_cidr                  = local.sw.pod_cidr
    service_cidr              = local.sw.service_cidr
    schedulable_control_plane = local.worker_count == 0
  })

  init_files = merge(
    {
      "/etc/kube-lab/kubeadm-init.yaml.tmpl" = local.kubeadm_init
      "/etc/kube-lab/kubelet-csr-approver.yaml" = templatefile("${local.templates_dir}/kubelet-csr-approver.yaml.tftpl", {
        version    = local.sw.csr_approver.version
        digest     = local.sw.csr_approver.digest
        node_cidrs = var.node_cidrs
      })
      "/usr/local/sbin/kube-lab-refresh-join"             = file("${local.files_dir}/refresh-join.sh")
      "/etc/systemd/system/kube-lab-refresh-join.service" = file("${local.files_dir}/kube-lab-refresh-join.service")
      "/etc/systemd/system/kube-lab-refresh-join.timer"   = file("${local.files_dir}/kube-lab-refresh-join.timer")
    },
    local.sw.cni == "calico" ? {
      "/etc/kube-lab/calico-installation.yaml" = templatefile("${local.templates_dir}/calico-installation.yaml.tftpl", {
        pod_cidr = local.sw.pod_cidr
      })
    } : {},
  )

  files = {
    for k, n in var.nodes : k => merge(
      {
        "/etc/kube-lab/cluster.env" = local.env[k]
        "/etc/kube-lab/lib.sh"      = file("${local.files_dir}/lib.sh")
      },
      n.init ? local.init_files : {
        "/etc/kube-lab/kubeadm-join.yaml.tmpl" = templatefile("${local.templates_dir}/kubeadm-join.yaml.tftpl", {
          node_name     = k
          api_endpoint  = var.api_endpoint
          control_plane = n.role == "control-plane"
          # Every control plane needs it: kubeadm applies taints per node.
          schedulable_control_plane = local.worker_count == 0
        })
      },
    )
  }

  executables = ["/usr/local/sbin/kube-lab-refresh-join"]

  # Everything else may hold cluster secrets once rendered, so it is root-only.
  file_mode = { for path in distinct(flatten([for f in values(local.files) : keys(f)])) : path => (
    contains(local.executables, path) ? "0700" : startswith(path, "/etc/systemd/") ? "0644" : "0600"
  ) }

  cloud_config = {
    for k, n in var.nodes : k => "#cloud-config\n${yamlencode({
      hostname          = k
      preserve_hostname = false
      manage_etc_hosts  = true
      write_files = [
        for path in sort(keys(local.files[k])) : {
          path        = path
          content     = local.files[k][path]
          owner       = "root:root"
          permissions = local.file_mode[path]
        }
      ]
    })}"
  }

  script = {
    for k, n in var.nodes : k => file("${local.files_dir}/${n.role}.sh")
  }
}
