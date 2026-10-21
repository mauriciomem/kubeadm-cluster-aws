# Operations

This page shows how to reach, resize and repair a running cluster. Run the commands from the
repository root, where `terraform output` works. On a node, run them as root after `sudo -i`.

## Point kubectl at the cluster

```bash
eval "$(./scripts/get-kubeconfig.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)")"
```

The script saves the admin kubeconfig to `~/.kube/<cluster>.yaml` and prints an
`export KUBECONFIG=...` line, which `eval` runs in your shell. A script can't change your
shell's environment, so without `eval` the file is written but `KUBECONFIG` stays unset, and
the script reminds you to run the `export` line. Run the `eval` line in every new terminal.

The script exits with 1 when cp-1 hasn't published the kubeconfig yet. Wait until
`wait-for-cluster.sh` says "The API is up".

If kubectl starts timing out, your public IP has probably changed, for example after you
switch networks or VPNs. Put the new address in `operator_cidrs` and run `terraform apply`.

## Open a shell on a node

Copy the node's command from `terraform output ssm_session_commands`, run it, then `sudo -i`.
On the control planes, root has kubectl set up, with the `k` alias and completion.

## Wait for the bootstrap

`wait-for-cluster.sh` prints a status line, with the time in UTC, whenever a node moves on:

```text
Waiting for kube-lab-a1b2 in us-east-1 (up to 40 min)...
12:02:04Z cluster=pending cp-1=pending worker-1=pending worker-2=pending
12:04:30Z cluster=installing cp-1=initialized worker-1=waiting worker-2=waiting
The API is up. Fetch the kubeconfig now; the nodes turn Ready as the network plugin starts:
  eval "$(./scripts/get-kubeconfig.sh kube-lab-a1b2 us-east-1)"
Still waiting for the cluster to report ready...
12:05:30Z cluster=ready cp-1=joined worker-1=joined worker-2=joined
Cluster is ready. Point kubectl at it with:
  eval "$(./scripts/get-kubeconfig.sh kube-lab-a1b2 us-east-1)"
```

With the default settings, the API is up about 2.5 minutes after `terraform apply` returns,
and the cluster is ready about a minute later. Three control planes or Cilium take longer, up
to about 6 minutes. `--once` prints the statuses once, and `--history` shows when each one
changed. [Troubleshooting](troubleshooting.md#check-the-progress) covers both.

Until the cluster is ready, every `terraform plan` and `terraform apply` ends with a warning
that says so. To make `terraform apply` itself wait, set `wait_for_cluster = true`.

## Add workers

Raise `worker_count` and run `terraform apply`. Terraform adds `worker-3`, `worker-4` and so on,
and leaves the existing nodes alone. Run `wait-for-cluster.sh` again to follow them: the
cluster still says `ready`, but the script also waits until every node has joined.

A node you replace with `terraform apply -replace` keeps its old status parameter, which says
`joined` until the new node installs the AWS CLI. Wait 2 or 3 minutes before you run the
script, or it can say the cluster is ready too early.

## Remove workers

Terraform always removes the highest-numbered workers. Drain and delete them first:

```bash
kubectl drain worker-3 --ignore-daemonsets --delete-emptydir-data
kubectl delete node worker-3
```

Then lower `worker_count` and run `terraform apply`.

## Add control planes

Keep the count odd: go from 1 to 3, or from 3 to 5. New control planes download the
certificates kubeadm uploaded to the cluster, and kubeadm deletes those two hours after the
upload. If the cluster is older than that, upload them again on cp-1 first:

```bash
sudo kube-lab-refresh-join --upload-certs
```

Then raise `control_plane_count` and run `terraform apply` within two hours.

## Remove control planes

Each control plane runs an etcd member, and etcd needs a majority of its members to work.
Terraform deletes instances but doesn't remove their etcd members. Go from 3 to 1 that way and
etcd still counts 3 members with only 1 alive. It loses quorum, and the API stops answering.

So remove the members first, one control plane at a time, starting with the highest number.
To go from 3 to 1:

1. Drain cp-3: `kubectl drain cp-3 --ignore-daemonsets --delete-emptydir-data`.
2. In a shell on cp-3, run `sudo kubeadm reset -f`. On a control plane, this also removes its
   etcd member.
3. Delete the node: `kubectl delete node cp-3`.
4. Check that etcd now has 2 members (see [Inspect etcd members](#inspect-etcd-members)).
5. Repeat for cp-2 right away. With 2 members, etcd needs both.
6. Set `control_plane_count = 1` and run `terraform apply`.

You can't remove cp-1.

## Inspect etcd members

etcdctl isn't installed on the nodes, but the etcd image has it:

```bash
kubectl -n kube-system exec etcd-cp-1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

If a control plane's instance is already gone, remove its member with the same command, ending
in `member remove <ID>`. That only works while etcd still has quorum. If quorum is lost,
restore a snapshot as in the [etcd lab](labs/etcd.md#restore-the-snapshot), or start over.

## Replace a node

Terraform doesn't rebuild nodes when the AMI or the bootstrap changes, so you replace one on
purpose. For a worker:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
kubectl delete node worker-1
terraform apply -replace='module.cluster.aws_instance.node["worker-1"]'
```

For cp-2 or higher, remove it as in [Remove control planes](#remove-control-planes), run
`sudo kube-lab-refresh-join --upload-certs` on cp-1, then run `terraform apply -replace` within
two hours.

You can't replace cp-1. It holds the cluster's certificate authority and the first etcd
member. To start over, destroy the cluster and create a new one.

## Join tokens

A timer on cp-1 publishes a new 24-hour join token every 12 hours and five minutes after every
boot, so a cluster you stopped for a day gets a valid token again. To publish one now, run
`sudo kube-lab-refresh-join` on cp-1.

## Destroy the cluster

```bash
rm -f ~/.kube/"$(terraform output -raw cluster_name)".yaml && unset KUBECONFIG
terraform destroy
```

Remove the local kubeconfig first, while `terraform output` still knows the cluster name. The
destroy takes 2 to 4 minutes and deletes every AWS resource, including the SSM parameters.
Stopping the instances isn't enough to stop paying; see
[Layouts and costs](configuration.md#layouts-and-costs).
