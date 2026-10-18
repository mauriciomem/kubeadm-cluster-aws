# kube-cluster refactor: target architecture (carter-architect, 2026-10-16)

Scope: an implementation-ready design for a learning-only kubeadm cluster on EC2. The operator decisions in `00-context.md` are taken as given.
> The code differs from this design in places. See "Implementation notes (as built)" at the end; the code and `docs/` are the source of truth.

Legend: ✅ verified against an official source this session (URL inline) · ⚠️ not verified, so check during implementation or apply.

## 0. Findings that change the brief (read first)

| # | Finding | Consequence |
|---|---------|-------------|
| F1 | An internet-facing NLB's DNS name resolves to **public** IPs, even from inside the VPC ✅ (https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/how-elastic-load-balancing-works.html). Nodes in private subnets therefore reach it **through the NAT gateway**, so the NLB SG sees the **NAT EIP** as the source, not the node SG. | NLB SG ingress 6443 = `operator_cidrs` + `nat_public_ips/32`. A rule referencing the node SG would never match. |
| F2 | With `preserve_client_ip` enabled, hairpin (target → own NLB → itself) times out ✅ (https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-troubleshooting.html#loopback-timeout). Instance targets default to enabled ✅ (https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html#client-ip-preservation). | Instance target group with `preserve_client_ip = "false"`. Targets then see NLB private IPs, and the node SG allows 6443 from the NLB SG. That reference works whether or not client IP preservation is on ✅ (https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-security-groups.html). |
| F3 | `kubeadm init` does **not** need the NLB. Its client is re-pointed at `LocalAPIEndpoint` (`EnsureAdminClusterRoleBinding` → `PointKubeConfigToLocalAPIEndpoint`), and the CP kubelet kubeconfig drops `controlPlaneEndpoint` (ControlPlaneKubeletLocalMode is GA and removed as a gate in 1.36) ✅ (source: https://github.com/kubernetes/kubernetes/blob/release-1.36/cmd/kubeadm/app/phases/kubeconfig/kubeconfig.go, `cmd/kubeadm/app/cmd/phases/init/kubeconfig.go` L161, CHANGELOG-1.36). | No `/etc/hosts` trick and no Route53 private zone. Only joiners and kube-proxy use the NLB, and joiners poll until it answers. |
| F4 | `aws_ssm_parameter` Read calls `GetParameter(WithDecryption=true)` and writes the plaintext into state, even with `ignore_changes`. That does not happen with `value_wo` (Read sets `value=nil` when `has_value_wo`) ✅ (provider source `internal/service/ssm/parameter.go` v6.69.1). | Terraform pre-creates the params with `value_wo` + a fixed `value_wo_version`. Nodes overwrite them, and the real token or kubeconfig never lands in state. This needs **Terraform ≥ 1.11** (write-only args) ✅ (registry doc `r/ssm_parameter`). |
| F5 | `AmazonSSMManagedInstanceCore` grants `ssm:GetParameter(s)` on `"*"` ✅ (https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html). The `aws/ssm` key lets every principal in the account decrypt ✅ (https://docs.aws.amazon.com/systems-manager/latest/userguide/ps-restrict-decryption.html). | Scoped Allow statements alone don't limit reads. The worker role gets an **explicit Deny** on `/<cluster>/kubeconfig/*`. P7 review: both roles now use an inline Session-Manager-only policy instead of the managed one; the Deny stays as defense in depth and also covers the path ARNs `GetParametersByPath` checks. |
| F6 | `admin.conf` is about 5.5 KB (RSA-2048 CA + client cert + key, base64), and the Standard tier caps values at 4 KB ✅ (https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html). | The kubeconfig param uses `tier = "Advanced"` (8 KB, about $0.05/month). The other params stay Standard. |
| F7 | kubeadm's default `serviceSubnet` 10.96.0.0/12 covers 10.96–10.111, which **contains the current VPC default 10.100.0.0/16** (checked with `cidrhost("10.100.0.0/12",0)` = 10.96.0.0 in `terraform console`). | New VPC default: `10.10.0.0/16`. A cross-variable validation rejects overlaps. |
| F8 | Cilium's default cluster-pool is `10.0.0.0/8` ✅ (values.yaml v1.20.3), which overlaps any 10.x VPC. | Cilium runs with `ipam.mode=kubernetes`, which uses the kubeadm `podSubnet`. One `pod_cidr` serves both CNIs. |
| F9 | `VXLANCrossSubnet` (the Calico default CR ✅ manifests/custom-resources.yaml v3.33.0) routes natively between nodes in the same subnet, which needs EC2 src/dst check disabled. | Calico runs with `encapsulation: VXLAN` (always) and `bgp: Disabled`. src/dst check stays on. |
| F10 | etcd allows **1 learner** by default (`DefaultMaxLearners = 1`, etcd release-3.6 `cluster_opts.go`), and kubeadm joins CPs as learners (`phases/etcd/local.go` `AddMemberAsLearner`) ✅. | CP joins are **serialized**: cp-N waits for `cp-(N-1)` to report `joined`. Workers join in parallel. |
| F11 | Changing `user_data` on `aws_instance` stops and starts the instance (or replaces it with `user_data_replace_on_change`) ✅ (registry `r/instance`). Replacing cp-1 destroys the cluster. | `lifecycle.ignore_changes = [ami, user_data_base64]`. To rebuild, run `terraform apply -replace=...` or destroy and apply. |

## 1. File tree and module boundaries

```
kube-cluster/
├── terraform.tf            # required_version, required_providers (root pins ~>)
├── providers.tf            # aws { region, default_tags }
├── variables.tf            # all inputs + validations
├── locals.tf               # cluster_name, node map, k8s minor
├── main.tf                 # random_string, module.network, module.cluster, optional wait
├── outputs.tf
├── modules/
│   ├── network/            # thin wrapper over terraform-aws-modules/vpc
│   │   ├── versions.tf  main.tf  variables.tf  outputs.tf
│   └── cluster/            # everything that is "the cluster"
│       ├── versions.tf  variables.tf  locals.tf
│       ├── iam.tf          # 2 roles: control-plane, worker
│       ├── security.tf     # node SG, NLB SG, rules
│       ├── nlb.tf          # NLB, TG, listener, attachments (CPs)
│       ├── ssm.tf          # pre-created parameters (value_wo)
│       ├── nodes.tf        # AMI data, cloudinit_config, aws_instance for_each
│       ├── outputs.tf
│       └── templates/
│           ├── cloud-config.yaml.tftpl        # hostname + write_files (configs/manifests)
│           ├── common.sh.tftpl                # lib (log/status/retry/ssm) + host prep + packages
│           ├── control-plane.sh.tftpl         # cp-1: init+addons+publish; cp-N: join
│           ├── worker.sh.tftpl                # join
│           ├── kubeadm-init.yaml.tftpl        # Init+Cluster+Kubelet+KubeProxy configs (v1beta4)
│           ├── kubeadm-join.yaml.tftpl        # JoinConfiguration (v1beta4), CP section optional
│           ├── calico-installation.yaml.tftpl # Installation + APIServer CRs
│           ├── kubelet-csr-approver.yaml.tftpl
│           └── refresh-join.sh.tftpl          # cp-1 systemd timer payload
├── scripts/
│   ├── get-kubeconfig.sh   # aws CLI only
│   └── wait-for-cluster.sh # aws CLI only
├── tests/
│   ├── mocks/aws.tfmock.hcl
│   ├── nodes.tftest.hcl  validation.tftest.hcl  user_data.tftest.hcl  cni.tftest.hcl
├── .tflint.hcl  .gitignore  README.md
└── .github/workflows/ci.yml   # fmt, validate, tflint, shellcheck, terraform test, trivy(optional)
```

**Module boundaries**
- `network` is a stable, generic concern with its own lifecycle and an upstream module. The wrapper earns its keep by fixing the swapped CIDRs, tags, and AZ selection, and by exposing a NAT-gated `private_subnet_ids` (§2.3).
- `cluster` holds SG, IAM, NLB, SSM, and nodes. These are tightly coupled (IAM path = cluster name, SG ↔ NLB, user_data ↔ NLB DNS), so splitting them would just shuttle a dozen IDs between modules for no reuse.
- `sg/`, `kubernetes/`, and `kubernetes-addons/` are deleted. There are no Kubernetes, Helm, or Vault providers: add-ons are installed on-node by cp-1, so Terraform never needs cluster credentials (that is what keeps secrets out of state).

**VPC module pin:** `terraform-aws-modules/vpc/aws` **`6.7.3` exact** (latest, published 2026-09-18 ✅ https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws). The exact pin is deliberate because `.terraform.lock.hcl` does not lock module versions. That module requires `aws >= 6.28` ✅ (`versions.tf` at v6.7.3).

### 1.1 user_data composition

`data "cloudinit_config"` with `gzip = true, base64_encode = true`, passed via `user_data_base64` (the provider docs say gzip must go through `user_data_base64` ✅). cloud-init decompresses gzip transparently ✅ (https://github.com/canonical/cloud-init/blob/main/doc/rtd/explanation/format/gzip.rst). Parts, which run in order:
1. `text/cloud-config`: `hostname`, `preserve_hostname: false`, `manage_etc_hosts: true`, and `write_files` for `/etc/kube-lab/*` (kubeadm templates, add-on manifests for cp-1 only, `refresh-join.sh` for cp-1 only). Files have mode 0600 and root ownership.
2. `text/x-shellscript` `common.sh`: the same for every node.
3. `text/x-shellscript` role script: `control-plane.sh` or `worker.sh`.

Size estimate (raw, before gzip): common ≈ 5 KB, control-plane ≈ 5 KB, cloud-config for cp-1 ≈ 6 KB (kubeadm YAML 1.5 KB, approver 2 KB, calico CR 0.5 KB, refresh 1 KB, MIME overhead), so cp-1 is about 16 KB, right at the 16 KB raw limit ✅ (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html). Shell and YAML gzip roughly 3–4x, giving about 5 KB. **gzip is mandatory**. Workers come to about 9 KB raw. The script must not inline upstream manifests: Calico, metrics-server, and Cilium are downloaded at a pinned version with sha256 verification.

*Rejected alternative:* a single `templatefile` script that inlines `common` as a variable. It works, but it loses the clean cloud-config `write_files` and hostname handling. Multipart is the documented cloud-init mechanism.

## 2. Node model

### 2.1 Node map (root `locals.tf`)
```hcl
locals {
  cluster_name = "${var.name_prefix}-${random_string.suffix.result}"   # e.g. kube-lab-x7k2
  cp_keys      = [for i in range(var.control_plane_count) : "cp-${i + 1}"]
  worker_keys  = [for i in range(var.worker_count) : "worker-${i + 1}"]
  nodes = merge(
    { for i, k in local.cp_keys     : k => { role = "control-plane", index = i, init = i == 0 } },
    { for i, k in local.worker_keys : k => { role = "worker",        index = i, init = false } },
  )
}
```
Inside `cluster`, `subnet_id = var.private_subnet_ids[each.value.index % length(var.private_subnet_ids)]`. CPs and workers each round-robin across the 3 AZs (cp-1, cp-2, cp-3 in a, b, c; worker-1, worker-2 in a, b). The keys are stable, so scaling `worker_count` from 2 to 3 adds only `worker-3`. Scaling down removes the highest index. The node object is not drained or deleted from the API, so the README tells the operator to run `kubectl drain` and `kubectl delete node` first.

### 2.2 Validations (`variables.tf`)
- `control_plane_count`: `>= 1 && <= 7 && count % 2 == 1` ("odd for etcd quorum").
- `worker_count`: `>= 0 && <= 20`. If it is 0, `InitConfiguration.nodeRegistration.taints = []` so workloads schedule on CPs. kubeadm documents "set taints to an empty list" ✅ (kubeadm-config.v1beta4 NodeRegistrationOptions).
- `operator_cidrs`: `length >= 1`, each `can(cidrhost(c, 0))`, and none equal to `0.0.0.0/0` (operator decision 5: restricted).
- `cni`: `contains(["calico","cilium"], var.cni)`.
- `k8s_version`: `can(regex("^1\\.[0-9]+\\.[0-9]+$", v))`. The minor is `join(".", slice(split(".", v), 0, 2))`.
- `pod_cidr` and `service_cidr` must not overlap each other or `vpc_cidr`. Cross-variable validation is allowed since TF 1.9 ✅ (Terraform v1.9 CHANGELOG). Overlap test for a, b: `p = min(prefix(a), prefix(b))`, overlap ⇔ `cidrhost("${ip(a)}/${p}",0) == cidrhost("${ip(b)}/${p}",0)`, implemented as a local function-free expression in each validation.

### 2.3 Hostnames and NAT readiness
- cloud-config `hostname: <key>`, and kubeadm `nodeRegistration.name: <key>`. The kubelet node name equals the hostname equals the TF key. Nodes don't resolve each other by name: kube-apiserver uses `--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname` ✅ (kubeadm `manifests.go` L201), so no `/etc/hosts` fan-out is needed.
- NAT ordering: in `modules/network/outputs.tf`, `output "private_subnet_ids" { value = module.vpc.private_subnets; depends_on = [module.vpc.private_nat_gateway_route_ids] }`. Output `depends_on` is supported ✅ (https://developer.hashicorp.com/terraform/language/block/output#depends_on). Instances that consume it are created only after the NAT default route exists. That is precise, and it avoids module-level `depends_on`, which would defer every data source in `cluster` to apply time. The scripts still retry every network call (§3.6).

## 3. Bootstrap and join protocol

### 3.1 SSM parameter layout (Terraform-owned, `ssm.tf`)
All are `SecureString`, KMS `aws/ssm`, created with `value_wo = "pending"` and `value_wo_version = 1`. Nodes overwrite them with `put-parameter --overwrite`. Terraform never reads plaintext back (F4), and `terraform destroy` deletes all of them, so nothing is orphaned.

| Path | Writer | Readers | Tier |
|------|--------|---------|------|
| `/<cluster>/join/token` | cp-1 (init and refresh timer) | all | Standard |
| `/<cluster>/join/ca-cert-hash` | cp-1 | all | Standard |
| `/<cluster>/join/certificate-key` | cp-1 | CPs | Standard |
| `/<cluster>/kubeconfig/admin` | cp-1 | operator, CPs | **Advanced** (F6) |
| `/<cluster>/status/cluster` | cp-1 | operator | Standard |
| `/<cluster>/nodes/<key>/status` (for_each nodes) | that node | CPs, operator | Standard |

`status/*` values: `pending` → `bootstrapping` → `installing` → `joined` (cp-1 writes `initialized`) → cluster `ready`. On error the value is `failed:<step>`. Statuses aren't secret, but they stay SecureString for one uniform code path.

The **nodes own the secret values**. kubeadm generates the token (`kubeadm token generate`) and the certificate key (`kubeadm certs certificate-key`) on cp-1 ✅ (https://v1-36.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/#automating-kubeadm). The CA hash is computed with the documented openssl pipeline ✅ (kubeadm-join docs). *Rejected:* a `random_password` token in Terraform, which would sit in state.

### 3.2 cp-1 (`init = true`)
1. `common.sh` runs (§9).
2. Render `/etc/kube-lab/kubeadm-init.yaml` from the TF template with `envsubst` (runtime values `PRIVATE_IP`, `JOIN_TOKEN`, `CERT_KEY`, all IMDSv2 or kubeadm generated). `envsubst` comes from `gettext-base` ⚠️ (present on Ubuntu server images; install explicitly to be safe).
   - `InitConfiguration`: `bootstrapTokens[{token, ttl: 24h, usages:[signing,authentication], groups:[system:bootstrappers:kubeadm:default-node-token]}]`, `certificateKey`, `localAPIEndpoint.advertiseAddress`, `nodeRegistration{name: cp-1, criSocket: unix:///run/containerd/containerd.sock, taints: (default | [])}`, `timeouts.controlPlaneComponentHealthCheck: 8m` (default 4m ✅ v1beta4 `Timeouts`).
   - `ClusterConfiguration`: `kubernetesVersion: v${k8s_version}`, `controlPlaneEndpoint: "${nlb_dns}:6443"`, `apiServer.certSANs: [${nlb_dns}]` (controlPlaneEndpoint is auto-added to SANs ✅ `pki_helpers.go` GetAPIServerAltNames; the explicit entry documents intent), `networking{podSubnet, serviceSubnet, dnsDomain: cluster.local}`.
   - `KubeletConfiguration`: `cgroupDriver: systemd`, `serverTLSBootstrap: true` (§5).
   - `KubeProxyConfiguration`: `mode: iptables` (explicit, so it's visible to students).
3. `kubeadm init --config /etc/kube-lab/kubeadm-init.yaml --upload-certs`. `--config` with `--upload-certs` is the documented HA form ✅ (https://v1-36.docs.kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/).
4. Publish `join/*` **immediately**, so workers and cp-2 join while add-ons install. Also publish `kubeconfig/admin` from `/etc/kubernetes/admin.conf`. Its server is already `https://<nlb>:6443`, because admin.conf uses controlPlaneEndpoint ✅ (`getKubeConfigSpecsBase`), so no rewrite is needed. Set node status to `initialized`.
5. Add-ons with `KUBECONFIG=/etc/kubernetes/admin.conf`: CNI (§4) → kubelet-csr-approver → metrics-server (§5).
6. Install the `kube-lab-refresh-join.timer` (§3.4).
7. Wait (up to 30 min) until `kubectl get nodes` shows `control_plane_count + worker_count` nodes, all `Ready`. Then write `status/cluster = ready` and node status `joined`. On timeout, write `failed:wait-nodes`.

### 3.3 Joiners (cp-2..N, workers)
1. `common.sh`.
2. Poll `/<cluster>/join/token` until it isn't `pending`. Use exponential backoff of 5→60 s, capped at 40 min overall.
3. **CPs only:** wait until `/<cluster>/nodes/cp-(N-1)/status == joined` (F10). cp-2 waits for cp-1 `initialized`, not `joined`, so the CP chain doesn't wait on CNI.
4. Wait for the NLB: loop `curl -sk -o /dev/null -w '%{http_code}' https://$EP:6443/livez` until it returns anything other than `000`. A 401 still means reachable, which matters for the CKS labs that disable anonymous auth. NLB registration "can take a few minutes" ✅ (https://docs.aws.amazon.com/elasticloadbalancing/latest/network/target-group-register-targets.html).
5. Render `kubeadm-join.yaml`:
   - `discovery.bootstrapToken{apiServerEndpoint: <nlb>:6443, token, caCertHashes:[sha256:<hash>]}`
   - `nodeRegistration.name`
   - `timeouts.discovery: 15m`, `tlsBootstrap: 10m`
   - CPs also get `controlPlane{localAPIEndpoint.advertiseAddress: $PRIVATE_IP, certificateKey}`.

   Run `kubeadm join --config ...`.
6. Status `joined`. The kubelet on a joined CP uses the local API (`phases/join/kubelet.go` L133 ✅). Workers use the NLB, which is fine.

### 3.4 Token and cert-key expiry: one systemd timer on cp-1
- `kube-lab-refresh-join.timer` (`OnBootSec=1h`, `OnUnitActiveSec=12h`) runs `refresh-join.sh`, which calls `kubeadm token create --ttl 24h` and PutParameters `join/token`. A worker replaced days later joins with zero touch. Old tokens expire on their own.
- The certificate key / `kubeadm-certs` Secret expires after **2 h** ✅ (HA docs). The timer does **not** re-upload certs, because keeping CA keys permanently in a Secret is a bad CKS habit. A CP added or replaced after 2 h needs one documented command on cp-1, `sudo /usr/local/sbin/kube-lab-refresh-join --upload-certs`, which re-runs `kubeadm init phase upload-certs --upload-certs --certificate-key <new>` and republishes. The joining CP's poll loop picks it up.
- Trade-off: replacing cp-1 itself isn't supported (it is the etcd seed). The README says to destroy and re-apply.

### 3.5 Readiness signal and Terraform blocking
- `scripts/wait-for-cluster.sh <cluster> [region]` polls `status/cluster` every 15 s, prints per-node statuses from `get-parameters-by-path /<cluster>/nodes --recursive --with-decryption`, exits 0 on `ready`, 1 on any `failed:*`, and 2 on a 40 min timeout.
- `scripts/get-kubeconfig.sh <cluster> [region]` runs `aws ssm get-parameter --with-decryption`, writes `~/.kube/<cluster>.yaml` with umask 077, and prints `export KUBECONFIG=...`.
- **Decision:** Terraform does not block by default. There is an optional `var.wait_for_cluster` (default `false`) that adds a `terraform_data` with `local-exec` running the wait script (`triggers_replace = module.cluster.instance_ids["cp-1"]`). A `check` block can't wait and runs before bootstrap finishes, so it is rejected. Trade-off: local-exec needs bash and the aws CLI on the operator machine, which is why it's opt-in.

### 3.6 Script robustness rules
`set -Eeuo pipefail` · `trap 'status "failed:${STEP}"' ERR` · `retry N cmd` helper for apt, curl, and aws · all output to `/var/log/kube-lab-bootstrap.log` plus cloud-init's log · no `read` · no `--allow-unauthenticated` · idempotency guard `/var/lib/kube-lab/<step>.done`, so a re-run after reboot doesn't re-init.

## 4. CNI

**Variables:**
- `cni` = `"calico"` (default) or `"cilium"`.
- `pod_cidr` = `"192.168.0.0/16"` for **both** CNIs.
- `service_cidr` = `"10.96.0.0/12"`.
- `vpc_cidr` = `"10.10.0.0/16"` (F7).

One pod CIDR, because Cilium runs with `ipam.mode=kubernetes`, which reads the node `podCIDR` that kube-controller-manager allocates from kubeadm `podSubnet` (`--allocate-node-cidrs` ✅ https://docs.cilium.io/en/stable/network/concepts/ipam/kubernetes/, kubeadm `manifests.go` L352). Per-CNI defaults would add a branch for no benefit. kube-proxy is kept for both (iptables mode).

**Both CNIs use VXLAN, so src/dst check stays enabled.** The encapsulated packets carry node IPs, so EC2 forwards them without disabling the check. BGP (179) and IPIP (protocol 4) are not used.

| | Calico (default) | Cilium |
|---|---|---|
| Version | **v3.33.0**, tested on k8s 1.35/1.36/1.37 ✅ (https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements) | **v1.20.3** (2026-10-15), tested on k8s 1.33–1.36 ✅ (`Documentation/network/kubernetes/requirements.rst` @v1.20.3). **1.37 is not listed** ⚠️ |
| Install | `kubectl create -f .../v3.33.0/manifests/v3_projectcalico_org.yaml` (CRDs for k8s ≥ 1.36 ✅ on-prem install doc), then `tigera-operator.yaml` (operator v1.44.0). Wait for CRD `installations.operator.tigera.io` Established, then `kubectl create` the TF-rendered `Installation` + `APIServer`. Goldmane/Whisker are omitted (saves RAM on t3.medium). | cilium-cli **v0.20.1** binary ("Cilium 1.17 and newer" ✅ cilium-cli README), sha256 `24e817dcfcc8a12e325ce7547617bcbcf171c5b0b335bb24d2bb1207ba047f61` ✅. `cilium install --version 1.20.3 --set ipam.mode=kubernetes --set routingMode=tunnel --set tunnelProtocol=vxlan --set kubeProxyReplacement=false`, then `cilium status --wait`. No Helm binary on the node. The CLI fetches the chart itself ⚠️ (source of the chart not verified) |
| Pinning | Download over HTTPS, then `sha256sum -c` against TF vars: `tigera-operator.yaml` `aef423b3…88ba`, `v3_projectcalico_org.yaml` `5306c2c6…26bd` (computed this session from raw.githubusercontent @v3.33.0) | binary checksum as above. Chart pinned by `--version` |
| Installation CR | `calicoNetwork: { bgp: Disabled, ipPools: [{ name: default-ipv4-ippool, cidr: ${pod_cidr}, encapsulation: VXLAN, natOutgoing: Enabled, blockSize: 26, nodeSelector: all() }] }` (`bgp` field ✅ operator v1.44.0 `installation_types.go`) | n/a |
| Ready check | `kubectl wait --for=condition=Available tigerastatus/calico --timeout=15m` ⚠️ (condition name) | `cilium status --wait --wait-duration 15m` |
| Ports between nodes | UDP 4789 VXLAN, TCP 5473 Typha ✅ (Calico requirements table) | UDP 8472 VXLAN, TCP 4240 health, ICMP 8/0 ✅ (Cilium system_requirements firewall rules). TCP 4244 Hubble if enabled later |

**SG decision:** a single self-referencing "all protocols" rule on the node SG covers both CNIs, the kubelet (10250), etcd (2379-2380), NodePorts, and labs that come later. That is simpler, and correct for a single-tenant lab SG. Per-port rules would be busywork that breaks whenever a student enables WireGuard or Hubble. The per-port lists above go in the README as documentation (a CKS exercise: "tighten the SG").

## 5. metrics-server and kubelet serving certs

**Decision:** `serverTLSBootstrap: true` + **kubelet-csr-approver v1.2.15**, and metrics-server **v0.9.0** stock `components.yaml` with **no `--kubelet-insecure-tls`**.
- metrics-server 0.9.x supports k8s 1.34+ ✅ (README compatibility matrix @v0.9.0). The manifest sha256 is `1cec29a5267809306a2c6ec74a3e449abbb705b4a8beed0c8a1963910f72c79b` (computed this session).
- kubeadm docs: kubelet-serving CSRs are not auto-approved and need "action from the user or a third party controller". They recommend kubelet-csr-approver and warn that approvers must check names and IPs ✅ (https://v1-36.docs.kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#kubelet-serving-certs).
- The approver is a TF-rendered manifest derived from upstream `deploy/k8s/*` @v1.2.15 (SA, ClusterRole with `signers approve` limited to `kubernetes.io/kubelet-serving`, CRB, Deployment). Image `ghcr.io/postfinance/kubelet-csr-approver:v1.2.15` (tag exists ✅), 1 replica with `-leader-election`, CP toleration. Env:
  - `PROVIDER_REGEX=^(cp|worker)-[0-9]+$`
  - `PROVIDER_IP_PREFIXES=${vpc_cidr}`
  - `BYPASS_DNS_RESOLUTION=true` (node names are not in DNS ✅ README parameters)
  - `MAX_EXPIRATION_SEC=31622400`
- Rationale: this teaches the correct pattern, and `--kubelet-insecure-tls` is explicitly "for testing purposes only" ✅ (metrics-server README). The cost is one extra Deployment.
- Kubelet serving CSR SANs on EC2 (hostname `cp-1` + InternalIP) are expected to pass the regex and IP-prefix checks ⚠️ (verify during the real apply). **Fallback** if it misbehaves: cp-1 runs a bounded loop that approves `kubernetes.io/kubelet-serving` CSRs whose username is `system:node:<known key>`.

## 6. Security

### 6.1 Security groups (`security.tf`, using `aws_vpc_security_group_{ingress,egress}_rule`)
| SG | Direction | Port | Source/Dest | Why |
|----|-----------|------|-------------|-----|
| node | in | all | node SG (self) | intra-cluster |
| node | in | 6443/tcp | NLB SG | API via NLB (client IP preservation off, F2) |
| node | out | all | 0.0.0.0/0 | apt, registries, SSM, NAT |
| nlb | in | 6443/tcp | each `operator_cidrs` | operator access |
| nlb | in | 6443/tcp | each `nat_public_ips` /32 | nodes reach the public NLB via NAT (F1) |
| nlb | in | ICMP 3/4 | 0.0.0.0/0 | PMTUD, per the AWS example ✅ |
| nlb | out | 6443/tcp | node SG | traffic and **health checks**, which obey outbound rules ✅ |

No port 22 and no key pair. The NLB **must** be created with an SG, because one can't be added later ✅ (NLB SG considerations).

### 6.2 NLB (`nlb.tf`)
- `aws_lb` with `internal = false`, `load_balancer_type = "network"`, the public subnets (3 AZs), `security_groups = [nlb]`, and `enable_cross_zone_load_balancing = true`, so a single CP serves all AZ IPs (default is false ✅ registry `r/lb`).
- `aws_lb_target_group`: TCP 6443, `target_type = "instance"`, **`preserve_client_ip = "false"`** (✅ registry `r/lb_target_group`), health check TCP 6443 with `interval = 10`, `healthy_threshold = 2`, `unhealthy_threshold = 2`, and `deregistration_delay = 30`.
- The listener is TCP 6443. Attachments come from `for_each` over the CP keys.
- Name: `"${cluster_name}-api"`, which must be ≤ 32 chars, so `name_prefix` is validated to ≤ 20 chars.
- The access trade-off is accepted (decision 5): with client IP preservation off, the apiserver audit logs show NLB IPs, not operator IPs. That makes a good CKS discussion point.

### 6.3 IAM (`iam.tf`): two roles, plus the `AmazonSSMManagedInstanceCore` attachment
`P = arn:aws:ssm:${region}:${account}:parameter/${cluster}`
- **control-plane role:** `ssm:GetParameter`, `ssm:GetParameters`, and `ssm:PutParameter` on `${P}/*`, plus `ssm:GetParametersByPath` on `${P}/*` ⚠️ (check the resource form for by-path during apply).
- **worker role:**
  - Get on `${P}/join/token` and `${P}/join/ca-cert-hash`, and on `${P}/nodes/*` (for the CP-ordering checks, harmless).
  - Put on `${P}/nodes/worker-*`.
  - **Explicit Deny** `ssm:GetParameter*` on `${P}/kubeconfig/*` and `${P}/join/certificate-key` (F5).
- **KMS:** no statement. `aws/ssm` already lets account principals decrypt via SSM ✅ (ps-restrict-decryption). Encrypt on Put through the AWS managed key is assumed to work the same way ⚠️ (watch for AccessDenied on the first apply; the fix is `kms:Encrypt`/`kms:Decrypt` with `kms:ViaService = ssm.${region}.amazonaws.com`).
- `AmazonEC2ReadOnlyAccess` and `ssm:*` on `*` are dropped.
- **Operator:** retrieval uses the operator's own credentials (`ssm:GetParameter` + `kms:Decrypt` via aws/ssm), which is normal for an admin.

### 6.4 Instances
- `metadata_options { http_tokens = "required", http_put_response_hop_limit = 1, http_endpoint = "enabled", instance_metadata_tags = "disabled" }`. With a hop limit of 1, containers on the pod network get no IMDSv2 token, because "going to the container is considered an additional network hop" ✅ (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html). hostNetwork pods (kube-proxy, calico-node, cilium-agent, static CP pods) share the host netns and **can** reach IMDS ⚠️ (inferred from the netns model, not stated by AWS). That gap is a CKS lab ("block 169.254.169.254 with NetworkPolicy / GlobalNetworkPolicy"). No component in this design needs IMDS from a pod.
- `root_block_device { volume_type = "gp3", volume_size = 30, encrypted = true, delete_on_termination = true }`.
- `instance_type`: `control_plane_instance_type` and `worker_instance_type`, both default `t3.medium` (2 vCPU / 4 GiB, which meets the kubeadm minimum).
- `lifecycle { ignore_changes = [ami, user_data_base64] }` (F11), plus a `precondition` that the rendered user_data base64 length is ≤ 21 845 (that's 16 KB raw, i.e. 4·⌈16384/3⌉), so the 16 KB limit fails at plan rather than at EC2 RunInstances.

### 6.5 Naming and tags
- `random_string.suffix` (4 chars, lower+numeric, no special) gives `cluster_name = "${var.name_prefix}-${suffix}"` with `name_prefix` default `kube-lab`. The cluster name is used for IAM names, SG names, the NLB, the SSM prefix, and Name tags (`<cluster>-cp-1`).
- `default_tags` in the provider are **static only** (`Project = "kube-lab"`, `ManagedBy = "terraform"`, `Environment = "lab"`) plus `var.tags`. The `Cluster = <cluster_name>` tag is applied through the module `tags` input, because a random value in `default_tags` is unknown at plan and produces perpetual "known after apply" tag diffs ⚠️ (known provider behaviour, not re-verified).
- Subnet tags `kubernetes.io/cluster/<name>` are dropped (there's no cloud controller).

## 7. AMI
`data "aws_ssm_parameter" "ubuntu" { name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" }`. The path matches Canonical's template `/aws/service/canonical/ubuntu/{product}/{release}/stable/{serial}/{arch}/hvm/{vol}/ami-id`, with `ebs-gp3` for ≥ 23.10 ✅ (https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/). Use `.insecure_value`, since an AMI ID isn't secret ✅ (data source docs).
- `var.ami_id` (default `null`) overrides it via `coalesce`.
- `ignore_changes = [ami]`: a new Canonical AMI must not replace nodes and wipe etcd. To pick up a new AMI, the operator runs `-replace` per node. A comment in the code says this.
- The SSM agent is preinstalled (snap) on Canonical Ubuntu Server AMIs ✅ (https://docs.aws.amazon.com/systems-manager/latest/userguide/ami-preinstalled-agent.html).

## 8. Versions and pins
| Item | Root | Child modules |
|------|------|---------------|
| Terraform | `required_version = ">= 1.11"` (value_wo ✅; mocks need ≥ 1.7, output `depends_on` and cross-var validation ≥ 1.9). Latest is 1.16.6, local is 1.16.0 | same |
| hashicorp/aws | `~> 6.69` (latest 6.69.1, 2026-10-15 ✅ registry API) | `>= 6.28` (VPC module floor) |
| hashicorp/random | `~> 3.9` (3.9.1 ✅) | (root only) |
| hashicorp/cloudinit | `~> 2.4` (2.4.1 ✅) | `>= 2.3` |
| vpc module | `6.7.3` exact | |
Removed: kubernetes, vault, helm, tls, time, external. `.terraform.lock.hcl` is committed, with multi-platform hashes (`terraform providers lock -platform=darwin_arm64 -platform=linux_amd64`).

Software pins are TF variables, so a version bump is one line plus a checksum:
- `k8s_version = "1.36.5"`
- `containerd_version = "2.3.*"`
- `calico_version = "v3.33.0"`
- `cilium_version = "1.20.3"`
- `cilium_cli_version = "v0.20.1"`
- `metrics_server_version = "v0.9.0"`
- `csr_approver_version = "v1.2.15"`
- `*_sha256` for each download

## 9. Host prep and package pins (`common.sh`)
1. Host prep: `swapoff -a` plus fstab comment-out, modules `overlay` and `br_netfilter`, sysctls `net.ipv4.ip_forward=1` and `net.bridge.bridge-nf-call-iptables`/`ip6tables=1` ✅ (kubernetes.io v1.36 container-runtimes).
2. APT with signed keyrings only:
   - Docker: `https://download.docker.com/linux/ubuntu/gpg` → `/etc/apt/keyrings/docker.asc`, then verify the fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` ⚠️ (could not re-fetch Docker's page this session; confirm against https://docs.docker.com/engine/install/ubuntu/).
   - Kubernetes: `https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/deb/Release.key` → `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`, with source line `deb [signed-by=...] https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/deb/ /` ✅ (install-kubeadm, the same key across minors).
3. `apt-get install -y containerd.io='${containerd_version}' kubelet='${k8s_version}-*' kubeadm='${k8s_version}-*' kubectl='${k8s_version}-*' gettext-base jq`. `cri-tools` and `kubernetes-cni` (1.9.1) come in as kubeadm dependencies from pkgs.k8s.io. Then `apt-mark hold kubelet kubeadm kubectl containerd.io` ✅ (install-kubeadm).
4. containerd: write a **minimal** `/etc/containerd/config.toml` (`version = 3` + `[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options] SystemdCgroup = true` ✅ container-runtimes v1.36) instead of sed on `config default`. containerd merges defaults ⚠️ (standard behaviour). The Docker package's `disabled_plugins = ["cri"]` file is replaced. Then `/etc/crictl.yaml` and `systemctl enable --now containerd kubelet`.
5. AWS CLI v2 via `snap install aws-cli --classic`, an official AWS-documented method ✅ (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
6. Ergonomics for `ubuntu` and `root`: kubectl completion, `alias k=kubectl`, vim 2-space tabs. No podman. **No etcdctl/etcdutl** (decision 10).

**Upgrade lab 1.36 → 1.37 (README):**
- Edit `/etc/apt/sources.list.d/kubernetes.list` to `v1.37` (https://v1-36.docs.kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/).
- `apt-mark unhold kubeadm && apt-get install kubeadm='1.37.1-*'`, then `kubeadm upgrade plan/apply` on cp-1 and `upgrade node` on the others, then kubelet and kubectl, per https://v1-36.docs.kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/.
- containerd 2.3 supports 1.37 ✅ (context). Calico 3.33 is tested on 1.37 ✅.
- **Cilium 1.20 is not tested on 1.37** ⚠️, so the README recommends `cni = "calico"` for the upgrade lab.

## 10. Outputs (nothing sensitive)
- `cluster_name`, `region`, `api_endpoint` (`https://<nlb_dns>:6443`), `ssm_parameter_prefix` (`/<cluster>`)
- `kubeconfig_command` = `./scripts/get-kubeconfig.sh <cluster> <region>`
- `wait_command` = `./scripts/wait-for-cluster.sh <cluster> <region>`
- `ssm_session_commands` = `{ for k, i in instances : k => "aws ssm start-session --target ${i.id} --region ${region}" }`
- `nodes` = `{ key => { role, private_ip, az, instance_id } }`
- `nat_public_ips`, for operators who want to understand the SG rule

## 11. Testing (`terraform test`, no credentials)
- `mock_provider "aws" { source = "./tests/mocks" }` with:
  - `mock_data "aws_availability_zones"` → `names = ["us-east-1a","us-east-1b","us-east-1c"]`
  - `mock_data "aws_ssm_parameter"` → `insecure_value = "ami-0123456789abcdef0"`
  - `mock_data "aws_caller_identity"` → `account_id = "123456789012"`
  - `mock_data "aws_iam_policy_document"` → `json = "{}"`
  - `mock_resource "aws_lb"` → `dns_name = "kl-api-abc.elb.us-east-1.amazonaws.com"`
  
  ✅ mock_data and override_data (https://developer.hashicorp.com/terraform/language/tests/mocking). `cloudinit` stays a **real** provider (no API), so rendered parts are genuine.
- Limitations:
  - mocks generate random strings for unset computed attributes, so ARNs, IDs, and `dns_name` must be pinned.
  - the module-level data sources in `terraform-aws-modules/vpc` are mocked too, but nested blocks can't be differentiated per instance ✅ (docs).
  - use `command = plan` with `override_during = plan` where assertions need values.
- Tests reference locals directly (assertions may use any named value ✅ tests docs):
  1. `nodes.tftest.hcl`:
     - defaults give `keys(local.nodes) == ["cp-1","worker-1","worker-2"]`
     - `cp=3, w=0` gives 3 CPs, all CP subnets distinct, and the init config contains `taints: []`
     - `worker_count=4` gives worker-4 in AZ index 0
  2. `validation.tftest.hcl` (`expect_failures`, plan only):
     - `control_plane_count = 2` and `0`
     - `worker_count = -1`
     - `cni = "flannel"`
     - `operator_cidrs = []` and `["0.0.0.0/0"]`
     - `pod_cidr = "10.10.0.0/16"` (overlaps VPC)
     - `service_cidr` overlapping `pod_cidr`
  3. `user_data.tftest.hcl`:
     - cp-1 parts contain `kubernetesVersion: v1.36.5`, `core:/stable:/v1.36`, `controlPlaneEndpoint`, and `serverTLSBootstrap: true`
     - workers don't contain `kubeadm init`
     - every node is under 16 KB raw (the precondition)
  4. `cni.tftest.hcl`:
     - `cni = "cilium"` gives cp-1 parts containing `cilium install --version 1.20.3` and not `tigera-operator`
     - the default contains `tigera-operator` and `encapsulation: VXLAN`
- CI also runs `shellcheck` on rendered scripts: a small test-only output can't do that, so CI renders the templates with `terraform console`/`templatefile` into `build/` and runs shellcheck there.

## 12. Cost (us-east-1, defaults: 1 CP + 2 workers)
| Item | Rate | Per hour |
|------|------|----------|
| 3 × t3.medium | $0.0416/h ✅ (AWS price list API) | $0.125 |
| NAT gateway (1) | $0.045/h ✅ (VPC pricing) | $0.045 |
| NLB | $0.0225/h + about 1 NLCU-hour at $0.006 ✅ (ELB pricing) | ≈ $0.029 |
| Public IPv4: 1 NAT EIP + 3 NLB AZ IPs | $0.005/h each ✅ | $0.020 |
| EBS gp3 3 × 30 GiB | ≈ $0.08/GB-month ⚠️ | ≈ $0.010 |
| SSM Advanced param (1) | $0.05/month ✅ | ~0 |
| **Total** | | **≈ $0.23/h ≈ $5.5/day ≈ $165/month** |

There is also a one-off NAT data processing charge of $0.045/GB (about 2–3 GB of images and packages on first boot, roughly $0.15). An HA variant (3 CP + 2 W) runs about $0.31/h. Lowering the price would mean an on-demand NAT instance or public subnets, both rejected by decision 4. The README says to destroy after each session.

## 13. Failure modes
| Failure | Symptom | Behaviour | Diagnose / recover |
|---------|---------|-----------|--------------------|
| cp-1 `kubeadm init` fails | `status/cluster` stays `pending`, cp-1 shows `failed:init` | ERR trap writes the status. Joiners keep polling until the 40 min cap, then write `failed:wait-join` | `wait-for-cluster.sh` exits 1. SSM into cp-1: `less /var/log/kube-lab-bootstrap.log`, `/var/log/cloud-init-output.log`, `journalctl -u kubelet -u containerd`, `crictl ps -a`. Fix: `terraform apply -replace='module.cluster.aws_instance.node["cp-1"]'` plus a full re-apply (simplest is destroy + apply) |
| NAT not ready at boot | apt/curl timeouts | Prevented by the gated subnet output (§2.3). `retry` with backoff covers transient blips | cloud-init-output.log |
| apt mirror / pkgs.k8s.io / GitHub down | `failed:packages` or `failed:cni` | retry 5× with backoff, then fail loudly | log. Re-run step-wise with `sudo /var/lib/cloud/instance/scripts/part-00N` (the idempotency guards skip finished steps) |
| SSM params missing / AccessDenied | joiners stuck `bootstrapping` | the poll loop logs the AWS error each iteration | `aws ssm get-parameters-by-path --path /<cluster> --recursive`. Check the IAM policy and the ⚠️ KMS assumption in §6.3 |
| Token expired (node added > 24 h later) | join `token not found` | prevented by the 12 h refresh timer | `systemctl status kube-lab-refresh-join.timer` on cp-1. Manual: `kubeadm token create` then put-parameter |
| Cert key expired (CP added > 2 h later) | CP join fails downloading certs | expected, by design | run `sudo kube-lab-refresh-join --upload-certs` on cp-1. The joining CP picks it up on its next poll |
| NLB target unhealthy / not yet registered | joiners loop on `/livez` = `000` | wait capped at 15 min, then `failed:wait-api` | `aws elbv2 describe-target-health`. Check that the node SG allows 6443 from the NLB SG and the NLB SG egress. Check cp-1 apiserver with `crictl logs` |
| Operator `kubectl` times out | CIDR not in `operator_cidrs` | NLB SG drops it (`SecurityGroupBlockedFlowCount_Inbound` ✅) | update `operator_cidrs`, then `terraform apply` (in-place SG rule change) |
| Two CPs join concurrently | etcd `too many learner members` | prevented by the serialized CP chain (F10) | — |
| CNI not ready | nodes `NotReady`, `failed:cni` | timeout of 15 min | `kubectl -n tigera-operator logs deploy/tigera-operator`, `kubectl get tigerastatus` / `cilium status` |
| metrics-server not Ready | `kubectl top` fails | kubelet-serving CSRs Pending | `kubectl get csr`, approver logs. Fallback is manual `kubectl certificate approve` |
| user_data > 16 KB | plan fails | precondition (§6.4) | trim the templates. Never inline manifests |

## 14. Explicitly not doing (YAGNI)
Route53 private zone or `/etc/hosts` endpoint tricks (F3 makes them unnecessary) · ASGs or launch templates (static named nodes suit labs) · remote state · AWS cloud controller or EBS CSI · Kubernetes/Helm TF providers · Hubble, Goldmane, or Whisker by default · audit policy, PSA, encryption-at-rest (CKS student work, decision 11).

## Implementation notes (as built)

Added after the audit of main @ 36def8e and the phase-1 fixes. The sections above are kept as
the original design.

- File tree (§1): Every module has `terraform.tf`, not `versions.tf`. `modules/cluster/nodes.tf`
  became `main.tf`. Bootstrap rendering lives in a provider-less submodule,
  `modules/cluster/bootstrap`, with `files/` (scripts and units copied verbatim: `lib.sh`,
  `control-plane.sh`, `worker.sh`, `kube-lab-refresh-join.sh`, the systemd units) and `templates/`
  (`cluster.env`, kubeadm init/join, Calico Installation, kubelet-csr-approver). There is no
  `common.sh.tftpl`, `cloud-config.yaml.tftpl` or `refresh-join.sh.tftpl`; the cloud-config is
  built with `yamlencode` in `bootstrap/main.tf`. Tests also include `cluster.tftest.hcl`,
  `network.tftest.hcl` and the `tests/render` harness used by `scripts/render-templates.sh` and
  `scripts/validate-kubeadm-config.sh`.
- Status values (§3.1): As built, nodes go `pending → bootstrapping → waiting → joining →
  joined`; cp-1 goes `pending → bootstrapping → initializing → initialized → joined`; the
  cluster goes `pending → installing → ready`. `installing` is a cluster status, not a node
  status. `docs/architecture.md` has the full table. The cp-1 wait step is `wait-nodes`, as
  §3.2 planned; `containerd`, `shell`, `local-kubeconfig` and `root-kubeconfig` are steps of
  their own, so every failure reports the step that was running.
- Join token timer (§3.5): `OnBootSec=5min`, not 1h, so a cluster restarted after more than a
  day gets a valid token within minutes.
- Shellcheck (§11): CI checks `modules/cluster/bootstrap/files/*.sh` in place with `-x`. The
  render harness is only used for the size report and the kubeadm config check.
- IAM (§6.3): `AmazonSSMManagedInstanceCore` is not attached. Both roles get an inline
  Session Manager policy instead. The control-plane role has `ssm:GetParameter`,
  `ssm:GetParameters` and `ssm:PutParameter` on `/<cluster>/*`, without
  `ssm:GetParametersByPath`. After e2e run 1, the six `ec2messages` actions were dropped, so
  the inline policy is exactly AWS's minimal Session Manager policy (plan R9).
- Host prep (§9): The container-runtimes page only documents `net.ipv4.ip_forward`. The
  `br_netfilter` module and the `bridge-nf-call-*` sysctls are kept, but the ✅ on them above is
  wrong.
- Upgrade lab (§9): The 1.36 → 1.37 procedure is on the current kubernetes.io page, not the
  v1-36 site, and the other nodes must upgrade the kubeadm package before `kubeadm upgrade node`.
  See `docs/labs/upgrade.md`.
- Outputs (§10): The URL output is `api_url`. Inside the modules, `api_endpoint` stays
  `host:port`, as kubeadm uses the word. The module output `instances` became `nodes`.
- Validations (§2.2): Version pins, `region`, `ami_id` and node roles are validated too, and a
  precondition rejects non-x86_64 instance types.
- Tests (§11): The CNI tests assert on the `CNI=` line in `cluster.env` and on which
  manifests ship, because both installers live in `control-plane.sh`.

