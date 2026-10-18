data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ec2_instance_type_offerings" "node" {
  for_each = toset(var.instance_types)

  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [each.value]
  }
}

locals {
  # Available AZs, in their usual order, that offer every node instance type.
  eligible_azs = [
    for az in data.aws_availability_zones.available.names : az
    if alltrue([for o in data.aws_ec2_instance_type_offerings.node : contains(o.locations, az)])
  ]
  azs = slice(local.eligible_azs, 0, min(var.az_count, length(local.eligible_azs)))

  # In a /16: private /20s start at the bottom of the range, public /24s at x.x.100.0,
  # so they never collide. scripts/render-templates.sh repeats the private carving.
  private_subnets = [for i in range(length(local.azs)) : cidrsubnet(var.cidr, 4, i)]
  public_subnets  = [for i in range(length(local.azs)) : cidrsubnet(var.cidr, 8, 100 + i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3" # Exact pin: the lock file does not cover module versions.

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Spelled out as the VPC module documents it: without one_nat_gateway_per_az the module
  # creates one NAT gateway per private subnet, which only equals one per AZ by coincidence.
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  map_public_ip_on_launch = false

  tags = var.tags
}
