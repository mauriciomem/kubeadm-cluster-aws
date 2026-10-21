variable "api_endpoint" {
  type        = string
  description = "Kubernetes API as host:port (the NLB). Becomes kubeadm's controlPlaneEndpoint."
}

variable "api_host" {
  type        = string
  description = "NLB DNS name, listed in the API server certificate's SANs. kubeadm adds the controlPlaneEndpoint host anyway; the explicit entry shows learners where it comes from."
}

variable "cluster_name" {
  type        = string
  description = "Cluster name."
}

variable "node_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs the nodes live in. The kubelet serving-certificate approver only accepts IPs inside them."
}

variable "nodes" {
  type = map(object({
    role  = string
    index = number
    init  = bool
  }))
  description = "Nodes keyed by name, as passed to the cluster module."
}

variable "region" {
  type        = string
  description = "AWS region, for the AWS CLI on the nodes."
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
  description = "Versions, checksums and CIDRs for the node scripts. Same shape as the cluster module's software variable."
}

variable "ssm_prefix" {
  type        = string
  description = "SSM Parameter Store path for this cluster."
}
