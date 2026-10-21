#!/usr/bin/env bash
# Waits for a kube-lab cluster to finish bootstrapping by polling its SSM status parameters.
# docs/troubleshooting.md explains each status value. Runs on macOS (bash 3.2) and Linux.
#
#   ./scripts/wait-for-cluster.sh <cluster-name> <region> [timeout-seconds]
#   ./scripts/wait-for-cluster.sh --once <cluster-name> <region>
#   ./scripts/wait-for-cluster.sh --history <cluster-name> <region>
#
# Exit codes: 0 ready, 1 a node reported a failure, 2 timed out, 3 the AWS CLI can't read the
# cluster's status (credentials, region or cluster name), 4 still in progress (--once only),
# 64 wrong arguments. --history exits 0 once it has printed the timeline.
set -euo pipefail

usage() {
  cat <<EOF
usage: $0 [--once | --history] <cluster-name> <region> [timeout-seconds]

Waits until the cluster reports ready, printing the statuses whenever they change. The
timeout defaults to 2400 seconds (40 minutes).

  --once     print the statuses once and exit: 0 ready, 1 failed, 4 still in progress
  --history  print when each status changed and how long each step took
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
# The same shape Terraform gives them. The name also goes into a sed pattern below.
if [[ ! $cluster =~ ^[a-z][a-z0-9-]*$ || ! $region =~ ^[a-z0-9-]+$ ]]; then
  echo "Expected a cluster name such as kube-lab-a1b2 and a region such as us-east-1." >&2
  usage >&2
  exit 64
fi
# Generous on purpose: a default cluster has reached ready about four minutes after apply.
# The cap only bounds how long you wait on a stuck bootstrap.
timeout=${3:-2400}
deadline=$((SECONDS + timeout))

errors=$(mktemp "${TMPDIR:-/tmp}/kube-lab-wait.XXXXXX")
trap 'rm -f "$errors"' EXIT

# Every value a status parameter accepts: the same regex as STATUS_PATTERN in
# modules/cluster/bootstrap/files/lib.sh (tests/scripts.sh keeps the two equal).
readonly STATUS_PATTERN='^(pending|bootstrapping|waiting|joining|joined|initializing|initialized|installing|ready|failed:[a-z0-9-]{1,40})$'

# Never trust a status value on read. IAM limits who writes each parameter, but root on a
# worker can write any text into a worker's status, including terminal escape sequences
# or a copy of the join token. So every value is fetched JSON-encoded, through JMESPath's
# to_string([...]), which keeps a value with newlines or control characters on one line,
# and anything that isn't a status value is shown as "invalid".
#
# Prints the status a JSON-encoded value holds, or "invalid".
# Arguments: the encoded value, for example ["ready"]
decode_status() {
  local value=$1
  value=${value#'["'}
  value=${value%'"]'}
  if [[ "[\"$value\"]" == "$1" && $value =~ $STATUS_PATTERN ]]; then
    printf '%s\n' "$value"
  else
    echo invalid
  fi
}

# Status parameters are plain Strings. --with-decryption still matters for clusters created
# before that change, whose statuses are SecureStrings; for a String it changes nothing.
# Prints "<node>\t<status>" lines. Only names of the form nodes/<cp|worker>-<n>/status count:
# anything else under the path didn't come from Terraform.
node_statuses() {
  local name value lines name_pattern="^/$cluster/nodes/(cp|worker)-[0-9]+/status$"
  lines=$(aws ssm get-parameters-by-path --region "$region" --path "/$cluster/nodes" --recursive \
    --with-decryption --query 'Parameters[].[Name, to_string([Value])]' --output text) || return
  while IFS=$'\t' read -r name value; do
    [[ $name =~ $name_pattern ]] || continue
    name=${name#/"$cluster"/nodes/}
    printf '%s\t%s\n' "${name%/status}" "$(decode_status "$value")"
  done <<<"$lines" | sort
}

cluster_status() {
  local value
  value=$(aws ssm get-parameter --region "$region" --name "/$cluster/status/cluster" \
    --with-decryption --query 'to_string([Parameter.Value])' --output text) || return
  decode_status "$value"
}

# Drops control characters, for text this script doesn't control, such as AWS CLI errors.
printable() {
  LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# Sets status, nodes and line from one round of AWS CLI calls; errors go to $errors.
# read_failed is true when a call failed: status is then "unknown", or nodes is empty.
read_statuses() {
  : >"$errors"
  read_failed=false
  status=$(cluster_status 2>>"$errors") || {
    status=unknown
    read_failed=true
  }
  nodes=$(node_statuses 2>>"$errors") || read_failed=true
  nodes=$(printf '%s\n' "$nodes" | awk -F '\t' 'NF == 2 { printf "%s%s=%s", sep, $1, $2; sep = " " }')
  line="cluster=$status${nodes:+ $nodes}"
}

is_failed() {
  [[ $status == failed:* || $nodes == *=failed:* ]]
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

# Prints the status parameter names, the cluster's first. Like node_statuses, it skips
# names Terraform doesn't create.
status_parameters() {
  local name name_pattern="^/$cluster/nodes/(cp|worker)-[0-9]+/status$"
  echo "/$cluster/status/cluster"
  aws ssm get-parameters-by-path --region "$region" --path "/$cluster/nodes" --recursive \
    --query 'Parameters[].Name' --output text | tr '\t' '\n' | while read -r name; do
    if [[ $name =~ $name_pattern ]]; then echo "$name"; fi
  done | sort
}

# Prints one line per status change: when, how long since the first write (Terraform's
# "pending"), the value, and how long it stayed. SSM keeps the last 100 versions of each
# parameter, with LastModifiedDate, so this needs no extra bookkeeping on the nodes.
# Values are checked like everywhere else: anything that isn't a status shows as invalid.
print_history() {
  local name label when value
  status_parameters | while read -r name; do
    label=${name#/"$cluster"/}
    label=${label#nodes/}
    label=${label%/status}
    label=${label#status/}
    aws ssm get-parameter-history --region "$region" --name "$name" --with-decryption \
      --query 'Parameters[].[LastModifiedDate, to_string([Value])]' --output text |
      while IFS=$'\t' read -r when value; do
        [[ $when =~ ^[0-9T:.+Z-]+$ ]] || continue
        printf '%s\t%s\t%s\n' "$label" "$when" "$(decode_status "$value")"
      done
  done | awk -F '\t' "$(history_awk)"
}

# The AWS CLI prints timestamps as ISO 8601 with an offset, for example
# 2026-10-21T12:02:04.123000+02:00, or as epoch seconds with cli_timestamp_format = wire.
# BSD awk on macOS has no time functions, so the date math is done by hand.
history_awk() {
  cat <<'EOF'
function epoch(ts,    y, m, d, off, era, yoe, doy, doe) {
  if (ts ~ /^[0-9]+(\.[0-9]+)?$/) return int(ts)
  y = substr(ts, 1, 4) + 0; m = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
  off = 0
  if (match(ts, /[+-][0-9][0-9]:?[0-9][0-9]$/)) {
    off = substr(ts, RSTART + 1, 2) * 3600 + substr(ts, RSTART + RLENGTH - 2, 2) * 60
    if (substr(ts, RSTART, 1) == "-") off = -off
  }
  # Days since 1970-01-01, from Howard Hinnant's days_from_civil.
  if (m <= 2) y--
  era = int(y / 400); yoe = y - era * 400
  doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2) - off
}
function clock(ts) { return ts ~ /^[0-9]+(\.[0-9]+)?$/ ? "-" : substr(ts, 12, 8) }
function span(s) { return sprintf("%dm%02ds", int(s / 60), s % 60) }
{
  n++; label[n] = $1; t[n] = epoch($2); when[n] = clock($2); value[n] = $3
  if (n == 1 || t[n] < t0) t0 = t[n]
}
END {
  for (i = 1; i <= n; i++) {
    if (i == 1 || label[i] != label[i - 1]) printf "%s\n", label[i]
    held = (i < n && label[i + 1] == label[i]) ? span(t[i + 1] - t[i]) : "(current)"
    printf "  %-8s  +%-7s  %-16s  %s\n", when[i], span(t[i] - t0), value[i], held
  }
}
EOF
}

# Fail fast when the AWS CLI can't work at all, instead of printing "unknown" until the
# timeout. Terraform created the parameter, so an error here is about access, not timing.
if ! cluster_status >/dev/null 2>"$errors"; then
  echo "Can't read /$cluster/status/cluster in $region:" >&2
  printable <"$errors" | sed 's/^/  /' >&2
  echo "Check your AWS credentials (aws sts get-caller-identity), the region and the cluster name." >&2
  exit 3
fi

case $mode in
  history)
    echo "Status history of $cluster (time, time since the first write, value, how long it stayed):"
    print_history
    exit 0
    ;;
  once)
    read_statuses
    echo "$line"
    if [[ $status == ready ]]; then
      exit 0
    fi
    if is_failed; then
      next_steps "that failed"
      exit 1
    fi
    # A call that failed after the check above worked (throttling, say) is an AWS CLI
    # error, not "in progress".
    if [[ $read_failed == true ]]; then
      echo "The AWS CLI failed while reading the statuses:" >&2
      printable <"$errors" | sed 's/^/  /' >&2
      exit 3
    fi
    exit 4
    ;;
  *) ;;
esac

echo "Waiting for $cluster in $region (up to $((timeout / 60)) min)..."
last_line=""
last_print=0
last_error=""
while ((SECONDS < deadline)); do
  read_statuses

  # Only changes, plus a heartbeat every 2 minutes so a long step doesn't look hung.
  if [[ $line != "$last_line" || $((SECONDS - last_print)) -ge 120 ]]; then
    printf '%s %s\n' "$(date +%T)" "$line"
    last_line=$line
    last_print=$SECONDS
  fi

  # A later call can still fail, for example when credentials expire during the wait.
  # Show the AWS CLI's message once, not on every line.
  error=$(printable <"$errors" | grep -v '^[[:space:]]*$' | tail -n 1 || true)
  if [[ -n $error && $error != "$last_error" ]]; then
    echo "  AWS CLI: $error" >&2
  fi
  last_error=$error

  if [[ $status == ready ]]; then
    echo "Cluster is ready. Point kubectl at it with:"
    echo "  eval \"\$($(printf '%q' "$(dirname "$0")")/get-kubeconfig.sh $cluster $region)\""
    exit 0
  fi
  if is_failed; then
    echo "Bootstrap failed. The status line names the node and the step." >&2
    next_steps "that failed"
    exit 1
  fi
  sleep 15
done

echo "Timed out after $((timeout / 60)) min." >&2
next_steps "that is furthest behind"
exit 2
