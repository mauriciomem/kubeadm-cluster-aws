# kube-lab

kube-lab builds a plain kubeadm cluster on AWS for practice. One `terraform apply`
gives you Kubernetes 1.36.5 with one control plane, two workers and Calico.
A few minutes after `terraform apply` finishes, every node is `Ready`, and the cluster is yours
to upgrade, back up, break and harden.

Run `terraform destroy` when you finish a session. It's built for learning, not
for production.

The nodes run in private subnets, with no public IPs and no SSH. Some security choices favor a
simple lab over a hardened one; [Architecture](docs/architecture.md#security-trade-offs) lists
them and explains the full picture.

## Before you start

- An AWS account you can experiment in. An admin role in a sandbox account is the easy path.
  With a narrower role, see [AWS permissions](docs/architecture.md#aws-permissions).
- Terraform 1.11 or later, and the AWS CLI v2, signed in: `aws sts get-caller-identity` should
  print your account.
- kubectl 1.35, 1.36 or 1.37, within one minor version of the cluster.
- For a shell on the nodes, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
  On macOS: `brew install --cask session-manager-plugin`.

## Create the cluster

Copy the example settings. Then open `terraform.tfvars` and set `operator_cidrs` to your public
IPv4 address as a `/32`, which the `curl` line prints. Only that address can reach the
Kubernetes API.

```bash
cp terraform.tfvars.example terraform.tfvars
curl -4 -s https://checkip.amazonaws.com
terraform init
terraform apply
```

Terraform finishes before Kubernetes does. The nodes install Kubernetes on first boot, which
takes 4 to 6 minutes after `terraform apply` returns, a little longer with three control
planes. `terraform output next_steps` prints the commands below with your cluster's name filled
in.

1. Follow the bootstrap. The script prints a status line whenever a node moves on, and returns
   when the cluster is ready or a node fails:

   ```bash
   ./scripts/wait-for-cluster.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)"
   ```

   ```text
   Waiting for kube-lab-a1b2 in us-east-1 (up to 40 min)...
   12:02:04 cluster=pending cp-1=pending worker-1=pending worker-2=pending
   12:03:10 cluster=pending cp-1=initializing worker-1=waiting worker-2=waiting
   12:03:40 cluster=installing cp-1=initialized worker-1=waiting worker-2=waiting
   The API is up. Fetch the kubeconfig now; the nodes turn Ready as the network plugin starts:
     eval "$(./scripts/get-kubeconfig.sh kube-lab-a1b2 us-east-1)"
   Still waiting for the cluster to report ready...
   12:04:20 cluster=installing cp-1=initialized worker-1=joining worker-2=joined
   12:05:50 cluster=ready cp-1=joined worker-1=joined worker-2=joined
   Cluster is ready. Point kubectl at it with:
     eval "$(./scripts/get-kubeconfig.sh kube-lab-a1b2 us-east-1)"
   ```

2. When it prints "The API is up", open a second terminal in this directory and run the
   `eval` line it shows. The script saves the admin kubeconfig to `~/.kube/<cluster>.yaml` and
   prints an `export KUBECONFIG=...` line, which `eval` runs in your shell. Without `eval`, the
   file is still written, but `KUBECONFIG` stays unset: a script can't change your shell's
   environment. The script then reminds you to run the `export` line yourself. Run the `eval`
   line again in every new terminal.

3. Watch the nodes join:

   ```bash
   kubectl get nodes -w
   ```

   Each node shows up as `NotReady` and turns `Ready` once the network plugin runs on it.

4. Back in the first terminal, the script ends with "Cluster is ready." The cluster is yours.

Until the cluster is ready, every `terraform plan` and `terraform apply` ends with a warning
that says so. To make `terraform apply` itself wait, set `wait_for_cluster = true`; the apply
output then shows the same lines.

## Use the cluster

Use kubectl as with any cluster. For a shell on a node, copy its command from
`terraform output ssm_session_commands`, then run `sudo -i`. On the control planes, root has
kubectl set up, with the `k` alias and completion.

The cluster comes with only a network plugin and kubelet-csr-approver. Some things a cloud
cluster gives you are missing, and each one makes a good exercise:

- No metrics-server, so `kubectl top` doesn't work until you install it.
- No cloud controller, so Services of type `LoadBalancer` stay `<pending>`. Use `NodePort` or
  `kubectl port-forward`.
- No StorageClass, so a PersistentVolumeClaim stays `Pending` until you create a
  PersistentVolume for it.
- No ingress controller.

[Add-ons](docs/addons.md) shows how to install them, with or without Helm.

## Practice labs

- [Upgrade from 1.36 to 1.37](docs/labs/upgrade.md) with kubeadm, node by node.
- [Back up and restore etcd](docs/labs/etcd.md), and watch an HA cluster lose quorum.
- [Harden the cluster](docs/labs/cks.md) the way the CKS exam expects.

## Change the cluster

Most settings only take effect when a node is created. Changing `k8s_version` or `cni` on a
running cluster upgrades nothing; only nodes you add later see the new value.
[Configuration](docs/configuration.md) lists when each setting takes effect.

To add workers, raise `worker_count` and run `terraform apply`. Before you remove or replace
nodes, or lower `control_plane_count`, read [Operations](docs/operations.md). A control plane
removed without first removing its etcd member can cost etcd its quorum and take the API down.

## Destroy the cluster

```bash
rm -f ~/.kube/"$(terraform output -raw cluster_name)".yaml && unset KUBECONFIG
terraform destroy                           # about 5 minutes
```

## When something goes wrong

1. Read the status line from `wait-for-cluster.sh`, or print it once with the command from
   `terraform output status_command`. A value such as `failed:join` names the node and the
   step that failed.
2. Open a shell on that node and read its log:
   `sudo less /var/log/kube-lab-bootstrap.log`.
3. Look the step up in [Troubleshooting](docs/troubleshooting.md).

If kubectl times out from your machine, your public IP has probably changed. Update
`operator_cidrs` and run `terraform apply`.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers the checks, the tests and how to bump versions.
