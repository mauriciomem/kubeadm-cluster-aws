# What each node boots with: which files reach which node, and the values rendered into them.
# The runs named static_guard_* are different: they check text in shell files that Terraform
# copies verbatim, so they guard against known regressions rather than test Terraform logic.
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
    error_message = "Kubelets must request serving certificates (for metrics-server without --kubelet-insecure-tls)."
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
    error_message = "metrics-server must not be patched with --kubelet-insecure-tls."
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

run "three_control_planes_fit_the_user_data_limit" {
  command = plan

  variables {
    control_plane_count = 3
  }

  # Planning succeeds only if the precondition on aws_instance.node holds for every node.
  assert {
    condition     = length(module.cluster.bootstrap) == 5
    error_message = "Expected cp-1..cp-3 and two workers."
  }
}

run "static_guard_join_secrets_stay_out_of_logs" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "--skip-token-print --skip-certificate-key-print")
    error_message = "kubeadm init must not print the join token or certificate key."
  }

  # retry logs only its first two arguments; later ones can be secrets.
  assert {
    condition = alltrue([
      for f in [module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], module.cluster.bootstrap["cp-1"].files["/usr/local/sbin/kube-lab-refresh-join"]] :
      length(regexall("log \"[^\"\n]*\\$[*@]", f)) == 0
    ])
    error_message = "No log call may print a full argument list (\"$*\" or \"$@\"); arguments can be secrets."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "chmod 0600 \"$LOG_FILE\"")
    error_message = "The bootstrap log must be root-only."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "readonly RUN_DIR=/run/kube-lab\n")
    error_message = "Rendered kubeadm configs must live on tmpfs (/run/kube-lab)."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/lib.sh"], "trap 'rm -f \"$RUN_DIR\"/kubeadm-*.yaml \"$RUN_DIR\"/admin-local.conf' EXIT")
    error_message = "Rendered kubeadm configs and the local admin kubeconfig must be removed on exit, including failures."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "export -n JOIN_TOKEN CERT_KEY")
    error_message = "Join secrets must leave kubeadm's environment once rendered."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/usr/local/sbin/kube-lab-refresh-join"], "token=$(kubeadm token create --ttl 24h)\n")
    error_message = "refresh-join must assign the token on its own line, so a failed token create stops the script."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "run_step publish publish_join_material")
    error_message = "Publishing join material is its own step, so a re-run doesn't re-init."
  }
}

run "static_guard_downloads_are_verified" {
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
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "sha256sum --check")
    error_message = "Downloads must be checked against their pinned sha256."
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

run "static_guard_apt_waits_for_first_boot_upgrades" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "systemctl stop apt-daily.timer apt-daily-upgrade.timer")
    error_message = "apt-daily timers must be stopped before the first apt call."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["worker-1"].files["/etc/kube-lab/lib.sh"], "dpkg --configure -a")
    error_message = "Retried installs must finish a half-configured dpkg first."
  }
}

run "static_guard_refresh_join_service_is_sandboxed" {
  command = plan

  assert {
    condition = alltrue([
      for d in ["ProtectSystem=full", "PrivateTmp=yes", "ProtectHome=tmpfs"] :
      strcontains(module.cluster.bootstrap["cp-1"].files["/etc/systemd/system/kube-lab-refresh-join.service"], "${d}\n")
    ])
    error_message = "kube-lab-refresh-join.service must keep its systemd sandboxing."
  }
}
