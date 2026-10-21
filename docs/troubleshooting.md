# Troubleshooting

Start with the status line from `wait-for-cluster.sh`. A value such as `failed:join` names the
node and the step that failed. Then read that node's log.

## First steps

1. Print the statuses once with the command from `terraform output status_command`.
2. Open a shell on the node (`terraform output ssm_session_commands`) and run `sudo -i`.
3. Read the bootstrap log. Every line names the node and the step, and the last lines show what
   failed:

   ```bash
   less /var/log/kube-lab-bootstrap.log
   ```

4. If that isn't enough, look at cloud-init, the kubelet, containerd and the containers:

   ```bash
   less /var/log/cloud-init-output.log
   journalctl -u kubelet -u containerd --since "1 hour ago"
   crictl ps -a
   ```

To grab a log without an interactive shell, run one command through Session Manager. `sleep`
keeps the session open until the output arrives. No shell runs the command, so wrap pipes and
variables in `sudo bash -c '...'`.

```bash
id=i-0123456789abcdef0    # from terraform output nodes
sleep 30 | aws ssm start-session --region "$(terraform output -raw region)" --target "$id" \
  --document-name AWS-StartNonInteractiveCommand \
  --parameters command="sudo tail -n 200 /var/log/kube-lab-bootstrap.log"
```

## Check the progress

Each node writes its progress to an SSM parameter. You can read it three ways.

In Terraform, every plan and apply ends with a warning until the cluster is ready and every
node has joined. It never blocks anything. When a node fails, the warning names the node and
the step. `terraform output cluster_status` shows the same values, but only as of the last
apply: `terraform output` doesn't read them again. While the nodes work, a plan can list
`cluster_status` under "Changes to Outputs". That's the bootstrap moving on, not a change you
made.

With `wait-for-cluster.sh --once`, you get the live values once. It exits with 0 when the
cluster is ready, 1 when a node failed and 4 while the bootstrap runs, so you can use it in
your own scripts.

With `wait-for-cluster.sh --history`, you see every value each status has had, with the time
SSM recorded it, in UTC. The first `pending` is Terraform creating the parameter. Use it to
see which step took long.

The script's header and `--help` list every exit code.

## Status values

| Value | Meaning | Usual time |
|---|---|---|
| `pending` | The node hasn't installed the AWS CLI yet, so it can't report. | Under a minute; 2 or 3 when the download is slow |
| `bootstrapping` | Preparing the host and installing packages. | 1 to 3 minutes |
| `initializing` | cp-1 runs `kubeadm init`. | About 1 minute |
| `initialized` | cp-1 has published the kubeconfig. It installs the add-ons and waits until every node is `Ready`. | 1 to 5 minutes |
| `waiting` | A joining node waits for the join token, the previous control plane and the API. | Until cp-1 is `initialized` |
| `joining` | `kubeadm join` runs. | 1 to 3 minutes |
| `joined` | Done. | |

The cluster status is `pending` until cp-1 publishes the kubeconfig, then `installing` (kubectl
works from here), then `ready` once every node is `Ready`. Any status can end in
`failed:<step>`.

## Failed steps

The steps run in this order. Most downloads are retried 5 times.

| Step | Nodes | What to check |
|---|---|---|
| `awscli` | all | The node can't report this one, so it stays `pending`. Usually there's no internet through the NAT gateway, or `aws_cli_sha256` doesn't match `aws_cli_version`. |
| `host` | all | Swap, kernel modules and sysctls. This rarely fails. |
| `packages` | all | An apt repository was down, `containerd_version` matches no package, or an apt signing key changed. A key change stops the bootstrap on purpose: check the new fingerprint against the Docker and Kubernetes install docs before you update `lib.sh`. |
| `containerd` | all | `journalctl -u containerd`. |
| `shell` | all | kubectl completion and the `k` alias. This rarely fails. |
| `helm` | control planes, with `helm_enabled` | A failed download or a checksum mismatch. |
| `init` | cp-1 | `crictl ps -a`, `crictl logs <container-id>` and `journalctl -u kubelet`. |
| `publish` | cp-1 | Look for `AccessDenied` in the log. |
| `local-kubeconfig` | cp-1 | The log shows whether the metadata lookup or the copy failed. |
| `cni` | cp-1 | Calico: `kubectl get tigerastatus` and `kubectl -n tigera-operator logs deploy/tigera-operator`. Cilium: `kubectl -n kube-system get pods -l k8s-app=cilium`. A checksum mismatch means the pinned sha256 doesn't match the download. |
| `csr-approver` | cp-1 | Read the log. The API server must answer on cp-1. |
| `refresh-timer` | cp-1 | `systemctl status kube-lab-refresh-join.timer`. |
| `wait-nodes` | cp-1 | `kubectl get nodes`, then the status and log of the node that isn't `Ready`. cp-1 gives up after 30 minutes. |
| `join` | joining nodes | The log says what it waited for. The token: check cp-1. The API: see [below](#joining-nodes-cant-reach-the-api). `kubeadm join` itself: `journalctl -u kubelet`. |
| `root-kubeconfig` | control planes | Check that `/etc/kubernetes/admin.conf` exists. |

## Run the bootstrap again

After you fix the cause, run the bootstrap again. It skips every step that already finished.
If `kubeadm init` or `kubeadm join` failed halfway, reset the node first:

```bash
sudo kubeadm reset -f                                  # only after a failed init or join
sudo bash /var/lib/cloud/instance/scripts/worker.sh    # or control-plane.sh
```

Each finished step leaves a marker such as `/var/lib/kube-lab/packages.done`. Delete it to run
that step again. If cp-1 fails at `init` and a reset doesn't help, destroy the cluster and
create a new one.

## Common problems

### kubectl doesn't use the new cluster

You ran `get-kubeconfig.sh` without `eval`, or in another terminal. Run it through `eval`, then
check with `echo "$KUBECONFIG"`. See [Point kubectl at the cluster](operations.md#point-kubectl-at-the-cluster).

### kubectl times out

Your public IP isn't in `operator_cidrs` any more. Update it and run `terraform apply`.

### Joining nodes can't reach the API

The log says the node waits for the API server through the load balancer. Check the load
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

### kubectl logs or exec fails with tls: internal error

```text
error dialing backend: remote error: tls: internal error
```

`kubectl logs`, `exec` and `port-forward` go through the kubelet, which can't serve them until
its serving certificate is approved. That normally happens within a minute, so wait and try
again. `kubectl get csr` should show `Approved,Issued`.

If requests stay `Pending`, check the approver. It only approves node names like `cp-1` or
`worker-2` with an IP in the private subnets. If cp-1 failed at `cni`, the approver was never
installed.

```bash
kubectl -n kube-system logs deploy/kubelet-csr-approver
kubectl certificate approve <csr-name>    # last resort
```

### A new control plane can't download certificates

kubeadm deletes the uploaded certificates two hours after the upload. Run
`sudo kube-lab-refresh-join --upload-certs` on cp-1. Then reset the new node and run its
bootstrap again, or replace it with `terraform apply -replace`.

### A node is stuck at pending

The node hasn't installed the AWS CLI yet. Wait five minutes. If it's still `pending`, read its
log. If Session Manager can't reach the node either, it has no outbound internet: check the NAT
gateway and the private route tables.
