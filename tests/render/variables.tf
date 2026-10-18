variable "node_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs, carved from the root vpc_cidr the same way modules/network does."
}

variable "nodes" {
  type = map(object({
    role  = string
    index = number
    init  = bool
  }))
  description = "Node map from the root module."
}

variable "region" {
  type        = string
  description = "AWS region from the root module."
}

variable "software" {
  type        = any
  description = "Software pins from the root module. The bootstrap module checks the shape."
}
