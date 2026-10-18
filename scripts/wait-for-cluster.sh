#!/usr/bin/env bash
# Waits for a kube-lab cluster to finish bootstrapping by polling its SSM status parameters.
# docs/troubleshooting.md explains each status value. Runs on macOS (bash 3.2) and Linux.
#
#   ./scripts/wait-for-cluster.sh <cluster-name> <region> [timeout-seconds]
#
# Exit codes: 0 ready, 1 a node reported a failure, 2 timed out, 3 the AWS CLI can't read the
# cluster's status (credentials, region or cluster name), 64 wrong arguments.
set -euo pipefail

usage() {
  cat <<EOF
usage: $0 <cluster-name> <region> [timeout-seconds]

Waits until the cluster reports ready and prints every node's status every 15 seconds.
The timeout defaults to 2400 seconds (40 minutes). Terraform knows both values:

  $0 "\$(terraform output -raw cluster_name)" "\$(terraform output -raw region)"
EOF
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
esac
if [[ $# -lt 2 || $# -gt 3 || ! ${3:-0} =~ ^[0-9]+$ ]]; then
  usage >&2
  exit 64
fi

cluster=$1
region=$2
# Generous on purpose: a default cluster has reached ready about four minutes after apply.
# The cap only bounds how long you wait on a stuck bootstrap.
timeout=${3:-2400}
deadline=$((SECONDS + timeout))

errors=$(mktemp "${TMPDIR:-/tmp}/kube-lab-wait.XXXXXX")
trap 'rm -f "$errors"' EXIT

node_statuses() {
  aws ssm get-parameters-by-path --region "$region" --path "/$cluster/nodes" --recursive \
    --with-decryption --query 'Parameters[].[Name,Value]' --output text |
    sed "s#^/$cluster/nodes/##; s#/status##" | sort
}

cluster_status() {
  aws ssm get-parameter --region "$region" --name "/$cluster/status/cluster" \
    --with-decryption --query Parameter.Value --output text
}

# Arguments: which node to look at, for example "that failed"
next_steps() {
  cat >&2 <<EOF
Next: open a shell on the node $1 and read its bootstrap log:
  terraform output ssm_session_commands
  sudo tail -n 50 /var/log/kube-lab-bootstrap.log
docs/troubleshooting.md explains each status.
EOF
}

# Fail fast when the AWS CLI can't work at all, instead of printing "unknown" until the
# timeout. Terraform created the parameter, so an error here is about access, not timing.
if ! cluster_status >/dev/null 2>"$errors"; then
  echo "Can't read /$cluster/status/cluster in $region:" >&2
  sed 's/^/  /' "$errors" >&2
  echo "Check your AWS credentials (aws sts get-caller-identity), the region and the cluster name." >&2
  exit 3
fi

echo "Waiting for $cluster in $region (up to $((timeout / 60)) min)..."
last_error=""
while ((SECONDS < deadline)); do
  : >"$errors"
  status=$(cluster_status 2>>"$errors") || status=unknown
  nodes=$(node_statuses 2>>"$errors" | awk '{ printf "%s=%s ", $1, $2 }') || nodes=""
  printf '%s cluster=%s %s\n' "$(date +%T)" "$status" "$nodes"

  # A later call can still fail, for example when credentials expire during the wait.
  # Show the AWS CLI's message once, not on every line.
  error=$(grep -v '^[[:space:]]*$' "$errors" | tail -n 1 || true)
  if [[ -n $error && $error != "$last_error" ]]; then
    echo "  AWS CLI: $error" >&2
  fi
  last_error=$error

  if [[ $status == ready ]]; then
    echo "Cluster is ready. Next: $(dirname "$0")/get-kubeconfig.sh $cluster $region"
    exit 0
  fi
  if [[ $status == failed:* || $nodes == *=failed:* ]]; then
    echo "Bootstrap failed. The status line names the node and the step." >&2
    next_steps "that failed"
    exit 1
  fi
  sleep 15
done

echo "Timed out after $((timeout / 60)) min." >&2
next_steps "that is furthest behind"
exit 2
