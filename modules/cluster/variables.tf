variable "ami_id" {
  description = "AMI override. Null uses the latest Canonical Ubuntu 24.04 amd64 image."
  type        = string
  default     = null
}

variable "software" {
  description = "Software versions, checksums and Kubernetes networking used by the node bootstrap scripts."
  type = object({
    k8s_version        = string
    containerd_version = string
    cni                = string
    pod_cidr           = string
    service_cidr       = string
    calico = object({
      version         = string
      crds_sha256     = string
      operator_sha256 = string
    })
    cilium = object({
      version     = string
      cli_version = string
      cli_sha256  = string
    })
    metrics_server = object({
      version = string
      sha256  = string
    })
    csr_approver = object({
      version = string
      digest  = string
    })
  })
}

variable "cluster_name" {
  description = "Unique cluster name. Prefixes AWS resource names and the SSM parameter path."
  type        = string
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control-plane nodes."
  type        = string
}

variable "nat_public_ips" {
  description = "NAT gateway public IPs. Nodes reach the internet-facing NLB from these."
  type        = list(string)
}

variable "nodes" {
  description = "Nodes keyed by name (cp-1, worker-1, ...). index drives subnet placement; init marks the node that runs kubeadm init."
  type = map(object({
    role  = string
    index = number
    init  = bool
  }))

  validation {
    condition     = length([for n in values(var.nodes) : n if n.init]) == 1
    error_message = "Exactly one node must have init = true."
  }
}

variable "operator_cidrs" {
  description = "IPv4 CIDRs allowed to reach the Kubernetes API on the NLB."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets for the nodes, one per AZ."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDRs of private_subnet_ids. Bounds which IPs the kubelet serving-cert approver accepts."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets for the API NLB, one per AZ."
  type        = list(string)
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource in the module."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes."
  type        = string
}
