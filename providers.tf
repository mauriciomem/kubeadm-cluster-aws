provider "aws" {
  region = var.region

  # Static values only: the random cluster suffix here would cause perpetual tag diffs.
  # The Cluster tag is applied through module tags instead.
  default_tags {
    tags = merge(var.tags, {
      Project     = "kube-lab"
      Environment = "lab"
      ManagedBy   = "terraform"
    })
  }
}
