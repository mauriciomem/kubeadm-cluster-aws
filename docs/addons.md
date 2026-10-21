# Add-ons

kube-lab ships a vanilla cluster. The bootstrap installs only the network plugin (Calico or
Cilium) and kubelet-csr-approver, which approves the kubelets' serving certificates.
Everything else, such as metrics, storage and ingress, you add yourself. That is also exam
practice: the CKA curriculum includes "Use Helm and Kustomize to install cluster components".

This page shows how to use Helm with the cluster, how to install metrics-server, and a general
recipe for other components.

## Use Helm

Helm installs packaged applications, called charts, and tracks each installation as a
release that you can upgrade or roll back. You can run it in two places.

From your own machine, [install Helm](https://helm.sh/docs/intro/install/), then point it at
the cluster the same way as kubectl. Helm reads `KUBECONFIG`, so this is enough:

```bash
eval "$(./scripts/get-kubeconfig.sh "$(terraform output -raw cluster_name)" "$(terraform output -raw region)")"
helm list -A
```

On a control plane, set `helm_enabled = true` in `terraform.tfvars` before you create the
cluster. The control planes then install Helm v3.22.1 (`helm_version`), with bash completion,
before they report `joined`. The setting only applies to nodes created after you set it. Open
a shell on the node (`terraform output ssm_session_commands`) and run `sudo -i`; Helm uses
root's kubeconfig.

The commands you use most:

```bash
helm repo add <name> <url>                      # once per chart repository
helm repo update                                 # refresh the list of charts
helm search repo <keyword> --versions            # find a chart and its versions
helm show values <repo>/<chart> --version <v>    # the settings the chart accepts
helm template <release> <repo>/<chart> --version <v> -f values.yaml   # print the manifests
helm install <release> <repo>/<chart> --version <v> -n <namespace> --create-namespace -f values.yaml
helm upgrade <release> <repo>/<chart> --version <v> -n <namespace> -f values.yaml
helm history <release> -n <namespace>
helm rollback <release> <revision> -n <namespace>
helm uninstall <release> -n <namespace>
helm list -A                                     # every release in every namespace
```

Always pass `--version`. Without it, Helm installs whatever is newest that day, and the next
install may differ. Read the values before you install, keep your changes in a `values.yaml`
file, and run `helm template` when you want to see exactly what will reach the cluster.

## Install metrics-server

metrics-server collects CPU and memory usage from every kubelet. `kubectl top` and the
HorizontalPodAutoscaler need it. Version 0.9.0 supports Kubernetes 1.34 and later, so it covers
1.36 and the 1.37 upgrade lab. Pick one of the two methods below.

With the release manifest:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
```

With the Helm chart. Chart version 3.14.0 installs metrics-server 0.9.0:

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm install metrics-server metrics-server/metrics-server --version 3.14.0 -n kube-system
```

Many guides tell you to add `--kubelet-insecure-tls`. Don't. That flag makes metrics-server skip
checking the kubelets' certificates, which is only needed when the kubelets use self-signed
ones. In kube-lab every kubelet requests a serving certificate from the cluster's certificate
authority, and kubelet-csr-approver approves it, so metrics-server can verify each kubelet.

Give it a minute to collect the first samples, then check:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io    # AVAILABLE should be True
kubectl top nodes
kubectl top pods -A
```

If `AVAILABLE` stays `False`, read `kubectl -n kube-system logs deploy/metrics-server`. A TLS
error there usually means a kubelet serving certificate is still pending: see
[Kubelet serving certificates stay Pending](troubleshooting.md#kubelet-serving-certificates-stay-pending).

To remove it, use the method you installed with. With the manifest:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
```

With Helm:

```bash
helm uninstall metrics-server -n kube-system
```

## Add other components

The same recipe works for most components:

1. Find the project's own install page and pick a release that supports Kubernetes 1.36.
2. Use the versioned manifest URL or chart version, never `latest` or `master`.
3. Read what it installs (`helm template`, or the manifest itself) before you apply it.
4. Check it with `kubectl get pods -n <namespace>` and the component's own status command.

For example, the cluster has no StorageClass, so a PersistentVolumeClaim stays `Pending`.
[local-path-provisioner](https://github.com/rancher/local-path-provisioner) creates volumes in a
directory on the node's own disk. Install it from its manifest, then make it the default
StorageClass:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
kubectl get storageclass
```

Each volume lives in `/opt/local-path-provisioner` on one node, on the root volume. The pod that
uses it is tied to that node, and the data is gone when the node is replaced. A new claim stays
`Pending` until a pod uses it, because the StorageClass waits for the scheduler to pick a node.

Two other gaps you will notice:

- Services of type `LoadBalancer` stay `<pending>`. kube-lab runs no cloud controller manager,
  which is the component that would create AWS load balancers for them. Use `NodePort` or
  `kubectl port-forward` instead.
- There is no ingress controller. If you look for one, know that the Ingress NGINX project
  [was retired in March 2026](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
  and gets no more releases or security fixes.
