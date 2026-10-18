variable "az_count" {
  type        = number
  description = "Maximum number of availability zones to spread subnets across."
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_count must be between 1 and 3."
  }
}

variable "cidr" {
  type        = string
  description = "VPC CIDR block with a prefix length of 16 or less. Private subnets get prefix + 4 (/20 in a /16), public subnets prefix + 8 (/24 in a /16)."

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && try(tonumber(split("/", var.cidr)[1]) <= 16, false)
    error_message = "cidr must be a valid IPv4 CIDR with a prefix length of 16 or less, such as 10.10.0.0/16."
  }
}

variable "instance_types" {
  type        = list(string)
  description = "EC2 instance types the nodes use. Only AZs offering all of them get subnets."

  validation {
    condition     = length(var.instance_types) > 0
    error_message = "instance_types must list at least one instance type."
  }
}

variable "name" {
  type        = string
  description = "Name used for the VPC and as a prefix for its resources."
}

variable "single_nat_gateway" {
  type        = bool
  description = "Use one NAT gateway for all AZs (cheaper) instead of one per AZ."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource in the module."
  default     = {}
}
