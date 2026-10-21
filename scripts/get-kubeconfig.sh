#!/usr/bin/env bash
# Downloads the cluster-admin kubeconfig from SSM Parameter Store to ~/.kube/<cluster>.yaml,
# with your own AWS credentials; it never passes through Terraform state.
# Runs on macOS (bash 3.2) and Linux.
#
# A script can't set variables in the shell that started it, so it prints an export line
# for your shell to run:
#
#   eval "$(./scripts/get-kubeconfig.sh <cluster-name> <region>)"
#
# Exit codes: 0 written, 1 not published yet, 64 wrong arguments; otherwise the AWS CLI's.
set -euo pipefail

usage() {
  echo "usage: eval \"\$($0 <cluster-name> <region>)\""
  echo "Terraform prints the full line: terraform output next_steps"
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
  *) ;;
esac
if [[ $# -ne 2 ]]; then
  usage >&2
  exit 64
fi
cluster=$1
region=$2
dest="$HOME/.kube/$cluster.yaml"

value=$(aws ssm get-parameter --region "$region" --name "/$cluster/kubeconfig/admin" \
  --with-decryption --query Parameter.Value --output text)
if [[ $value == pending ]]; then
  echo "The kubeconfig is not published yet; run $(dirname "$0")/wait-for-cluster.sh $cluster $region first." >&2
  exit 1
fi

# The kubeconfig is a cluster-admin credential: keep it private to you. umask only applies
# to new files, so chmod tightens an older one.
umask 077
mkdir -p "$HOME/.kube"
printf '%s\n' "$value" >"$dest"
chmod 0600 "$dest"
echo "Wrote $dest" >&2

printf 'export KUBECONFIG=%q\n' "$dest"
# Run straight from a terminal, the line above changed nothing yet.
if [[ -t 1 ]]; then
  echo "Run that line yourself, or next time: eval \"\$($0 $cluster $region)\"" >&2
fi
