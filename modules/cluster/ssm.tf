# Terraform creates every parameter (so destroy removes them) with the placeholder
# value "pending". The nodes overwrite them with the real values. value_wo is never
# read back, so tokens and the admin kubeconfig never reach Terraform state.
# The status values the nodes write are listed in docs/architecture.md.
locals {
  parameters = merge(
    {
      "join/token"           = "Standard"
      "join/ca-cert-hash"    = "Standard"
      "join/certificate-key" = "Standard"
      "status/cluster"       = "Standard"
      # admin.conf is about 5.5 KB and Standard parameters cap at 4 KB. cp-1 passes the
      # same tier when it writes the value, because PutParameter can't downgrade a tier.
      "kubeconfig/admin" = "Advanced"
    },
    { for k in keys(var.nodes) : "nodes/${k}/status" => "Standard" },
  )
}

resource "aws_ssm_parameter" "cluster" {
  for_each = local.parameters

  name             = "${local.ssm_prefix}/${each.key}"
  description      = "kube-lab ${each.key}. Written by the nodes; \"pending\" until then."
  type             = "SecureString"
  tier             = each.value
  value_wo         = "pending"
  value_wo_version = 1
  tags             = var.tags
}
