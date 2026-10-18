# Lab: upgrade from Kubernetes 1.36 to 1.37

In this lab you upgrade the cluster one minor version with kubeadm, the way the CKA exam
expects: control planes first, then workers, one node at a time. The steps follow the official
guides, which are worth keeping open next to this page:

- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
  (the current page covers 1.36.x to 1.37.x)
- [Upgrading Linux nodes](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/)
- [Changing the Kubernetes package repository](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/)

## Before you start

- Create the cluster with Calico, the default. Calico 3.33 is tested on Kubernetes 1.37;
  Cilium 1.20 isn't. Because Calico supports both versions, you don't need to upgrade the CNI.
- containerd 2.3, which the nodes run, supports both 1.36 and 1.37.
- This upgrade also moves etcd from 3.6.8 to 3.7.0. Take a snapshot first, as described in the
  [etcd lab](etcd.md#take-a-snapshot), so you have a way back.
- Read the [release notes](https://git.k8s.io/kubernetes/CHANGELOG) for 1.37 first.

Run the node commands as root (`sudo -i` in a Session Manager shell). Run the `kubectl`
commands from your machine. In the commands, replace `1.37.x` with the patch version you pick
in step 1.

## 1. Switch the package repository on every node

The nodes install Kubernetes from `pkgs.k8s.io`, which has one repository per minor version.
On every node, point apt at the 1.37 repository and look up the newest patch release:

```bash
sed -i 's#/v1.36/#/v1.37/#' /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-cache madison kubeadm     # the newest 1.37.x-* at the top
```

## 2. Upgrade the first control plane, cp-1

On cp-1, upgrade kubeadm and check the plan:

```bash
apt-mark unhold kubeadm && \
apt-get install -y kubeadm='1.37.x-*' && \
apt-mark hold kubeadm

kubeadm version
kubeadm upgrade plan
```

`kubeadm upgrade plan` checks that the cluster can be upgraded and lists the versions you can
upgrade to. Apply the upgrade, and answer `y` when it asks whether to proceed:

```bash
kubeadm upgrade apply v1.37.x
```

When it prints `SUCCESS! A control plane node of your cluster was upgraded to "v1.37.x"`, the
control-plane components and etcd run the new version. The kubelet doesn't yet. Drain cp-1 from your machine:

```bash
kubectl drain cp-1 --ignore-daemonsets --delete-emptydir-data
```

Upgrade the kubelet and kubectl on cp-1 and restart the kubelet:

```bash
apt-mark unhold kubelet kubectl && \
apt-get install -y kubelet='1.37.x-*' kubectl='1.37.x-*' && \
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet
```

Then make cp-1 schedulable again from your machine:

```bash
kubectl uncordon cp-1
```

With `worker_count = 0`, draining your only node leaves the evicted pods `Pending` until you
uncordon it. That's expected.

## 3. Upgrade the other control planes

Skip this step if you have one control plane. Otherwise do cp-2, then cp-3, one at a time.
It's the same as cp-1 with one difference: run `kubeadm upgrade node` instead of
`kubeadm upgrade plan` and `kubeadm upgrade apply`. You still have to upgrade the kubeadm package
first, or `kubeadm upgrade node` runs the old version and changes nothing.

```bash
apt-mark unhold kubeadm && \
apt-get install -y kubeadm='1.37.x-*' && \
apt-mark hold kubeadm
kubeadm upgrade node
```

Then drain the node, upgrade the kubelet and kubectl, run `systemctl daemon-reload`, restart
the kubelet and uncordon the node, exactly as for cp-1.

## 4. Upgrade the workers

One worker at a time. On the worker, upgrade kubeadm and kubectl, then let kubeadm update the
kubelet configuration:

```bash
apt-mark unhold kubeadm kubectl && \
apt-get install -y kubeadm='1.37.x-*' kubectl='1.37.x-*' && \
apt-mark hold kubeadm kubectl
kubeadm upgrade node
```

Drain it from your machine:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```

Upgrade the kubelet on the worker and restart it:

```bash
apt-mark unhold kubelet && \
apt-get install -y kubelet='1.37.x-*' && \
apt-mark hold kubelet

systemctl daemon-reload
systemctl restart kubelet
```

Make it schedulable again, then move on to the next worker:

```bash
kubectl uncordon worker-1
```

## 5. Check the result

```bash
kubectl get nodes
```

Every node should be `Ready` and show `v1.37.x`. Check that etcd runs 3.7.0:

```bash
kubectl -n kube-system get pod etcd-cp-1 -o jsonpath='{.spec.containers[0].image}'
```

## 6. Tell Terraform

Set `k8s_version = "1.37.x"` in `terraform.tfvars`, with your patch version. Nothing changes
on the running nodes: the value only matters for nodes you add or replace later, which then
install 1.37 to match the cluster. Without this, a new node would install 1.36.5.

## If something goes wrong

`kubeadm upgrade` is safe to run again; it brings the node to the state you asked for. It also
keeps backups of the etcd data and the static pod manifests under `/etc/kubernetes/tmp`. The
[recovery section](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/#recovering-from-a-failure-state)
of the upgrade guide explains how to use them. As a last resort, restore the etcd snapshot you
took before you started.
