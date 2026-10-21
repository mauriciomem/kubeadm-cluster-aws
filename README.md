# kube-lab

kube-lab builds a plain kubeadm cluster on AWS for practice. One `terraform apply`
gives you Kubernetes 1.36.5 with one control plane, two workers and Calico.
A few minutes after `terraform apply` finishes, every node is `Ready`, and the cluster is yours
to upgrade, back up, break and harden.

Run `terraform destroy` when you finish a session. It's built for learning, not
for production.

The nodes run in private subnets, with no public IPs and no SSH. Some choices favor a simple
lab over a hardened one; [Architecture](docs/architecture.md#security-trade-offs) lists them.

## Before you start

- An AWS account to experiment in, ideally a sandbox with an admin role
  ([narrower permissions](docs/architecture.md#aws-permissions)).
- Terraform 1.11 or later, and the AWS CLI v2, signed in.
- kubectl within one minor version of the cluster.
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
  for a shell on the nodes.

## Create the cluster

Copy the example settings and set `operator_cidrs` in `terraform.tfvars` to your public IPv4
address as a `/32`. The `curl` line prints it. Only that address can reach the API.

```bash
cp terraform.tfvars.example terraform.tfvars
curl -4 -s https://checkip.amazonaws.com
terraform init
terraform apply
```

The apply takes about 3.5 minutes. The nodes then install Kubernetes on first boot. Follow
them with:

```bash
./scripts/wait-for-cluster.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)"
```

When it prints "The API is up", about 2.5 minutes later, open a second terminal and run the
`eval` line it shows, such as the first line below. Then watch the nodes turn `Ready`:

```bash
eval "$(./scripts/get-kubeconfig.sh kube-lab-a1b2 us-east-1)"
kubectl get nodes -w
```

The `eval` sets `KUBECONFIG` in your shell, so run it again in every new terminal.
[Operations](docs/operations.md#point-kubectl-at-the-cluster) explains why.

The first terminal ends with "Cluster is ready." `terraform output next_steps` prints these
commands with your cluster's name filled in.

## Next

- Labs: [upgrade to 1.37](docs/labs/upgrade.md), [back up and restore etcd](docs/labs/etcd.md),
  [harden the cluster](docs/labs/cks.md).
- [Add-ons](docs/addons.md): Helm, metrics-server, storage, and what the cluster leaves out.
- [Operations](docs/operations.md): node shells, scaling, replacing nodes, costs.
- [Troubleshooting](docs/troubleshooting.md): what each status means when a node fails.
- [Configuration](docs/configuration.md): which settings change a running cluster.
- [Architecture](docs/architecture.md): how the pieces fit together.

## Destroy the cluster

```bash
rm -f ~/.kube/"$(terraform output -raw cluster_name)".yaml && unset KUBECONFIG
terraform destroy
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
