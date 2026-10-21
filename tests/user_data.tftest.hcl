# What each node boots with: which files reach which node, and the values rendered into them.
mock_provider "aws" {
  source = "./tests/mocks"
}

# Fixes the random suffix so rendered content is known at plan time.
override_resource {
  target          = random_string.suffix
  override_during = plan
  values = {
    result = "test"
  }
}

# modules/status reads live SSM values, which a plan of a new cluster can't evaluate.
# tests/status.tftest.hcl tests it on its own.
override_module {
  target = module.status
  outputs = {
    status  = { cluster = "ready" }
    message = ""
  }
}

# Every value the runs assume is pinned here: test-file variables win over terraform.tfvars,
# so your own settings don't change what the tests see.
variables {
  operator_cidrs      = ["203.0.113.10/32"]
  region              = "us-east-1"
  name_prefix         = "kube-lab"
  control_plane_count = 1
  worker_count        = 2
  cni                 = "calico"
  k8s_version         = "1.36.5"
  cilium_version      = "1.20.3"
  vpc_cidr            = "10.10.0.0/16"
  pod_cidr            = "192.168.0.0/16"
  service_cidr        = "10.96.0.0/12"
  ami_id              = null
  helm_enabled        = false
  wait_for_cluster    = false
}

run "cp1_runs_kubeadm_init" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "\nIS_INIT_NODE='true'\n")
    error_message = "cluster.env must mark cp-1 as the node that runs kubeadm init."
  }

  assert {
    condition = (
      contains(keys(module.cluster.bootstrap["cp-1"].files), "/etc/kube-lab/kubeadm-init.yaml.tmpl") &&
      !contains(keys(module.cluster.bootstrap["cp-1"].files), "/etc/kube-lab/kubeadm-join.yaml.tmpl")
    )
    error_message = "cp-1 must receive the kubeadm init config and no join config."
  }

  assert {
    condition     = contains(keys(module.cluster.bootstrap["cp-1"].files), "/etc/kube-lab/kubelet-csr-approver.yaml")
    error_message = "cp-1 must receive the kubelet-csr-approver manifest."
  }

  # Bootstrap logs get pasted into chats and issues.
  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "--skip-token-print --skip-certificate-key-print")
    error_message = "kubeadm init must not print the join token or certificate key."
  }
}

run "kubeadm_init_config" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "kubernetesVersion: v1.36.5\n")
    error_message = "The kubeadm init config must pin v1.36.5."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "controlPlaneEndpoint: \"kube-lab-test-api-0123456789abcdef.elb.us-east-1.amazonaws.com:6443\"")
    error_message = "controlPlaneEndpoint must be the NLB DNS name."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "serverTLSBootstrap: true\n")
    error_message = "Kubelets must request serving certificates signed by the cluster CA, which kubelet-csr-approver approves."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "\nK8S_MINOR='1.36'\n")
    error_message = "The pkgs.k8s.io repository must track the v1.36 minor."
  }
}

run "workers_join" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["worker-1", "worker-2"] :
      strcontains(module.cluster.bootstrap[k].files["/etc/kube-lab/cluster.env"], "\nIS_INIT_NODE='false'\n") &&
      strcontains(module.cluster.bootstrap[k].files["/etc/kube-lab/cluster.env"], "\nNODE_ROLE='worker'\n")
    ])
    error_message = "Workers must be marked as joining workers in cluster.env."
  }

  assert {
    condition = (
      contains(keys(module.cluster.bootstrap["worker-1"].files), "/etc/kube-lab/kubeadm-join.yaml.tmpl") &&
      !contains(keys(module.cluster.bootstrap["worker-1"].files), "/etc/kube-lab/kubeadm-init.yaml.tmpl")
    )
    error_message = "Workers must receive the join config and no init config."
  }

  assert {
    condition     = !contains(keys(module.cluster.bootstrap["worker-1"].files), "/etc/kube-lab/kubelet-csr-approver.yaml")
    error_message = "Add-on manifests belong on cp-1 only."
  }

  assert {
    condition     = !strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/kubeadm-join.yaml.tmpl"], "controlPlane:")
    error_message = "Workers must not join as control planes."
  }
}

run "secrets_are_root_only" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for k, n in module.cluster.bootstrap : [
        for f in yamldecode(n.cloud_config).write_files :
        f.permissions == "0600" if startswith(f.path, "/etc/kube-lab/")
      ]
    ]))
    error_message = "Everything under /etc/kube-lab can hold cluster secrets once filled in, so it must be 0600."
  }

  assert {
    condition = {
      for f in yamldecode(module.cluster.bootstrap["cp-1"].cloud_config).write_files : f.path => f.permissions
      if !startswith(f.path, "/etc/kube-lab/")
      } == {
      "/usr/local/sbin/kube-lab-refresh-join"             = "0700"
      "/etc/systemd/system/kube-lab-refresh-join.service" = "0644"
      "/etc/systemd/system/kube-lab-refresh-join.timer"   = "0644"
    }
    error_message = "Only the refresh-join script (0700) and its systemd units (0644) live outside /etc/kube-lab."
  }
}

run "user_data_hygiene" {
  command = plan

  assert {
    condition     = alltrue([for n in module.cluster.bootstrap : !strcontains(jsonencode(n), "allow-unauthenticated")])
    error_message = "No unauthenticated apt installs."
  }

  assert {
    condition     = alltrue([for n in module.cluster.bootstrap : !strcontains(jsonencode(n), "kubelet-insecure-tls")])
    error_message = "Nothing may turn off kubelet certificate verification with --kubelet-insecure-tls."
  }

  assert {
    condition     = alltrue([for n in module.cluster.bootstrap : !strcontains(jsonencode(n), "etcdctl")])
    error_message = "etcdctl is a student exercise and must not be installed."
  }

  # cloud-init has no terminal: a read would hang the bootstrap. Comment lines are ignored.
  assert {
    condition = alltrue([
      for n in module.cluster.bootstrap :
      length(regexall("(?m)^[^#\n]*\\bread\\s", join("\n", [n.script, n.files["/etc/kube-lab/lib.sh"]]))) == 0
    ])
    error_message = "Bootstrap scripts must never read from stdin."
  }
}

run "no_metrics_server" {
  command = plan

  assert {
    condition     = alltrue([for n in module.cluster.bootstrap : !strcontains(lower(jsonencode(n)), "metrics-server") && !strcontains(jsonencode(n), "METRICS_SERVER")])
    error_message = "The bootstrap installs no metrics-server: install it yourself, with its manifest or Helm chart."
  }
}

run "helm_is_off_by_default" {
  command = plan

  assert {
    condition = alltrue([
      for n in module.cluster.bootstrap : strcontains(n.files["/etc/kube-lab/cluster.env"], "\nHELM_ENABLED='false'\n")
    ])
    error_message = "No node installs Helm unless helm_enabled is set."
  }
}

run "helm_on_control_planes_only" {
  command = plan

  variables {
    helm_enabled        = true
    control_plane_count = 3
  }

  assert {
    condition = alltrue([
      for k, n in module.cluster.bootstrap :
      strcontains(n.files["/etc/kube-lab/cluster.env"], "\nHELM_ENABLED='${startswith(k, "cp-")}'\n")
    ])
    error_message = "With helm_enabled, every control plane installs Helm (root has a kubeconfig there) and no worker does."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-2"].files["/etc/kube-lab/cluster.env"], "\nHELM_VERSION='v3.22.1'\nHELM_SHA256='896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea'\n")
    error_message = "cluster.env must carry the pinned Helm version and checksum."
  }
}

run "every_node_gets_the_aws_cli_pins" {
  command = plan

  variables {
    aws_cli_version = "2.99.1"
    aws_cli_sha256  = "0000000000000000000000000000000000000000000000000000000000000001"
  }

  assert {
    condition = alltrue([
      for n in module.cluster.bootstrap :
      strcontains(n.files["/etc/kube-lab/cluster.env"], "\nAWS_CLI_VERSION='2.99.1'\nAWS_CLI_SHA256='0000000000000000000000000000000000000000000000000000000000000001'\n")
    ])
    error_message = "Every node installs the AWS CLI before it can report a status, so cluster.env must carry its version and checksum."
  }
}

run "largest_bootstrap_fits_the_user_data_limit" {
  command = plan

  # Calico ships an extra manifest to cp-1; Helm adds its settings everywhere.
  variables {
    control_plane_count = 3
    helm_enabled        = true
  }

  # Planning succeeds only if the precondition on aws_instance.node holds for every node.
  assert {
    condition     = length(module.cluster.bootstrap) == 5
    error_message = "Expected cp-1..cp-3 and two workers."
  }
}

run "apt_waits_for_first_boot_upgrades" {
  command = plan

  # The most common first-boot failure: apt-daily holds the dpkg lock.
  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "systemctl stop apt-daily.timer apt-daily-upgrade.timer")
    error_message = "apt-daily timers must be stopped before the first apt call."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "dpkg --configure -a")
    error_message = "Retried installs must finish a half-configured dpkg first."
  }
}
