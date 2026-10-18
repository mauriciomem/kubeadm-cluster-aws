# Harness for scripts/render-templates.sh: renders the bootstrap module with the root
# module's node map and pins, plus a fake load balancer name. Not a deployable configuration.
locals {
  cluster_name = "kube-lab-test"
  api_host     = "${local.cluster_name}-api-0123456789abcdef.elb.${var.region}.amazonaws.com"
}

module "bootstrap" {
  source = "../../modules/cluster/bootstrap"

  api_endpoint = "${local.api_host}:6443"
  api_host     = local.api_host
  cluster_name = local.cluster_name
  node_cidrs   = var.node_cidrs
  nodes        = var.nodes
  region       = var.region
  software     = var.software
  ssm_prefix   = "/${local.cluster_name}"
}
