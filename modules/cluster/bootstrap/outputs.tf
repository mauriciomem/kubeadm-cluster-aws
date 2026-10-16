output "nodes" {
  description = "Per node: cloud_config (hostname and files under /etc/kube-lab), script (role bootstrap script) and files (path => content, for inspection)."
  value = {
    for k in keys(var.nodes) : k => {
      cloud_config = local.cloud_config[k]
      script       = local.script[k]
      files        = local.files[k]
    }
  }
}
