output "api_endpoint" {
  description = "Kubernetes API URL (internet-facing NLB, restricted to operator_cidrs)."
  value       = module.cluster.api_endpoint
}

output "cluster_name" {
  description = "Cluster name; prefixes AWS resources and the SSM parameter path."
  value       = local.cluster_name
}

output "kubeconfig_command" {
  description = "Fetches the admin kubeconfig from SSM into ~/.kube/<cluster>.yaml."
  value       = "./scripts/get-kubeconfig.sh ${local.cluster_name} ${var.region}"
}

output "nat_public_ips" {
  description = "NAT gateway public IPs. Nodes reach the API NLB from these, so the NLB security group allows them."
  value       = module.network.nat_public_ips
}

output "nodes" {
  description = "Nodes keyed by name: role, instance ID, private IP and AZ."
  value       = module.cluster.instances
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "ssm_parameter_prefix" {
  description = "SSM Parameter Store path with cluster and node bootstrap status."
  value       = module.cluster.ssm_parameter_prefix
}

output "ssm_session_commands" {
  description = "Shell access to each node via SSM Session Manager."
  value = {
    for k, n in module.cluster.instances : k => "aws ssm start-session --region ${var.region} --target ${n.instance_id}"
  }
}

output "wait_command" {
  description = "Blocks until every node has joined and the cluster reports ready."
  value       = "./scripts/wait-for-cluster.sh ${local.cluster_name} ${var.region}"
}
