data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Session Manager shell access only, in place of AmazonSSMManagedInstanceCore (which also
# allows ssm:GetParameter on "*"). Run Command and State Manager are intentionally not enabled.
# ec2messages is the SSM Agent's message channel; ssmmessages carries the sessions.
# These actions don't support resource-level scoping, hence "*".
data "aws_iam_policy_document" "session_manager" {
  statement {
    sid = "SessionManager"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }
}

# Control planes publish join material and the admin kubeconfig, so they own the whole cluster path.
data "aws_iam_policy_document" "control_plane" {
  statement {
    sid       = "ClusterParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter"]
    resources = ["${local.ssm_prefix_arn}/*"]
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

  statement {
    sid       = "WriteOwnStatus"
    actions   = ["ssm:PutParameter"]
    resources = ["${local.ssm_prefix_arn}/nodes/worker-*"]
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

locals {
  roles = {
    control-plane = data.aws_iam_policy_document.control_plane.json
    worker        = data.aws_iam_policy_document.worker.json
  }
}

resource "aws_iam_role" "node" {
  for_each = local.roles

  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "node" {
  for_each = local.roles

  name   = "cluster-parameters"
  role   = aws_iam_role.node[each.key].id
  policy = each.value
}

resource "aws_iam_role_policy" "session_manager" {
  for_each = local.roles

  name   = "session-manager"
  role   = aws_iam_role.node[each.key].id
  policy = data.aws_iam_policy_document.session_manager.json
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.roles

  name = "${var.cluster_name}-${each.key}"
  role = aws_iam_role.node[each.key].name
  tags = var.tags
}
