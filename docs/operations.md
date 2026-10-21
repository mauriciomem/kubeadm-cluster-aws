# Operations

How to reach, resize and repair a running cluster. The commands assume you run them from the
repository root, where `terraform output` works. On a node, run them as root after `sudo -i`.

In the examples, `<cluster>` is your cluster name and `<region>` its AWS region. Print them with:

```bash
terraform output -raw cluster_name
terraform output -raw region
```

## Get the kubeconfig again

```bash
eval "$(./scripts/get-kubeconfig.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)")"
```

This downloads the admin kubeconfig from SSM to `~/.kube/<cluster>.yaml` and sets
`KUBECONFIG` for the current shell. Run it in every new terminal, or point `KUBECONFIG` at the
file yourself. Without `eval`, the script can't set `KUBECONFIG`, so it prints the commands to
copy instead.

## Status parameters on a cluster created before they became Strings

Status parameters are plain `String` parameters (they used to be `SecureString`). On a cluster
created before that change, the next `terraform apply` converts them and resets them to
`pending`, and the `cluster_ready` check then warns that the cluster isn't ready. The cluster
itself is unaffected. To show the real values again, write them back:

```bash
c=$(terraform output -raw cluster_name) r=$(terraform output -raw region)
aws ssm put-parameter --region "$r" --overwrite --name "/$c/status/cluster" --value ready
for n in $(terraform output -json nodes | jq -r 'keys[]'); do aws ssm put-parameter --region "$r" --overwrite --name "/$c/nodes/$n/status" --value joined; done
terraform apply -refresh-only
```

## Open a shell on a node

```bash
terraform output ssm_session_commands
aws ssm start-session --region <region> --target <instance-id>    # copy from the output
sudo -i
```

## Watch a node that joins later

`wait-for-cluster.sh` only follows the first bootstrap. It returns at once after you scale out,
because the cluster status already says `ready`. Watch the new node instead:

```bash
kubectl get nodes -w
```

Or read its status parameter. For a while it can still show the value from an earlier node
with the same name, until the new node has installed the AWS CLI:

```bash
aws ssm get-parameter --region "$(terraform output -raw region)" \
  --name "$(terraform output -raw ssm_parameter_prefix)/nodes/worker-3/status" \
  --with-decryption --query Parameter.Value --output text
```

## Add workers

Raise `worker_count` in `terraform.tfvars` and run `terraform apply`. Terraform adds the next
names (`worker-3`, `worker-4`) and leaves the existing nodes alone. The new workers join with
the token that cp-1 refreshes every 12 hours, so you can add them at any time.

## Remove workers

Terraform always removes the highest-numbered workers. Drain and delete them in Kubernetes
first, so their pods move elsewhere and no `NotReady` node is left behind:

```bash
kubectl drain worker-3 --ignore-daemonsets --delete-emptydir-data
kubectl delete node worker-3
```

Then lower `worker_count` and run `terraform apply`.

## Add control planes

Keep the count odd: go from 1 to 3, or from 3 to 5. The new control planes download the
control-plane certificates that kubeadm uploads to the cluster, and kubeadm deletes them two
hours after the upload. If the cluster is older than two hours, upload them again on cp-1 first:

```bash
sudo kube-lab-refresh-join --upload-certs
```

Then raise `control_plane_count` and run `terraform apply` within two hours. The new control
planes join one at a time, so each one adds a few minutes.

## Remove control planes

Lowering `control_plane_count` without preparation takes the cluster down. Each control plane
runs an etcd member, and etcd needs a majority of its members (a quorum) to work: 2 of 3, or
3 of 5. Terraform deletes the instances, but nothing removes their members from etcd. Go from 3
to 1 that way and etcd still counts 3 members with only 1 alive. It loses quorum, and the API
server stops answering.

So remove the etcd members first, one control plane at a time, starting with the highest
number. Terraform removes those first. To go from 3 control planes to 1:

1. Drain cp-3 from your machine:

   ```bash
   kubectl drain cp-3 --ignore-daemonsets --delete-emptydir-data
   ```

2. In a shell on cp-3, reset it. On a control plane, `kubeadm reset` also removes the node's
   etcd member:

   ```bash
   sudo kubeadm reset -f
   ```

3. Delete the node from your machine:

   ```bash
   kubectl delete node cp-3
   ```

4. Check that etcd now has 2 members (see [Inspect etcd members](#inspect-etcd-members)).
5. Repeat steps 1 to 4 for cp-2. With 2 members etcd needs both, so finish cp-2 promptly.
6. Set `control_plane_count = 1` and run `terraform apply`.

You can't remove cp-1. It always stays in the node list.

## Inspect etcd members

etcdctl isn't installed on the nodes (installing it is part of the [etcd lab](labs/etcd.md)),
but the etcd container image has it. Run it inside cp-1's etcd pod:

```bash
kubectl -n kube-system exec etcd-cp-1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

If a control plane's instance is already gone and you couldn't run `kubeadm reset` on it,
remove its member by ID with the same command, ending in `member remove <ID>` instead of
`member list -w table`. This only works while etcd still has quorum, because removing a member
is itself a change that a majority must agree to. If quorum is already lost, the way back is
the restore in the [etcd lab](labs/etcd.md#restore-the-snapshot), or a new cluster.

## Replace a worker

Terraform doesn't rebuild nodes when the AMI or the bootstrap scripts change, so you rebuild
one on purpose:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
kubectl delete node worker-1
terraform apply -replace='module.cluster.aws_instance.node["worker-1"]'
```

## Replace a control plane

For cp-2 and higher, remove the old etcd member before the new instance joins:

1. Drain the node, run `sudo kubeadm reset -f` on it, and delete it, as in
   [Remove control planes](#remove-control-planes). If the instance is broken, remove its etcd
   member with `etcdctl member remove` instead (see [Inspect etcd members](#inspect-etcd-members)).
2. On cp-1, upload fresh control-plane certificates:

   ```bash
   sudo kube-lab-refresh-join --upload-certs
   ```

3. Within two hours, replace the instance:

   ```bash
   terraform apply -replace='module.cluster.aws_instance.node["cp-2"]'
   ```

You can't replace cp-1. It holds the cluster's certificate authority and the first etcd member,
and the other nodes depend on what it publishes. To start over, destroy the cluster and create a
new one.

## Join tokens

`kube-lab-refresh-join.timer` on cp-1 creates a new 24-hour join token every 12 hours and
publishes it to SSM. It also runs five minutes after every boot, so a cluster you stopped for
more than a day gets a valid token again right away. To publish a token now, run
`sudo kube-lab-refresh-join` on cp-1. `systemctl list-timers kube-lab-refresh-join.timer` shows
when it runs next.

## Your IP address changed

When you change networks or turn a VPN on or off, kubectl starts timing out. Put your new
address in `operator_cidrs` and run `terraform apply`. Only the load balancer's security group
changes.

## Destroy and clean up

```bash
rm -f ~/.kube/"$(terraform output -raw cluster_name)".yaml
unset KUBECONFIG
terraform destroy
```

`terraform destroy` deletes every AWS resource, including the SSM parameters. Remove the local
kubeconfig first, while `terraform output` still knows the cluster name.
