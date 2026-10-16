# Internet-facing by design so kubectl works without a VPN; the security group admits only
# operator_cidrs and the NAT IPs on 6443.
# trivy:ignore:AWS-0053
resource "aws_lb" "api" {
  name               = "${var.cluster_name}-api"
  load_balancer_type = "network"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.nlb.id]

  # A single control plane must answer on every AZ address of the NLB.
  enable_cross_zone_load_balancing = true

  tags = var.tags
}

resource "aws_lb_target_group" "api" {
  name        = "${var.cluster_name}-api"
  port        = 6443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  # With client IP preservation, a control plane calling the NLB can be routed to
  # itself and the connection times out (NLB hairpin). Off, targets see NLB IPs.
  preserve_client_ip   = "false"
  deregistration_delay = 30

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = var.tags
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = var.tags
}

resource "aws_lb_target_group_attachment" "control_plane" {
  for_each = local.control_planes

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.node[each.key].id
  port             = 6443
}
