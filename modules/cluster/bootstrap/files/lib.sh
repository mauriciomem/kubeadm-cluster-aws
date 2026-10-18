#!/bin/bash
# Helpers shared by the kube-lab node scripts: control-plane.sh, worker.sh and
# kube-lab-refresh-join. Sourced, never executed directly. The callers turn on strict mode
# (set -Eeuo pipefail) before they source this file.
#
# Globals from /etc/kube-lab/cluster.env, written by Terraform (templates/cluster.env.tftpl):
#   NODE_NAME, NODE_ROLE      this node, for example worker-2 and worker
#   IS_INIT_NODE              "true" on cp-1, the node that runs kubeadm init
#   PREVIOUS_CONTROL_PLANE    the control plane this one joins after; empty if none
#   EXPECTED_NODES            how many nodes cp-1 waits for
#   REGION, SSM_PREFIX        where this cluster's SSM parameters live
#   API_ENDPOINT              the API load balancer, as host:port
#   K8S_VERSION, K8S_MINOR, CONTAINERD_VERSION   package versions
#   CNI, CALICO_*, CILIUM_*, METRICS_SERVER_*    add-on choice, versions and checksums
#
# Status protocol. docs/architecture.md (Status values) is the reference.
#   /<cluster>/nodes/<node>/status, written by each node:
#     every node starts at "pending", Terraform's placeholder (modules/cluster/ssm.tf)
#     joining nodes: bootstrapping -> waiting -> joining -> joined
#     cp-1:          bootstrapping -> initializing -> initialized -> joined
#   /<cluster>/status/cluster, written by cp-1 only: pending -> installing -> ready
#   On failure, failed:<step>, where <step> is the run_step or run_always name.
#   Readers: scripts/wait-for-cluster.sh, and join_cluster (cp-N waits for cp-(N-1)).

# shellcheck source-path=SCRIPTDIR source=../templates/cluster.env.tftpl
source /etc/kube-lab/cluster.env

# cloud-init and systemd start us without HOME, which the aws-cli snap needs, and snaps
# live in /snap/bin.
export HOME=${HOME:-/root}
export PATH=$PATH:/snap/bin
export DEBIAN_FRONTEND=noninteractive

# Trust anchors for the apt repositories; a key that doesn't match aborts the bootstrap.
# https://docs.docker.com/engine/install/ubuntu/
readonly DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
readonly K8S_KEY_FINGERPRINT=DE15B14486CD377B9E876E1A234654DA9A296436

# One <step>.done marker per finished step.
readonly STATE_DIR=/var/lib/kube-lab
# tmpfs, so rendered kubeadm configs and staged SSM values (they hold secrets) never reach disk.
readonly RUN_DIR=/run/kube-lab
readonly LOG_FILE=/var/log/kube-lab-bootstrap.log
# The step that is running, for log lines and failed:<step>. Set by run_step and run_always.
STEP=${STEP:-start}

# --- Logging, SSM and status ---------------------------------------------------------

#######################################
# Logs a line to stderr, so functions can still return values on stdout.
# Globals: NODE_NAME, STEP
#######################################
log() {
  printf '%s %s [%s] %s\n' "$(date -u +%FT%TZ)" "$NODE_NAME" "$STEP" "$*" >&2
}

#######################################
# Writes a file's content to a SecureString parameter under SSM_PREFIX.
# Globals: REGION, SSM_PREFIX
# Arguments: name, file, tier (default Standard; PutParameter can't downgrade a tier)
#######################################
ssm_put_file() {
  local name=$1 file=$2 tier=${3:-Standard}
  aws ssm put-parameter --region "$REGION" --name "$SSM_PREFIX/$name" \
    --type SecureString --tier "$tier" --overwrite --value "file://$file" >/dev/null
}

#######################################
# Writes a value to a SecureString parameter. The value goes through a root-only temp
# file on tmpfs, so secrets never show up in `ps` or on disk.
# Globals: RUN_DIR
# Arguments: name, value, tier (default Standard)
#######################################
ssm_put() {
  local name=$1 value=$2 tier=${3:-Standard} tmp rc=0
  tmp=$(mktemp -p "$RUN_DIR")
  printf '%s' "$value" >"$tmp"
  ssm_put_file "$name" "$tmp" "$tier" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

#######################################
# Prints a decrypted parameter value.
# Globals: REGION, SSM_PREFIX
# Arguments: name
#######################################
ssm_get() {
  local name=$1
  aws ssm get-parameter --region "$REGION" --name "$SSM_PREFIX/$name" \
    --with-decryption --query Parameter.Value --output text
}

#######################################
# Publishes this node's status. Never fails: a lost status update must not stop the bootstrap.
# Globals: NODE_NAME
# Arguments: status
#######################################
status() {
  local value=$1
  ssm_put "nodes/$NODE_NAME/status" "$value" || log "could not publish node status '$value'"
}

#######################################
# Publishes the cluster status, on cp-1 only (a no-op elsewhere). Never fails.
# Globals: IS_INIT_NODE
# Arguments: status
#######################################
cluster_status() {
  local value=$1
  [[ $IS_INIT_NODE == true ]] || return 0
  ssm_put status/cluster "$value" || log "could not publish cluster status '$value'"
}

#######################################
# ERR trap: reports failed:<step> for this node (and the cluster, on cp-1), then exits.
# Globals: STEP
#######################################
on_error() {
  local rc=$?
  # With errtrace, subshells inherit the trap; report once, from the main shell.
  [[ $BASHPID == "$$" ]] || exit "$rc"
  log "failed with exit code $rc"
  status "failed:$STEP"
  cluster_status "failed:$STEP"
  exit "$rc"
}

#######################################
# Call once at the top of a bootstrap script: creates the state directories, sends all
# output to LOG_FILE as well, and installs the traps.
# Globals: STATE_DIR, RUN_DIR, LOG_FILE
#######################################
start_bootstrap() {
  mkdir -p "$STATE_DIR"
  install -d -m 0700 "$RUN_DIR"
  [[ -e $LOG_FILE ]] || install -m 0600 /dev/null "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap on_error ERR
  # Secrets on tmpfs go even when the script fails: rendered kubeadm configs, and the
  # local admin kubeconfig control-plane.sh writes.
  trap 'rm -f "$RUN_DIR"/kubeadm-*.yaml "$RUN_DIR"/admin-local.conf' EXIT
}

finish_bootstrap() {
  STEP=complete
  log "bootstrap complete"
}

#######################################
# Runs a step once: a marker file lets a manual re-run skip work that already succeeded.
# Globals: STATE_DIR, STEP (set to the step name)
# Arguments: step name, then the command to run
#######################################
run_step() {
  local name=$1
  shift
  STEP=$name
  if [[ -f $STATE_DIR/$name.done ]]; then
    log "already done"
    return 0
  fi
  log "starting"
  "$@"
  touch "$STATE_DIR/$name.done"
  log "done"
}

#######################################
# Like run_step, but without a marker: for quick work that every run must repeat, such as
# files on tmpfs. A failure still reports failed:<step name>.
# Globals: STEP (set to the step name)
# Arguments: step name, then the command to run
#######################################
run_always() {
  STEP=$1
  shift
  log "starting"
  "$@"
  log "done"
}

# --- Retry and wait ------------------------------------------------------------------

# Prints the next backoff delay: double the current one, capped at 60 seconds.
next_delay() {
  local doubled=$(($1 * 2))
  echo $((doubled > 60 ? 60 : doubled))
}

#######################################
# Runs a command until it succeeds, with exponential backoff from 5s, capped at 60s.
# Logs only the command and its first argument: later ones can be secrets.
# Arguments: attempts, then the command
# Returns: 1 when every attempt failed
#######################################
retry() {
  local attempts=$1 n=1 delay=5
  shift
  until "$@"; do
    if ((n >= attempts)); then
      log "giving up after $n attempts: $1 ${2:-}"
      return 1
    fi
    log "attempt $n failed, retrying in ${delay}s: $1 ${2:-}"
    sleep "$delay"
    n=$((n + 1))
    delay=$(next_delay "$delay")
  done
}

#######################################
# Polls a command until it succeeds or the timeout passes.
# Arguments: timeout in seconds, description for the log, then the command
# Returns: 1 on timeout
#######################################
wait_for() {
  local timeout=$1 what=$2 delay=5 deadline
  shift 2
  deadline=$((SECONDS + timeout))
  log "waiting for $what"
  until "$@"; do
    if ((SECONDS >= deadline)); then
      log "timed out waiting for $what"
      return 1
    fi
    sleep "$delay"
    delay=$(next_delay "$delay")
  done
}

# --- Downloads -----------------------------------------------------------------------

#######################################
# Prints an instance metadata value, through IMDSv2.
# Arguments: metadata path, for example local-ipv4
#######################################
imds() {
  local path=$1 token
  token=$(curl -sf --max-time 5 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') &&
    curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$path"
}

#######################################
# curl that refuses plain HTTP and TLS older than 1.2, including on redirects.
# Arguments: url, then extra curl arguments
#######################################
https_get() {
  local url=$1
  shift
  curl --proto '=https' --tlsv1.2 -fsSL "$@" "$url"
}

#######################################
# Downloads a file and checks it against a pinned sha256. The file only appears at dest
# once it has passed the check.
# Arguments: url, sha256, dest
#######################################
fetch_verified() {
  local url=$1 sha256=$2 dest=$3 tmp=$3.download
  retry 5 https_get "$url" -o "$tmp"
  if ! echo "$sha256  $tmp" | sha256sum --check --quiet -; then
    rm -f "$tmp"
    log "checksum mismatch for $url"
    return 1
  fi
  mv -f "$tmp" "$dest"
}

install_aws_cli() {
  retry 5 snap wait system seed.loaded
  retry 5 snap install aws-cli --classic
}

# --- Host preparation and packages ---------------------------------------------------

#######################################
# Swap off, kernel modules and sysctls for Kubernetes.
#######################################
prepare_host() {
  swapoff -a
  sed -ri '/\sswap\s/s/^#*/#/' /etc/fstab

  # The Kubernetes docs only require ip_forward. br_netfilter and bridge-nf-call-* are
  # kept because many CNI and kube-proxy setups, and CKA material, expect bridged traffic
  # to pass through iptables.
  printf '%s\n' overlay br_netfilter >/etc/modules-load.d/kubernetes.conf
  modprobe overlay
  modprobe br_netfilter

  cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  sysctl --system >/dev/null
}

#######################################
# Installs an apt signing key after checking that the file holds exactly one primary key,
# with the pinned fingerprint.
# Arguments: url, fingerprint, dest, format ("dearmor" to convert from ASCII armor)
# Returns: 1 if the key doesn't match
#######################################
install_apt_key() {
  local url=$1 fingerprint=$2 dest=$3 format=${4:-armored} tmp actual
  tmp=$(mktemp)
  retry 5 https_get "$url" -o "$tmp"
  # Extra keys in the file are rejected, not just a wrong one.
  actual=$(gpg --show-keys --with-colons "$tmp" |
    awk -F: '$1 == "pub" { p++ } $1 == "fpr" && !f { f = $10 } END { if (p == 1) print f }')
  if [[ $actual != "$fingerprint" ]]; then
    log "apt key from $url must be exactly one key with fingerprint '$fingerprint', got '$actual'"
    return 1
  fi
  install -d -m 0755 /etc/apt/keyrings
  if [[ $format == dearmor ]]; then
    gpg --dearmor --yes -o "$dest" "$tmp"
  else
    install -m 0644 "$tmp" "$dest"
  fi
  chmod 0644 "$dest"
  rm -f "$tmp"
}

# True when no apt run is in progress. The actual work of unattended upgrades runs inside
# apt-daily-upgrade.service; unattended-upgrades.service is a long-running shutdown helper,
# always active, so it isn't checked.
apt_idle() {
  ! systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service || return 1
  ! { command -v fuser >/dev/null && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; }
}

# apt-daily fires minutes after first boot and holds the dpkg lock while it runs. Stop the
# timers, wait out a run already in progress, and keep apt's own lock wait as a backstop.
quiesce_apt() {
  systemctl stop apt-daily.timer apt-daily-upgrade.timer || true
  wait_for 900 "apt-daily to finish" apt_idle
}

# dpkg --configure -a finishes an install that an earlier attempt left half-done.
apt_get_once() {
  dpkg --configure -a
  apt-get -q -o DPkg::Lock::Timeout=600 "$@"
}

apt_get() {
  retry 5 apt_get_once "$@"
}

#######################################
# Installs containerd, kubeadm, kubelet and kubectl from the Docker and Kubernetes apt
# repositories, and holds them at the pinned versions.
# Globals: CONTAINERD_VERSION, K8S_VERSION, K8S_MINOR, the *_KEY_FINGERPRINT constants
#######################################
install_packages() {
  quiesce_apt
  apt_get update
  apt_get install -y ca-certificates curl gnupg gettext-base jq

  # containerd.io from Docker's repo: Ubuntu's own containerd is too old for the 1.37 upgrade lab.
  install_apt_key https://download.docker.com/linux/ubuntu/gpg "$DOCKER_KEY_FINGERPRINT" /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  # Same layout as the kubernetes.io install docs, so the upgrade lab's repo switch applies verbatim.
  install_apt_key "https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR/deb/Release.key" "$K8S_KEY_FINGERPRINT" \
    /etc/apt/keyrings/kubernetes-apt-keyring.gpg dearmor
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list

  apt_get update
  apt_get install -y \
    "containerd.io=$CONTAINERD_VERSION" \
    "kubelet=$K8S_VERSION-*" \
    "kubeadm=$K8S_VERSION-*" \
    "kubectl=$K8S_VERSION-*" \
    cri-tools
  apt-mark hold containerd.io kubelet kubeadm kubectl
  systemctl enable kubelet
}

# The containerd.io package ships a config that disables the CRI plugin, so replace it.
# containerd merges this over its built-in defaults.
configure_containerd() {
  cat >/etc/containerd/config.toml <<'EOF'
version = 3

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
  echo 'runtime-endpoint: unix:///run/containerd/containerd.sock' >/etc/crictl.yaml
  systemctl restart containerd
  systemctl enable containerd
}

# kubectl completion, the k alias and YAML-friendly vim settings, for every shell user.
configure_shell() {
  cat >>/etc/bash.bashrc <<'EOF'

# kube-lab
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
  install -d /etc/vim
  printf '%s\n' 'set tabstop=2 shiftwidth=2 expandtab' >>/etc/vim/vimrc.local
}

#######################################
# The steps every node runs before the roles split. The node can only report status once
# the AWS CLI is installed, so it stays "pending" until then.
#######################################
prepare_node() {
  run_step awscli install_aws_cli
  status bootstrapping
  run_step host prepare_host
  run_step packages install_packages
  run_step containerd configure_containerd
  run_step shell configure_shell
}

# --- Join ----------------------------------------------------------------------------

#######################################
# Re-uploads the control-plane certificates under a new key and prints the key. It is read
# from kubeadm's stdout, never logged; supplying our own key with
# --skip-certificate-key-print would put it in argv instead.
# Outputs: the certificate key
#######################################
upload_certs() {
  local key
  key=$(kubeadm init phase upload-certs --upload-certs | tail -n 1)
  if [[ ! $key =~ ^[0-9a-f]{64}$ ]]; then
    log "kubeadm upload-certs did not print a certificate key"
    return 1
  fi
  printf '%s' "$key"
}

# Gives root on control planes a working kubectl, as a lab user would expect.
setup_root_kubeconfig() {
  install -d -m 0700 /root/.kube
  install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
}

# True once cp-1 has replaced Terraform's "pending" placeholder. Arguments: parameter name
param_published() {
  local name=$1 value
  value=$(ssm_get "$name") || return 1
  [[ -n $value && $value != pending ]]
}

# True if the node's status is one of the given values. Arguments: node, then statuses
node_status_in() {
  local node=$1 value
  shift
  value=$(ssm_get "nodes/$node/status") || return 1
  [[ " $* " == *" $value "* ]]
}

# Any HTTP status, even 401 or 403, means the NLB reached a live API server.
# Globals: API_ENDPOINT
api_reachable() {
  [[ $(curl --proto '=https' --tlsv1.2 -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$API_ENDPOINT/livez" || true) != 000 ]]
}

#######################################
# Fills the runtime placeholders in a kubeadm template. The result holds secrets: it is
# root-only, on tmpfs, and the EXIT trap removes it.
# Globals: PRIVATE_IP, JOIN_TOKEN, CA_CERT_HASH, CERT_KEY (exported by the caller)
# Arguments: template, output file
#######################################
render_kubeadm_config() {
  local template=$1 out=$2
  (
    umask 077
    # shellcheck disable=SC2016 # envsubst takes the literal variable names.
    envsubst '${PRIVATE_IP} ${JOIN_TOKEN} ${CA_CERT_HASH} ${CERT_KEY}' <"$template" >"$out"
  )
}

#######################################
# Joins this node (a worker, or cp-2 and later) through the API load balancer.
# The waits are generous on purpose: the first live run had every node joined about four
# minutes after apply. They only bound how long a broken boot hangs before failed:join.
# Globals: NODE_ROLE, PREVIOUS_CONTROL_PLANE, RUN_DIR
# Node status: waiting -> joining
#######################################
join_cluster() {
  local config=$RUN_DIR/kubeadm-join.yaml
  export PRIVATE_IP JOIN_TOKEN CA_CERT_HASH CERT_KEY=""

  status waiting
  wait_for 2400 "join token" param_published join/token
  if [[ $NODE_ROLE == control-plane ]]; then
    # etcd admits one learner at a time, so control planes join strictly in order.
    wait_for 2400 "$PREVIOUS_CONTROL_PLANE" node_status_in "$PREVIOUS_CONTROL_PLANE" initialized joined
    CERT_KEY=$(retry 5 ssm_get join/certificate-key)
  fi
  wait_for 900 "API server via NLB" api_reachable

  PRIVATE_IP=$(retry 5 imds local-ipv4)
  JOIN_TOKEN=$(retry 5 ssm_get join/token)
  CA_CERT_HASH=$(retry 5 ssm_get join/ca-cert-hash)
  render_kubeadm_config /etc/kube-lab/kubeadm-join.yaml.tmpl "$config"
  unset JOIN_TOKEN CA_CERT_HASH CERT_KEY

  status joining
  kubeadm join --config "$config"
  rm -f "$config"
}
