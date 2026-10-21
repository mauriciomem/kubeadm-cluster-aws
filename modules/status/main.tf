# Shows bootstrap progress in Terraform: a status map for the root's cluster_status output,
# and a warning on every plan and apply until the cluster is ready. Live progress:
# scripts/wait-for-cluster.sh.
#
# One data source per status parameter, by explicit name. Never read a whole path (for
# example with aws_ssm_parameters_by_path): /<cluster>/ also holds the join token and the
# admin kubeconfig, and they would end up in the state. Status parameters are plain
# Strings, and with_decryption = false means that even a SecureString would only reach the
# state encrypted.
#
# The reads sit outside the check block on purpose. A data source nested in a check turns
# its errors into warnings, but only that check can use it, so the cluster_status output
# would be lost: https://developer.hashicorp.com/terraform/language/block/check
# The cost: a plan fails if the caller can't run ssm:GetParameter on the status parameters.
# A missing parameter doesn't fail it: the root reads only after module.cluster has no
# changes left, so a parameter Terraform must create again is read after the apply.
data "aws_ssm_parameter" "status" {
  for_each = var.parameters

  name            = each.value
  with_decryption = false
}

locals {
  # Never trust a value on read: any text that isn't a status value becomes "invalid", so
  # it can't reach the outputs, the check message or the state through them. A node with a
  # bug can't write such a value (allowed_pattern), but root on a worker can.
  # insecure_value is null for a SecureString, for example a status a node rewrote with an
  # older bootstrap script.
  status = {
    for k, d in data.aws_ssm_parameter.status : k => (
      d.insecure_value == null ? "unreadable" : (can(regex(var.status_pattern, d.insecure_value)) ? d.insecure_value : "invalid")
    )
  }

  failed_steps = { for k, v in local.status : k => trimprefix(v, "failed:") if startswith(v, "failed:") }

  summary = join(" ", concat(
    ["cluster=${local.status["cluster"]}"],
    [for k, v in local.status : "${k}=${v}" if k != "cluster"],
  ))

  message = (
    length(local.failed_steps) > 0
    ? "Bootstrap failed: ${join(", ", [for k, step in local.failed_steps : "${k} at step ${step}"])}. Open a shell on that node (terraform output ssm_session_commands) and read /var/log/kube-lab-bootstrap.log as root; docs/troubleshooting.md explains each step. Statuses: ${local.summary}"
    : "Cluster ${var.cluster_name} is not ready yet: ${local.summary}. The nodes usually finish about 5 minutes after they're created. Follow them with: ./scripts/wait-for-cluster.sh ${var.cluster_name} ${var.region}"
  )
}

# A check only warns: it never blocks plan, apply or destroy.
check "cluster_ready" {
  assert {
    condition     = local.status["cluster"] == "ready"
    error_message = local.message
  }
}
