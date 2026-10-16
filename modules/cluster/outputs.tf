output "api_endpoint" {
  description = "Kubernetes API URL (internet-facing NLB)."
  value       = "https://${local.api_endpoint}"
}

output "bootstrap" {
  description = "Rendered bootstrap content per node (no secrets; placeholders are filled on the node). For tests and inspection."
  value       = module.bootstrap.nodes
}

output "instances" {
  description = "Node details keyed by node name."
  value = {
    for k, i in aws_instance.node : k => {
      role        = var.nodes[k].role
      instance_id = i.id
      private_ip  = i.private_ip
      az          = i.availability_zone
    }
  }
}

output "ssm_parameter_prefix" {
  description = "SSM Parameter Store path holding cluster status and join material."
  value       = local.ssm_prefix
}

output "user_data_base64_length" {
  description = "Length of each node's gzipped, base64-encoded user_data."
  value       = { for k, c in data.cloudinit_config.node : k => length(c.rendered) }
}
