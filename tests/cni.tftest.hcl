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

run "calico_by_default" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "CNI=calico")
    error_message = "Calico must be the default CNI."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "tigera-operator.yaml")
    error_message = "cp-1 must install Calico through the Tigera operator."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/calico-installation.yaml"], "encapsulation: VXLAN\n")
    error_message = "Calico must use always-on VXLAN (EC2 source/destination checks stay enabled)."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/calico-installation.yaml"], "cidr: 192.168.0.0/16")
    error_message = "Calico IP pool must match pod_cidr."
  }
}

run "cilium_when_selected" {
  command = plan

  variables {
    cni = "cilium"
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "CNI=cilium\n")
    error_message = "cluster.env must select Cilium."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "CILIUM_VERSION=1.20.3\n")
    error_message = "Cilium version must be pinned to 1.20.3."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].script, "--set ipam.mode=kubernetes")
    error_message = "Cilium must use kubernetes IPAM so it follows pod_cidr."
  }

  assert {
    condition     = !contains(keys(module.cluster.bootstrap["cp-1"].files), "/etc/kube-lab/calico-installation.yaml")
    error_message = "The Calico Installation CR must not ship when Cilium is selected."
  }
}
