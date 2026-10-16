variable "az_count" {
  description = "Maximum number of availability zones to spread subnets across."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_count must be between 1 and 3."
  }
}

variable "cidr" {
  description = "VPC CIDR block. Private subnets are /20s and public subnets /24s carved from a /16."
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 16
    error_message = "cidr must be a valid IPv4 CIDR with a prefix of /16 or larger."
  }
}

variable "instance_types" {
  description = "EC2 instance types the nodes use. Only AZs offering all of them get subnets."
  type        = list(string)

  validation {
    condition     = length(var.instance_types) > 0
    error_message = "instance_types must list at least one instance type."
  }
}

variable "name" {
  description = "Name used for the VPC and as a prefix for its resources."
  type        = string
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all AZs (cheaper) instead of one per AZ."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in the module."
  type        = map(string)
  default     = {}
}
