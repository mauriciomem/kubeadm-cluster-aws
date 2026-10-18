# Only operator_cidrs is required. docs/configuration.md says when a change to each
# variable takes effect: right away, only on nodes created later, or only on a new cluster.

variable "ami_id" {
  type        = string
  description = "AMI for every node. Null uses the latest Canonical Ubuntu 24.04 amd64 image. Only used when a node is created."
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-([0-9a-f]{8}|[0-9a-f]{17})$", var.ami_id))
    error_message = "ami_id must be null or an AMI ID such as ami-0123456789abcdef0."
  }
}

variable "calico_crds_sha256" {
  type        = string
  description = "sha256 of Calico's v3_projectcalico_org.yaml for calico_version."
  default     = "5306c2c6d9fd6762d804f9da51c049b8269c33498a364c5df0eed555aba026bd"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.calico_crds_sha256))
    error_message = "calico_crds_sha256 must be a lowercase hex sha256."
  }
}

variable "calico_operator_sha256" {
  type        = string
  description = "sha256 of Calico's tigera-operator.yaml for calico_version."
  default     = "aef423b36aef8cf86567f92bbe5eea4b4ca105a6fc7dbf43de599c6fa70388ba"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.calico_operator_sha256))
    error_message = "calico_operator_sha256 must be a lowercase hex sha256."
  }
}

variable "calico_version" {
  type        = string
  description = "Calico release tag, with the leading v (for example v3.33.0)."
  default     = "v3.33.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.calico_version))
    error_message = "calico_version must be a release tag such as v3.33.0, with the leading v."
  }
}

variable "cilium_cli_sha256" {
  type        = string
  description = "sha256 of cilium-linux-amd64.tar.gz for cilium_cli_version."
  default     = "24e817dcfcc8a12e325ce7547617bcbcf171c5b0b335bb24d2bb1207ba047f61"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.cilium_cli_sha256))
    error_message = "cilium_cli_sha256 must be a lowercase hex sha256."
  }
}

variable "cilium_cli_version" {
  type        = string
  description = "cilium-cli release tag used to install Cilium, with the leading v (for example v0.20.1)."
  default     = "v0.20.1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.cilium_cli_version))
    error_message = "cilium_cli_version must be a release tag such as v0.20.1, with the leading v."
  }
}

variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version, without a leading v (for example 1.20.3)."
  default     = "1.20.3"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.cilium_version))
    error_message = "cilium_version must be a chart version such as 1.20.3, without a leading v."
  }
}

variable "cni" {
  type        = string
  description = "Network plugin: calico (the default, tested on 1.36 and 1.37) or cilium. Installed once, when the cluster is created."
  default     = "calico"

  validation {
    condition     = contains(["calico", "cilium"], var.cni)
    error_message = "cni must be \"calico\" or \"cilium\"."
  }
}

variable "containerd_version" {
  type        = string
  description = "Version of the containerd.io package from Docker's apt repository. Accepts an apt pattern such as 2.3.*."
  default     = "2.3.*"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9A-Za-z.+~*-]+$", var.containerd_version))
    error_message = "containerd_version must be an apt version or pattern such as 2.3.* or 2.3.6-1~ubuntu.24.04~noble."
  }
}

variable "control_plane_count" {
  type        = number
  description = "Number of control-plane nodes: 1, 3, 5 or 7 (odd, so etcd keeps quorum). Read docs/operations.md before you lower it on a running cluster."
  default     = 1

  validation {
    condition     = var.control_plane_count >= 1 && var.control_plane_count <= 7 && var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be an odd number between 1 and 7 (etcd quorum); got ${var.control_plane_count}."
  }
}

variable "control_plane_instance_type" {
  type        = string
  description = "EC2 instance type for control-plane nodes. Must be x86_64; kubeadm needs at least 2 vCPUs and 2 GiB of memory."
  default     = "t3.medium"
}

variable "csr_approver_digest" {
  type        = string
  description = "Image index digest of ghcr.io/postfinance/kubelet-csr-approver for csr_approver_version."
  default     = "sha256:6469ef517d2b6d3cb108fce8a913483533a48b1cd78b5d4af307fa09e04a7818"

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.csr_approver_digest))
    error_message = "csr_approver_digest must look like sha256:<64 hex characters>."
  }
}

variable "csr_approver_version" {
  type        = string
  description = "kubelet-csr-approver release tag, with the leading v. It approves the kubelets' serving certificates."
  default     = "v1.2.15"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.csr_approver_version))
    error_message = "csr_approver_version must be a release tag such as v1.2.15, with the leading v."
  }
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes version the nodes install (kubeadm, kubelet, kubectl and the control plane). Only used when a node is created; to upgrade a running cluster, follow docs/labs/upgrade.md."
  default     = "1.36.5"

  validation {
    condition     = can(regex("^1\\.[0-9]+\\.[0-9]+$", var.k8s_version))
    error_message = "k8s_version must look like 1.36.5, without a leading v; got \"${var.k8s_version}\"."
  }
}

variable "metrics_server_sha256" {
  type        = string
  description = "sha256 of metrics-server's components.yaml for metrics_server_version."
  default     = "1cec29a5267809306a2c6ec74a3e449abbb705b4a8beed0c8a1963910f72c79b"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.metrics_server_sha256))
    error_message = "metrics_server_sha256 must be a lowercase hex sha256."
  }
}

variable "metrics_server_version" {
  type        = string
  description = "metrics-server release tag, with the leading v (for example v0.9.0)."
  default     = "v0.9.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.metrics_server_version))
    error_message = "metrics_server_version must be a release tag such as v0.9.0, with the leading v."
  }
}

variable "name_prefix" {
  type        = string
  description = "Prefix for the cluster name. A random 4-character suffix is added, for example kube-lab-a1b2."
  default     = "kube-lab"

  validation {
    # The load balancer name "<prefix>-<suffix>-api" must fit in 32 characters.
    condition     = can(regex("^[a-z]([a-z0-9-]{0,18}[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix must be 1-20 lowercase letters, digits or hyphens, start with a letter and end with a letter or digit; got \"${var.name_prefix}\"."
  }
}

variable "operator_cidrs" {
  type        = list(string)
  description = "Public IPv4 CIDRs allowed to reach the Kubernetes API, for example [\"203.0.113.10/32\"]. Each prefix must be /8 or longer."

  validation {
    condition     = length(var.operator_cidrs) > 0
    error_message = "operator_cidrs must list at least one CIDR."
  }

  validation {
    condition = alltrue([
      for c in var.operator_cidrs : can(regex("^[0-9.]+/[0-9]+$", c)) && try(cidrsubnet(c, 0, 0) == c, false)
    ])
    # A CIDR with host bits set (203.0.113.10/24) is normalized by AWS and causes perpetual diffs.
    error_message = "Every operator_cidrs entry must be a canonical IPv4 CIDR such as 203.0.113.10/32 or 203.0.113.0/24."
  }

  validation {
    condition     = alltrue([for c in var.operator_cidrs : try(tonumber(split("/", c)[1]) >= 8, false)])
    error_message = "operator_cidrs prefixes must be /8 or longer; wider ranges open the API to a large part of the internet."
  }
}

# The CIDR overlap checks below all use the same test. Two CIDRs overlap when their
# network addresses match after both are cut to the shorter prefix length.
# try() turns a malformed CIDR into a validation failure instead of an error.
variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR (kubeadm podSubnet), used by both Calico and Cilium. Only used when the cluster is created."
  default     = "192.168.0.0/16"

  validation {
    condition = try(
      cidrsubnet("${cidrhost(var.pod_cidr, 0)}/${min(split("/", var.pod_cidr)[1], split("/", var.vpc_cidr)[1])}", 0, 0) !=
      cidrsubnet("${cidrhost(var.vpc_cidr, 0)}/${min(split("/", var.pod_cidr)[1], split("/", var.vpc_cidr)[1])}", 0, 0),
      false
    )
    error_message = "pod_cidr (${var.pod_cidr}) must be a valid CIDR that does not overlap vpc_cidr (${var.vpc_cidr})."
  }
}

variable "region" {
  type        = string
  description = "AWS region to create the cluster in."
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS region name such as us-east-1; got \"${var.region}\"."
  }
}

variable "root_volume_size" {
  type        = number
  description = "Root EBS volume size in GiB for every node, at least 20. EBS volumes can grow but not shrink."
  default     = 30

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "root_volume_size must be at least 20 GiB."
  }
}

variable "service_cidr" {
  type        = string
  description = "Service CIDR (kubeadm serviceSubnet). Only used when the cluster is created."
  default     = "10.96.0.0/12"

  validation {
    condition = try(
      cidrsubnet("${cidrhost(var.service_cidr, 0)}/${min(split("/", var.service_cidr)[1], split("/", var.vpc_cidr)[1])}", 0, 0) !=
      cidrsubnet("${cidrhost(var.vpc_cidr, 0)}/${min(split("/", var.service_cidr)[1], split("/", var.vpc_cidr)[1])}", 0, 0),
      false
    )
    error_message = "service_cidr (${var.service_cidr}) must be a valid CIDR that does not overlap vpc_cidr (${var.vpc_cidr})."
  }

  validation {
    condition = try(
      cidrsubnet("${cidrhost(var.service_cidr, 0)}/${min(split("/", var.service_cidr)[1], split("/", var.pod_cidr)[1])}", 0, 0) !=
      cidrsubnet("${cidrhost(var.pod_cidr, 0)}/${min(split("/", var.service_cidr)[1], split("/", var.pod_cidr)[1])}", 0, 0),
      false
    )
    error_message = "service_cidr (${var.service_cidr}) must not overlap pod_cidr (${var.pod_cidr})."
  }
}

variable "single_nat_gateway" {
  type        = bool
  description = "Use one NAT gateway for all AZs (cheaper). Set false for one per AZ."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Extra tags applied to every AWS resource."
  default     = {}
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR with a prefix length of 16 or less (for example /16 or /15). Must not overlap pod_cidr or service_cidr; kubeadm's default service range is 10.96.0.0/12."
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && try(tonumber(split("/", var.vpc_cidr)[1]) <= 16, false)
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix length of 16 or less, such as 10.10.0.0/16; got \"${var.vpc_cidr}\"."
  }
}

variable "wait_for_cluster" {
  type        = bool
  description = "Make terraform apply wait until the cluster reports ready. Runs scripts/wait-for-cluster.sh on your machine, once, when cp-1 is created."
  default     = false
}

variable "worker_count" {
  type        = number
  description = "Number of worker nodes, from 0 to 20. With 0, workloads run on the control planes."
  default     = 2

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 20 && floor(var.worker_count) == var.worker_count
    error_message = "worker_count must be a whole number between 0 and 20; got ${var.worker_count}."
  }
}

variable "worker_instance_type" {
  type        = string
  description = "EC2 instance type for worker nodes. Must be x86_64."
  default     = "t3.medium"
}
