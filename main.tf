resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

module "network" {
  source = "./modules/network"

  name               = local.cluster_name
  cidr               = var.vpc_cidr
  single_nat_gateway = var.single_nat_gateway
  # Only AZs that offer both instance types, so no node lands where it can't launch.
  instance_types = distinct([var.control_plane_instance_type, var.worker_instance_type])
  tags           = local.tags
}

module "cluster" {
  source = "./modules/cluster"

  cluster_name                = local.cluster_name
  nodes                       = local.nodes
  software                    = local.software
  ami_id                      = var.ami_id
  control_plane_instance_type = var.control_plane_instance_type
  worker_instance_type        = var.worker_instance_type
  root_volume_size            = var.root_volume_size
  operator_cidrs              = var.operator_cidrs

  vpc_id               = module.network.vpc_id
  private_subnet_ids   = module.network.private_subnet_ids
  private_subnet_cidrs = module.network.private_subnet_cidrs
  public_subnet_ids    = module.network.public_subnet_ids
  nat_public_ips       = module.network.nat_public_ips

  tags = local.tags
}

# Opt-in: block `terraform apply` until the cluster reports ready (needs bash and the AWS CLI locally).
resource "terraform_data" "wait_for_cluster" {
  count = var.wait_for_cluster ? 1 : 0

  triggers_replace = [module.cluster.instances[local.cp_keys[0]].instance_id]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-cluster.sh ${local.cluster_name} ${var.region}"
  }
}
