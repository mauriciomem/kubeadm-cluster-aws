output "nodes" {
  description = "Per node: cloud_config (hostname and files under /etc/kube-lab), script (role bootstrap script) and files (path => content, for inspection)."
  value = {
    for k in keys(var.nodes) : k => {
      cloud_config = local.cloud_config[k]
      script       = local.script[k]
      files        = local.files[k]
    }
  }

  # The guards live here because a module without resources has nowhere else to put a
  # precondition, and this output is always evaluated.
  precondition {
    condition     = alltrue([for k in keys(var.nodes) : can(regex(local.node_name_regex, k))])
    error_message = "Every node name must match ${local.node_name_regex}, or kubelet-csr-approver won't approve its serving certificate. Keep the names in the root locals.tf in sync with node_name_regex in modules/cluster/bootstrap/main.tf."
  }

  precondition {
    condition     = alltrue(flatten([for vars in values(local.env_vars) : [for v in values(vars) : !strcontains(v, "'")]]))
    error_message = "A cluster.env value contains a single quote. cluster.env is sourced as shell, so values must not contain one."
  }
}
