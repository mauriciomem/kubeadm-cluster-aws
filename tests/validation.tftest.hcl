# Input validation: bad values must fail at plan, and valid edge cases must still plan.
mock_provider "aws" {
  source = "./tests/mocks"
}

# Fixes the random suffix so rendered content is known at plan time.
override_resource {
  target          = random_string.suffix
  override_during = plan
  values = {
    result = "test"
  }
}

variables {
  operator_cidrs = ["203.0.113.10/32"]
}

run "even_control_plane_count_rejected" {
  command = plan

  variables {
    control_plane_count = 2
  }

  expect_failures = [var.control_plane_count]
}

run "zero_control_planes_rejected" {
  command = plan

  variables {
    control_plane_count = 0
  }

  expect_failures = [var.control_plane_count]
}

run "too_many_control_planes_rejected" {
  command = plan

  variables {
    control_plane_count = 9
  }

  expect_failures = [var.control_plane_count]
}

run "negative_worker_count_rejected" {
  command = plan

  variables {
    worker_count = -1
  }

  expect_failures = [var.worker_count]
}

run "unknown_cni_rejected" {
  command = plan

  variables {
    cni = "flannel"
  }

  expect_failures = [var.cni]
}

run "empty_operator_cidrs_rejected" {
  command = plan

  variables {
    operator_cidrs = []
  }

  expect_failures = [var.operator_cidrs]
}

run "open_operator_cidr_rejected" {
  command = plan

  variables {
    operator_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.operator_cidrs]
}

run "very_wide_operator_cidr_rejected" {
  command = plan

  variables {
    operator_cidrs = ["16.0.0.0/4"]
  }

  expect_failures = [var.operator_cidrs]
}

run "slash_8_operator_cidr_accepted" {
  command = plan

  variables {
    operator_cidrs = ["10.0.0.0/8"]
  }
}

run "malformed_operator_cidr_rejected" {
  command = plan

  variables {
    operator_cidrs = ["203.0.113.10"]
  }

  expect_failures = [var.operator_cidrs]
}

run "non_canonical_operator_cidr_rejected" {
  command = plan

  variables {
    operator_cidrs = ["203.0.113.10/24"]
  }

  expect_failures = [var.operator_cidrs]
}

run "pod_cidr_overlapping_vpc_rejected" {
  command = plan

  variables {
    pod_cidr = "10.10.0.0/16"
  }

  expect_failures = [var.pod_cidr]
}

run "service_cidr_overlapping_pod_cidr_rejected" {
  command = plan

  variables {
    service_cidr = "192.168.128.0/20"
  }

  expect_failures = [var.service_cidr]
}

run "vpc_inside_default_service_cidr_rejected" {
  command = plan

  variables {
    vpc_cidr = "10.100.0.0/16"
  }

  expect_failures = [var.service_cidr]
}

run "bad_k8s_version_rejected" {
  command = plan

  variables {
    k8s_version = "v1.36"
  }

  expect_failures = [var.k8s_version]
}

run "long_name_prefix_rejected" {
  command = plan

  variables {
    name_prefix = "this-prefix-is-far-too-long"
  }

  expect_failures = [var.name_prefix]
}

run "trailing_hyphen_name_prefix_rejected" {
  command = plan

  variables {
    name_prefix = "lab-"
  }

  expect_failures = [var.name_prefix]
}

run "fractional_worker_count_rejected" {
  command = plan

  variables {
    worker_count = 1.5
  }

  expect_failures = [var.worker_count]
}

run "vpc_cidr_smaller_than_slash_16_rejected" {
  command = plan

  variables {
    vpc_cidr = "10.10.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "malformed_pod_cidr_rejected" {
  command = plan

  variables {
    pod_cidr = "192.168.0.0"
  }

  expect_failures = [var.pod_cidr]
}

run "region_with_shell_characters_rejected" {
  command = plan

  variables {
    region = "us-east-1; true"
  }

  expect_failures = [var.region]
}

run "malformed_ami_id_rejected" {
  command = plan

  variables {
    ami_id = "ami-123"
  }

  expect_failures = [var.ami_id]
}

run "calico_version_without_v_rejected" {
  command = plan

  variables {
    calico_version = "3.33.0"
  }

  expect_failures = [var.calico_version]
}

run "cilium_version_with_v_rejected" {
  command = plan

  variables {
    cilium_version = "v1.20.3"
  }

  expect_failures = [var.cilium_version]
}

run "cilium_cli_version_without_v_rejected" {
  command = plan

  variables {
    cilium_cli_version = "0.20.1"
  }

  expect_failures = [var.cilium_cli_version]
}

run "metrics_server_version_without_v_rejected" {
  command = plan

  variables {
    metrics_server_version = "0.9.0"
  }

  expect_failures = [var.metrics_server_version]
}

run "csr_approver_version_without_v_rejected" {
  command = plan

  variables {
    csr_approver_version = "1.2.15"
  }

  expect_failures = [var.csr_approver_version]
}

# cluster.env is sourced as root on every node, so a version must not carry shell syntax.
run "containerd_version_with_shell_characters_rejected" {
  command = plan

  variables {
    containerd_version = "2.3.*' ; touch /tmp/x ; '"
  }

  expect_failures = [var.containerd_version]
}

run "exact_containerd_version_accepted" {
  command = plan

  variables {
    containerd_version = "2.3.6-1~ubuntu.24.04~noble"
  }
}
