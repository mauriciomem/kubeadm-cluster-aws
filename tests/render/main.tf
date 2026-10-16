# Offline harness for scripts/render-templates.sh: renders the bootstrap module with the
# root module's node map and pins plus a fake NLB name. Not a deployable configuration.
terraform {
  required_version = ">= 1.11"
}

variable "nodes" {
  description = "Node map from the root module."
  type = map(object({
    role  = string
    index = number
    init  = bool
  }))
}

variable "region" {
  description = "AWS region from the root module."
  type        = string
}

variable "software" {
  description = "Software pins from the root module."
  type        = any
}

variable "node_cidrs" {
  description = "Private subnet CIDRs, as the network module carves them from the root vpc_cidr."
  type        = list(string)
}

locals {
  cluster_name = "kube-lab-test"
  api_host     = "${local.cluster_name}-api-0123456789abcdef.elb.${var.region}.amazonaws.com"
}

module "bootstrap" {
  source = "../../modules/cluster/bootstrap"

  api_endpoint = "${local.api_host}:6443"
  api_host     = local.api_host
  cluster_name = local.cluster_name
  nodes        = var.nodes
  region       = var.region
  software     = var.software
  ssm_prefix   = "/${local.cluster_name}"
  node_cidrs   = var.node_cidrs
}

output "nodes" {
  description = "Rendered bootstrap content per node."
  value       = module.bootstrap.nodes
}
