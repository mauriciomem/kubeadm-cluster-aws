data "aws_ssm_parameter" "ubuntu_ami" {
  count = var.ami_id == null ? 1 : 0

  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.ubuntu_ami[0].insecure_value

  # EC2 caps user data at 16 KB before base64 encoding.
  max_user_data_base64 = 4 * ceil(16384 / 3)
}

module "bootstrap" {
  source = "./bootstrap"

  api_endpoint = local.api_endpoint
  api_host     = local.api_host
  cluster_name = var.cluster_name
  nodes        = var.nodes
  region       = local.region
  software     = var.software
  ssm_prefix   = local.ssm_prefix
  node_cidrs   = var.private_subnet_cidrs
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
  instance_type               = each.value.role == "control-plane" ? var.control_plane_instance_type : var.worker_instance_type
  subnet_id                   = var.private_subnet_ids[each.value.index % length(var.private_subnet_ids)]
  vpc_security_group_ids      = [aws_security_group.node.id]
  iam_instance_profile        = aws_iam_instance_profile.node[each.value.role].name
  associate_public_ip_address = false
  user_data_base64            = data.cloudinit_config.node[each.key].rendered

  # Hop limit 1 keeps IMDS tokens away from pod-network containers.
  # hostNetwork pods can still reach IMDS: blocking that is a CKS exercise.
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

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-${each.key}"
    Role = each.value.role
  })

  # Nodes overwrite these parameters at boot, so they and the IAM grants must exist first.
  depends_on = [
    aws_ssm_parameter.cluster,
    aws_iam_role_policy.node,
    aws_iam_role_policy.session_manager,
  ]

  lifecycle {
    # A new AMI or bootstrap script must not silently rebuild nodes (cp-1 holds etcd).
    # Rebuild a node deliberately with: terraform apply -replace='module.cluster.aws_instance.node["worker-1"]'
    ignore_changes = [ami, user_data_base64]

    precondition {
      condition     = length(data.cloudinit_config.node[each.key].rendered) <= local.max_user_data_base64
      error_message = "Rendered user_data for ${each.key} exceeds the 16 KB EC2 limit. Trim the bootstrap templates."
    }
  }
}
