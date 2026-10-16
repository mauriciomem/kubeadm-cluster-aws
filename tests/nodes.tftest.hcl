mock_provider "aws" {
  source = "./tests/mocks"
}

# Fixes the random suffix so rendered content is known at plan time.
override_resource {
  target          = random_string.suffix
  override_during = plan
  values = {
    result = "test"
  }
}

variables {
  operator_cidrs = ["203.0.113.10/32"]
}

run "defaults_one_control_plane_two_workers" {
  command = plan

  assert {
    condition     = keys(local.nodes) == ["cp-1", "worker-1", "worker-2"]
    error_message = "Default node map should be cp-1, worker-1, worker-2; got ${jsonencode(keys(local.nodes))}."
  }

  assert {
    condition     = local.nodes["cp-1"].init && !local.nodes["worker-1"].init
    error_message = "Only cp-1 runs kubeadm init."
  }

  assert {
    condition     = keys(module.cluster.instances) == ["cp-1", "worker-1", "worker-2"]
    error_message = "The cluster module should create one instance per node."
  }

  assert {
    condition     = !strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "taints: []")
    error_message = "With workers, the control plane keeps its default taint."
  }
}

run "three_control_planes_no_workers" {
  command = plan

  variables {
    control_plane_count = 3
    worker_count        = 0
  }

  assert {
    condition     = keys(local.nodes) == ["cp-1", "cp-2", "cp-3"]
    error_message = "Expected cp-1..cp-3 only."
  }

  assert {
    condition     = [for k in ["cp-1", "cp-2", "cp-3"] : local.nodes[k].index] == [0, 1, 2]
    error_message = "Control planes need distinct indexes so they land in distinct AZs."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/kubeadm-init.yaml.tmpl"], "taints: []")
    error_message = "With no workers the control plane must be schedulable (taints: [])."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-3"].files["/etc/kube-lab/cluster.env"], "PREVIOUS_CONTROL_PLANE=cp-2\n")
    error_message = "cp-3 must wait for cp-2 so etcd learners join one at a time."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-2"].files["/etc/kube-lab/kubeadm-join.yaml.tmpl"], "controlPlane:")
    error_message = "cp-2 must join as a control plane."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-2"].files["/etc/kube-lab/kubeadm-join.yaml.tmpl"], "taints: []")
    error_message = "With no workers, joining control planes must be schedulable too (taints: [])."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "EXPECTED_NODES=3\n")
    error_message = "cp-1 must wait for all three nodes."
  }
}

run "control_planes_keep_taint_with_workers" {
  command = plan

  variables {
    control_plane_count = 3
  }

  assert {
    condition = alltrue([
      for k in ["cp-2", "cp-3", "worker-1"] :
      !strcontains(module.cluster.bootstrap[k].files["/etc/kube-lab/kubeadm-join.yaml.tmpl"], "taints:")
    ])
    error_message = "With workers, joining nodes keep kubeadm's default taints."
  }
}

run "scaling_workers_keeps_existing_keys" {
  command = plan

  variables {
    worker_count = 4
  }

  assert {
    condition     = keys(local.nodes) == ["cp-1", "worker-1", "worker-2", "worker-3", "worker-4"]
    error_message = "Scaling up must only append worker keys."
  }

  assert {
    condition     = local.nodes["worker-4"].index % 3 == 0
    error_message = "worker-4 should land in the first AZ (index 3 % 3 == 0)."
  }
}
