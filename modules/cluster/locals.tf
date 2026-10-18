locals {
  region = data.aws_region.current.region

  # Join material, the admin kubeconfig and bootstrap status all live under this path.
  # docs/architecture.md lists every parameter and who reads and writes it.
  ssm_prefix = "/${var.cluster_name}"

  # The API load balancer, as kubeadm expects it: controlPlaneEndpoint is host:port.
  api_host     = aws_lb.api.dns_name
  api_endpoint = "${local.api_host}:6443"
}
