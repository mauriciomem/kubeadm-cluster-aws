terraform {
  # value_wo needs 1.11; cross-variable validation needs 1.9.
  required_version = ">= 1.11"

  # Child modules only declare minimum versions. The root pins every provider they use,
  # including cloudinit, which only modules/cluster calls.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
