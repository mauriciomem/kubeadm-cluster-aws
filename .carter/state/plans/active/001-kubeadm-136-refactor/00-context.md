# kube-cluster refactor — shared context (written by carter-maestro)

Repo: <repo-root>/infra/aws/kube-cluster
Purpose: LEARNING-ONLY kubeadm cluster on AWS EC2 for CKA/CKS/CKAD labs (kubeadm upgrades 1.36->1.37,
etcd inspection/backup/restore, security hardening practice). Operator runs `terraform apply`, gets a
working cluster with all nodes Ready, then "forgets about the underlying cluster".

## Current state (audit by maestro, 2026-10-15)
- Forked from a HashiCorp Vault demo (origin hashicorp/demo-vault-trusted-identity). Vault/LDAP/PG files deleted uncommitted.
- Root: terraform.tf (aws 6.25.0, kubernetes, vault pinned; no required_version), providers.tf, variables.tf,
  locals.tf (hardcoded Route53 domain <old-personal-route53-zone>), main.tf (data "external" curl
  api.ipify.org; 1 master + 1 worker hardcoded w/ cidrhost static IPs), outputs.tf, kubernetes_addons.tf (all commented).
- modules/network (terraform-aws-modules/vpc 6.5.1, 3 AZ, NAT; public/private cidr locals swapped),
  modules/sg (generic rule map), modules/kubernetes (1 EC2/call; IAM role w/ ssm:* on "*", EC2ReadOnly;
  key pair+tls key; Route53 A record; SSM param data->resource loop after time_sleep 180s),
  modules/kubernetes-addons (helm, unused). Templates cks-master.sh.tftpl / cks-worker.sh.tftpl:
  k8s 1.32.5, two apt repos, --allow-unauthenticated, duplicated containerd block, `read` in cloud-init,
  worker never joins, no CNI, join token --ttl 0 as SSM String, kubeconfig as SSM String output unsensitive.
- Private STRIDE AMI (owner <private-ami-owner-account>) — not portable. Root volume unencrypted. IMDS hop limit 2.
- .github: JIRA + Sherpa DDR workflows, dependabot for nonexistent dirs. README is the Vault demo.

## Verified facts (official sources, fetched 2026-10-15)
- Kubernetes: stable-1.36 = v1.36.5 (dl.k8s.io/release/stable-1.36.txt). pkgs.k8s.io v1.36 debs: kubeadm/kubelet/kubectl 1.36.5-1.1,
  kubernetes-cni 1.9.1-1.1. v1.37.1 exists (good for upgrade lab).
- containerd RELEASES.md matrix: k8s 1.36 -> containerd 2.3.0+, 2.2.0+; k8s 1.37 -> 2.4.0+, 2.3.0+. 1.7 EOL Sep 2026.
  2.3 is LTS until 2028-04-30. Docker apt repo (download.docker.com, noble) has containerd.io 2.3.6-1~ubuntu.24.04~noble.
  Ubuntu noble archive containerd = 2.2.1 (would block 1.37 upgrade lab). => use containerd.io 2.3.x from Docker repo, pinned.
- containerd 2.x systemd cgroup config path (kubernetes.io v1.36 container-runtimes):
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options] SystemdCgroup = true
- kubeadm config API: kubeadm.k8s.io/v1beta4 (current in 1.36). 1.36 changelog: NodeLocalCRISocket GA, ControlPlaneKubeletLocalMode
  removed (GA), etcd < 3.6 unsupported, flex-volume removed. ContainerRuntimeVersion preflight checks RuntimeConfig RPC.
- Calico v3.33.0 tested on k8s 1.35/1.36/1.37 (docs.tigera.io). Cilium latest v1.20.2 (verify its k8s compat matrix).
- cri-tools latest v1.37.0.

## Operator decisions (FINAL — do not re-litigate)
1. Subagent model: claude-opus-5-5.
2. Git: fresh `git init` (delete existing .git, history not kept). Delete terraform.tfstate AND terraform.tfstate.backup, no backup.
3. State: local backend (state gitignored).
4. Nodes in PRIVATE subnets + NAT gateway (single NAT default).
5. API access: ALWAYS an internet-facing NLB on 6443, restricted to `operator_cidrs` (NLB security group), same endpoint for 1..N CPs.
   controlPlaneEndpoint = NLB DNS name from day one. (Consider hairpin: NLB w/ client IP preservation & targets calling themselves via NLB —
   nodes should talk to API via the NLB too; check AWS docs on NLB hairpin/loopback with client IP preservation and pick target type/settings accordingly.)
6. Operator CIDR: required variable `operator_cidrs` with validation, NO auto-detect.
7. Shell: SSM Session Manager only; no SSH ingress, no key pair.
8. CNI: variable, support Calico and Cilium, Calico default. Pinned versions.
9. Instances: t3.medium amd64 for all nodes by default (variables allow override).
10. Extras: metrics-server (pinned). Do NOT install etcdctl/etcdutl (student exercise).
11. Hardening: secure infrastructure (SSM SecureString, least-priv IAM scoped to cluster param path, IMDSv2 hop 1 w/ note,
    encrypted gp3 root), but vanilla kubeadm cluster (no audit policy, no PSA config, no encryption-at-rest) — left for CKS labs.
12. Remove Vault leftovers (README, assets/, CONTRIBUTING.md, JIRA/Sherpa workflows, dependabot junk). New README.
    New CI workflow: fmt, validate, tflint, shellcheck, terraform test (mock providers), trivy optional.
13. Default region us-east-1.
14. End: real apply -> verify all nodes Ready + smoke test -> destroy, every AWS-mutating step confirmed by the user.
15. Defaults: 1 control plane, 2 workers; operator can set control_plane_count (odd numbers for etcd quorum) and worker_count.
16. K8s baseline 1.36 (pin patch 1.36.5 as default variable). Ubuntu 24.04 Canonical AMI.
17. Comments: succinct, human-readable. Code readable by humans.
