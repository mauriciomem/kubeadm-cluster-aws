# Exercises modules/cluster directly so assertions can see its resources.
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  cluster_name                = "kube-lab-test"
  control_plane_instance_type = "t3.medium"
  worker_instance_type        = "t3.medium"
  operator_cidrs              = ["203.0.113.10/32", "198.51.100.0/24"]
  nat_public_ips              = ["198.51.100.10"]
  vpc_id                      = "vpc-0123456789abcdef0"
  private_subnet_ids          = ["subnet-a", "subnet-b", "subnet-c"]
  private_subnet_cidrs        = ["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"]
  public_subnet_ids           = ["subnet-pa", "subnet-pb", "subnet-pc"]
  root_volume_size            = 30
  # Also root variables: pinned so a terraform.tfvars in the working directory can't reach them.
  ami_id = null
  tags   = {}

  nodes = {
    cp-1     = { role = "control-plane", index = 0, init = true }
    cp-2     = { role = "control-plane", index = 1, init = false }
    cp-3     = { role = "control-plane", index = 2, init = false }
    worker-1 = { role = "worker", index = 0, init = false }
    worker-4 = { role = "worker", index = 3, init = false }
  }

  software = {
    k8s_version        = "1.36.5"
    containerd_version = "2.3.*"
    cni                = "calico"
    pod_cidr           = "192.168.0.0/16"
    service_cidr       = "10.96.0.0/12"
    calico             = { version = "v3.33.0", crds_sha256 = "0", operator_sha256 = "0" }
    cilium             = { version = "1.20.3", cli_version = "v0.20.1", cli_sha256 = "0" }
    helm               = { enabled = false, version = "v3.22.1", sha256 = "0" }
    csr_approver       = { version = "v1.2.15", digest = "sha256:0" }
  }
}

run "placement_and_load_balancer" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition     = [for k in ["cp-1", "cp-2", "cp-3"] : aws_instance.node[k].subnet_id] == ["subnet-a", "subnet-b", "subnet-c"]
    error_message = "Control planes must be spread across the three private subnets."
  }

  assert {
    condition     = aws_instance.node["worker-4"].subnet_id == "subnet-a"
    error_message = "worker-4 should round-robin back to the first subnet."
  }

  assert {
    condition     = keys(aws_lb_target_group_attachment.control_plane) == ["cp-1", "cp-2", "cp-3"]
    error_message = "Every control plane, and only control planes, must be an NLB target."
  }

  assert {
    condition     = aws_lb_target_group.api.preserve_client_ip == "false"
    error_message = "Client IP preservation must be off, or control planes hairpin through the NLB and time out."
  }

  assert {
    condition     = aws_lb.api.enable_cross_zone_load_balancing && !aws_lb.api.internal
    error_message = "The API NLB must be internet-facing with cross-zone load balancing."
  }

  assert {
    condition     = aws_iam_instance_profile.node["worker"].name == "kube-lab-test-worker"
    error_message = "Workers get their own, narrower instance profile."
  }

  assert {
    condition     = aws_instance.node["worker-1"].iam_instance_profile == "kube-lab-test-worker" && aws_instance.node["cp-2"].iam_instance_profile == "kube-lab-test-control-plane"
    error_message = "Each node must use its role's instance profile."
  }
}

run "nodes_are_hardened" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition = alltrue([
      for i in aws_instance.node :
      i.metadata_options[0].http_tokens == "required" && i.metadata_options[0].http_put_response_hop_limit == 1
    ])
    error_message = "Every node must require IMDSv2 with hop limit 1."
  }

  assert {
    condition = alltrue([
      for i in aws_instance.node :
      i.root_block_device[0].encrypted && i.root_block_device[0].volume_type == "gp3"
    ])
    error_message = "Every root volume must be encrypted gp3."
  }

  assert {
    condition     = alltrue([for i in aws_instance.node : i.associate_public_ip_address == false])
    error_message = "Nodes must not get public IPs."
  }

  assert {
    condition     = alltrue([for i in aws_instance.node : i.ami == "ami-0123456789abcdef0"])
    error_message = "Nodes should use the Canonical AMI from SSM when ami_id is unset."
  }
}

run "root_volumes_are_tagged" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  variables {
    tags = { Cluster = "kube-lab-test" }
  }

  assert {
    condition     = aws_instance.node["worker-1"].root_block_device[0].tags == tomap({ Cluster = "kube-lab-test", Name = "kube-lab-test-worker-1-root" })
    error_message = "Root volumes must carry the Cluster tag and a Name: instance tags don't reach volumes."
  }
}

run "security_groups" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.nlb_operator) == 2
    error_message = "One NLB ingress rule per operator CIDR."
  }

  assert {
    condition     = [for r in aws_vpc_security_group_ingress_rule.nlb_nat : r.cidr_ipv4] == ["198.51.100.10/32"]
    error_message = "Nodes reach the public NLB from the NAT IP, so it must be allowed."
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_vpc_security_group_ingress_rule.nlb_operator), aws_vpc_security_group_ingress_rule.nlb_nat) :
      r.from_port == 6443 && r.to_port == 6443 && r.ip_protocol == "tcp"
    ])
    error_message = "The NLB only accepts TCP 6443 from operators and NAT."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.node_api_from_nlb.from_port == 6443
    error_message = "Nodes accept the API port from the NLB security group."
  }
}

run "ssm_parameters" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition = alltrue([
      for k in ["join/token", "join/ca-cert-hash", "join/certificate-key", "kubeconfig/admin"] :
      aws_ssm_parameter.cluster[k].type == "SecureString" && aws_ssm_parameter.cluster[k].allowed_pattern == null && aws_ssm_parameter.cluster[k].value_wo_version == 1
    ])
    error_message = "Join material and the admin kubeconfig must stay SecureStrings created through value_wo."
  }

  assert {
    condition = alltrue([
      for k, p in aws_ssm_parameter.cluster :
      p.type == "String" && p.allowed_pattern == local.status_pattern && p.value_wo_version == 2
      if k == "status/cluster" || startswith(k, "nodes/")
    ])
    error_message = "Status parameters must be Strings limited to the status values (allowed_pattern), at value_wo_version 2."
  }

  assert {
    condition     = length([for p in aws_ssm_parameter.cluster : p if p.type == "String"]) == 1 + length(var.nodes)
    error_message = "Only the status parameters may be plain Strings: one per node plus the cluster's."
  }

  assert {
    condition     = output.status_parameters == merge({ cluster = "/kube-lab-test/status/cluster" }, { for k in keys(var.nodes) : k => "/kube-lab-test/nodes/${k}/status" })
    error_message = "status_parameters must name exactly the status parameters, which Terraform reads; never a secret."
  }

  assert {
    condition     = aws_ssm_parameter.cluster["kubeconfig/admin"].tier == "Advanced"
    error_message = "admin.conf exceeds 4 KB and needs an Advanced parameter."
  }

  assert {
    condition     = toset([for k in keys(aws_ssm_parameter.cluster) : k if startswith(k, "nodes/")]) == toset([for k in keys(var.nodes) : "nodes/${k}/status"])
    error_message = "Each node needs exactly one status parameter."
  }

  assert {
    condition     = aws_ssm_parameter.cluster["join/token"].name == "/kube-lab-test/join/token"
    error_message = "Parameters must live under /<cluster>/."
  }
}

run "status_pattern_accepts_only_status_values" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  # Every value the node scripts write, including failed:<step> for every step name.
  assert {
    condition = alltrue([
      for v in concat(
        ["pending", "bootstrapping", "waiting", "joining", "joined", "initializing", "initialized", "installing", "ready"],
        [for s in ["start", "awscli", "host", "packages", "containerd", "shell", "init", "publish", "local-kubeconfig", "cni", "csr-approver", "refresh-timer", "wait-nodes", "join", "root-kubeconfig", "complete"] : "failed:${s}"],
      ) : can(regex(local.status_pattern, v))
    ])
    error_message = "status_pattern must accept every status the node scripts write."
  }

  assert {
    condition = !anytrue([
      for v in ["", "Ready", "failed:", "failed:$(cat /etc/kubernetes/admin.conf)", "failed:a b", "ready\nabcdef.0123456789abcdef", "joined ", "failed:${join("", [for i in range(41) : "a"])}", "sha256:0123"] :
      can(regex(local.status_pattern, v))
    ])
    error_message = "status_pattern must reject anything outside the status protocol, so a status can never carry a secret."
  }

  # lib.sh checks values before it writes them; both sides must agree.
  assert {
    condition     = strcontains(module.bootstrap.nodes["worker-1"].files["/etc/kube-lab/lib.sh"], "readonly STATUS_PATTERN='${local.status_pattern}'\n")
    error_message = "STATUS_PATTERN in lib.sh must equal status_pattern in modules/cluster/ssm.tf."
  }
}

run "kubelet_csr_approver_trusts_only_node_subnets" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition     = strcontains(module.bootstrap.nodes["cp-1"].files["/etc/kube-lab/kubelet-csr-approver.yaml"], "value: \"10.10.0.0/20,10.10.16.0/20,10.10.32.0/20\"")
    error_message = "PROVIDER_IP_PREFIXES must list exactly the private subnet CIDRs."
  }
}

run "session_manager_only" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition     = keys(aws_iam_role_policy.session_manager) == ["control-plane", "worker"]
    error_message = "Both roles get the inline Session Manager policy."
  }

  assert {
    condition = alltrue(flatten([
      for doc in [data.aws_iam_policy_document.session_manager, data.aws_iam_policy_document.control_plane, data.aws_iam_policy_document.worker] : [
        for s in doc.statement : !(
          s.effect != "Deny" && contains(s.resources, "*") &&
          anytrue([for a in s.actions : startswith(a, "ssm:GetParameter") || a == "ssm:*" || a == "*"])
        )
      ]
    ]))
    error_message = "No role may allow ssm:GetParameter* on \"*\" (the reason AmazonSSMManagedInstanceCore was dropped)."
  }

  assert {
    condition = toset(flatten([for s in data.aws_iam_policy_document.session_manager.statement : tolist(s.actions)])) == toset([
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ])
    error_message = "The Session Manager policy must be exactly AWS's minimal Session Manager policy. ec2messages would let the agent receive Run Command documents."
  }
}

run "node_roles_can_do_their_job" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.worker.statement :
      s.effect != "Deny" && contains(s.actions, "ssm:GetParameter") &&
      contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/join/token") &&
      contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/join/ca-cert-hash")
    ])
    error_message = "Workers must be able to read the join token and CA cert hash."
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.worker.statement :
      s.effect != "Deny" && contains(s.actions, "ssm:PutParameter") &&
      contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/nodes/worker-*")
    ])
    error_message = "Workers must be able to publish their own status."
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.worker.statement : [
        for r in s.resources : !strcontains(r, "kubeconfig") && !strcontains(r, "certificate-key") if s.effect != "Deny"
      ]
    ]))
    error_message = "No worker Allow may cover the kubeconfig or certificate key."
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.control_plane.statement :
      s.effect != "Deny" && contains(s.actions, "ssm:GetParameter") && contains(s.actions, "ssm:PutParameter") &&
      contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/*")
    ])
    error_message = "Control planes must be able to read and write the whole cluster path."
  }
}

run "worker_cannot_read_control_plane_secrets" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.worker.statement :
      s.effect == "Deny" && contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/kubeconfig/*")
    ])
    error_message = "The worker role must explicitly deny the admin kubeconfig."
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.worker.statement :
      s.effect == "Deny" && contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/join/certificate-key")
    ])
    error_message = "The worker role must explicitly deny the certificate key."
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.worker.statement :
      s.effect == "Deny" && length(setintersection(s.resources, [
        "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test",
        "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/join",
        "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/kubeconfig",
      ])) == 3
    ])
    error_message = "The Deny must cover the path ARNs GetParametersByPath authorizes against."
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.worker.statement : [
        !contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/join/token"),
        !contains(s.resources, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/join/ca-cert-hash"),
      ] if s.effect == "Deny"
    ]))
    error_message = "The Deny must not block the join material workers need."
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.control_plane.statement : [
        for r in s.resources : startswith(r, "arn:aws:ssm:us-east-1:123456789012:parameter/kube-lab-test/")
      ]
    ]))
    error_message = "Control-plane permissions must be scoped to the cluster's parameter path."
  }
}

run "each_role_boots_its_own_script" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  assert {
    condition = alltrue([
      for k, n in var.nodes : data.cloudinit_config.node[k].part[1].filename == "${n.role}.sh"
    ])
    error_message = "Each node must run the bootstrap script for its role."
  }

  assert {
    condition     = strcontains(module.bootstrap.nodes["cp-2"].files["/etc/kube-lab/cluster.env"], "\nNODE_ROLE='control-plane'\nIS_INIT_NODE='false'\n")
    error_message = "cp-2 must join as a control plane, not run kubeadm init."
  }
}

run "arm64_instance_types_rejected" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  variables {
    worker_instance_type = "t4g.medium"
  }

  override_data {
    target = data.aws_ec2_instance_type.node["t4g.medium"]
    values = { supported_architectures = ["arm64"] }
  }

  expect_failures = [aws_instance.node]
}

run "unknown_node_role_rejected" {
  command = plan

  module {
    source = "./modules/cluster"
  }

  variables {
    nodes = {
      cp-1     = { role = "control-plane", index = 0, init = true }
      master-1 = { role = "master", index = 0, init = false }
    }
  }

  expect_failures = [var.nodes]
}
