# Lab: back up and restore etcd

etcd holds the whole state of the cluster. In this lab you install the etcd tools, take a
snapshot, restore it, and, with three control planes, watch what losing quorum does. The steps
follow [Operating etcd clusters for Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/).

Run everything on cp-1 as root (`sudo -i` in a Session Manager shell), unless a step says
otherwise.

## Install etcdctl and etcdutl

The nodes don't come with etcd's tools. Use the same version as the cluster's etcd, which the
image tag shows:

```bash
kubectl -n kube-system get pod etcd-cp-1 -o jsonpath='{.spec.containers[0].image}'
```

With Kubernetes 1.36 this prints `registry.k8s.io/etcd:3.6.8-0`, so the version is `v3.6.8`.
After the [upgrade lab](upgrade.md) it's 3.7.0. Download, check and install both tools:

```bash
ETCD_VER=v3.6.8
cd /tmp
curl -fsSLO "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz"
curl -fsSLO "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf "etcd-${ETCD_VER}-linux-amd64.tar.gz"
install -m 0755 "etcd-${ETCD_VER}-linux-amd64/etcdctl" "etcd-${ETCD_VER}-linux-amd64/etcdutl" /usr/local/bin/
etcdctl version
```

`etcdctl` talks to a running etcd. `etcdutl` works on etcd's files directly, which a restore
needs.

## Connect to etcd

etcd only accepts clients with a certificate signed by its own CA. kubeadm keeps them in
`/etc/kubernetes/pki/etcd/`. Set the connection once:

```bash
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key

etcdctl endpoint health
etcdctl member list -w table
```

## Take a snapshot

Create something you can recognize, then take the snapshot and check it:

```bash
kubectl create namespace before-snapshot
etcdctl snapshot save /root/snapshot.db
etcdutl --write-out=table snapshot status /root/snapshot.db
```

Now change the cluster, so you can see the restore undo it:

```bash
kubectl delete namespace before-snapshot
kubectl create namespace after-snapshot
```

## Restore the snapshot

On a single control plane, you stop the API server, restore into a new data directory, point
etcd at it, and start the API server again. A running API server would keep writing to the etcd
you are replacing.

1. Restore the snapshot into a new directory:

   ```bash
   etcdutl --data-dir /var/lib/etcd-restore snapshot restore /root/snapshot.db
   ```

2. Stop the API server by moving its static pod manifest away. Wait until `crictl ps` no longer
   lists it:

   ```bash
   mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/
   crictl ps --name kube-apiserver
   ```

3. Edit `/etc/kubernetes/manifests/etcd.yaml`. Under `volumes`, change the `hostPath` `path` of
   `etcd-data` from `/var/lib/etcd` to `/var/lib/etcd-restore`. Changing only `--data-dir`
   doesn't work, because the container still mounts the old directory. Wait until etcd runs
   again:

   ```bash
   crictl ps --name etcd
   ```

4. Start the API server again, and restart the kubelet so it doesn't act on stale state:

   ```bash
   mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
   systemctl restart kubelet
   ```

5. After a minute, `before-snapshot` is back and `after-snapshot` is gone:

   ```bash
   kubectl get namespaces
   ```

The docs also recommend restarting kube-scheduler and kube-controller-manager after a restore.
They usually restart on their own when they lose their leader lock.

## Three control planes

Create the cluster with `control_plane_count = 3`. `etcdctl member list -w table` shows three
members, and etcd needs two of them to accept any change. Stop etcd on cp-2 and cp-3:

```bash
mv /etc/kubernetes/manifests/etcd.yaml /root/     # on cp-2, then on cp-3
```

From your machine, `kubectl get nodes` now hangs or fails: one member of three is not a
majority. Move the manifests back and the cluster recovers.

Restoring a snapshot into three members means restoring on every member, with matching
`--name`, `--initial-cluster` and `--initial-advertise-peer-urls`. Treat it as an advanced
exercise and follow the [etcd disaster recovery guide](https://etcd.io/docs/v3.6/op-guide/recovery/).
