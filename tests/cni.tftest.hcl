# CNI selection. Both installers live in control-plane.sh, so these tests check what
# actually changes with var.cni: the CNI= line in cluster.env and which manifests ship.
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

run "calico_is_the_default" {
  command = plan

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "\nCNI=calico\n")
    error_message = "cluster.env must select Calico by default."
  }

  assert {
    condition     = contains(keys(module.cluster.bootstrap["cp-1"].files), "/etc/kube-lab/calico-installation.yaml")
    error_message = "cp-1 must receive the Calico Installation resource."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/calico-installation.yaml"], "encapsulation: VXLAN\n")
    error_message = "Calico must use always-on VXLAN (EC2 source/destination checks stay enabled)."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/calico-installation.yaml"], "cidr: 192.168.0.0/16\n")
    error_message = "The Calico IP pool must match pod_cidr."
  }
}

run "cilium_when_selected" {
  command = plan

  variables {
    cni = "cilium"
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "\nCNI=cilium\n")
    error_message = "cluster.env must select Cilium."
  }

  assert {
    condition     = strcontains(module.cluster.bootstrap["cp-1"].files["/etc/kube-lab/cluster.env"], "\nCILIUM_VERSION=1.20.3\n")
    error_message = "cluster.env must carry the pinned Cilium version."
  }

  assert {
    condition     = !contains(keys(module.cluster.bootstrap["cp-1"].files), "/etc/kube-lab/calico-installation.yaml")
    error_message = "The Calico Installation resource must not ship when Cilium is selected."
  }
}

run "only_cp1_receives_cni_manifests" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["worker-1", "worker-2"] :
      !contains(keys(module.cluster.bootstrap[k].files), "/etc/kube-lab/calico-installation.yaml")
    ])
    error_message = "Only cp-1 installs the CNI, so only cp-1 receives its manifests."
  }
}
