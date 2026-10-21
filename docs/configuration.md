# Configuration

You configure kube-lab in `terraform.tfvars`. Only `operator_cidrs` is required.
`variables.tf` lists every setting with its default, its description and the rules it must
follow.

## When a change takes effect

The nodes read most settings once, when they are created. After that, Terraform ignores
changes to a node's user data on purpose: rebuilding a node because a setting changed could
wipe etcd. So check this list before you change a running cluster.

| Takes effect | Settings |
|---|---|
| Right away | `operator_cidrs`, `worker_count`, `root_volume_size`, `single_nat_gateway`, `tags` |
| Right away, restarts nodes | `control_plane_instance_type`, `worker_instance_type` |
| Right away, with care | `control_plane_count` |
| Only on nodes created later | `k8s_version`, `ami_id`, `containerd_version`, `helm_enabled`, and the AWS CLI and Helm pins |
| Only on a new cluster | `cni`, `pod_cidr`, `service_cidr`, and the Calico, Cilium and kubelet-csr-approver pins |
| Destroy first | `region`, `name_prefix`, `vpc_cidr` |
| Once, when cp-1 is created | `wait_for_cluster` |

A few of these need more care:

- A new instance type restarts each node, and with one control plane the API is down while
  cp-1 restarts. If the type isn't offered in every AZ the cluster uses, the plan replaces
  subnets and nodes instead, so read the plan first.
- Raising `control_plane_count` is safe. Lowering it breaks etcd unless you follow
  [Remove control planes](operations.md#remove-control-planes) first.
- `root_volume_size` can grow but not shrink. The filesystem grows at the next reboot.
- `k8s_version` is not an upgrade switch. If you raise it and then add a worker, that worker
  runs a newer kubelet than the control plane, which the version skew policy doesn't allow.
  Upgrade with [the upgrade lab](labs/upgrade.md), then set `k8s_version` to match.
- For "Destroy first" settings, run `terraform destroy`, change the value, then apply.
  Otherwise Terraform replaces everything and loses track of the old resources.

## Layouts and costs

The cluster bills by the hour until `terraform destroy` finishes. These are rough us-east-1
on-demand prices; check the AWS pricing pages before you rely on them.

| Layout | Settings | Per hour |
|---|---|---|
| Default: 1 control plane, 2 workers | | about $0.23 |
| Highly available, survives losing a control plane | `control_plane_count = 3` | about $0.32 |
| Single node that also runs your workloads | `worker_count = 0` | about $0.14 |
| One NAT gateway per AZ | `single_nat_gateway = false` | about $0.10 more |

The NAT gateway, the load balancer and their public IPv4 addresses make up about $0.09 of each
hour. They keep billing when you stop the instances, and so do the volumes, so stopping isn't
enough: destroy the cluster to stop paying.

For Cilium instead of Calico, set `cni = "cilium"`. Stay with Calico if you plan to do the
upgrade lab, because Cilium 1.20 isn't tested on Kubernetes 1.37.
