data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  ssm_prefix_arn = "arn:${data.aws_partition.current.partition}:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}"
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

# AWS's minimal Session Manager policy, instead of AmazonSSMManagedInstanceCore, which also
# allows ssm:GetParameter on "*" (the admin kubeconfig included). No ec2messages, so no Run Command.
# https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-create-iam-instance-profile.html
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

# Control planes read and write everything under the cluster path: they publish the join
# material, the admin kubeconfig and the statuses.
data "aws_iam_policy_document" "control_plane" {
  statement {
    sid       = "ClusterParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter"]
    resources = ["${local.ssm_prefix_arn}/*"]
  }
}

# Workers read only what kubeadm join needs (never the admin kubeconfig or the certificate
# key) and write node statuses. All workers share this role, so a worker can overwrite
# another worker's status: a good CKS exercise in what a compromised node can do.
data "aws_iam_policy_document" "worker" {
  statement {
    sid     = "ReadJoinMaterial"
    actions = ["ssm:GetParameter"]
    resources = [
      "${local.ssm_prefix_arn}/join/token",
      "${local.ssm_prefix_arn}/join/ca-cert-hash",
    ]
  }

  statement {
    sid       = "WriteNodeStatus"
    actions   = ["ssm:PutParameter"]
    resources = ["${local.ssm_prefix_arn}/nodes/worker-*"]
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
