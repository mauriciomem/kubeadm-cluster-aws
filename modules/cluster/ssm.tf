# Terraform creates every parameter with the placeholder "pending", so destroy removes them,
# and the nodes overwrite them. value_wo is write-only: the join token and the admin
# kubeconfig never reach Terraform state.
#
# Statuses are plain Strings, so Terraform can show them (modules/status). allowed_pattern
# makes SSM refuse anything that isn't a status value, so a bug can't put a secret in one.
locals {
  # failed:<step> names the run_step that failed. docs/architecture.md lists the values.
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
  # Bumped for the statuses when they changed from SecureString to String.
  value_wo_version = each.value.secret ? 1 : 2
  tags             = var.tags
}
