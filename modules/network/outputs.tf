output "azs" {
  description = "Availability zones used, in subnet order."
  value       = local.azs

  # The guard lives on an output because Terraform evaluates every output during plan.
  precondition {
    condition     = length(local.azs) >= 2
    error_message = "Need at least 2 availability zones offering ${join(" and ", var.instance_types)} (for the NLB and node spread); found ${jsonencode(local.azs)}. Pick other instance types or another region."
  }
}

output "nat_public_ips" {
  description = "Public IPs of the NAT gateways. Nodes reach the public API NLB from these addresses."
  value       = module.vpc.nat_public_ips
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs, in private_subnet_ids order."
  value       = module.vpc.private_subnets_cidr_blocks
}

output "private_subnet_ids" {
  description = "Private subnet IDs. Only known once the NAT default route exists, so nodes never boot without egress."
  value       = module.vpc.private_subnets

  depends_on = [module.vpc.private_nat_gateway_route_ids]
}

output "public_subnet_ids" {
  description = "Public subnet IDs (used by the API NLB)."
  value       = module.vpc.public_subnets
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}
