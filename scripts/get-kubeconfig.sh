#!/usr/bin/env bash
# Downloads the cluster-admin kubeconfig from SSM Parameter Store to ~/.kube/<cluster>.yaml
# and prints an export KUBECONFIG line. Uses your own AWS credentials; the kubeconfig never
# passes through Terraform state. Runs on macOS (bash 3.2) and Linux.
#
#   eval "$(./scripts/get-kubeconfig.sh <cluster-name> <region>)"
set -euo pipefail

usage() {
  cat <<EOF
usage: $0 <cluster-name> <region>

Writes the admin kubeconfig to ~/.kube/<cluster-name>.yaml and prints the export line for it,
so wrap it in eval. Terraform knows both values:

  eval "\$($0 "\$(terraform output -raw cluster_name)" "\$(terraform output -raw region)")"
EOF
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
esac
if [[ $# -ne 2 ]]; then
  usage >&2
  exit 64
fi

cluster=$1
region=$2
dest="$HOME/.kube/$cluster.yaml"

umask 077
mkdir -p "$HOME/.kube"
value=$(aws ssm get-parameter --region "$region" --name "/$cluster/kubeconfig/admin" \
  --with-decryption --query Parameter.Value --output text)

if [[ $value == pending ]]; then
  echo "The kubeconfig is not published yet; run $(dirname "$0")/wait-for-cluster.sh $cluster $region first." >&2
  exit 1
fi

printf '%s\n' "$value" >"$dest"
# umask only applies to new files; an older kubeconfig may have looser permissions.
chmod 0600 "$dest"
echo "Wrote $dest" >&2
printf 'export KUBECONFIG=%q\n' "$dest"
