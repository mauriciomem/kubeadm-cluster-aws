# Contributing

This page is for people who change kube-lab itself. [Architecture](docs/architecture.md)
explains how the pieces fit together, including the bootstrap contract between Terraform and
the node scripts. Read it first.

## Tools

You need everything from the README, plus:

- [TFLint](https://github.com/terraform-linters/tflint)
- [ShellCheck](https://www.shellcheck.net/)
- [Trivy](https://trivy.dev/), for the security scan
- jq, for `scripts/render-templates.sh`
- Docker on macOS, if you want to run the kubeadm config check locally. On Linux it runs
  directly.

None of the checks need AWS credentials.

## Run the checks

Run these from the repository root before you open a pull request. CI runs the same set.

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
tflint --init && tflint --recursive
shellcheck -S warning -x scripts/*.sh modules/cluster/bootstrap/files/*.sh tests/*.sh
./scripts/render-templates.sh
terraform test
bash tests/scripts.sh
trivy config --quiet --severity HIGH,CRITICAL .
./scripts/validate-kubeadm-config.sh
```

ShellCheck reads the node scripts straight from `modules/cluster/bootstrap/files`, because they
reach the nodes unchanged. `-x` lets it follow their `source` lines into `lib.sh` and
`templates/cluster.env.tftpl`, so it knows every function and variable they use.

`render-templates.sh` renders each node's cloud-init content into `build/nodes/` from the root
module's own values and prints the raw and gzipped sizes. EC2 caps user data at 16 KB before
base64 encoding. The user data is gzipped, so the gzip column is the one that counts, and a
precondition fails the plan if a node goes over. Pass `-var` flags to render
other layouts, for example
`./scripts/render-templates.sh -var cni=cilium -var control_plane_count=3 -var worker_count=0`.

`validate-kubeadm-config.sh` renders three layouts and runs `kubeadm config validate` on every
kubeadm config, with the kubeadm version the nodes install. On macOS without Docker it skips
the check and leaves it to CI.

In CI the Trivy job is advisory: it reports findings without failing the build.

## Tests

`terraform test` runs the files in `tests/` against mocked AWS providers, so it needs no
credentials and creates nothing. The tests pin the values they assume, so your
`terraform.tfvars` doesn't affect them.

| File | What it covers |
|---|---|
| `tests/nodes.tftest.hcl` | The node map: names, roles, indexes and taints |
| `tests/cluster.tftest.hcl` | `modules/cluster` on its own: placement, the load balancer, security groups, SSM parameters, IAM, and the x86_64 check |
| `tests/bootstrap.tftest.hcl` | `modules/cluster/bootstrap` on its own: the plan-time guards on node names and `cluster.env` values |
| `tests/network.tftest.hcl` | `modules/network` on its own: AZ selection by instance type |
| `tests/user_data.tftest.hcl` | Which files reach which node and what is rendered into them |
| `tests/cni.tftest.hcl` | What changes with `cni` |
| `tests/status.tftest.hcl` | `modules/status` on its own: the `cluster_ready` check and its messages |
| `tests/validation.tftest.hcl` | Every input validation rule |

`tests/scripts.sh` is plain bash. It runs `get-kubeconfig.sh`, `wait-for-cluster.sh` and the
status helpers in `lib.sh` against a fake `aws` on `PATH`, with `/bin/bash` (set `TEST_BASH` to
use another). On macOS that is bash 3.2, the oldest version the operator scripts support.

The `static_guard_*` runs in `user_data.tftest.hcl` are different from the rest. They check the
text of shell files that Terraform copies without changing, to stop known mistakes from coming
back. If you change one of those lines on purpose, update the guard in the same commit.

Name runs after the behavior they check, and write error messages that say why the rule
matters. Mocked values that the code parses, such as the load balancer DNS name, are pinned in
`tests/mocks/aws.tfmock.hcl`.

Changes to the node scripts also need a real cluster: create one, check that every node reaches
`joined`, and destroy it.

## Bump a version

Most pins are variables in `variables.tf`, each with its checksum next to it.

1. Change the version variable: `k8s_version`, `containerd_version`, `calico_version`,
   `cilium_version`, `cilium_cli_version`, `csr_approver_version` or `helm_version`.
2. Recompute the matching checksum from the exact file the nodes download. On macOS, use
   `shasum -a 256` instead of `sha256sum`.

   Calico has two files, and each has its own variable, so hash them one at a time:

   ```bash
   v=v3.33.0
   base=https://raw.githubusercontent.com/projectcalico/calico/$v/manifests
   curl -fsSL "$base/v3_projectcalico_org.yaml" | sha256sum    # calico_crds_sha256
   curl -fsSL "$base/tigera-operator.yaml" | sha256sum         # calico_operator_sha256
   ```

   For `cilium_cli_sha256`, take the value from the release's
   `cilium-linux-amd64.tar.gz.sha256sum` file. For `helm_sha256`, take it from
   `https://get.helm.sh/helm-<version>-linux-amd64.tar.gz.sha256sum`. For `csr_approver_digest`, take the image index
   digest of `ghcr.io/postfinance/kubelet-csr-approver:<version>`, for example with
   `crane digest` or `docker buildx imagetools inspect`.
3. Check compatibility: the containerd release matrix for your Kubernetes version, the Kubernetes
   versions Calico or Cilium support, and the Helm version skew policy.
4. Run the checks above, then create a fresh cluster and check that it reaches `ready`.
5. If you changed a default, update the tables in `docs/configuration.md` and any version the
   docs mention, such as the etcd version in the labs.

A few pins live outside `variables.tf`:

- The Docker and Kubernetes apt signing key fingerprints, `DOCKER_KEY_FINGERPRINT` and
  `K8S_KEY_FINGERPRINT` in `modules/cluster/bootstrap/files/lib.sh`. Check new values against
  the [Docker](https://docs.docker.com/engine/install/ubuntu/) and
  [Kubernetes](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
  install guides.
- The tool versions and checksums CI installs, at the top of `.github/workflows/ci.yml`.
- The provider versions in `terraform.tf` and `.terraform.lock.hcl`. After changing them, run
  `terraform providers lock -platform=darwin_arm64 -platform=linux_amd64`, because CI refuses
  to update the lock file.

`validate-kubeadm-config.sh` reads the kubeadm version from the rendered configs, so it follows
`k8s_version` without a separate pin. Set `KUBEADM_VERSION` to test another version.

Changes to the bootstrap only reach nodes created after them, because Terraform ignores
`user_data` changes on existing nodes.

## Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`,
`test:`, `refactor:`, `chore:`. Keep each commit to one logical change, with the checks passing.

## Writing style

Code comments explain why, not what, in a line or two. Docs speak to the reader as "you", in
the present tense and plain words, in US English. Each page in `docs/` serves one purpose:
labs teach, operations and troubleshooting help you do a task, configuration is reference, and
architecture explains.
