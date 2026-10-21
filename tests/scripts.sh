#!/usr/bin/env bash
# Tests for the shell scripts, with a fake `aws` on PATH: no AWS account, no network.
#   - scripts/get-kubeconfig.sh and scripts/wait-for-cluster.sh, the operator scripts
#   - the step and status helpers in modules/cluster/bootstrap/files/lib.sh
# The scripts under test run with TEST_BASH (default /bin/bash), so on macOS this checks
# bash 3.2, which is what the operator scripts promise to support. CI runs it on Linux.
#
#   bash tests/scripts.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_bash=${TEST_BASH:-/bin/bash}
work=$(mktemp -d "${TMPDIR:-/tmp}/kube-lab-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  echo "ok    $1"
}

not_ok() {
  failed=$((failed + 1))
  echo "FAIL  $1"
  shift
  local detail
  for detail in "$@"; do
    printf '%s\n' "$detail" | sed 's/^/      /'
  done
}

# check <name> <condition...>: runs the condition and records the result.
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else not_ok "$name" "stdout: $(cat "$work/out" 2>/dev/null)" "stderr: $(cat "$work/err" 2>/dev/null)"; fi
}

contains() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

# --- Fake AWS CLI ----------------------------------------------------------------------
# Parameters are files under $FAKE_AWS_DIR/params/<name>, version history lines
# ("<LastModifiedDate>\t<Value>") under $FAKE_AWS_DIR/history/<name>. Touch
# $FAKE_AWS_DIR/fail to make every call fail like expired credentials. Every call is logged
# to $FAKE_AWS_DIR/calls.
mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -u
d=$FAKE_AWS_DIR
printf '%s\n' "$*" >>"$d/calls"
if [[ -e $d/fail ]]; then
  echo "An error occurred (ExpiredTokenException) when calling the $2 operation: The security token included in the request is expired" >&2
  exit 254
fi
cmd="$1 $2"
shift 2
name="" path="" query="" value=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) name=$2; shift 2 ;;
    --path) path=$2; shift 2 ;;
    --query) query=$2; shift 2 ;;
    --value) value=$2; shift 2 ;;
    *) shift ;;
  esac
done
case $cmd in
  "ssm get-parameter")
    if [[ ! -f $d/params$name ]]; then
      echo "An error occurred (ParameterNotFound) when calling the GetParameter operation:" >&2
      exit 254
    fi
    cat "$d/params$name"
    echo
    ;;
  "ssm get-parameters-by-path")
    [[ -d $d/params$path ]] || exit 0
    names=$(cd "$d/params" && find ".$path" -type f | sed 's#^\.##' | sort)
    if [[ $query == *Value* ]]; then
      for n in $names; do printf '%s\t%s\n' "$n" "$(cat "$d/params$n")"; done
    else
      printf '%s\n' "$names" | paste -s - | tr -d '\n'
      echo
    fi
    ;;
  "ssm get-parameter-history")
    cat "$d/history$name"
    ;;
  "ssm put-parameter")
    mkdir -p "$(dirname "$d/params$name")"
    printf '%s' "$value" >"$d/params$name"
    ;;
  *)
    echo "fake aws: unsupported command $cmd" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH"
export FAKE_AWS_DIR="$work/aws"

# set_param <name> <value>
set_param() {
  mkdir -p "$(dirname "$FAKE_AWS_DIR/params$1")"
  printf '%s' "$2" >"$FAKE_AWS_DIR/params$1"
}

# reset_aws: an empty fake account.
reset_aws() {
  rm -rf "$FAKE_AWS_DIR"
  mkdir -p "$FAKE_AWS_DIR/params" "$FAKE_AWS_DIR/history"
  : >"$FAKE_AWS_DIR/calls"
}

# cluster_with <cluster> <cp-1> <worker-1>: statuses of a two-node cluster.
cluster_with() {
  reset_aws
  set_param /kube-lab-t1/status/cluster "$1"
  set_param /kube-lab-t1/nodes/cp-1/status "$2"
  set_param /kube-lab-t1/nodes/worker-1/status "$3"
}

# --- get-kubeconfig.sh -----------------------------------------------------------------
kubeconfig=$(printf 'apiVersion: v1\nkind: Config\n# SECRET-MARKER-7f3a\nusers: []')
get_kubeconfig="$repo_root/scripts/get-kubeconfig.sh"

reset_aws
set_param /kube-lab-t1/kubeconfig/admin "$kubeconfig"
export HOME="$work/home dir"
mkdir -p "$HOME"

"$test_bash" "$get_kubeconfig" kube-lab-t1 us-east-1 >"$work/out" 2>"$work/err"
rc=$?
check "get-kubeconfig: exits 0" test "$rc" -eq 0
check "get-kubeconfig: prints exactly one export line" test "$(cat "$work/out")" = "export KUBECONFIG=$(printf '%q' "$HOME/.kube/kube-lab-t1.yaml")"
check "get-kubeconfig: writes the kubeconfig" test "$(cat "$HOME/.kube/kube-lab-t1.yaml")" = "$kubeconfig"
check "get-kubeconfig: kubeconfig is 0600" test "$(find "$HOME/.kube/kube-lab-t1.yaml" -perm 0600 | wc -l | tr -d ' ')" = 1
check "get-kubeconfig: kubeconfig never on stdout" lacks "$work/out" SECRET-MARKER
check "get-kubeconfig: kubeconfig never on stderr" lacks "$work/err" SECRET-MARKER

# eval sets KUBECONFIG in the calling shell, even with a space in HOME.
result=$("$test_bash" -c 'eval "$("$0" "$1" kube-lab-t1 us-east-1 2>/dev/null)" && printf "%s" "$KUBECONFIG"' "$test_bash" "$get_kubeconfig")
check "get-kubeconfig: eval sets KUBECONFIG (HOME with a space)" test "$result" = "$HOME/.kube/kube-lab-t1.yaml"

# An older file with loose permissions is tightened.
chmod 0644 "$HOME/.kube/kube-lab-t1.yaml"
"$test_bash" "$get_kubeconfig" kube-lab-t1 us-east-1 >/dev/null 2>&1
check "get-kubeconfig: tightens an existing file to 0600" test "$(find "$HOME/.kube/kube-lab-t1.yaml" -perm 0600 | wc -l | tr -d ' ')" = 1

reset_aws
set_param /kube-lab-t2/kubeconfig/admin pending
"$test_bash" "$get_kubeconfig" kube-lab-t2 us-east-1 >"$work/out" 2>"$work/err"
rc=$?
check "get-kubeconfig: pending exits 1" test "$rc" -eq 1
check "get-kubeconfig: pending points at wait-for-cluster.sh" contains "$work/err" "wait-for-cluster.sh kube-lab-t2 us-east-1"
check "get-kubeconfig: pending writes no file" test ! -e "$HOME/.kube/kube-lab-t2.yaml"
check "get-kubeconfig: pending prints nothing to eval" test ! -s "$work/out"

"$test_bash" "$get_kubeconfig" kube-lab-t1 >"$work/out" 2>"$work/err"
check "get-kubeconfig: a missing argument exits 64" test $? -eq 64
"$test_bash" "$get_kubeconfig" --help >"$work/out" 2>"$work/err"
check "get-kubeconfig: --help exits 0" test $? -eq 0

# --- wait-for-cluster.sh ---------------------------------------------------------------
wait_script="$repo_root/scripts/wait-for-cluster.sh"

cluster_with ready joined joined
"$test_bash" "$wait_script" --once kube-lab-t1 us-east-1 >"$work/out" 2>"$work/err"
rc=$?
check "wait --once: ready exits 0" test "$rc" -eq 0
check "wait --once: prints one status line" test "$(cat "$work/out")" = "cluster=ready cp-1=joined worker-1=joined"

cluster_with installing initialized joining
"$test_bash" "$wait_script" --once kube-lab-t1 us-east-1 >"$work/out" 2>"$work/err"
rc=$?
check "wait --once: in progress exits 4" test "$rc" -eq 4
check "wait --once: in progress line" test "$(cat "$work/out")" = "cluster=installing cp-1=initialized worker-1=joining"

cluster_with installing initialized failed:join
"$test_bash" "$wait_script" --once kube-lab-t1 us-east-1 >"$work/out" 2>"$work/err"
rc=$?
check "wait --once: a failed node exits 1" test "$rc" -eq 1
check "wait --once: a failure shows the next steps" contains "$work/err" "kube-lab-bootstrap.log"

cluster_with ready joined joined
touch "$FAKE_AWS_DIR/fail"
"$test_bash" "$wait_script" --once kube-lab-t1 us-east-1 >"$work/out" 2>"$work/err"
rc=$?
check "wait: AWS CLI errors exit 3" test "$rc" -eq 3
check "wait: AWS CLI errors are shown" contains "$work/err" "ExpiredTokenException"
"$test_bash" "$wait_script" kube-lab-t1 us-east-1 >"$work/out" 2>"$work/err"
check "wait: AWS CLI errors exit 3 without --once" test $? -eq 3

cluster_with ready joined joined
"$test_bash" "$wait_script" kube-lab-t1 us-east-1 60 >"$work/out" 2>"$work/err"
rc=$?
check "wait: ready exits 0" test "$rc" -eq 0
check "wait: ready prints the eval form" contains "$work/out" "eval \"\$($(printf '%q' "$repo_root/scripts")/get-kubeconfig.sh kube-lab-t1 us-east-1)\""

cluster_with failed:cni failed:cni joined
"$test_bash" "$wait_script" kube-lab-t1 us-east-1 60 >"$work/out" 2>"$work/err"
check "wait: failure exits 1" test $? -eq 1

for args in "--once kube-lab-t1 us-east-1 60" "kube-lab-t1" "kube-lab-t1 us-east-1 soon" "--history kube-lab-t1"; do
  eval "set -- $args"
  "$test_bash" "$wait_script" "$@" >"$work/out" 2>"$work/err"
  rc=$?
  check "wait: rejects arguments ($args) with 64" test "$rc" -eq 64
done

# --history: one block per parameter, the cluster's first, each value with its time.
cluster_with ready joined joined
history="$FAKE_AWS_DIR/history/kube-lab-t1"
mkdir -p "$history/status" "$history/nodes/cp-1" "$history/nodes/worker-1"
printf '%s\t%s\n' "2026-10-21T12:00:00+00:00" pending "2026-10-21T12:05:50+00:00" ready >"$history/status/cluster"
printf '%s\t%s\n' "2026-10-21T12:00:00+00:00" pending "2026-10-21T12:05:40+00:00" joined >"$history/nodes/cp-1/status"
printf '%s\t%s\n' "2026-10-21T12:00:00+00:00" pending "2026-10-21T12:05:05+00:00" joined >"$history/nodes/worker-1/status"
"$test_bash" "$wait_script" --history kube-lab-t1 us-east-1 >"$work/out" 2>"$work/err"
rc=$?
check "wait --history: exits 0" test "$rc" -eq 0
check "wait --history: cluster block first" test "$(sed -n 1p "$work/out")" = "status/cluster"
check "wait --history: shows each value with its time" contains "$work/out" "$(printf '  2026-10-21T12:05:40+00:00\tjoined')"
check "wait --history: one block per node" test "$(grep -c '^nodes/' "$work/out")" -eq 2

# --- lib.sh: steps and statuses -------------------------------------------------------
# lib.sh hard-codes node paths, so the test runs a copy that points them into $work.
# The node scripts run on Ubuntu's bash 5, and the ERR trap needs BASHPID (bash 4), so
# these tests use NODE_BASH, or bash from PATH, and skip on an older bash.
node_bash=${NODE_BASH:-bash}
node="$work/node"
mkdir -p "$node/state" "$node/run"
cat >"$node/cluster.env" <<'EOF'
NODE_NAME='cp-1'
NODE_ROLE='control-plane'
IS_INIT_NODE='true'
REGION='us-east-1'
SSM_PREFIX='/kube-lab-t1'
EOF
sed -e "s#/etc/kube-lab/cluster.env#$node/cluster.env#" \
  -e "s#^readonly STATE_DIR=[^ ]*#readonly STATE_DIR=$node/state#" \
  -e "s#^readonly RUN_DIR=[^ ]*#readonly RUN_DIR=$node/run#" \
  -e "s#^readonly LOG_FILE=.*#readonly LOG_FILE=$node/bootstrap.log#" \
  "$repo_root/modules/cluster/bootstrap/files/lib.sh" >"$node/lib.sh"

# A bootstrap in miniature: two statuses, a step that runs once, then a step that fails.
cat >"$node/test.sh" <<'EOF'
set -Eeuo pipefail
source "$1"
start_bootstrap
status joined
cluster_status ready
count() { echo run >>"$STATE_DIR/count"; }
run_step counted count
run_step counted count
echo secret >"$RUN_DIR/kubeadm-join.yaml"
run_step broken false
echo "after the failed step" >>"$STATE_DIR/count"
EOF

if "$node_bash" -c '((BASH_VERSINFO[0] >= 4))' 2>/dev/null; then
  reset_aws
  "$node_bash" "$node/test.sh" "$node/lib.sh" >"$work/out" 2>"$work/err"
  rc=$?
  check "lib.sh: a failed step stops the bootstrap" test "$rc" -ne 0 -a "$(cat "$node/state/count")" = run
  check "lib.sh: a finished step runs once and leaves a marker" test -e "$node/state/counted.done"
  check "lib.sh: a failed step leaves no marker" test ! -e "$node/state/broken.done"
  check "lib.sh: a failed step reports failed:<step> for the node" test "$(cat "$FAKE_AWS_DIR/params/kube-lab-t1/nodes/cp-1/status")" = failed:broken
  check "lib.sh: cp-1 reports failed:<step> for the cluster" test "$(cat "$FAKE_AWS_DIR/params/kube-lab-t1/status/cluster")" = failed:broken
  check "lib.sh: status writes don't set the type or tier" test "$(grep 'put-parameter' "$FAKE_AWS_DIR/calls" | grep -c -e '--type' -e '--tier')" -eq 0
  check "lib.sh: files in RUN_DIR are removed on exit" test ! -e "$node/run/kubeadm-join.yaml"
else
  echo "skip  lib.sh: $node_bash is older than bash 4 (set NODE_BASH; CI runs these)"
fi

echo
echo "$passed passed, $failed failed ($("$test_bash" -c 'echo "bash $BASH_VERSION"'))"
[[ $failed -eq 0 ]]
