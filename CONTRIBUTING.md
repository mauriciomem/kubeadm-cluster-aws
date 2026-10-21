# Contributing

[Architecture](docs/architecture.md) explains how the pieces fit together, including the
bootstrap contract between Terraform and the node scripts. Read it first.

## Run the checks

Besides the README's tools, you need TFLint, ShellCheck, Trivy and jq. Docker is optional on
macOS for the kubeadm check; without it, the check is skipped and left to CI. None of the
checks need AWS credentials. CI (`.github/workflows/ci.yml`) runs the same set:

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

- `render-templates.sh` writes each node's cloud-init content to `build/nodes/` and prints its
  size. EC2 caps user data at 16 KB, and the gzip column is the one that counts. Pass `-var`
  flags to render other layouts.
- `terraform test` runs `tests/*.tftest.hcl` against mocked AWS providers. It creates nothing
  and ignores your `terraform.tfvars`.
- `tests/scripts.sh` runs the operator scripts against a fake `aws` with `/bin/bash`, which is
  bash 3.2 on macOS. The node-side tests need bash 4 or later and are skipped otherwise.
- In CI, Trivy only reports; it doesn't fail the build.

Changes to the node scripts also need a real cluster: create one, check that every node reaches
`joined`, and destroy it.

## Bump a version

Every download the nodes make has a version variable and a checksum variable next to it in
`variables.tf`. Each checksum's description says which file it hashes.

1. Change the version and recompute its checksum from the exact file the nodes download
   (`shasum -a 256` on macOS). For the AWS CLI, check the zip's PGP signature against the
   [AWS CLI public key](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
   before you hash it. For Cilium CLI and Helm, use the published `.sha256sum` file. For
   kubelet-csr-approver, use the image index digest.
2. Check compatibility: containerd and the network plugin against the Kubernetes version, and
   the Helm version skew policy.
3. When you change `k8s_version`, check the versions in `docs/addons.md` and the etcd versions
   in the labs.
4. Run the checks, then create a fresh cluster and check that it reaches `ready`.

A few pins live elsewhere: the apt signing key fingerprints in
`modules/cluster/bootstrap/files/lib.sh`, the CI tool versions at the top of
`.github/workflows/ci.yml`, and the providers in `terraform.tf` and `.terraform.lock.hcl`.
CI won't update the lock file, so run
`terraform providers lock -platform=darwin_arm64 -platform=linux_amd64` yourself.

Bootstrap changes only reach nodes created after them.

## Commits and style

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`,
`test:`, `refactor:`, `chore:`), one logical change per commit, with the checks passing.

Code comments explain why, in a line or two. Docs speak to the reader as "you", in the present
tense, plain words and US English. Prefer pointing to the source over copying it into the docs.
