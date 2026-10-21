# Lab: upgrade from Kubernetes 1.36 to 1.37

In this lab you upgrade the cluster one minor version with kubeadm, the way the CKA exam
expects: control planes first, then workers, one node at a time. Keep the official guides open
next to this page:

- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Upgrading Linux nodes](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/)
- [Changing the Kubernetes package repository](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/)

## Before you start

- Use Calico, the default. Calico 3.33 supports both versions, so you don't upgrade the
  network plugin. Cilium 1.20 isn't tested on 1.37.
- etcd moves from 3.6.8 to 3.7.0. Take a [snapshot](etcd.md#take-a-snapshot) first.
- Read the [1.37 release notes](https://git.k8s.io/kubernetes/CHANGELOG).

Run node commands as root (`sudo -i` in a Session Manager shell) and `kubectl` from your
machine. Replace `1.37.x` with the patch version you pick in step 1.

## 1. Switch the package repository on every node

`pkgs.k8s.io` has one repository per minor version. On every node:

```bash
sed -i 's#/v1.36/#/v1.37/#' /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-cache madison kubeadm     # the newest 1.37.x-* at the top
```

## 2. Upgrade cp-1

Upgrade kubeadm and check the plan:

```bash
apt-mark unhold kubeadm && \
apt-get install -y kubeadm='1.37.x-*' && \
apt-mark hold kubeadm

kubeadm version
kubeadm upgrade plan
```

Apply the upgrade and answer `y`:

```bash
kubeadm upgrade apply v1.37.x
```

After `SUCCESS!`, the control plane and etcd run the new version, but the kubelet doesn't yet.
Drain cp-1 from your machine:

```bash
kubectl drain cp-1 --ignore-daemonsets --delete-emptydir-data
```

Upgrade the kubelet and kubectl on cp-1:

```bash
apt-mark unhold kubelet kubectl && \
apt-get install -y kubelet='1.37.x-*' kubectl='1.37.x-*' && \
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet
```

Uncordon it from your machine:

```bash
kubectl uncordon cp-1
```

With `worker_count = 0`, the evicted pods stay `Pending` until you uncordon. That's expected.

## 3. Upgrade the other control planes

Skip this with one control plane. Otherwise do cp-2, then cp-3, the same way as cp-1, but run
`kubeadm upgrade node` instead of `plan` and `apply`. Upgrade the kubeadm package first, or
`kubeadm upgrade node` runs the old version and changes nothing:

```bash
apt-mark unhold kubeadm && \
apt-get install -y kubeadm='1.37.x-*' && \
apt-mark hold kubeadm
kubeadm upgrade node
```

Then drain, upgrade the kubelet and kubectl, restart the kubelet and uncordon, as for cp-1.

## 4. Upgrade the workers

One worker at a time. On the worker:

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

Upgrade the kubelet on the worker:

```bash
apt-mark unhold kubelet && \
apt-get install -y kubelet='1.37.x-*' && \
apt-mark hold kubelet

systemctl daemon-reload
systemctl restart kubelet
```

Uncordon it, then move on to the next worker:

```bash
kubectl uncordon worker-1
```

## 5. Check the result

Every node should be `Ready` with `v1.37.x`, and etcd should run 3.7.0:

```bash
kubectl get nodes
kubectl -n kube-system get pod etcd-cp-1 -o jsonpath='{.spec.containers[0].image}'
```

## 6. Tell Terraform

Set `k8s_version = "1.37.x"` in `terraform.tfvars`. Nothing changes on the running nodes, but
nodes you add later then install 1.37 instead of 1.36.

## If something goes wrong

`kubeadm upgrade` is safe to run again. It keeps backups of the etcd data and the static pod
manifests under `/etc/kubernetes/tmp`; the
[recovery section](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/#recovering-from-a-failure-state)
explains how to use them. As a last resort, restore your etcd snapshot.
