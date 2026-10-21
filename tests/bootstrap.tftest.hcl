# Exercises modules/cluster/bootstrap on its own: the guard on its output. It has no
# providers, so nothing is mocked.
variables {
  api_endpoint = "kube-lab-test-api.elb.us-east-1.amazonaws.com:6443"
  api_host     = "kube-lab-test-api.elb.us-east-1.amazonaws.com"
  cluster_name = "kube-lab-test"
  node_cidrs   = ["10.10.0.0/20"]
  region       = "us-east-1"
  ssm_prefix   = "/kube-lab-test"

  nodes = {
    cp-1     = { role = "control-plane", index = 0, init = true }
    worker-1 = { role = "worker", index = 0, init = false }
  }

  software = {
    k8s_version        = "1.36.5"
    containerd_version = "2.3.*"
    cni                = "calico"
    pod_cidr           = "192.168.0.0/16"
    service_cidr       = "10.96.0.0/12"
    aws_cli            = { version = "2.38.3", sha256 = "0" }
    calico             = { version = "v3.33.0", crds_sha256 = "0", operator_sha256 = "0" }
    cilium             = { version = "1.20.3", cli_version = "v0.20.1", cli_sha256 = "0" }
    helm               = { enabled = false, version = "v3.22.1", sha256 = "0" }
    csr_approver       = { version = "v1.2.15", digest = "sha256:0" }
  }
}

run "csr_approver_accepts_the_node_names" {
  command = plan

  module {
    source = "./modules/cluster/bootstrap"
  }

  assert {
    condition     = strcontains(output.nodes["cp-1"].files["/etc/kube-lab/kubelet-csr-approver.yaml"], "value: \"^(cp|worker)-[0-9]+$\"")
    error_message = "PROVIDER_REGEX must come from node_name_regex."
  }
}

run "node_names_the_csr_approver_rejects_fail_the_plan" {
  command = plan

  module {
    source = "./modules/cluster/bootstrap"
  }

  variables {
    nodes = {
      cp-1  = { role = "control-plane", index = 0, init = true }
      node1 = { role = "worker", index = 0, init = false }
    }
  }

  expect_failures = [output.nodes]
}
