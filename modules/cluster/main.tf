# Entry point: the nodes and the bootstrap content they boot with.
# The rest of the module: IAM in iam.tf, security groups in security.tf,
# the API load balancer in nlb.tf and the SSM parameters in ssm.tf.

data "aws_region" "current" {}

data "aws_ssm_parameter" "ubuntu_ami" {
  count = var.ami_id == null ? 1 : 0

  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# The AMI and the Cilium CLI download are amd64, so every instance type must be x86_64.
data "aws_ec2_instance_type" "node" {
  for_each = toset(values(local.instance_types))

  instance_type = each.value
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.ubuntu_ami[0].insecure_value

  instance_types = {
    control-plane = var.control_plane_instance_type
    worker        = var.worker_instance_type
  }

  # EC2 caps user data at 16 KB before base64 encoding.
  max_user_data_base64 = 4 * ceil(16384 / 3)
}

module "bootstrap" {
  source = "./bootstrap"

  api_endpoint = local.api_endpoint
  api_host     = local.api_host
  cluster_name = var.cluster_name
  node_cidrs   = var.private_subnet_cidrs
  nodes        = var.nodes
  region       = local.region
  software     = var.software
  ssm_prefix   = local.ssm_prefix
}

# gzip keeps cp-1 well under the EC2 user data limit; cloud-init decompresses it transparently.
data "cloudinit_config" "node" {
  for_each = var.nodes

  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"
    content      = module.bootstrap.nodes[each.key].cloud_config
  }

  part {
    filename     = "${each.value.role}.sh"
    content_type = "text/x-shellscript"
    content      = module.bootstrap.nodes[each.key].script
  }
}

resource "aws_instance" "node" {
  for_each = var.nodes

  ami                         = local.ami_id
  instance_type               = local.instance_types[each.value.role]
  subnet_id                   = var.private_subnet_ids[each.value.index % length(var.private_subnet_ids)]
  vpc_security_group_ids      = [aws_security_group.node.id]
  iam_instance_profile        = aws_iam_instance_profile.node[each.value.role].name
  associate_public_ip_address = false
  user_data_base64            = data.cloudinit_config.node[each.key].rendered

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-${each.key}"
    Role = each.value.role
  })

  # Hop limit 1 keeps IMDS tokens away from pods on the pod network.
  # hostNetwork pods share the node's network and can still reach IMDS (see docs/labs/cks.md).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  lifecycle {
    # A new AMI or bootstrap script must not rebuild nodes behind your back: cp-1 holds etcd.
    # Rebuild a node on purpose with: terraform apply -replace='module.cluster.aws_instance.node["worker-1"]'
    ignore_changes = [ami, user_data_base64]

    precondition {
      condition     = contains(data.aws_ec2_instance_type.node[local.instance_types[each.value.role]].supported_architectures, "x86_64")
      error_message = "${local.instance_types[each.value.role]} is not an x86_64 instance type. The nodes run the amd64 Ubuntu image, so pick an x86_64 type such as t3.medium."
    }

    precondition {
      condition     = length(data.cloudinit_config.node[each.key].rendered) <= local.max_user_data_base64
      error_message = "Rendered user_data for ${each.key} exceeds the 16 KB EC2 limit. Trim the bootstrap templates."
    }
  }

  # Nodes overwrite these parameters at boot, so they and the IAM grants must exist first.
  depends_on = [
    aws_ssm_parameter.cluster,
    aws_iam_role_policy.node,
    aws_iam_role_policy.session_manager,
  ]
}
