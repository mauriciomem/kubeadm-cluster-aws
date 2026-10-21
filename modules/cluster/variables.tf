variable "ami_id" {
  type        = string
  description = "AMI for every node. Null uses the latest Canonical Ubuntu 24.04 amd64 image."
  default     = null
}

variable "cluster_name" {
  type        = string
  description = "Unique cluster name. Prefixes AWS resource names and the SSM parameter path."
}

variable "control_plane_instance_type" {
  type        = string
  description = "EC2 instance type for control-plane nodes. Must be x86_64."
}

variable "nat_public_ips" {
  type        = list(string)
  description = "NAT gateway public IPs. Nodes reach the internet-facing NLB from these."
}

variable "nodes" {
  type = map(object({
    role  = string
    index = number
    init  = bool
  }))
  description = "Nodes keyed by name (cp-1, worker-1, ...). index drives subnet placement; init marks the node that runs kubeadm init."

  validation {
    condition     = length([for n in values(var.nodes) : n if n.init]) == 1
    error_message = "Exactly one node must have init = true."
  }

  validation {
    # The role picks the bootstrap script and the instance profile.
    condition     = alltrue([for n in values(var.nodes) : contains(["control-plane", "worker"], n.role)])
    error_message = "Each node role must be \"control-plane\" or \"worker\"."
  }
}

variable "operator_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach the Kubernetes API on the NLB."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs of private_subnet_ids. The kubelet serving-certificate approver only accepts node IPs inside them."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for the nodes, one per AZ."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the API NLB, one per AZ."
}

variable "root_volume_size" {
  type        = number
  description = "Root EBS volume size in GiB."
}

variable "software" {
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
    helm = object({
      enabled = bool
      version = string
      sha256  = string
    })
    csr_approver = object({
      version = string
      digest  = string
    })
  })
  description = "Everything the node bootstrap scripts install, and the pod and service CIDRs they pass to kubeadm. Validated in the root module."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource in the module."
  default     = {}
}

variable "vpc_id" {
  type        = string
  description = "VPC to deploy into."
}

variable "worker_instance_type" {
  type        = string
  description = "EC2 instance type for worker nodes. Must be x86_64."
}
