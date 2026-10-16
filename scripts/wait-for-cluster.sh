#!/usr/bin/env bash
# Waits for a kube-lab cluster to finish bootstrapping by polling its SSM status parameters.
# Exit codes: 0 ready, 1 a node reported failure, 2 timed out.
#
#   ./scripts/wait-for-cluster.sh <cluster-name> [region] [timeout-seconds]
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <cluster-name> [region] [timeout-seconds]" >&2
  exit 64
fi

cluster=$1
region=${2:-${AWS_REGION:-us-east-1}}
timeout=${3:-2400}
deadline=$((SECONDS + timeout))

node_statuses() {
  aws ssm get-parameters-by-path --region "$region" --path "/$cluster/nodes" --recursive \
    --with-decryption --query 'Parameters[].[Name,Value]' --output text |
    sed "s#^/$cluster/nodes/##; s#/status##" | sort
}

cluster_status() {
  aws ssm get-parameter --region "$region" --name "/$cluster/status/cluster" \
    --with-decryption --query Parameter.Value --output text
}

echo "Waiting for $cluster in $region (up to $((timeout / 60)) min)..."
while ((SECONDS < deadline)); do
  status=$(cluster_status 2>/dev/null || echo unknown)
  nodes=$(node_statuses 2>/dev/null | awk '{ printf "%s=%s ", $1, $2 }' || true)
  printf '%s cluster=%s %s\n' "$(date +%T)" "$status" "$nodes"

  if [[ $status == ready ]]; then
    echo "Cluster is ready. Next: $(dirname "$0")/get-kubeconfig.sh $cluster $region"
    exit 0
  fi
  if [[ $status == failed:* || $nodes == *=failed:* ]]; then
    echo "Bootstrap failed. Inspect /var/log/kube-lab-bootstrap.log on the failed node (see README, Troubleshooting)." >&2
    exit 1
  fi
  sleep 15
done

echo "Timed out after $((timeout / 60)) min." >&2
exit 2
