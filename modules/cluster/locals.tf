data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  region         = data.aws_region.current.region
  ssm_prefix     = "/${var.cluster_name}"
  ssm_prefix_arn = "arn:${data.aws_partition.current.partition}:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}"

  control_planes = { for k, n in var.nodes : k => n if n.role == "control-plane" }

  api_host     = aws_lb.api.dns_name
  api_endpoint = "${local.api_host}:6443"
}
