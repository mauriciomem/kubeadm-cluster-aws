variable "cluster_name" {
  type        = string
  description = "Cluster name, for the messages."
}

variable "parameters" {
  type        = map(string)
  description = "Status parameter names keyed by \"cluster\" and node name: the cluster module's status_parameters output. Never a secret: their values end up in the state."
}

variable "region" {
  type        = string
  description = "AWS region, for the messages."
}
