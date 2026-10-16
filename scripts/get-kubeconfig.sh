#!/usr/bin/env bash
# Downloads the cluster-admin kubeconfig from SSM Parameter Store to ~/.kube/<cluster>.yaml.
# Uses your own AWS credentials; the kubeconfig never passes through Terraform state.
#
#   eval "$(./scripts/get-kubeconfig.sh <cluster-name> [region])"
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <cluster-name> [region]" >&2
  exit 64
fi

cluster=$1
region=${2:-${AWS_REGION:-us-east-1}}
dest="$HOME/.kube/$cluster.yaml"

umask 077
mkdir -p "$HOME/.kube"
value=$(aws ssm get-parameter --region "$region" --name "/$cluster/kubeconfig/admin" \
  --with-decryption --query Parameter.Value --output text)

if [[ $value == pending ]]; then
  echo "The kubeconfig is not published yet; run ./scripts/wait-for-cluster.sh $cluster $region first." >&2
  exit 1
fi

printf '%s\n' "$value" >"$dest"
# umask only applies to new files; an older kubeconfig may have looser permissions.
chmod 0600 "$dest"
echo "Wrote $dest" >&2
printf 'export KUBECONFIG=%q\n' "$dest"
