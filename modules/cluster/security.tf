resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "Kubernetes nodes"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-node" })
}

# One self-referencing rule covers kubelet, etcd, CNI overlays and NodePorts.
# Tightening it to per-port rules is left as a CKS exercise.
resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  description                  = "All traffic between cluster nodes"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_ingress_rule" "node_api_from_nlb" {
  security_group_id            = aws_security_group.node.id
  description                  = "Kubernetes API and health checks from the NLB"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.nlb.id
}

# Nodes need apt, registries, GitHub releases and AWS APIs; restricting egress is a CKS exercise.
# trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "Package mirrors, registries and AWS APIs via NAT"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# An NLB only gets security groups if they are attached at creation time.
resource "aws_security_group" "nlb" {
  name        = "${var.cluster_name}-api-nlb"
  description = "Kubernetes API load balancer"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-api-nlb" })
}

resource "aws_vpc_security_group_ingress_rule" "nlb_operator" {
  for_each = toset(var.operator_cidrs)

  security_group_id = aws_security_group.nlb.id
  description       = "Kubernetes API from operator"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = each.value
}

# The NLB DNS name resolves to public IPs even inside the VPC, so node traffic
# (joins, kube-proxy, workers' kubelets) arrives from the NAT gateway address.
# count, not for_each: the NAT IPs are unknown until apply, and for_each keys must be known at plan.
resource "aws_vpc_security_group_ingress_rule" "nlb_nat" {
  count = length(var.nat_public_ips)

  security_group_id = aws_security_group.nlb.id
  description       = "Kubernetes API from nodes via NAT"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = "${var.nat_public_ips[count.index]}/32"
}

# For ICMP, from_port is the type and to_port the code:
# type 3 (destination unreachable), code 4 (fragmentation needed).
resource "aws_vpc_security_group_ingress_rule" "nlb_pmtud" {
  security_group_id = aws_security_group.nlb.id
  description       = "Path MTU discovery (ICMP fragmentation needed)"
  ip_protocol       = "icmp"
  from_port         = 3
  to_port           = 4
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_nodes" {
  security_group_id            = aws_security_group.nlb.id
  description                  = "Forwarded API traffic and health checks"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.node.id
}
