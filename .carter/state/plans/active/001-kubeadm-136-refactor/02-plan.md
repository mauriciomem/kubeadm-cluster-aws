---
id: 001-kubeadm-136-refactor
title: kube-cluster refactor to kubeadm 1.36.5 lab cluster (private nodes, NLB API, SSM-only)
status: active
owner: carter-pm
created: 2026-10-16
sources: [00-context.md (decisions, FINAL), 01-design.md (architecture; do not re-design)]
must_haves:
  - MH1  Default `terraform apply` (only operator_cidrs set) yields cp-1 + worker-1 + worker-2, all `Ready`, all `v1.36.5`
  - MH2  CNI pods Running: Calico default (`tigerastatus` Available); `cni="cilium"` passes `terraform test` (live Cilium is optional)
  - MH3  `kubectl top nodes` returns metrics for every node, with no `--kubelet-insecure-tls` (serving CSRs approved by kubelet-csr-approver)
  - MH4  No secrets in state: `grep -E 'B[E]GIN|[a-z0-9]{6}\.[a-z0-9]{16}|certificate-authority-dat[a]|client-key-dat[a]' terraform.tfstate` (bracketed so the plan doesn't match its own pattern) matches nothing
  - MH5  `operator_cidrs` is required (no default, no auto-detect); `[]`, a malformed CIDR, and `0.0.0.0/0` are rejected at plan
  - MH6  Even (and 0) `control_plane_count` is rejected at plan; CIDR overlap (pod/service/vpc) is rejected
  - MH7  `terraform fmt -check -recursive`, `validate`, `tflint --recursive`, `shellcheck` (rendered scripts), and `terraform test` all pass; trivy config has no unaccepted HIGH/CRITICAL findings (accepted ones are listed with reasons)
  - MH8  `terraform output` has no sensitive values (no kubeconfig, token, cert key, or CA hash); no output is marked sensitive to hide one
  - MH9  After `terraform destroy`: `aws ssm get-parameters-by-path --path /<cluster> --recursive` is empty, and no instances, NLB, NAT, or EIP tagged with the cluster remain
  - MH10 README covers prereqs, usage, access (kubeconfig + SSM), upgrade lab 1.36→1.37, etcd lab pointers (etcdctl NOT installed), costs, troubleshooting, and scaling caveats
  - MH11 Comments are short and readable; no Vault/LDAP/STRIDE/Route53 leftovers (`grep -rniE 'vault|ldap|stride|hashi[d]emos|ipify' . --exclude-dir=.git --exclude-dir=.terraform --exclude-dir=.carter` is clean)
---

# Plan 001: kubeadm 1.36 refactor

## Execution model
- **One engineer (carter-engineer) runs P1–P6 in sequence in a single session** so naming, variables, and template contracts stay consistent. Splitting the work would mean renegotiating interfaces (node map, SSM paths, template vars) between agents. Parallel work is limited to the cases below.
- carter-devops owns git, state, CI runs, and every AWS-mutating command. **Every `apply` or `destroy` needs the user to confirm it first.**
- carter-security reviews in P7. It is advisory, and fixes go back to the engineer.
- Git decision: after P0 the repo has a `.gitignore` and **no commit**. The **first commit comes at the end of P1** (network module validates). After that there is one commit per step (`git reset --hard <prev-step>` is the rollback). Rule: `.gitignore` (state, `.terraform/`, `build/`, `*.tfvars` except `*.tfvars.example`) must exist before any `git add`.

| Step | Owner | Depends on | Parallel? | Effort |
|------|-------|-----------|-----------|--------|
| P0 Repo hygiene | devops | — | — | 0.25 h |
| P1 Network module | engineer | P0 | — | 0.5 h |
| P2 Cluster module skeleton (IAM/SG/NLB/SSM/nodes) | engineer | P1 | — | 1.5 h |
| P3 Bootstrap templates | engineer | P2 | — | 3 h |
| P4 Root wiring, variables, outputs, scripts | engineer | P3 | — | 1 h |
| P5 Tests, tflint, CI | engineer | P4 | CI yaml can be drafted alongside P4 | 1.5 h |
| P6 README | engineer (carter-docs skill) | P4 | **can run in parallel with P5** (2nd engineer session) | 1 h |
| P7 Static gate + reviews (≤ 2 rounds) | devops + security + engineer | P5, P6 | security and code review run **in parallel** | 1–2 h |
| P8 Live e2e | devops (+ user) | P7 | — | 1–1.5 h wall |
| P9 Fix-from-e2e + final commit | engineer → devops | P8 | — | 0.5–2 h |

Total ≈ 11–14 h of agent effort. The e2e wall time is ≈ 60–80 min: plan 2 min, apply ≈ 4–6 min (NAT/NLB), bootstrap ≈ 12–20 min until `ready`, verification 10–15 min, destroy ≈ 5–8 min, leftovers check 2 min. Allow up to 2 re-runs (+40 min each) in P9.

---

## P0: Repo hygiene (carter-devops)
- **Inputs:** 00-context decision 2 and 12.
- **Actions:**
  - `rm -f terraform.tfstate terraform.tfstate.backup` (no backup, decision 2).
  - `rm -rf .git .terraform/ .terraform.lock.hcl`.
  - Delete: `README.md assets/ CONTRIBUTING.md .github/workflows/jira.yml .github/workflows/releaser-default.yml .github/dependabot.yml modules/sg modules/kubernetes modules/kubernetes-addons kubernetes_addons.tf`. Old templates go with `modules/kubernetes`.
  - `git init -b main`, then write `.gitignore`.
- **Files:** `.gitignore` (new).
- **Acceptance:**
  - `ls` shows no tfstate files and no `.git` history (`git log` errors with "does not have any commits").
  - `git status --ignored` lists `.terraform/` and `*.tfstate*` as ignored once they exist.
  - `grep -rIl -iE 'vault|ldap|sherpa|jira' . --exclude-dir=.git` lists only files that P1–P4 will rewrite (root `*.tf`, `modules/network`).
- **Risk/rollback:** this step is irreversible by decision. Confirm there is no live AWS infra referenced by the old state before deleting it. Ask the user once: "Old state will be deleted; any resources it tracks become unmanaged — proceed?"

## P1: Network module (carter-engineer)
- **Inputs:** design §1 (vpc 6.7.3 exact), §2.3 (NAT-gated output), F7 (vpc_cidr 10.10.0.0/16).
- **Files:** `modules/network/{versions.tf,main.tf,variables.tf,outputs.tf}`.
- **Content:**
  - 3 AZs from `aws_availability_zones`, with public and private CIDRs correctly assigned (fixes the swap).
  - `single_nat_gateway = true`.
  - Outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids` (with `depends_on` on the NAT routes), `nat_public_ips`.
- **Acceptance:** `terraform -chdir=modules/network init -backend=false && terraform -chdir=modules/network validate` and `terraform fmt -check -recursive modules/network`.
- **Risk/rollback:** the output name for NAT route IDs in v6.7.3 could differ. Check the upstream `outputs.tf`. Rollback is to delete the dir. **Commit 1:** `chore: fresh baseline + network module`.

## P2: Cluster module skeleton (carter-engineer)
- **Inputs:** design §6.1–6.5, §3.1, §7, F1/F2/F4/F5/F6/F11.
- **Files:** `modules/cluster/{versions.tf,variables.tf,locals.tf,iam.tf,security.tf,nlb.tf,ssm.tf,nodes.tf,outputs.tf}`.
- **Content:**
  - IAM: 2 roles + SSMManagedInstanceCore. CP role gets Get/Put/ByPath on `/<cluster>/*`. Worker role gets the scoped Get/Put plus an **explicit Deny** on `kubeconfig/*` and `join/certificate-key`.
  - SGs: the tables in §6.1. No port 22.
  - NLB: SG attached at create, cross-zone on, TG `preserve_client_ip="false"`.
  - SSM: params with `value_wo="pending"` / `value_wo_version=1`; kubeconfig is `Advanced`.
  - Nodes: `aws_instance for_each`, IMDSv2 hop 1, gp3 encrypted, `ignore_changes=[ami,user_data_base64]`, and a user_data size precondition (≤ 21 845 b64). Use a placeholder `cloudinit_config` until P3.
- **Acceptance:**
  - `terraform validate` on the module.
  - `grep -n 'value\s*=' modules/cluster/ssm.tf` shows no plaintext `value =` (only `value_wo`).
  - `grep -n '"\*"' modules/cluster/iam.tf` shows no wildcard resources except managed-policy attachments.
- **Risk/rollback:** R1 (KMS on Put) and R6 (hairpin) are encoded here but only retired in P8. Rollback with `git reset --hard` to commit 1. **Commit 2.**

## P3: Bootstrap templates (carter-engineer)
- **Inputs:** design §1.1, §3.2–3.6, §4, §5, §9. The pins table in §8 (versions + sha256 as variables).
- **Files (`modules/cluster/templates/`):** `cloud-config.yaml.tftpl`, `common.sh.tftpl`, `control-plane.sh.tftpl`, `worker.sh.tftpl`, `kubeadm-init.yaml.tftpl`, `kubeadm-join.yaml.tftpl`, `calico-installation.yaml.tftpl`, `kubelet-csr-approver.yaml.tftpl`, `refresh-join.sh.tftpl` (+ systemd timer/service via `write_files`). Wire the real `data "cloudinit_config"` (gzip + base64) in `nodes.tf`.
- **Rules:**
  - Scripts:
    - `set -Eeuo pipefail` + ERR trap writing `failed:<step>`
    - a `retry` helper
    - `.done` guards
    - no `read`, no `--allow-unauthenticated`
  - Downloads:
    - every download is `sha256sum -c` verified
    - nothing upstream is inlined
  - Join order:
    - CP joins serialized on the previous CP's status (cp-2 waits on cp-1 `initialized`)
    - workers join in parallel after `/livez` ≠ `000`
  - Addons:
    - Calico CRDs → operator → wait CRD Established → CRs
    - Cilium via cilium-cli, `ipam.mode=kubernetes`, VXLAN
    - csr-approver → metrics-server
  - Timer: 12 h token refresh. `--upload-certs` is manual only.
  - Do NOT install etcdctl/etcdutl.
- **Acceptance:**
  - `terraform console` / `templatefile` renders each script into `build/`, and `shellcheck -S warning build/*.sh` is clean.
  - The rendered cp-1 user_data is < 16 KB raw (precondition passes in plan).
  - `grep -c kubeadm\ init build/worker*.sh` returns 0.
- **Risk/rollback:** R2, R3, R4, R5, R7, R8 live here. Keep each addon in its own function, so a fallback (e.g. the manual CSR-approve loop) is a local change. **Commit 3.**

## P4: Root wiring, variables, outputs, scripts (carter-engineer)
- **Inputs:** design §2.1–2.2, §3.5, §6.5, §8, §10.
- **Files:** `terraform.tf` (required_version `>= 1.11`, pins), `providers.tf` (static `default_tags`), `variables.tf` (all validations: odd CP 1–7, workers 0–20, operator_cidrs, cni, k8s_version regex, name_prefix ≤ 20, CIDR overlap), `locals.tf`, `main.tf` (random suffix, modules, opt-in `terraform_data` wait), `outputs.tf` (non-sensitive set from §10), `scripts/get-kubeconfig.sh`, `scripts/wait-for-cluster.sh`, `terraform.tfvars.example`, `.terraform.lock.hcl` (`terraform providers lock -platform=darwin_arm64 -platform=linux_amd64`).
- **Acceptance:**
  - `terraform init -backend=false && terraform validate`.
  - `shellcheck scripts/*.sh`.
  - `terraform plan` without operator_cidrs prompts or errors (no default).
  - `grep -n sensitive outputs.tf` returns nothing.
  - `grep -riE 'ipify|external|hashi[d]emos|route53' *.tf modules/` is empty.
- **Risk/rollback:** cross-variable validation syntax errors on TF < 1.9 (the required_version guards that). **Commit 4.**

## P5: Tests, tflint, CI (carter-engineer)
- **Inputs:** design §11.
- **Files:** `tests/mocks/aws.tfmock.hcl`, `tests/{nodes,validation,user_data,cni}.tftest.hcl`, `.tflint.hcl` (terraform + aws ruleset, pinned), `.trivyignore` (if needed, with reasons), `.github/workflows/ci.yml` (fmt, validate, tflint, render+shellcheck, `terraform test`, trivy config as optional/soft-fail job; pinned action SHAs).
- **Acceptance:**
  - `terraform test` passes all four files, including every MH5/MH6 `expect_failures` case.
  - `tflint --init && tflint --recursive` is clean.
  - `trivy config --severity HIGH,CRITICAL .` shows each finding fixed or listed in `.trivyignore` with a reason. Expected accepted findings: NLB public, egress 0.0.0.0/0, ICMP from 0.0.0.0/0.
  - `actionlint` (if available) is clean on ci.yml.
- **Risk/rollback:** mocks returning random strings for computed attrs break assertions. Pin them per design §11. **Commit 5.**

## P6: README (carter-engineer, carter-docs skill; may run parallel to P5)
- **Files:** `README.md`.
- **Sections:**
  - What/why (learning lab), architecture diagram (mermaid), prereqs (TF ≥ 1.11, aws CLI v2 + session-manager-plugin, creds).
  - Quickstart: tfvars `operator_cidrs`, apply, `wait-for-cluster.sh`, `get-kubeconfig.sh`.
  - Access via SSM. Variables table.
  - Scaling caveats: drain/delete before scale-down, cert-key 2 h + `kube-lab-refresh-join --upload-certs`, no cp-1 replacement.
  - Upgrade lab 1.36→1.37 (repo switch, use Calico).
  - etcd lab pointers (install etcdctl yourself, cert paths under `/etc/kubernetes/pki/etcd`).
  - CKS hardening ideas (audit, PSA, encryption-at-rest, tighten SG, IMDS block).
  - Costs (§12) + "destroy after each session". Troubleshooting (§13 table). Version bump procedure (var + sha256).
- **Acceptance:** each MH10 heading is present (`grep -E '^## ' README.md`), and every command in README exists in the repo or outputs. **Commit 6.**

## P7: Static gate + reviews (≤ 2 fix rounds)
- **Gate (devops):** `terraform fmt -check -recursive && terraform validate && tflint --recursive && shellcheck scripts/*.sh build/*.sh && terraform test && trivy config --severity HIGH,CRITICAL .` locally, plus the same CI run if a remote exists (local `act` is optional).
- **Reviews in parallel:**
  - carter-security (carter-secure-review): IAM scope and Deny, SG rules, state secrecy (F4), IMDS, download verification, apt key handling, outputs.
  - carter-engineer (carter-code-review): script robustness, idempotency, readability/comments, test coverage of MH5/MH6.
- **Loop:** findings → engineer fixes → gate re-run. **Max 2 rounds.** Anything unresolved goes back to the user as an explicit accept/defer decision.
- **Acceptance:** gate is green, no open HIGH review findings, MH7/MH8/MH11 checked. **Commit 7** (`chore: static gate green`).

## P8: Live e2e (carter-devops; **user confirms each AWS-mutating step**)
1. The user refreshes AWS creds. Check with `aws sts get-caller-identity` and confirm account/region with the user.
2. `terraform init && terraform plan -out=tfplan -var 'operator_cidrs=["<ip>/32"]'`. Review the counts (≈ 3 instances, 1 NLB, 1 NAT, ~13 SSM params). **Confirm → `terraform apply tfplan`.**
3. `./scripts/wait-for-cluster.sh <cluster> us-east-1` → exit 0 (40 min cap).
4. `eval "$(./scripts/get-kubeconfig.sh ...)"`, then verify:
   - `kubectl get nodes -o wide`: 3 nodes Ready, v1.36.5 (MH1)
   - `kubectl get pods -A`: all Running/Completed; `kubectl get tigerastatus` Available (MH2)
   - `kubectl get csr` all Approved; `kubectl top nodes` (MH3)
   - Smoke: `kubectl create deploy web --image=nginx --replicas=4`, `kubectl expose deploy web --port 80`. Pods are spread on both workers, and `kubectl run t --rm -it --image=busybox -- wget -qO- web` succeeds from each node's pods (cross-node VXLAN).
   - NetworkPolicy: apply default-deny ingress to the namespace, and the same wget times out. Delete the policy and it works again.
   - SSM: `aws ssm start-session` to worker-1. `aws ssm get-parameter --name /<cluster>/kubeconfig/admin --with-decryption` from that node must return **AccessDenied** (F5 Deny).
   - State: the MH4 grep on `terraform.tfstate` returns nothing. `terraform output` is reviewed (MH8).
5. **Confirm → `terraform destroy`.** Then check leftovers (MH9):
   - `aws ssm get-parameters-by-path --path /<cluster> --recursive --query 'Parameters[].Name'` returns `[]`
   - `aws ec2 describe-instances --filters Name=tag:Cluster,Values=<cluster> Name=instance-state-name,Values=pending,running,stopping,stopped` returns empty
   - `aws elbv2 describe-load-balancers --names <cluster>-api` returns not found
   - `aws ec2 describe-nat-gateways --filter Name=tag:Cluster,Values=<cluster>` returns only `deleted`
   - `aws ec2 describe-addresses --filters Name=tag:Cluster,Values=<cluster>` returns empty
- **Risk/rollback:** on a bootstrap failure, collect logs via SSM first (`/var/log/kube-lab-bootstrap.log`, cloud-init-output, `journalctl -u kubelet`), **then destroy** (confirmed) so it doesn't keep billing (~$0.23/h). Never leave the cluster running between sessions.

## P9: Fix-from-e2e loop + final commit
- The engineer fixes the root cause (most likely R1/R2/R4/R6/R8), the P7 gate re-runs, and P8 re-runs (each apply/destroy confirmed). Max 2 re-runs before escalating to the user.
- Optional: one extra apply with `cni="cilium"` (user's choice; Cilium not tested on 1.37 is documented).
- devops: final `git add -A && git commit -m "feat: kubeadm 1.36.5 lab cluster"`. Confirm `git ls-files | grep -E 'tfstate|\.terraform/'` is empty. Move the plan to `completed/` with `status: completed` once all MH are ticked.

---

## Risk register
| # | Risk (design ⚠️) | Impact | Likelihood | Mitigation | Retired in |
|---|------------------|--------|-----------|------------|-----------|
| R1 | KMS Encrypt on `PutParameter` via `aws/ssm` is denied without an explicit KMS statement (§6.3) | cp-1 can't publish join data, so the whole cluster stalls | M | ERR trap shows `failed:publish` fast. Pre-write the fix (`kms:Encrypt/Decrypt` + `kms:ViaService=ssm.<region>.amazonaws.com`) as a commented block ready to enable. Check whether by-path needs the path resource form (`parameter/<cluster>` and `/*`) | P8 |
| R2 | kubelet-csr-approver rejects EC2 serving-CSR SANs (hostname `cp-1` + InternalIP) (§5) | `kubectl top` fails (MH3) | M | `BYPASS_DNS_RESOLUTION=true`, regex/IP prefix from vars. Fallback: a bounded on-node approve loop limited to `system:node:<known key>`, kept behind a function | P8 |
| R3 | cilium-cli chart source/version not verified; Cilium 1.20 untested on 1.37 (§4) | Cilium path fails or upgrade lab breaks | M | Calico is default and the live e2e path. Cilium is covered by `terraform test` plus an optional live run in P9. README says to use Calico for the upgrade lab | P5 (render) / P9 (optional live) |
| R4 | `tigerastatus/calico` condition name isn't `Available` (§4) | ready-wait times out → `failed:cni` though Calico works | M | Check against the operator v1.44.0 API during P3. Fallback wait: `kubectl -n calico-system rollout status ds/calico-node` | P3 (check) / P8 |
| R5 | Docker apt key fingerprint `9DC8…CD88` unconfirmed (§9) | apt fails on every node, or (worse) an unverified key is used | L | P3 fetches https://docs.docker.com/engine/install/ubuntu/ and confirms. The script hard-fails on mismatch | P3 |
| R6 | NAT hairpin to the public NLB: NAT EIP rule / `preserve_client_ip=false` wrong (F1/F2) | joiners loop on `/livez`=`000` → `failed:wait-api` | L-M | SG rules from `nat_public_ips`, TG client-IP-preservation off, NLB SG egress to node SG. Diagnose with `describe-target-health` + `SecurityGroupBlockedFlowCount` | P8 |
| R7 | user_data > 16 KB raw on cp-1 (§1.1) | plan fails (precondition) or RunInstances rejects | M | gzip mandatory, no inlined manifests, precondition + `user_data.tftest.hcl` size assertion | P3 / P5 |
| R8 | cloud-init timing: NAT not ready, slow image pulls on t3.medium, 40 min caps too tight or too loose (§3.3, §13) | flaky first boot, false `failed:*` | M | NAT-gated subnet output, `retry` backoff, 8 m CP health timeout, 15 m discovery. Measure actual bootstrap time in P8 and tune the caps in P9 | P8 / P9 |
| R9 | Session Manager now uses an inline policy (`ssm:UpdateInstanceInformation`, `ssmmessages:*Channel`, `ec2messages:*`) instead of `AmazonSSMManagedInstanceCore`; the SSM Agent may need an action that isn't listed (P7 S2) | `aws ssm start-session` fails or nodes never show as managed, so operators lose shell access | L-M | Actions follow the AWS minimal Session Manager policy plus the agent's ec2messages channel. Check `aws ssm describe-instance-information` and open a session on every node. If it fails, CloudTrail shows the denied action; add only that one | P8 |
| R10 | `kube-lab-refresh-join.service` sandboxing (`ProtectSystem=full`, `PrivateTmp`, `ProtectHome=tmpfs`) breaks the aws-cli snap (P7 nitpick 8). `NoNewPrivileges` is deliberately omitted: it blocks snap-confine's AppArmor transitions | Token refresh fails, so nodes added after 24 h can't join | L-M | On cp-1: `systemctl start kube-lab-refresh-join` and `journalctl -u kube-lab-refresh-join`. Fallback: drop the failing directive | P8 |

Watch-list (below top 8): `envsubst`/`gettext-base` present (installed explicitly), the `default_tags` random-value diff (handled via module tags), hostNetwork IMDS access (documented as a CKS lab), vpc 6.7.3 NAT route output name (P1).

## Definition of done
All MH1–MH11 are ticked with evidence (command output pasted into the P8/P9 notes), the final commit exists with no state in git, and the cluster is destroyed and confirmed leftover-free.

## Implementation notes (as built)

Added after the audit of main @ 36def8e and the phase-1 fixes. The steps above are kept as
planned.

- P2/P3 file lists: see the as-built notes at the end of `01-design.md`. `nodes.tf` is now
  `modules/cluster/main.tf`, and the bootstrap lives in `modules/cluster/bootstrap`.
- P2 IAM: the control-plane role has Get/GetParameters/Put on `/<cluster>/*`, no
  `GetParametersByPath`, and no `AmazonSSMManagedInstanceCore` attachment.
- P5 MH2: `cni = "cilium"` passing `terraform test` now means `cluster.env` selects Cilium and
  no Calico manifest ships. It does not prove Cilium works on a live cluster.
- P6: the README was split into `README.md` plus `docs/` (architecture, configuration,
  operations, troubleshooting, costs, labs) and `CONTRIBUTING.md`. MH10 is covered across
  those files.
- P7 gate: tflint now runs the full rule set, including `terraform_standard_module_structure`.
- Open: R9 (are the `ec2messages` actions needed?) and the bootstrap-script findings deferred
  to phase 2 depend on the e2e result.

