# Configuration

You configure kube-lab in `terraform.tfvars`, which `cp terraform.tfvars.example
terraform.tfvars` creates. Only `operator_cidrs` is required. Every other variable has a
default that builds the cluster described in the README.

## When a change takes effect

The nodes read most settings once, when they are created. Terraform ignores changes to a
node's user data after that, on purpose: rebuilding a node because a setting changed could
wipe etcd. So the "Takes effect" column below matters.

| Takes effect | What happens when you change the value and run `terraform apply` |
|---|---|
| Now | Terraform updates the AWS resources in place. |
| Now, restarts nodes | Terraform stops each node, changes it and starts it again. With one control plane, the API is down while cp-1 restarts. If the new type isn't offered in every AZ the cluster uses, the plan replaces subnets and nodes instead, so read the plan before you confirm. |
| Now, with care | Raising the value is safe. Lowering it breaks etcd unless you follow [Operations](operations.md#remove-control-planes) first. |
| New nodes | Existing nodes keep the old value. Only nodes you add or replace later get the new one. |
| New cluster | Only used while the cluster is being created. To change it, destroy the cluster and create a new one. |
| Destroy first | Changing it replaces every resource and loses track of the old ones. Run `terraform destroy`, change the value, then apply. |
| When cp-1 is created | Runs once, while the cluster is being created. |

Watch out for `k8s_version`. It is "New nodes", not an upgrade switch. If you raise it on a
running cluster and then add a worker, that worker installs a newer kubelet than the control
plane runs, which the Kubernetes version skew policy doesn't allow. Upgrade with
[the upgrade lab](labs/upgrade.md), then set `k8s_version` to the version you upgraded to.

## Cluster settings

| Variable | Default | Takes effect | Description |
|---|---|---|---|
| `ami_id` | `null` | New nodes | AMI for every node. Null uses the latest Canonical Ubuntu 24.04 amd64 image. Only used when a node is created. |
| `cni` | `"calico"` | New cluster | Network plugin: calico (the default, tested on 1.36 and 1.37) or cilium. Installed once, when the cluster is created. |
| `control_plane_count` | `1` | Now, with care | Number of control-plane nodes: 1, 3, 5 or 7 (odd, so etcd keeps quorum). Read docs/operations.md before you lower it on a running cluster. |
| `control_plane_instance_type` | `"t3.medium"` | Now, restarts nodes | EC2 instance type for control-plane nodes. Must be x86_64; kubeadm needs at least 2 vCPUs and 2 GiB of memory. |
| `helm_enabled` | `false` | New nodes | Install the Helm CLI on the control planes, for root, with bash completion. If the download fails, the node reports `failed:helm`. [Add-ons](addons.md#use-helm) shows how to use it. |
| `name_prefix` | `"kube-lab"` | Destroy first | Prefix for the cluster name. A random 4-character suffix is added, for example kube-lab-a1b2. |
| `operator_cidrs` | required | Now | Public IPv4 CIDRs allowed to reach the Kubernetes API, for example ["203.0.113.10/32"]. Each prefix must be /8 or longer. |
| `pod_cidr` | `"192.168.0.0/16"` | New cluster | Pod network CIDR (kubeadm podSubnet), used by both Calico and Cilium. Only used when the cluster is created. |
| `region` | `"us-east-1"` | Destroy first | AWS region to create the cluster in. |
| `root_volume_size` | `30` | Now | Root EBS volume size in GiB for every node, at least 20. EBS volumes can grow but not shrink. The filesystem grows at the next reboot. |
| `service_cidr` | `"10.96.0.0/12"` | New cluster | Service CIDR (kubeadm serviceSubnet). Only used when the cluster is created. |
| `single_nat_gateway` | `true` | Now | Use one NAT gateway for all AZs (cheaper). Set false for one per AZ. |
| `tags` | `{}` | Now | Extra tags applied to every AWS resource. |
| `vpc_cidr` | `"10.10.0.0/16"` | Destroy first | VPC CIDR with a prefix length of 16 or less (for example /16 or /15). Must not overlap pod_cidr or service_cidr; kubeadm's default service range is 10.96.0.0/12. |
| `wait_for_cluster` | `false` | When cp-1 is created | Make terraform apply wait until the cluster reports ready. Runs scripts/wait-for-cluster.sh on your machine, once, when cp-1 is created. |
| `worker_count` | `2` | Now | Number of worker nodes, from 0 to 20. With 0, workloads run on the control planes. |
| `worker_instance_type` | `"t3.medium"` | Now, restarts nodes | EC2 instance type for worker nodes. Must be x86_64. |

## Software versions and checksums

Every download the nodes make is pinned to a version and checked against a sha256 or an image
digest. Checksums are shortened here; `variables.tf` has the full values.
[CONTRIBUTING.md](../CONTRIBUTING.md#bump-a-version) explains how to bump them.

| Variable | Default | Takes effect | Description |
|---|---|---|---|
| `aws_cli_sha256` | `ae55fa4a…c548` | New nodes | sha256 of awscli-exe-linux-x86_64-<aws_cli_version>.zip from awscli.amazonaws.com. |
| `aws_cli_version` | `"2.38.3"` | New nodes | AWS CLI v2 version the nodes install, without a leading v (for example 2.38.3). The nodes use it to report their status. |
| `calico_crds_sha256` | `5306c2c6…26bd` | New cluster | sha256 of Calico's v3_projectcalico_org.yaml for calico_version. |
| `calico_operator_sha256` | `aef423b3…88ba` | New cluster | sha256 of Calico's tigera-operator.yaml for calico_version. |
| `calico_version` | `"v3.33.0"` | New cluster | Calico release tag, with the leading v (for example v3.33.0). |
| `cilium_cli_sha256` | `24e817dc…7f61` | New cluster | sha256 of cilium-linux-amd64.tar.gz for cilium_cli_version. |
| `cilium_cli_version` | `"v0.20.1"` | New cluster | cilium-cli release tag used to install Cilium, with the leading v (for example v0.20.1). |
| `cilium_version` | `"1.20.3"` | New cluster | Cilium Helm chart version, without a leading v (for example 1.20.3). |
| `containerd_version` | `"2.3.*"` | New nodes | Version of the containerd.io package from Docker's apt repository. Accepts an apt pattern such as 2.3.*. |
| `csr_approver_digest` | `sha256:6469ef51…7818` | New cluster | Image index digest of ghcr.io/postfinance/kubelet-csr-approver for csr_approver_version. |
| `csr_approver_version` | `"v1.2.15"` | New cluster | kubelet-csr-approver release tag, with the leading v. It approves the kubelets' serving certificates. |
| `helm_sha256` | `896cf636…a0ea` | New nodes | sha256 of helm-<helm_version>-linux-amd64.tar.gz from get.helm.sh. |
| `helm_version` | `"v3.22.1"` | New nodes | Helm release tag, with the leading v (for example v3.22.1). |
| `k8s_version` | `"1.36.5"` | New nodes | Kubernetes version the nodes install (kubeadm, kubelet, kubectl and the control plane). Only used when a node is created; to upgrade a running cluster, follow docs/labs/upgrade.md. |

## Examples

A highly available control plane. Three control planes are the smallest layout that survives
losing one:

```hcl
operator_cidrs      = ["203.0.113.10/32"]
control_plane_count = 3
```

Cilium instead of Calico. Use Calico if you plan to do the upgrade lab, because Cilium 1.20
isn't tested on Kubernetes 1.37:

```hcl
operator_cidrs = ["203.0.113.10/32"]
cni            = "cilium"
```

The cheapest layout, a single node that runs your workloads too:

```hcl
operator_cidrs = ["203.0.113.10/32"]
worker_count   = 0
```

A different region. Pick it before you create the cluster:

```hcl
operator_cidrs = ["203.0.113.10/32"]
region         = "eu-west-1"
```
