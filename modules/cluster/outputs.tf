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
