output "api_url" {
  description = "Kubernetes API URL: https://<NLB DNS name>:6443."
  value       = "https://${local.api_endpoint}"
}

output "bootstrap" {
  description = "Rendered bootstrap content per node, for tests and terraform console. Holds no secrets. Not a stable interface."
  value       = module.bootstrap.nodes
}

output "nodes" {
  description = "Nodes keyed by name: role, instance ID, private IP and AZ."
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
  description = "SSM path holding the join material, the admin kubeconfig and bootstrap status."
  value       = local.ssm_prefix
}

output "status_pattern" {
  description = "Regular expression every status value matches. Readers show anything else as invalid."
  value       = local.status_pattern
}

output "status_parameters" {
  description = "Names of the status parameters (never the secrets), keyed by \"cluster\" and by node name. Their keys are known at plan time."
  value = merge(
    { cluster = aws_ssm_parameter.cluster["status/cluster"].name },
    { for k in keys(var.nodes) : k => aws_ssm_parameter.cluster["nodes/${k}/status"].name },
  )
}
