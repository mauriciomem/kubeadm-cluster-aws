# Shows bootstrap progress in Terraform: the cluster_status output, and a warning on every
# plan and apply until the cluster is ready. For live progress: scripts/wait-for-cluster.sh.
#
# Each status parameter is read by name. Reading the whole /<cluster>/ path would put the join
# token and the admin kubeconfig in the state.
data "aws_ssm_parameter" "status" {
  for_each = var.parameters

  name            = each.value
  with_decryption = false
}

locals {
  status = { for k, d in data.aws_ssm_parameter.status : k => d.insecure_value }

  failed = [for k, v in local.status : "${k} at step ${trimprefix(v, "failed:")}" if startswith(v, "failed:")]

  summary = join(" ", [for k, v in local.status : "${k}=${v}"])

  message = (
    length(local.failed) > 0
    ? "Bootstrap failed: ${join(", ", local.failed)}. Read /var/log/kube-lab-bootstrap.log on that node (terraform output ssm_session_commands); docs/troubleshooting.md explains each step."
    : "Cluster ${var.cluster_name} is not ready yet: ${local.summary}. Follow it with: ./scripts/wait-for-cluster.sh ${var.cluster_name} ${var.region}"
  )
}

# A check only warns: it never blocks plan, apply or destroy. The reads sit outside it so the
# cluster_status output can use them too.
check "cluster_ready" {
  assert {
    condition     = local.status["cluster"] == "ready"
    error_message = local.message
  }
}
