variable "api_endpoint" {
  description = "Kubernetes API host:port (the NLB)."
  type        = string
}

variable "api_host" {
  description = "Kubernetes API host name (the NLB DNS name), added to the API server certificate."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name."
  type        = string
}

variable "node_cidrs" {
  description = "Private subnet CIDRs the nodes live in; the kubelet serving-cert approver accepts only these IPs."
  type        = list(string)
}

variable "nodes" {
  description = "Nodes keyed by name, as passed to the cluster module."
  type = map(object({
    role  = string
    index = number
    init  = bool
  }))
}

variable "region" {
  description = "AWS region, for the AWS CLI on the nodes."
  type        = string
}

variable "software" {
  description = "Software versions, checksums and Kubernetes networking (see the cluster module's bootstrap variable)."
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

variable "ssm_prefix" {
  description = "SSM Parameter Store path for this cluster."
  type        = string
}
