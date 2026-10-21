# kube-lab

kube-lab builds a plain kubeadm cluster on AWS for practice. One `terraform apply`
gives you Kubernetes 1.36.5 with one control plane, two workers and Calico.
A few minutes after `terraform apply` finishes, every node is `Ready`, and the cluster is yours
to upgrade, back up, break and harden.

Run `terraform destroy` when you finish a session. It's built for learning, not
for production.

The nodes run in private subnets, with no public IPs and no SSH.
[Architecture](docs/architecture.md) explains the full picture.

## Before you start

- An AWS account you can experiment in. An admin role in a sandbox account is the easy path.
- Terraform 1.11 or later, and the AWS CLI v2, signed in: `aws sts get-caller-identity` should
  print your account.
- kubectl 1.35, 1.36 or 1.37, within one minor version of the cluster.
- For a shell on the nodes, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
  On macOS: `brew install --cask session-manager-plugin`.

With a narrower role than admin, `terraform apply` needs the permissions listed in
[AWS permissions](docs/architecture.md#aws-permissions). The helper scripts and node shells
need `ssm:GetParameter`, `ssm:GetParametersByPath`, `ssm:StartSession`,
`ssm:TerminateSession` and `ssm:ResumeSession`, plus `ssm:GetParameterHistory` for
`wait-for-cluster.sh --history`.

## Create the cluster

Copy the example settings, then open `terraform.tfvars` and set `operator_cidrs` to your public
IPv4 address as a `/32`. Only that address can reach the Kubernetes API.

```bash
cp terraform.tfvars.example terraform.tfvars
curl -4 -s https://checkip.amazonaws.com
terraform init
terraform apply
```

Terraform finishes before Kubernetes does. The nodes install Kubernetes on first boot, which
usually takes 4 to 6 minutes after `terraform apply` finishes, a little longer with three
control planes. Until then, every plan and apply ends with a warning that the cluster isn't
ready yet, and `terraform output next_steps` prints the commands below with your cluster's
name filled in.

This script shows the nodes' progress and returns when the cluster is ready or a node fails
(output abridged):

```bash
./scripts/wait-for-cluster.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)"
```

```text
Waiting for kube-lab-a1b2 in us-east-1 (up to 40 min)...
12:02:04 cluster=pending cp-1=pending worker-1=pending worker-2=pending
12:03:10 cluster=pending cp-1=initializing worker-1=waiting worker-2=waiting
12:04:20 cluster=installing cp-1=initialized worker-1=joining worker-2=joined
12:05:50 cluster=ready cp-1=joined worker-1=joined worker-2=joined
Cluster is ready. Point kubectl at it with:
  eval "$(./scripts/get-kubeconfig.sh kube-lab-a1b2 us-east-1)"
```

Now fetch the admin kubeconfig:

```bash
eval "$(./scripts/get-kubeconfig.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)")"
kubectl get nodes
```

Keep the `eval "$(...)"` around the script. The script saves the kubeconfig to
`~/.kube/<cluster>.yaml` and prints an `export KUBECONFIG=...` line, and `eval` runs that line
in your shell. A script can't change your shell's environment by itself, so if you run it
without `eval`, `KUBECONFIG` stays unset and the script prints the commands to copy instead.
Run the `eval` line again in every new terminal.

To make `terraform apply` itself wait for the cluster, set `wait_for_cluster = true`.

## Use the cluster

Use kubectl as with any cluster. For a shell on a node, copy its command from
`terraform output ssm_session_commands`, then run `sudo -i`. On the control planes, root has
kubectl set up, with the `k` alias and completion.

The cluster comes with only a network plugin and kubelet-csr-approver. A few things a cloud
cluster would give you are missing, and each makes a good exercise. There is no metrics-server,
so `kubectl top` doesn't work until you install it. With no cloud controller, Services of type
`LoadBalancer` stay `<pending>`, so use `NodePort` or `kubectl port-forward`. With no
StorageClass, a PersistentVolumeClaim stays `Pending` until you create a PersistentVolume for
it. There is no ingress controller. [Add-ons](docs/addons.md) shows how to install
metrics-server and other components, with or without Helm.

## Practice labs

- [Upgrade from 1.36 to 1.37](docs/labs/upgrade.md) with kubeadm, node by node.
- [Back up and restore etcd](docs/labs/etcd.md), and watch an HA cluster lose quorum.
- [Harden the cluster](docs/labs/cks.md) the way the CKS exam expects.

## Change the cluster

Most settings only take effect when a node is created. Changing `k8s_version` or `cni` on a
running cluster upgrades nothing; only nodes you add later see the new value.
[Configuration](docs/configuration.md) lists when each setting takes effect.

To add workers, raise `worker_count` and run `terraform apply`. Before you remove or replace
nodes, or lower `control_plane_count`, read [Operations](docs/operations.md). Removing a
control plane without first removing its etcd member breaks quorum and takes the API down.

## Destroy the cluster

```bash
rm -f ~/.kube/"$(terraform output -raw cluster_name)".yaml && unset KUBECONFIG
terraform destroy                           # about 5 minutes
```

## When something goes wrong

1. Read the status line from `wait-for-cluster.sh`, or print it once with the command from
   `terraform output status_command`. A value that starts with `failed:` names the step that
   failed. If the script can't read the cluster's status at all, it prints the AWS
   CLI's error and stops: check your credentials and the region.
2. Open a shell on the failed node and read its log:
   `sudo less /var/log/kube-lab-bootstrap.log`.
3. Look the step up in [Troubleshooting](docs/troubleshooting.md).

If kubectl times out from your machine, your public IP has probably changed. Update
`operator_cidrs` and run `terraform apply`.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers the checks, the tests and how to bump versions.
