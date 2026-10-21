# Lab: harden the cluster

kube-lab builds a plain kubeadm cluster: no audit log, no Pod Security admission
configuration, no encryption at rest. That leaves the CKS work to you. Each exercise has a hint
and a link to the official guide. Take an [etcd snapshot](etcd.md#take-a-snapshot) before you
edit the control plane manifests, so a typo doesn't cost you the cluster.

## Turn on audit logging

Write an audit policy, then add `--audit-policy-file` and `--audit-log-path` to
`/etc/kubernetes/manifests/kube-apiserver.yaml`, with `hostPath` volumes for both paths.
Guide: [Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/).

Look at the source IPs in the log. You see the load balancer's private addresses instead of
yours. Work out why, and what you would change to see the real address.

## Enforce Pod Security Standards

Label a namespace to enforce `baseline` or `restricted` and try to break the rule. Then set
cluster-wide defaults with an `AdmissionConfiguration` passed to the API server. Guides:
[namespace labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)
and [the admission controller](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/).

## Encrypt Secrets at rest

Create a Secret and read it straight from etcd (see the [etcd lab](etcd.md) for etcdctl). It's
plain text:

```bash
etcdctl get /registry/secrets/default/<name> | hexdump -C
```

Add an `EncryptionConfiguration`, pass it with `--encryption-provider-config`, rewrite the
existing Secrets, and read the key again. Guide:
[Encrypting confidential data at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/).

## Keep pods away from instance credentials

Every node has an IAM role, and the instance metadata service (IMDS) at `169.254.169.254`
hands out its credentials. kube-lab requires IMDSv2 with a hop limit of 1, so the token never
reaches a pod on the pod network, which sits one hop further away. Check it:

```bash
kubectl run imds --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token
```

The request times out. A pod with `hostNetwork: true` shares the node's network and does get a
token, and NetworkPolicy behavior for such pods is undefined. You can't block IMDS for the
whole node, because the node's own scripts use the role.

So stop untrusted workloads from using `hostNetwork`. Enforce the `baseline` Pod Security level
on a namespace and watch the API server reject a `hostNetwork` pod. As an extra layer, deny
egress to `169.254.169.254/32` with a NetworkPolicy. Guides:
[Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
and [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/#networkpolicy-and-hostnetwork-pods).

## Check the kubelet's security settings

kubeadm already configures the kubelet securely, so your job is to verify. On any node, read
`/var/lib/kubelet/config.yaml` and find:

- `authentication.anonymous.enabled: false`
- `authorization.mode: Webhook`
- `rotateCertificates: true`
- `serverTLSBootstrap: true`

Then call the kubelet API without credentials. You get `Unauthorized`:

```bash
curl -sk https://localhost:10250/pods
```

Guide: [Kubelet authentication and authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/).

## Tighten the node security group

One rule lets the nodes reach each other on every port. Replace it in
`modules/cluster/security.tf` with only the ports the cluster needs:

- 6443 to the control planes, and 10250 to every node.
- 2379 and 2380 between control planes, for etcd.
- Calico: UDP 4789 for VXLAN, and TCP 5473 if the operator runs Typha. Cilium: UDP 8472 and
  TCP 4240.
- 30000 to 32767, if you use NodePorts.

Apply, then check that pods on different nodes can still reach each other. Guide:
[Ports and protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/).

## Secure the supply chain

The kubelet-csr-approver image is pinned by digest
(`kubectl -n kube-system get deploy kubelet-csr-approver -o yaml`). Pin another image the same
way, then write a ValidatingAdmissionPolicy that rejects images without a digest. Also think
about which outbound destinations the cluster really needs. Guide:
[Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/).

## Review the lab's own shortcuts

[Security trade-offs](../architecture.md#security-trade-offs) lists the shortcuts kube-lab
takes. Treat each one as a question a reviewer could ask:

- All workers share one IAM role. In a shell on worker-1, overwrite worker-2's status:

  ```bash
  aws ssm put-parameter --overwrite --region <region> \
    --name /<cluster>/nodes/worker-2/status --value failed:spoofed
  ```

  `wait-for-cluster.sh --once` now shows `worker-2=failed:spoofed`, although the node is fine.
  Set it back to `joined`. What else could an attacker on a worker do with that role, and what
  would one role per node cost?
- cp-1 passes the join token to the AWS CLI on its command line. Who on that node could read
  it, and what can someone do with a join token in its 24 hours?
- A `hostNetwork` pod gets the node's IAM credentials. On a worker, which SSM parameters would
  those credentials read?
