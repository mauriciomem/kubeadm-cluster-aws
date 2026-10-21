# Bootstrap status in Terraform: modules/status (the cluster_ready check and the status
# map), and the root outputs built on it.
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  cluster_name = "kube-lab-test"
  region       = "us-east-1"
  # The root passes module.cluster.status_pattern; tests/cluster.tftest.hcl checks that copy.
  status_pattern = "^(pending|bootstrapping|waiting|joining|joined|initializing|initialized|installing|ready|failed:[a-z0-9-]{1,40})$"
  parameters = {
    cluster  = "/kube-lab-test/status/cluster"
    cp-1     = "/kube-lab-test/nodes/cp-1/status"
    worker-1 = "/kube-lab-test/nodes/worker-1/status"
  }
}

run "ready_cluster" {
  command = plan

  module {
    source = "./modules/status"
  }

  override_data {
    target = data.aws_ssm_parameter.status["cluster"]
    values = { insecure_value = "ready" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["cp-1"]
    values = { insecure_value = "joined" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["worker-1"]
    values = { insecure_value = "joined" }
  }

  assert {
    condition     = output.status == { cluster = "ready", cp-1 = "joined", worker-1 = "joined" }
    error_message = "status must show every status, keyed by cluster and node name."
  }

  assert {
    condition     = alltrue([for d in data.aws_ssm_parameter.status : d.with_decryption == false])
    error_message = "Terraform must never decrypt what it reads for status."
  }
}

run "bootstrapping_cluster_warns" {
  command = plan

  module {
    source = "./modules/status"
  }

  override_data {
    target = data.aws_ssm_parameter.status["cluster"]
    values = { insecure_value = "installing" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["cp-1"]
    values = { insecure_value = "initialized" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["worker-1"]
    values = { insecure_value = "pending" }
  }

  expect_failures = [check.cluster_ready]

  assert {
    condition     = output.message == "Cluster kube-lab-test is not ready yet: cluster=installing cp-1=initialized worker-1=pending. The nodes usually finish about 5 minutes after they're created. Follow them with: ./scripts/wait-for-cluster.sh kube-lab-test us-east-1"
    error_message = "The warning must list every status and say how to follow progress; got: ${output.message}"
  }
}

run "failed_bootstrap_names_node_and_step" {
  command = plan

  module {
    source = "./modules/status"
  }

  override_data {
    target = data.aws_ssm_parameter.status["cluster"]
    values = { insecure_value = "installing" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["cp-1"]
    values = { insecure_value = "initialized" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["worker-1"]
    values = { insecure_value = "failed:join" }
  }

  expect_failures = [check.cluster_ready]

  assert {
    condition     = startswith(output.message, "Bootstrap failed: worker-1 at step join. ")
    error_message = "A failure must name the node and the step; got: ${output.message}"
  }

  assert {
    condition     = strcontains(output.message, "/var/log/kube-lab-bootstrap.log")
    error_message = "A failure must say where the log is."
  }
}

# A status a node rewrote as a SecureString (an older bootstrap script) is never decrypted.
run "secure_string_status_is_unreadable" {
  command = plan

  module {
    source = "./modules/status"
  }

  override_data {
    target = data.aws_ssm_parameter.status["cluster"]
    values = { insecure_value = null, type = "SecureString" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["cp-1"]
    values = { insecure_value = "joined" }
  }
  override_data {
    target = data.aws_ssm_parameter.status["worker-1"]
    values = { insecure_value = "joined" }
  }

  expect_failures = [check.cluster_ready]

  assert {
    condition     = output.status["cluster"] == "unreadable"
    error_message = "A SecureString status must show as unreadable."
  }
}

# Root on a worker can write any text into a worker's status, because a PutParameter request
# can replace allowed_pattern. Such a value never reaches the outputs or the check message.
run "values_outside_the_protocol_are_invalid" {
  command = plan

  module {
    source = "./modules/status"
  }

  override_data {
    target = data.aws_ssm_parameter.status["cluster"]
    values = { insecure_value = "installing" }
  }
  # A join token copied into a status.
  override_data {
    target = data.aws_ssm_parameter.status["cp-1"]
    values = { insecure_value = "abcdef.0123456789abcdef" }
  }
  # A terminal escape sequence (OSC 52, clipboard write) behind a valid-looking prefix.
  override_data {
    target = data.aws_ssm_parameter.status["worker-1"]
    values = { insecure_value = "failed:join\u001b]52;c;ZXZpbA==\u0007" }
  }

  expect_failures = [check.cluster_ready]

  assert {
    condition     = output.status == { cluster = "installing", cp-1 = "invalid", worker-1 = "invalid" }
    error_message = "Values outside the status protocol must show as invalid; got: ${jsonencode(output.status)}"
  }

  assert {
    condition     = !strcontains(output.message, "abcdef.0123456789abcdef") && !strcontains(output.message, "\u001b") && !strcontains(output.message, "]52;")
    error_message = "The check message must never carry a value outside the status protocol."
  }

  assert {
    condition     = startswith(output.message, "Cluster kube-lab-test is not ready yet: cluster=installing cp-1=invalid worker-1=invalid.")
    error_message = "An invalid value must not count as a failure; got: ${output.message}"
  }
}

run "secret_parameters_rejected" {
  command = plan

  module {
    source = "./modules/status"
  }

  variables {
    parameters = {
      cluster = "/kube-lab-test/status/cluster"
      token   = "/kube-lab-test/join/token"
    }
  }

  expect_failures = [var.parameters]
}
