# Troubleshooting

Start with the status line that `wait-for-cluster.sh` prints. It tells you which node is stuck
and at which step. Then read that node's log. This page explains each status and what to do
about it.

## First steps

1. Print the statuses with `wait-for-cluster.sh`, or once with `--once` (see
   [Check the progress](#check-the-progress) below):

   ```bash
   ./scripts/wait-for-cluster.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)"
   ```

2. Open a shell on the node in question (`terraform output ssm_session_commands`) and become
   root with `sudo -i`. Most of the logs below need root.
3. Read the bootstrap log. Every line names the node and the step, and the last lines show what
   failed:

   ```bash
   less /var/log/kube-lab-bootstrap.log
   ```

4. If that isn't enough, look at cloud-init's own output, the kubelet and containerd, and the
   containers:

   ```bash
   less /var/log/cloud-init-output.log
   journalctl -u kubelet -u containerd --since "1 hour ago"
   crictl ps -a
   ```

### Run one command without an interactive shell

To grab a log from a script, or when an interactive session is awkward, run a single command
through Session Manager:

```bash
id=i-0123456789abcdef0    # the node's instance_id, from terraform output nodes
sleep 30 | aws ssm start-session --region "$(terraform output -raw region)" --target "$id" \
  --document-name AWS-StartNonInteractiveCommand \
  --parameters command="sudo tail -n 200 /var/log/kube-lab-bootstrap.log"
```

Three things to know:

- The session ends when its input closes, before the output arrives. `sleep 30 |` keeps it
  open; use a longer sleep for slower commands.
- No shell runs the command, so pipes, loops and `$VARIABLES` don't work on their own. Wrap
  them in `sudo bash -c '...'`.
- The AWS CLI rejects quotes inside `command=`. When the command needs them, put the
  parameters in a file, such as
  `{"command": ["sudo bash -c 'journalctl -u kubelet | tail -n 100'"]}` in `params.json`, and
  pass `--parameters file://params.json`.

## Check the progress

Each node writes its progress to an SSM parameter. You can read it in three ways.

### In Terraform

On the first plan, the `cluster_status` output shows `(known after apply)`, because the
parameters don't exist yet. From then on, every plan and apply ends with a warning until the
cluster is ready. While the nodes work, it reads:

```text
Cluster kube-lab-a1b2 is not ready yet: cluster=pending cp-1=bootstrapping worker-1=pending worker-2=pending. Follow it with: ./scripts/wait-for-cluster.sh kube-lab-a1b2 us-east-1
```

When a node fails, it names the node and the step:

```text
Bootstrap failed: worker-2 at step join. Read /var/log/kube-lab-bootstrap.log on that node (terraform output ssm_session_commands); docs/troubleshooting.md explains each step.
```

The warning never blocks a plan, an apply or a destroy. `terraform output cluster_status` shows
the same values as a map, but only as of the last `terraform apply` or
`terraform apply -refresh-only`: `terraform output` doesn't read them again.

When the plan also changes the cluster, for example when you add a worker, Terraform reads
the statuses only after the apply. The plan then shows them as `(known after apply)`, and
the warning appears at the end of the apply instead. While the nodes work, a plan that changes
nothing else can list `cluster_status` under "Changes to Outputs". That's the bootstrap moving
on, not a change you made.

Reading the statuses needs `ssm:GetParameter` on `/<cluster>/status/cluster` and
`/<cluster>/nodes/*/status`. Without it, the plan fails with `AccessDenied`.

### Once, from the script

`terraform output status_command` prints a command that reads the live values once:

```bash
./scripts/wait-for-cluster.sh --once kube-lab-a1b2 us-east-1
```

It exits with 0 when the cluster is ready, 1 when a node reports a failure, 4 while the
bootstrap is still running, 3 when the AWS CLI can't read the status, and 64 when the arguments
are wrong. That makes it easy to use in your own scripts.

### Until it finishes

Without `--once`, the script prints a line whenever a status changes, and repeats it every 2
minutes so a long step doesn't look hung. When the cluster reaches `installing`, it prints the
`get-kubeconfig.sh` line once: kubectl works from then on, and the nodes turn `Ready` as the
network plugin starts on them.

It exits with 0 when the cluster is ready, 1 when a node fails, 2 after 40 minutes without
either, and 3 when the AWS CLI can't read the status at the start. In that last case the AWS
CLI's own error, such as expired credentials or a cluster that doesn't exist in that region, is
printed above the script's message. If a read fails later, for example when your credentials
expire during the wait, the script shows the AWS CLI's error and keeps polling. `--help` shows
the usage.

### Afterward, with timings

`--history` shows every value each status parameter has had, with the time SSM recorded it.
The first value, `pending`, is Terraform creating the parameter (output abridged):

```text
status/cluster
  2026-10-21T12:00:00.123000+00:00	pending
  2026-10-21T12:03:50.456000+00:00	installing
  2026-10-21T12:05:50.789000+00:00	ready
nodes/worker-1/status
  2026-10-21T12:00:00.321000+00:00	pending
  2026-10-21T12:01:10.654000+00:00	bootstrapping
  2026-10-21T12:03:20.987000+00:00	waiting
  2026-10-21T12:04:10.111000+00:00	joining
  2026-10-21T12:05:05.222000+00:00	joined
```

It needs the `ssm:GetParameterHistory` permission. SSM keeps the last 100 versions of each
parameter, far more than one bootstrap writes.

## Status values

Each node reports one of these values:

| Value | Meaning | Typical time in this state |
|---|---|---|
| `pending` | The node hasn't installed the AWS CLI yet, so it can't report. | Under 1 minute after the node starts |
| `bootstrapping` | Preparing the host and installing packages. | 1 to 3 minutes |
| `initializing` | cp-1 runs `kubeadm init`. | About 1 minute |
| `initialized` | The API is up and the kubeconfig is published. cp-1 installs the network plugin and kubelet-csr-approver, then waits until every node is `Ready`. | 2 to 5 minutes; gives up after 30 |
| `waiting` | A joining node waits for the join token, the previous control plane and the API. | Until cp-1 is `initialized` |
| `joining` | `kubeadm join` runs. | 1 to 3 minutes |
| `joined` | Done. | |
| `failed:<step>` | The step failed. See below. | |

The cluster status has its own values, which only cp-1 writes:

| Value | Meaning |
|---|---|
| `pending` | cp-1 hasn't published the admin kubeconfig yet. |
| `installing` | The kubeconfig is published and kubectl works. cp-1 installs the add-ons and waits until every node is `Ready`. |
| `ready` | Every node is `Ready` and cp-1 has finished. |
| `failed:<step>` | cp-1 failed at that step. |

[Architecture](architecture.md#bootstrap-contract) shows the full sequence.

## Failed steps

A value such as `failed:packages` names the step that was running, and the log shows the
command that failed. The steps below are in the order they run.

| Step | Nodes | What it does | What to check |
|---|---|---|---|
| `awscli` | all | Downloads the AWS CLI v2 zip for `aws_cli_version` from awscli.amazonaws.com, checks it against `aws_cli_sha256` and installs it to `/usr/local/bin/aws` | The node can't report this failure, so it stays `pending`. Open a shell and read the log. The usual causes are no internet access through the NAT gateway, or a checksum mismatch after you changed `aws_cli_version` without `aws_cli_sha256`. |
| `host` | all | Turns off swap, loads kernel modules, sets sysctls | Read the log. This rarely fails. |
| `packages` | all | Installs containerd, kubeadm, kubelet and kubectl from the Docker and Kubernetes apt repositories | A repository or mirror was down, `containerd_version` matches no package, or an apt signing key changed. A key mismatch stops the bootstrap on purpose: check the new key's fingerprint against the Docker and Kubernetes install docs before you update `lib.sh`. |
| `containerd` | all | Writes `/etc/containerd/config.toml` (CRI on, systemd cgroups) and restarts containerd | `journalctl -u containerd`. |
| `shell` | all | Adds kubectl completion and the `k` alias for every user | Read the log. This rarely fails. |
| `helm` | control planes, with `helm_enabled` | Downloads and checks the Helm CLI, and writes its bash completion file, before `kubeadm init` or `join` | A checksum mismatch or a failed download is the usual cause. Every download is retried 5 times; an attempt stops after 10 minutes, or after a minute with almost no data. |
| `init` | cp-1 | Runs `kubeadm init` | `crictl ps -a` and `crictl logs <container-id>` for the control-plane containers, and `journalctl -u kubelet`. |
| `publish` | cp-1 | Writes the join token, CA hash, certificate key and admin kubeconfig to SSM | Look for `AccessDenied` in the log. A re-run skips `init` and creates a new token and certificate key. |
| `local-kubeconfig` | cp-1 | Writes a kubeconfig for the local API server to `/run/kube-lab`, which the add-on steps use | The log shows whether the instance metadata lookup or the copy failed. |
| `cni` | cp-1 | Installs Calico or Cilium and waits up to 15 minutes for it | Calico: `kubectl get tigerastatus` and `kubectl -n tigera-operator logs deploy/tigera-operator`. Cilium: `kubectl -n kube-system get pods -l k8s-app=cilium` and the cilium-operator pods. `cilium status` only works once the kubelets' serving certificates are approved, normally within a minute of the bootstrap. A checksum mismatch in the log means the pinned sha256 doesn't match the download. If `kubectl logs` fails with `tls: internal error`, see [below](#kubectl-logs-or-exec-fails-with-tls-internal-error). |
| `csr-approver` | cp-1 | Applies kubelet-csr-approver | Read the log; the API server must be reachable on cp-1. |
| `refresh-timer` | cp-1 | Enables the join-token refresh timer | `systemctl status kube-lab-refresh-join.timer`. |
| `wait-nodes` | cp-1 | Waits up to 30 minutes for every node to be `Ready`, then restarts CoreDNS so its two replicas spread across nodes | `kubectl get nodes`, then the status and log of the node that isn't `Ready`. |
| `join` | joining nodes | Waits for the join token and the previous control plane (40 minutes each) and for the API (15 minutes), checking every 10 seconds, then runs `kubeadm join` | The log says what it was waiting for. Waiting on the token: check cp-1. Waiting on the API: check the load balancer (below). `kubeadm join` itself failed: `journalctl -u kubelet`. |
| `root-kubeconfig` | control planes | Copies `admin.conf` to `/root/.kube/config`, so `sudo -i` gives you a working kubectl | Check that `/etc/kubernetes/admin.conf` exists. |

## Run the bootstrap again

After you fix the cause, run the bootstrap again on the node. It skips every step that already
finished. If `kubeadm init` or `kubeadm join` failed halfway, reset the node first:

```bash
sudo kubeadm reset -f                                  # only after a failed init or join
sudo bash /var/lib/cloud/instance/scripts/worker.sh    # or control-plane.sh
```

Each finished step leaves a marker in `/var/lib/kube-lab/`, such as `packages.done`. Delete a
marker to make that step run again. `local-kubeconfig` and `root-kubeconfig` have no marker:
they are quick and run every time.

If cp-1 fails at `init` and a reset doesn't help, the quickest fix is a new cluster:
`terraform destroy`, then `terraform apply`.

## Common problems

### kubectl doesn't use the new cluster

You ran `get-kubeconfig.sh` without `eval`, or in another terminal. A script runs in its own
process and can't set `KUBECONFIG` in your shell, so kubectl still uses your previous
kubeconfig, or none. Run the script through `eval`:

```bash
eval "$(./scripts/get-kubeconfig.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)")"
echo "$KUBECONFIG"    # should end in /.kube/<cluster>.yaml
```

[Get the kubeconfig again](operations.md#get-the-kubeconfig-again) explains the script's other
messages.

### kubectl times out from your machine

Your public IP isn't in `operator_cidrs` any more, usually after a network change or a VPN.
Update it and run `terraform apply`.

### Joining nodes can't reach the API

The node's log says it is waiting for the API server through the load balancer. Check the load
balancer's view of the control planes:

```bash
region=$(terraform output -raw region)
tg=$(aws elbv2 describe-target-groups --region "$region" \
  --names "$(terraform output -raw cluster_name)-api" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --region "$region" --target-group-arn "$tg"
```

A new target stays `initial` for a minute or two. If cp-1 stays `unhealthy`, its API server
isn't running: check `crictl ps -a` on cp-1.

### Kubelet serving certificates stay Pending

Every kubelet asks for a serving certificate. kubelet-csr-approver approves them, but only for
node names like `cp-1` or `worker-2` with an IP inside the private subnets.

```bash
kubectl get csr
kubectl -n kube-system logs deploy/kubelet-csr-approver
```

As a last resort, approve a request by hand with `kubectl certificate approve <csr-name>`.

### kubectl logs or exec fails with tls: internal error

Right after the bootstrap, `kubectl logs`, `kubectl exec`, `kubectl port-forward` and
`cilium status` can fail with:

```text
error dialing backend: remote error: tls: internal error
```

These commands go through the kubelet, and a kubelet can't serve them until kubelet-csr-approver
has approved its serving certificate. That normally happens within a minute of the bootstrap,
so wait and try again. `kubectl get csr` shows the requests: `Approved,Issued` is what you want.

If cp-1 failed at `cni`, the approver was never installed, so the requests stay `Pending`. Read
container logs on the node with `crictl ps -a` and `crictl logs <container-id>` instead, or
approve the requests by hand as in the previous section.

### A new control plane can't download certificates

kubeadm deletes the uploaded control-plane certificates two hours after the upload. Run
`sudo kube-lab-refresh-join --upload-certs` on cp-1. Then either run the bootstrap again on the
new node, after `sudo kubeadm reset -f`, or replace it with `terraform apply -replace`.

### A node is stuck at pending

The node hasn't installed the AWS CLI, so it can't report anything. Wait five minutes. If it's
still `pending`, open a shell and read the log. If Session Manager can't reach the node either,
the node probably has no outbound internet access: check the NAT gateway and the private
subnets' route tables in the AWS console.
