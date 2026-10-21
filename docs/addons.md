# Add-ons

The bootstrap installs only the network plugin and kubelet-csr-approver. Some things a cloud
cluster gives you are missing, and each one makes a good exercise:

- No metrics-server, so `kubectl top` and the HorizontalPodAutoscaler don't work.
- No StorageClass, so a PersistentVolumeClaim stays `Pending` until you create a volume for it.
- No cloud controller manager, so Services of type `LoadBalancer` stay `<pending>`. Use
  `NodePort` or `kubectl port-forward` instead.
- No ingress controller. If you pick one, note that Ingress NGINX
  [was retired in March 2026](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/).

Installing components is exam practice too: the CKA curriculum includes "Use Helm and Kustomize
to install cluster components".

## Use Helm

From your machine, [install Helm](https://helm.sh/docs/intro/install/). It reads `KUBECONFIG`,
so once kubectl works, `helm list -A` does too.

To have Helm on the control planes instead, set `helm_enabled = true` before you create the
cluster. It only reaches nodes created after you set it. In a shell on a control plane, run
`sudo -i`; Helm uses root's kubeconfig and has bash completion.

Always pass `--version`, so the next install gives you the same thing. Read the chart's
settings with `helm show values`, keep your changes in a `values.yaml`, and run
`helm template` to see exactly what will reach the cluster.

## Install metrics-server

metrics-server 0.9.0 supports Kubernetes 1.34 and later, so it covers the upgrade lab too. Use
the release manifest:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
```

Or the Helm chart, whose version 3.14.0 installs metrics-server 0.9.0:

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server --version 3.14.0 -n kube-system
```

Many guides add `--kubelet-insecure-tls`. You don't need it: every kubelet here has a serving
certificate signed by the cluster's certificate authority, so metrics-server can verify them.

Give it a minute to collect the first samples, then check:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io    # AVAILABLE should be True
kubectl top nodes
```

If `AVAILABLE` stays `False`, read `kubectl -n kube-system logs deploy/metrics-server`. A TLS
error usually means a kubelet certificate is still pending; see
[Troubleshooting](troubleshooting.md#kubectl-logs-or-exec-fails-with-tls-internal-error).

## Add storage

[local-path-provisioner](https://github.com/rancher/local-path-provisioner) creates volumes in
a directory on the node's own disk. Install it and make it the default StorageClass:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
```

Each volume ties its pod to one node, and the data is gone when the node is replaced. A new
claim stays `Pending` until a pod uses it, because the StorageClass waits for the scheduler to
pick a node.

## Add other components

The same recipe works for most components:

1. Pick a release from the project's install page that supports your Kubernetes version.
2. Use a versioned manifest URL or chart version, never `latest` or `master`.
3. Read what it installs before you apply it.
4. Check it with `kubectl get pods -n <namespace>`.
