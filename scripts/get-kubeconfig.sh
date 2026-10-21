#!/usr/bin/env bash
# Downloads the cluster-admin kubeconfig from SSM Parameter Store to ~/.kube/<cluster>.yaml.
# Uses your own AWS credentials; the kubeconfig never passes through Terraform state.
# Runs on macOS (bash 3.2) and Linux.
#
# A script can't change the environment of the shell that started it, so this one prints an
# export line for your shell to run:
#
#   eval "$(./scripts/get-kubeconfig.sh <cluster-name> <region>)"
#
# Run without eval in a terminal, it says so and prints the commands to copy instead.
# Exit codes: 0 written, 1 not published yet, 2 sourced instead of run, 64 wrong arguments;
# when the AWS CLI fails, its own exit code.

# Sourcing would leak set -euo pipefail and umask 077 into your shell, and exit would close
# it. So refuse, in zsh and in bash, before strict mode is on.
case ${ZSH_EVAL_CONTEXT:-} in
  *:file*)
    echo 'Run get-kubeconfig.sh with eval instead of sourcing it:' >&2
    echo '  eval "$(./scripts/get-kubeconfig.sh <cluster-name> <region>)"' >&2
    return 2
    ;;
  *) ;;
esac
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo 'Run get-kubeconfig.sh with eval instead of sourcing it:' >&2
  echo '  eval "$(./scripts/get-kubeconfig.sh <cluster-name> <region>)"' >&2
  return 2
fi

set -euo pipefail

usage() {
  cat <<EOF
usage: $0 <cluster-name> <region>

Writes the admin kubeconfig to ~/.kube/<cluster-name>.yaml and prints a line that sets
KUBECONFIG. A script can't set variables in your shell, so let the shell run that line with
eval. Terraform knows both values:

  eval "\$($0 "\$(terraform output -raw cluster_name)" "\$(terraform output -raw region)")"

Run without eval in a terminal, it prints the commands to copy instead.
EOF
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
# Terraform builds cluster names from lowercase letters, digits and hyphens. Checking keeps
# a typo from writing outside ~/.kube, and makes the commands below safe to print as they are.
if [[ ! $cluster =~ ^[a-z][a-z0-9-]*$ || ! $region =~ ^[a-z0-9-]+$ ]]; then
  echo "Expected a cluster name such as kube-lab-a1b2 and a region such as us-east-1." >&2
  usage >&2
  exit 64
fi
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

# Quoted for the shell that runs it, so a $HOME with spaces still works.
kubeconfig=$(printf '%q' "$dest")

# Something other than a terminal reads stdout: eval "$(...)", a pipe or a file. Print only
# the line to run.
if [[ ! -t 1 ]]; then
  printf 'export KUBECONFIG=%s\n' "$kubeconfig"
  exit 0
fi

# Run straight from a terminal. A bare export line here would look as if it had worked.
# A command name without a slash would be looked up in PATH, so keep it relative.
case $0 in
  */*) self=$(printf '%q' "$0") ;;
  *) self=./$(printf '%q' "$0") ;;
esac
cat <<EOF

KUBECONFIG is not set yet: a script can't change your shell's environment.
To use the cluster in this shell, run:

  export KUBECONFIG=$kubeconfig
  kubectl get nodes

Or pass the file to a single command:

  kubectl --kubeconfig $kubeconfig get nodes

Next time, let the script set it for you:

  eval "\$($self $cluster $region)"
EOF
