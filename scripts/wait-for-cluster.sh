#!/usr/bin/env bash
# Waits for a kube-lab cluster to finish bootstrapping by polling its SSM status parameters.
# docs/troubleshooting.md explains each status value. Runs on macOS (bash 3.2) and Linux.
# Times are in UTC, like the nodes' bootstrap logs.
#
#   ./scripts/wait-for-cluster.sh <cluster-name> <region> [timeout-seconds]
#   ./scripts/wait-for-cluster.sh --once <cluster-name> <region>
#   ./scripts/wait-for-cluster.sh --history <cluster-name> <region>
#
# Exit codes: 0 ready, 1 a node failed, 2 timed out, 3 the AWS CLI can't read the status,
# 4 still in progress (--once only), 64 wrong arguments.
set -euo pipefail

usage() {
  cat <<EOF
usage: $0 [--once | --history] <cluster-name> <region> [timeout-seconds]

Waits until the cluster reports ready and every node has joined (default timeout 2400
seconds), printing the statuses whenever they change. Times are in UTC.

  --once     print the statuses once and exit: 0 ready, 1 failed, 4 still in progress
  --history  print every value each status parameter has had, with its time
             (needs ssm:GetParameterHistory)

Terraform knows both values:

  $0 "\$(terraform output -raw cluster_name)" "\$(terraform output -raw region)"
EOF
}

mode=watch
case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
  --once | --history)
    mode=${1#--}
    shift
    ;;
  *) ;;
esac
max_args=3
[[ $mode == watch ]] || max_args=2
if [[ $# -lt 2 || $# -gt $max_args || ! ${3:-0} =~ ^[0-9]+$ ]]; then
  usage >&2
  exit 64
fi
cluster=$1
region=$2
timeout=${3:-2400}

# Prints "cluster=<status> cp-1=<status> worker-1=<status> ...".
read_statuses() {
  local cluster_value node_values
  cluster_value=$(aws ssm get-parameter --region "$region" --name "/$cluster/status/cluster" \
    --query Parameter.Value --output text) || return
  node_values=$(aws ssm get-parameters-by-path --region "$region" --path "/$cluster/nodes" \
    --recursive --query 'Parameters[].[Name, Value]' --output text) || return
  printf 'cluster=%s' "$cluster_value"
  # /<cluster>/nodes/worker-1/status<TAB>joined  ->  worker-1=joined
  printf '%s\n' "$node_values" | sort | awk -F '\t' 'NF == 2 { split($1, p, "/"); printf " %s=%s", p[4], $2 }'
  echo
}

# is_ready <status line>: cp-1 reports ready and every node has joined. After a scale-out the
# cluster already says ready while the new nodes are still on their way.
is_ready() {
  local word
  [[ $1 == cluster=ready* ]] || return 1
  for word in ${1#cluster=ready}; do
    [[ $word == *=joined ]] || return 1
  done
}

# next_steps <which node>
next_steps() {
  cat >&2 <<EOF
Next: open a shell on the node $1 and read its bootstrap log:
  terraform output ssm_session_commands
  sudo tail -n 50 /var/log/kube-lab-bootstrap.log
docs/troubleshooting.md explains each status.
EOF
}

# Fail fast when the AWS CLI can't work at all, instead of waiting for the timeout. Its own
# error message is shown first.
err=$(mktemp)
trap 'rm -f "$err"' EXIT
if ! line=$(read_statuses 2>"$err"); then
  cat "$err" >&2
  if grep -q ParameterNotFound "$err"; then
    echo "No cluster '$cluster' in region $region. Check the name: terraform output -raw cluster_name" >&2
  else
    echo "Can't read the status of $cluster in $region. Check your AWS credentials" >&2
    echo "(aws sts get-caller-identity), the region and the cluster name." >&2
  fi
  exit 3
fi
rm -f "$err"

case $mode in
  history)
    for name in "/$cluster/status/cluster" $(aws ssm get-parameters-by-path --region "$region" \
      --path "/$cluster/nodes" --recursive --query 'Parameters[].Name' --output text | tr '\t' '\n' | sort); do
      echo "${name#/"$cluster"/}"
      # The AWS CLI prints the dates in the local time zone unless told otherwise.
      TZ=UTC aws ssm get-parameter-history --region "$region" --name "$name" \
        --query 'Parameters[].[LastModifiedDate, Value]' --output text | sed 's/^/  /'
    done
    exit 0
    ;;
  once)
    echo "$line"
    if is_ready "$line"; then exit 0; fi
    if [[ $line == *=failed:* ]]; then
      next_steps "that failed"
      exit 1
    fi
    exit 4
    ;;
  *) ;;
esac

echo "Waiting for $cluster in $region (up to $((timeout / 60)) min)..."
get_kubeconfig="$(printf '%q' "$(dirname "$0")")/get-kubeconfig.sh $cluster $region"
deadline=$((SECONDS + timeout))
last_line=""
last_print=0
api_announced=false
while ((SECONDS < deadline)); do
  # A failed read (expired credentials, throttling) keeps the last line; the AWS CLI's
  # error message is on stderr.
  line=$(read_statuses) || line=$last_line
  # Only changes, plus a heartbeat every 2 minutes so a long step doesn't look hung.
  if [[ $line != "$last_line" || $((SECONDS - last_print)) -ge 120 ]]; then
    printf '%s %s\n' "$(date -u +%TZ)" "$line"
    last_line=$line
    last_print=$SECONDS
  fi
  # cp-1 publishes the admin kubeconfig before it reports installing, so kubectl works from
  # here on. The nodes stay NotReady until the network plugin runs.
  if [[ $line == cluster=installing* && $api_announced == false ]]; then
    echo "The API is up. Fetch the kubeconfig now; the nodes turn Ready as the network plugin starts:"
    echo "  eval \"\$($get_kubeconfig)\""
    echo "Still waiting for the cluster to report ready..."
    api_announced=true
  fi
  if is_ready "$line"; then
    echo "Cluster is ready. Point kubectl at it with:"
    echo "  eval \"\$($get_kubeconfig)\""
    exit 0
  fi
  if [[ $line == *=failed:* ]]; then
    echo "Bootstrap failed. The status line names the node and the step." >&2
    next_steps "that failed"
    exit 1
  fi
  sleep 10
done

echo "Timed out after $((timeout / 60)) min." >&2
next_steps "that is furthest behind"
exit 2
