# Shows bootstrap progress in Terraform: a status map for the root's cluster_status output,
# and a warning on every plan and apply until the cluster is ready. Live progress:
# scripts/wait-for-cluster.sh.
#
# One data source per status parameter, by explicit name. Never read a whole path (for
# example with aws_ssm_parameters_by_path): /<cluster>/ also holds the join token and the
# admin kubeconfig, and they would end up in the state. Status parameters are plain
# Strings, and with_decryption = false means that even a SecureString would only reach the
# state encrypted.
data "aws_ssm_parameter" "status" {
  for_each = var.parameters

  name            = each.value
  with_decryption = false
}

locals {
  # insecure_value is null for a SecureString, for example a status a node rewrote with an
  # older bootstrap script.
  status = { for k, d in data.aws_ssm_parameter.status : k => coalesce(d.insecure_value, "unreadable") }

  failed_steps = { for k, v in local.status : k => trimprefix(v, "failed:") if startswith(v, "failed:") }

  summary = join(" ", concat(
    ["cluster=${local.status["cluster"]}"],
    [for k, v in local.status : "${k}=${v}" if k != "cluster"],
  ))

  message = (
    length(local.failed_steps) > 0
    ? "Bootstrap failed: ${join(", ", [for k, step in local.failed_steps : "${k} at step ${step}"])}. Open a shell on that node (terraform output ssm_session_commands) and read /var/log/kube-lab-bootstrap.log as root; docs/troubleshooting.md explains each step. Statuses: ${local.summary}"
    : "Cluster ${var.cluster_name} is not ready yet: ${local.summary}. The nodes usually finish about 5 minutes after the first apply. Follow them with: ./scripts/wait-for-cluster.sh ${var.cluster_name} ${var.region}"
  )
}

# A check only warns: it never blocks plan, apply or destroy.
check "cluster_ready" {
  assert {
    condition     = local.status["cluster"] == "ready"
    error_message = local.message
  }
}
