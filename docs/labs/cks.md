# Lab: harden the cluster

kube-lab builds a plain kubeadm cluster on purpose: no audit log, no Pod Security admission
configuration, no encryption at rest. That leaves the CKS work to you. Each exercise below has
a hint and a link to the official guide. Take an [etcd snapshot](etcd.md#take-a-snapshot)
before you edit the control plane manifests, so a typo doesn't cost you the cluster.

## Turn on audit logging

Write an audit policy, then add `--audit-policy-file` and `--audit-log-path` to
`/etc/kubernetes/manifests/kube-apiserver.yaml`, with `hostPath` volumes for both paths.
Guide: [Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/).

Look at the source IPs in the log. The API load balancer doesn't preserve client IPs, so you
see its private addresses instead of yours. Work out why, and what you would change to see
the real address.

## Enforce Pod Security Standards

Label a namespace to enforce the `baseline` or `restricted` level and try to break the rule.
Then set cluster-wide defaults with an `AdmissionConfiguration` passed to the API server.
Guides: [namespace labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)
and [the built-in admission controller](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/).

## Encrypt Secrets at rest

Create a Secret, then read it straight from etcd with etcdctl (see the [etcd lab](etcd.md)) to
see it in plain text:

```bash
etcdctl get /registry/secrets/default/<name> | hexdump -C
```

Add an `EncryptionConfiguration`, pass it to the API server with
`--encryption-provider-config`, rewrite existing Secrets so they get encrypted, and read the
key again. Guide: [Encrypting confidential data at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/).

## Keep pods away from instance credentials

Every node has an IAM role, and the EC2 instance metadata service (IMDS) at `169.254.169.254`
hands out its credentials. kube-lab requires IMDSv2 with a hop limit of 1. The token that
IMDSv2 needs comes back in a packet that may make only one network hop. A pod on the pod network
sits one hop further away, behind its own network interface, so the token never reaches it.
Check that from a normal pod:

```bash
kubectl run imds --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token
```

The request times out and prints no token.

A pod with `hostNetwork: true` shares the node's network, so it is not a hop away and does get
a token. A NetworkPolicy won't reliably stop it either: the Kubernetes docs leave NetworkPolicy
behavior for `hostNetwork` pods undefined, and most network plugins treat their traffic as
the node's own. Blocking IMDS for the whole node isn't an option, because the node's own
scripts use the instance role.

The fix is to stop untrusted workloads from using `hostNetwork` at all. The Pod Security
Standards' `baseline` level forbids it. Enforce `baseline` on a namespace, try to create a
`hostNetwork` pod there, and watch the API server reject it. As an extra layer, add a
NetworkPolicy that denies egress to `169.254.169.254/32` for ordinary pods.

Guides: [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
and [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/#networkpolicy-and-hostnetwork-pods).

## Check the kubelet's security settings

kubeadm already configures the kubelet securely, and kube-lab adds serving certificates signed
by the cluster CA. Your job is to verify, not to fix. On any node, read
`/var/lib/kubelet/config.yaml` and find these settings:

- `authentication.anonymous.enabled` is `false`.
- `authorization.mode` is `Webhook`, so the API server decides who may call the kubelet.
- `rotateCertificates` is `true`.
- `serverTLSBootstrap` is `true`.

Then see what they protect. From a node, call the kubelet API without credentials:

```bash
curl -sk https://localhost:10250/pods
```

You get `Unauthorized`. Turn anonymous access on in a scratch cluster to see what an attacker
would get otherwise. Guide: [Kubelet authentication and authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/).

## Tighten the node security group

Today one rule lets the nodes reach each other on every port. Replace it in
`modules/cluster/security.tf` with only the ports the cluster needs:

- 6443 to the control planes, and 10250 to every node.
- 2379 and 2380 between control planes, for etcd.
- For Calico, UDP 4789 for VXLAN, and TCP 5473 if the operator runs Typha. For Cilium, UDP 8472
  for VXLAN and TCP 4240 for health checks.
- NodePorts, 30000 to 32767, if you use them.

Apply, then check that pods on different nodes can still reach each other. Guide:
[Ports and protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/).

## Secure the supply chain

The kubelet-csr-approver image is pinned by digest; find it with
`kubectl -n kube-system get deploy kubelet-csr-approver -o yaml`. Pin another image the same
way, then write a ValidatingAdmissionPolicy that rejects images without a digest. The node
security group also allows all outbound traffic. Think about which destinations the cluster
actually needs. Guide: [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/).

## Review the lab's own shortcuts

kube-lab takes a few shortcuts to stay simple, listed in
[Security trade-offs](../architecture.md#security-trade-offs). Treat each one as a question a
security reviewer could ask:

- All workers share one IAM role. In a shell on worker-1, overwrite worker-2's status:

  ```bash
  aws ssm put-parameter --overwrite --region <region> \
    --name /<cluster>/nodes/worker-2/status --value failed:spoofed
  ```

  Run `wait-for-cluster.sh --once` on your machine: the line now shows
  `worker-2=failed:spoofed`, although the node is fine. Set the value back to `joined`. What else could an attacker on a worker do with that role, and what
  would one role per node cost?
- cp-1 passes the join token to the AWS CLI on its command line. Who on that node could read
  it from the process list, and what can someone do with a join token in its 24 hours?
- A `hostNetwork` pod gets the node's IAM credentials (see
  [above](#keep-pods-away-from-instance-credentials)). On a worker, which SSM parameters would
  those credentials read?
