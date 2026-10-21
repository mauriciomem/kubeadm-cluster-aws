output "api_url" {
  description = "Kubernetes API URL. The load balancer only accepts operator_cidrs."
  value       = module.cluster.api_url
}

output "cluster_name" {
  description = "Cluster name, for example kube-lab-a1b2. It prefixes the AWS resources and the SSM parameter path."
  value       = local.cluster_name
}

output "cluster_status" {
  description = "Bootstrap status of the cluster and of each node, as of the last apply or apply -refresh-only (terraform output does not refresh it). For the live value, run status_command."
  value       = module.status.status
}

output "kubeconfig_command" {
  description = "Command that downloads the admin kubeconfig to ~/.kube/<cluster>.yaml. Run it as eval \"$(...)\" to set KUBECONFIG in your shell; next_steps shows the full line."
  value       = "./scripts/get-kubeconfig.sh ${local.cluster_name} ${var.region}"
}

output "nat_public_ips" {
  description = "NAT gateway public IPs. Nodes reach the API load balancer from these, so its security group allows them."
  value       = module.network.nat_public_ips
}

output "next_steps" {
  description = "Commands to run after apply, ready to paste: wait for the cluster, then point kubectl at it."
  value       = <<-EOT
    ./scripts/wait-for-cluster.sh ${local.cluster_name} ${var.region}
    eval "$(./scripts/get-kubeconfig.sh ${local.cluster_name} ${var.region})"
    kubectl get nodes
  EOT
}

output "nodes" {
  description = "Nodes keyed by name: role, instance ID, private IP and AZ."
  value       = module.cluster.nodes
}

output "region" {
  description = "AWS region the cluster runs in."
  value       = var.region
}

output "ssm_parameter_prefix" {
  description = "SSM path holding the join material, the admin kubeconfig and bootstrap status."
  value       = module.cluster.ssm_parameter_prefix
}

output "ssm_session_commands" {
  description = "Command that opens a shell on each node through Session Manager."
  value = {
    for k, n in module.cluster.nodes : k => "aws ssm start-session --region ${var.region} --target ${n.instance_id}"
  }
}

output "status_command" {
  description = "Command that prints the live bootstrap status once. Exit code 0 ready, 1 failed, 4 still in progress."
  value       = "./scripts/wait-for-cluster.sh --once ${local.cluster_name} ${var.region}"
}

output "wait_command" {
  description = "Command that waits until every node has joined and the cluster reports ready."
  value       = "./scripts/wait-for-cluster.sh ${local.cluster_name} ${var.region}"
}
