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

variables {
  operator_cidrs = ["203.0.113.10/32"]
}

run "control_plane_user_data" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "kubernetesVersion: v1.36.5")
    error_message = "kubeadm init config must pin v1.36.5."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "controlPlaneEndpoint: \"kube-lab-test-api-0123456789abcdef.elb.us-east-1.amazonaws.com:6443\"")
    error_message = "controlPlaneEndpoint must be the NLB DNS name."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "serverTLSBootstrap: true")
    error_message = "Kubelets must request serving certificates (for metrics-server without --kubelet-insecure-tls)."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "K8S_MINOR=1.36")
    error_message = "The pkgs.k8s.io repo must track the v1.36 minor."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "core:/stable:/v$K8S_MINOR/deb/")
    error_message = "lib.sh must configure the per-minor pkgs.k8s.io repository."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "kubeadm init --config")
    error_message = "cp-1 must run kubeadm init."
  }

  assert {
    condition     = contains(keys(module.cluster.bootstrap["cp-1"].files), "/etc/kube-lab/kubelet-csr-approver.yaml")
    error_message = "cp-1 must ship the kubelet-csr-approver manifest."
  }
}

run "join_secrets_stay_out_of_logs" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "kubeadm init --config \"$config\" --upload-certs --skip-token-print --skip-certificate-key-print")
    error_message = "kubeadm init must not print the join token or certificate key."
  }

  assert {
    condition = alltrue([
      for f in [module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], module.cluster.bootstrap["cp-1"].files["/usr/local/sbin/kube-lab-refresh-join"]] :
      !strcontains(f, ": $*\"")
    ])
    error_message = "retry must not log its full argv (arguments can be secrets)."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "install -m 0600 /dev/null \"$LOG_FILE\"") && strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "chmod 0600 \"$LOG_FILE\"")
    error_message = "The bootstrap log must be root-only."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "RUN_DIR=/run/kube-lab") && strcontains(module.cluster.bootstrap["cp-1"].script, "local config=$RUN_DIR/kubeadm-init.yaml") && strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "local config=$RUN_DIR/kubeadm-join.yaml")
    error_message = "Rendered kubeadm configs must live on tmpfs (/run/kube-lab)."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "trap 'rm -f \"$RUN_DIR\"/kubeadm-*.yaml' EXIT")
    error_message = "Rendered kubeadm configs must be removed on exit, including failures."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "export -n JOIN_TOKEN CERT_KEY")
    error_message = "Join secrets must leave kubeadm's environment once rendered."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/usr/local/sbin/kube-lab-refresh-join"], "token=$(kubeadm token create --ttl 24h)\nretry 5 ssm_put join/token \"$token\"")
    error_message = "A failed token create must stop refresh-join, not publish an empty token."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "run_step publish publish_join_material")
    error_message = "Publishing join material is its own step, so a re-run doesn't re-init."
  }
}

run "node_scripts_verify_what_they_download" {
  command = plan

  # Every curl except the two IMDS calls must refuse plain HTTP and old TLS.
  assert {
    condition = alltrue(flatten([
      for n in module.cluster.bootstrap : [
        for line in regexall("curl -[^\n]*", join("\n", concat([n.script], values(n.files)))) :
        strcontains(line, "--proto '=https' --tlsv1.2") || strcontains(line, "169.254.169.254")
      ]
    ]))
    error_message = "Every curl in the node scripts must use --proto '=https' --tlsv1.2."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "END { if (p == 1) print f }")
    error_message = "An apt key file must hold exactly one primary key with the pinned fingerprint."
  }

  assert {
    condition     = !strcontains(module.cluster.bootstrap["cp-1"].script, "/tmp/cilium")
    error_message = "The cilium tarball must use mktemp, not a fixed /tmp path."
  }
}

run "apt_waits_for_first_boot_upgrades" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "systemctl stop apt-daily.timer apt-daily-upgrade.timer || true")
    error_message = "apt-daily timers must be stopped before the first apt call."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "wait_for 900 \"apt-daily to finish\" apt_idle")
    error_message = "Bootstrap must wait (bounded) for an apt-daily run in progress."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "dpkg --configure -a")
    error_message = "Retried installs must finish a half-configured dpkg first."
  }
}

run "refresh_join_service_is_sandboxed" {
  command = plan

  assert {
    condition = alltrue([
      for d in ["ProtectSystem=full", "PrivateTmp=yes", "ProtectHome=tmpfs"] :
      strcontains(module.cluster.bootstrap["cp-1"].files["/etc/systemd/system/kube-lab-refresh-join.service"], "${d}\n")
    ])
    error_message = "kube-lab-refresh-join.service must keep its systemd sandboxing."
  }
}

run "metrics_server_uses_stock_manifest" {
  command = plan

  assert {
    condition = alltrue([
      for n in module.cluster.bootstrap :
      !strcontains(jsonencode(n), "kubelet-insecure-tls")
    ])
    error_message = "metrics-server must not be patched with --kubelet-insecure-tls."
  }
}

run "worker_user_data" {
  command = plan

  assert {
    condition     = !strcontains(module.cluster.bootstrap["worker-1"].script, "kubeadm init")
    error_message = "Workers must never run kubeadm init."
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

run "user_data_hygiene" {
  command = plan

  assert {
    condition = alltrue([
      for n in module.cluster.bootstrap :
      !strcontains(jsonencode(n), "allow-unauthenticated") && !strcontains(n.script, "read -")
    ])
    error_message = "No unauthenticated apt installs and no interactive reads in bootstrap."
  }

  assert {
    condition     = alltrue([for n in module.cluster.bootstrap : !strcontains(jsonencode(n), "etcdctl")])
    error_message = "etcdctl is a student exercise and must not be installed."
  }
}

run "user_data_fits_ec2_limit" {
  command = plan

  variables {
    control_plane_count = 3
  }

  # The gzipped user data must stay under 16 KB before base64 (precondition on aws_instance).
  assert {
    condition     = alltrue([for k, l in module.cluster.user_data_base64_length : l <= 21848])
    error_message = "user_data too large: ${jsonencode(module.cluster.user_data_base64_length)}."
  }

  # Raw size budget: cp-1 should stay compressible well below the limit.
  assert {
    condition     = length(module.cluster.bootstrap["cp-1"].cloud_config) + length(module.cluster.bootstrap["cp-1"].script) < 40000
    error_message = "cp-1 bootstrap content has grown unexpectedly; do not inline upstream manifests."
  }
}
