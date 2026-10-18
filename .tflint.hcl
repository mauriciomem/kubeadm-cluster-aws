config {
  call_module_type = "local"
}

# "all" adds the style rules the recommended preset leaves out: documented variables
# and outputs, naming, comment syntax and the standard module structure.
plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# The root pins cloudinit on purpose: child modules only declare minimum versions,
# and the root sets the exact constraint for every provider they use.
rule "terraform_unused_required_providers" {
  enabled = false
}
