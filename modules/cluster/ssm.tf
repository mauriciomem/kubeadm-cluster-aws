# Terraform creates every parameter (so destroy removes them) with the placeholder
# value "pending". The nodes overwrite them with the real values. value_wo is never
# read back, so tokens and the admin kubeconfig never reach Terraform state.
#
# Two kinds of parameter:
# - Secrets (join material, admin kubeconfig): SecureString. Terraform never reads them.
# - Statuses: plain String, so Terraform can show them (modules/status) without
#   decrypting anything. allowed_pattern makes SSM reject a value outside the status
#   protocol from an honest node with a bug. It is not access control: a PutParameter
#   request can replace the pattern, so IAM (iam.tf) decides who writes, and every reader
#   checks the value again. The nodes check the same pattern before they write
#   (STATUS_PATTERN in bootstrap/files/lib.sh; a test keeps the copies equal).
# The status values are listed in docs/architecture.md and at the top of bootstrap/files/lib.sh.
locals {
  # failed:<step>, where <step> is a run_step or run_always name in the node scripts.
  status_pattern = "^(pending|bootstrapping|waiting|joining|joined|initializing|initialized|installing|ready|failed:[a-z0-9-]{1,40})$"

  parameters = merge(
    {
      "join/token"           = { tier = "Standard", secret = true }
      "join/ca-cert-hash"    = { tier = "Standard", secret = true }
      "join/certificate-key" = { tier = "Standard", secret = true }
      # admin.conf is about 5.5 KB and Standard parameters cap at 4 KB. cp-1 passes the
      # same tier when it writes the value, because PutParameter can't downgrade a tier.
      "kubeconfig/admin" = { tier = "Advanced", secret = true }
      "status/cluster"   = { tier = "Standard", secret = false }
    },
    { for k in keys(var.nodes) : "nodes/${k}/status" => { tier = "Standard", secret = false } },
  )
}

resource "aws_ssm_parameter" "cluster" {
  for_each = local.parameters

  name            = "${local.ssm_prefix}/${each.key}"
  description     = "kube-lab ${each.key}. Written by the nodes; \"pending\" until then."
  type            = each.value.secret ? "SecureString" : "String"
  tier            = each.value.tier
  allowed_pattern = each.value.secret ? null : local.status_pattern
  value_wo        = "pending"
  # Status parameters are at version 2 because they changed from SecureString to String.
  # On a cluster created before that change, the bump makes the next apply rewrite them
  # with "pending" (docs/operations.md shows how to restore the real values).
  value_wo_version = each.value.secret ? 1 : 2
  tags             = var.tags
}
