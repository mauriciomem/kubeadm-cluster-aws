# Terraform creates every parameter (so destroy removes them) with a placeholder
# write-only value. Nodes overwrite the real values; value_wo is never read back,
# so tokens and the admin kubeconfig never reach Terraform state.
locals {
  parameters = merge(
    {
      "join/token"           = "Standard"
      "join/ca-cert-hash"    = "Standard"
      "join/certificate-key" = "Standard"
      "status/cluster"       = "Standard"
      # admin.conf is ~5.5 KB; Standard parameters cap at 4 KB.
      "kubeconfig/admin" = "Advanced"
    },
    { for k in keys(var.nodes) : "nodes/${k}/status" => "Standard" },
  )
}

resource "aws_ssm_parameter" "cluster" {
  for_each = local.parameters

  name             = "${local.ssm_prefix}/${each.key}"
  type             = "SecureString"
  tier             = each.value
  value_wo         = "pending"
  value_wo_version = 1
  tags             = var.tags
}
