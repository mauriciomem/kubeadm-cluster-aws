# Renders what each node boots with: a cloud-config that writes files under /etc/kube-lab,
# and one role script (files/control-plane.sh or files/worker.sh).
# It has no providers, so scripts/render-templates.sh can evaluate it without AWS credentials.
#
# Two templating passes, so watch the dollar signs in templates/:
#   ${x}  is filled here by templatefile, at plan time.
#   $${X} becomes ${X} and is filled on the node by envsubst, at boot (join secrets only).
# docs/architecture.md describes the boot sequence, status values and SSM paths.
locals {
  k8s_minor = join(".", slice(split(".", var.software.k8s_version), 0, 2))

  control_plane_names = sort([for k, n in var.nodes : k if n.role == "control-plane"])
  worker_count        = length(var.nodes) - length(local.control_plane_names)

  files_dir     = "${path.module}/files"
  templates_dir = "${path.module}/templates"

  # The contract between Terraform and the node scripts: each key, upper-cased, is a
  # shell variable in /etc/kube-lab/cluster.env.
  env_vars = {
    for k, n in var.nodes : k => {
      node_name    = k
      node_role    = n.role
      is_init_node = tostring(n.init)
      # cp-N joins only after cp-(N-1) reports in; see join_cluster in lib.sh.
      previous_control_plane = n.role == "control-plane" && n.index > 0 ? "cp-${n.index}" : ""
      expected_nodes         = tostring(length(var.nodes))
      region                 = var.region
      ssm_prefix             = var.ssm_prefix
      api_endpoint           = var.api_endpoint
      k8s_version            = var.software.k8s_version
      k8s_minor              = local.k8s_minor
      containerd_version     = var.software.containerd_version
      cni                    = var.software.cni
      calico_version         = var.software.calico.version
      calico_crds_sha256     = var.software.calico.crds_sha256
      calico_operator_sha256 = var.software.calico.operator_sha256
      cilium_version         = var.software.cilium.version
      cilium_cli_version     = var.software.cilium.cli_version
      cilium_cli_sha256      = var.software.cilium.cli_sha256
      metrics_server_version = var.software.metrics_server.version
      metrics_server_sha256  = var.software.metrics_server.sha256
    }
  }

  env = {
    for k, vars in local.env_vars : k => templatefile("${local.templates_dir}/cluster.env.tftpl", vars)
  }

  # kubelet-csr-approver only approves serving certificates for node names that match.
  # The root module builds the names (cp-N, worker-N); outputs.tf fails the plan if one
  # doesn't match, rather than leaving its kubelet without a serving certificate.
  node_name_regex = "^(cp|worker)-[0-9]+$"

  init_node = one([for k, n in var.nodes : k if n.init])

  kubeadm_init = templatefile("${local.templates_dir}/kubeadm-init.yaml.tftpl", {
    node_name                 = local.init_node
    k8s_version               = var.software.k8s_version
    cluster_name              = var.cluster_name
    api_endpoint              = var.api_endpoint
    api_host                  = var.api_host
    pod_cidr                  = var.software.pod_cidr
    service_cidr              = var.software.service_cidr
    schedulable_control_plane = local.worker_count == 0
  })

  init_files = merge(
    {
      "/etc/kube-lab/kubeadm-init.yaml.tmpl" = local.kubeadm_init
      "/etc/kube-lab/kubelet-csr-approver.yaml" = templatefile("${local.templates_dir}/kubelet-csr-approver.yaml.tftpl", {
        version         = var.software.csr_approver.version
        digest          = var.software.csr_approver.digest
        node_cidrs      = var.node_cidrs
        node_name_regex = local.node_name_regex
      })
      "/usr/local/sbin/kube-lab-refresh-join"             = file("${local.files_dir}/refresh-join.sh")
      "/etc/systemd/system/kube-lab-refresh-join.service" = file("${local.files_dir}/kube-lab-refresh-join.service")
      "/etc/systemd/system/kube-lab-refresh-join.timer"   = file("${local.files_dir}/kube-lab-refresh-join.timer")
    },
    var.software.cni == "calico" ? {
      "/etc/kube-lab/calico-installation.yaml" = templatefile("${local.templates_dir}/calico-installation.yaml.tftpl", {
        pod_cidr = var.software.pod_cidr
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

  # Files not listed here hold, or will hold, cluster secrets, so they are root-only 0600.
  file_modes = {
    "/usr/local/sbin/kube-lab-refresh-join"             = "0700"
    "/etc/systemd/system/kube-lab-refresh-join.service" = "0644"
    "/etc/systemd/system/kube-lab-refresh-join.timer"   = "0644"
  }

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
          permissions = lookup(local.file_modes, path, "0600")
        }
      ]
    })}"
  }

  script = {
    for k, n in var.nodes : k => file("${local.files_dir}/${n.role}.sh")
  }
}
