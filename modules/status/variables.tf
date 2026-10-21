variable "cluster_name" {
  type        = string
  description = "Cluster name, for the messages."
}

variable "parameters" {
  type        = map(string)
  description = "Status parameter names, keyed by \"cluster\" and by node name (the cluster module's status_parameters output). Never pass a secret parameter here: this module reads them into the state."

  validation {
    condition     = contains(keys(var.parameters), "cluster")
    error_message = "parameters must include the cluster status, under the key \"cluster\"."
  }

  validation {
    condition     = alltrue([for name in values(var.parameters) : endswith(name, "/status") || endswith(name, "/status/cluster")])
    error_message = "parameters may only name status parameters."
  }
}

variable "region" {
  type        = string
  description = "AWS region, for the messages."
}
