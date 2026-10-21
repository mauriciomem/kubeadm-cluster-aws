data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  ssm_prefix_arn = "arn:${data.aws_partition.current.partition}:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}"

  # PutParameter only on the exact names Terraform creates (ssm.tf), never a wildcard: in an
  # ARN, * also matches /, so a wildcard would let a node create any number of parameters
  # that outlive terraform destroy. Built from the var.nodes keys, never from instance
  # attributes, so the policy exists before the nodes boot and there is no dependency cycle.
  # Scaling out adds the new node's ARN in the same apply.
  status_arns = { for k in keys(var.nodes) : k => "${local.ssm_prefix_arn}/nodes/${k}/status" }

  control_plane_writable_arns = concat(
    [for name in ["join/token", "join/ca-cert-hash", "join/certificate-key", "kubeconfig/admin", "status/cluster"] : "${local.ssm_prefix_arn}/${name}"],
    [for k, n in var.nodes : local.status_arns[k] if n.role == "control-plane"],
  )
  worker_writable_arns = [for k, n in var.nodes : local.status_arns[k] if n.role == "worker"]
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Replaces AmazonSSMManagedInstanceCore, which also allows ssm:GetParameter on "*".
# This is AWS's minimal Session Manager instance policy: the agent registers with
# ssm:UpdateInstanceInformation and shell sessions flow over ssmmessages.
# https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-create-iam-instance-profile.html
# There are no ec2messages actions, so the agent can't receive Run Command documents.
# None of these actions supports resource-level scoping, hence "*".
data "aws_iam_policy_document" "session_manager" {
  statement {
    sid = "SessionManager"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

# Control planes read the whole cluster path (join material, the other control planes'
# statuses) and write the join material, the admin kubeconfig, the cluster status and the
# control-plane statuses.
data "aws_iam_policy_document" "control_plane" {
  statement {
    sid       = "ReadClusterParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.ssm_prefix_arn}/*"]
  }

  statement {
    sid       = "WriteClusterParameters"
    actions   = ["ssm:PutParameter"]
    resources = local.control_plane_writable_arns
  }

  # A parameter policy (Expiration) would make SSM delete a parameter later, and the nodes
  # never set one. ssm:Policies is "true" when the request carries a policy:
  # https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-policy-conditions.html
  statement {
    sid       = "DenyParameterPolicies"
    effect    = "Deny"
    actions   = ["ssm:PutParameter"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:Policies"
      values   = ["true"]
    }
  }
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid     = "ReadJoinMaterial"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "${local.ssm_prefix_arn}/join/token",
      "${local.ssm_prefix_arn}/join/ca-cert-hash",
    ]
  }

  # IAM is the access control for statuses; allowed_pattern (ssm.tf) only catches bugs in
  # honest nodes, because a PutParameter request can replace the pattern. Every worker
  # shares one role, so root on a worker can still write any worker's status, with any
  # text. That only changes what you see: no node waits on a worker's status, and the
  # readers (modules/status, wait-for-cluster.sh) show anything that isn't a status value
  # as "invalid". Per-node scoping would need a role per node.
  # No statement when there are no workers: an empty resource list is an invalid policy.
  dynamic "statement" {
    for_each = length(local.worker_writable_arns) > 0 ? [1] : []

    content {
      sid       = "WriteWorkerStatus"
      actions   = ["ssm:PutParameter"]
      resources = local.worker_writable_arns
    }
  }

  statement {
    sid       = "DenyParameterPolicies"
    effect    = "Deny"
    actions   = ["ssm:PutParameter"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:Policies"
      values   = ["true"]
    }
  }

  # Defense in depth: nothing above grants these, but aws/ssm lets the whole account decrypt,
  # so an explicit Deny keeps cluster-admin material off workers even if another policy is
  # attached later. Path ARNs cover GetParametersByPath.
  statement {
    sid     = "DenyControlPlaneSecrets"
    effect  = "Deny"
    actions = ["ssm:GetParameter*"]
    resources = [
      local.ssm_prefix_arn,
      "${local.ssm_prefix_arn}/join",
      "${local.ssm_prefix_arn}/kubeconfig",
      "${local.ssm_prefix_arn}/kubeconfig/*",
      "${local.ssm_prefix_arn}/join/certificate-key",
    ]
  }
}

# One role per node role. The keys match var.nodes[*].role.
locals {
  role_policies = {
    control-plane = data.aws_iam_policy_document.control_plane.json
    worker        = data.aws_iam_policy_document.worker.json
  }
}

resource "aws_iam_role" "node" {
  for_each = local.role_policies

  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = var.tags
}

# Each role's access to the cluster's SSM parameters.
resource "aws_iam_role_policy" "cluster_parameters" {
  for_each = local.role_policies

  name   = "cluster-parameters"
  role   = aws_iam_role.node[each.key].id
  policy = each.value
}

resource "aws_iam_role_policy" "session_manager" {
  for_each = local.role_policies

  name   = "session-manager"
  role   = aws_iam_role.node[each.key].id
  policy = data.aws_iam_policy_document.session_manager.json
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.role_policies

  name = "${var.cluster_name}-${each.key}"
  role = aws_iam_role.node[each.key].name
  tags = var.tags
}
