# Bootstrap status in Terraform: modules/status (the cluster_ready check and the status
# map), and the root outputs built on it.
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  cluster_name = "kube-lab-test"
  region       = "us-east-1"
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
    condition     = output.message == "Cluster kube-lab-test is not ready yet: cluster=installing cp-1=initialized worker-1=pending. Follow it with: ./scripts/wait-for-cluster.sh kube-lab-test us-east-1"
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
