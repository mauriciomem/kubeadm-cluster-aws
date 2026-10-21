#!/bin/bash
# Helpers shared by control-plane.sh, worker.sh and kube-lab-refresh-join.
# Sourced after the caller has turned on strict mode (set -Eeuo pipefail).
#
# Status protocol (docs/architecture.md has the full table):
#   /<cluster>/nodes/<node>/status  pending -> bootstrapping -> waiting -> joining -> joined
#                                   (cp-1: ... -> initializing -> initialized -> joined)
#   /<cluster>/status/cluster       pending -> installing -> ready   (cp-1 writes it)
#   On failure: failed:<step>, where <step> is the run_step or run_always name.

# Written by Terraform from templates/cluster.env.tftpl.
# shellcheck source-path=SCRIPTDIR source=../templates/cluster.env.tftpl
source /etc/kube-lab/cluster.env

# cloud-init and systemd start us without HOME; kubectl, helm and cilium keep caches under it.
export HOME=${HOME:-/root}
export DEBIAN_FRONTEND=noninteractive

# Signing keys of the apt repositories, from the Docker and Kubernetes install docs.
readonly DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
readonly K8S_KEY_FINGERPRINT=DE15B14486CD377B9E876E1A234654DA9A296436

readonly STATE_DIR=/var/lib/kube-lab # one <step>.done marker per finished step
readonly RUN_DIR=/run/kube-lab       # tmpfs: rendered kubeadm configs hold the join token
readonly LOG_FILE=/var/log/kube-lab-bootstrap.log
STEP=${STEP:-start}

# --- Logging, SSM and status ---------------------------------------------------------

# Logs to stderr, so functions can still return values on stdout.
log() {
  printf '%s %s [%s] %s\n' "$(date -u +%FT%TZ)" "$NODE_NAME" "$STEP" "$*" >&2
}

# ssm_put <name> <value> [tier]: writes a SecureString under SSM_PREFIX. A value of
# file://<path> makes the AWS CLI read it from that file.
# PutParameter can't downgrade a tier, so pass the tier Terraform created it with.
ssm_put() {
  aws ssm put-parameter --region "$REGION" --name "$SSM_PREFIX/$1" \
    --type SecureString --tier "${3:-Standard}" --overwrite --value "$2" >/dev/null
}

ssm_get() {
  aws ssm get-parameter --region "$REGION" --name "$SSM_PREFIX/$1" \
    --with-decryption --query Parameter.Value --output text
}

# Publishes this node's status. Never fails: a lost update must not stop the bootstrap.
# Terraform owns the parameter's type and allowed_pattern (modules/cluster/ssm.tf).
status() {
  aws ssm put-parameter --region "$REGION" --name "$SSM_PREFIX/nodes/$NODE_NAME/status" \
    --overwrite --value "$1" >/dev/null || log "could not publish node status '$1'"
}

# Publishes the cluster status; only cp-1 does.
cluster_status() {
  [[ $IS_INIT_NODE == true ]] || return 0
  aws ssm put-parameter --region "$REGION" --name "$SSM_PREFIX/status/cluster" \
    --overwrite --value "$1" >/dev/null || log "could not publish cluster status '$1'"
}

# ERR trap: reports failed:<step>, then exits.
on_error() {
  local rc=$?
  # Subshells inherit the trap (errtrace); report once, from the main shell.
  [[ $BASHPID == "$$" ]] || exit "$rc"
  log "failed with exit code $rc"
  status "failed:$STEP"
  cluster_status "failed:$STEP"
  exit "$rc"
}

start_bootstrap() {
  mkdir -p "$STATE_DIR"
  install -d -m 0700 "$RUN_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap on_error ERR
  # Also on failure: the files in RUN_DIR hold the join token or an admin kubeconfig.
  trap 'rm -f "$RUN_DIR"/*' EXIT
}

finish_bootstrap() {
  STEP=complete
  log "bootstrap complete"
}

# run_step <name> <command...>: runs a step once. A marker file lets a re-run skip it.
run_step() {
  STEP=$1
  shift
  if [[ -f $STATE_DIR/$STEP.done ]]; then
    log "already done"
    return 0
  fi
  log "starting"
  "$@"
  touch "$STATE_DIR/$STEP.done"
  log "done"
}

# Like run_step, without a marker, for quick work every run must repeat.
run_always() {
  STEP=$1
  shift
  log "starting"
  "$@"
  log "done"
}

# --- Retry and wait ------------------------------------------------------------------

# Doubles a delay, up to 60 seconds.
next_delay() {
  local doubled=$(($1 * 2))
  echo $((doubled > 60 ? 60 : doubled))
}

# retry <attempts> <command...>: backs off from 5s to 60s. Logs only the command name and
# its first argument, because later arguments can be secrets.
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

# wait_for <timeout-seconds> <description> <command...>
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

# imds <path>: an instance metadata value, through IMDSv2.
imds() {
  local token
  token=$(curl -sf --max-time 5 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') &&
    curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

# fetch_verified <url> <sha256> <dest>: downloads a file and checks its pinned checksum.
# The file only appears at dest once it has passed. --max-time turns a stalled download
# into a failure that retry can repeat. The URL comes first so retry's log line shows it.
fetch_verified() {
  local url=$1 sha256=$2 dest=$3
  retry 5 curl "$url" -fsSL --max-time 600 -o "$dest.download"
  if ! echo "$sha256  $dest.download" | sha256sum --check --quiet -; then
    rm -f "$dest.download"
    log "checksum mismatch for $url"
    return 1
  fi
  mv -f "$dest.download" "$dest"
}

# AWS CLI v2 from AWS's own zip, to /usr/local/aws-cli with a link in /usr/local/bin. The
# AMI has no unzip and apt isn't set up yet, so Python's zipfile unpacks it. zipfile drops
# the file modes, hence the chmod. --update makes a re-run safe.
install_aws_cli() {
  local dir
  dir=$(mktemp -d)
  fetch_verified "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWS_CLI_VERSION.zip" \
    "$AWS_CLI_SHA256" "$dir/awscli.zip"
  python3 -m zipfile -e "$dir/awscli.zip" "$dir"
  chmod -R a+rx "$dir/aws"
  "$dir/aws/install" --update
  rm -rf "$dir"
}

# --- Host preparation and packages ---------------------------------------------------

prepare_host() {
  swapoff -a
  sed -ri '/\sswap\s/s/^#*/#/' /etc/fstab

  # Kubernetes only requires ip_forward. Bridged traffic through iptables is what most CNI
  # and kube-proxy setups, and the CKA material, expect.
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

# install_apt_key <url> <fingerprint> <dest>: installs an apt signing key, dearmored, if it
# has the pinned fingerprint. A key that doesn't match stops the bootstrap.
install_apt_key() {
  local url=$1 fingerprint=$2 dest=$3 tmp keys
  tmp=$(mktemp)
  retry 5 curl "$url" -fsSL --max-time 60 -o "$tmp"
  keys=$(gpg --show-keys --with-colons "$tmp")
  if ! grep -q "^fpr:*:$fingerprint:" <<<"$keys"; then
    log "the key from $url does not have fingerprint $fingerprint"
    return 1
  fi
  install -d -m 0755 /etc/apt/keyrings
  gpg --dearmor --yes -o "$dest" "$tmp"
  chmod 0644 "$dest"
  rm -f "$tmp"
}

# True when no apt run is in progress. unattended-upgrades.service is always active, so the
# check looks at the services that do the work.
apt_idle() {
  ! systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service || return 1
  ! { command -v fuser >/dev/null && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; }
}

# apt-daily starts minutes after first boot and holds the dpkg lock. Stop its timers, wait
# out a run already in progress, and keep apt's own lock wait as a backstop.
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

# containerd, kubeadm, kubelet and kubectl, held at the pinned versions.
install_packages() {
  quiesce_apt
  apt_get update
  apt_get install -y ca-certificates curl gnupg gettext-base jq

  # containerd.io from Docker's repo: Ubuntu's own containerd is too old for the 1.37 upgrade lab.
  install_apt_key https://download.docker.com/linux/ubuntu/gpg "$DOCKER_KEY_FINGERPRINT" /etc/apt/keyrings/docker.gpg
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
EOF

  # Same layout as the kubernetes.io install docs, so the upgrade lab's repo switch applies verbatim.
  install_apt_key "https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR/deb/Release.key" "$K8S_KEY_FINGERPRINT" \
    /etc/apt/keyrings/kubernetes-apt-keyring.gpg
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

# Every node runs these before the roles split. A node can only report status once the AWS
# CLI is installed, so it stays "pending" until then.
prepare_node() {
  run_step awscli install_aws_cli
  status bootstrapping
  run_step host prepare_host
  run_step packages install_packages
  run_step containerd configure_containerd
  run_step shell configure_shell
}

# --- Join ----------------------------------------------------------------------------

# Re-uploads the control-plane certificates under a new key and prints the key. It comes
# from kubeadm's stdout and is never logged.
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

# True once cp-1 has replaced Terraform's "pending" placeholder.
param_published() {
  local value
  value=$(ssm_get "$1") || return 1
  [[ -n $value && $value != pending ]]
}

# node_status_in <node> <status...>
node_status_in() {
  local node=$1 value
  shift
  value=$(ssm_get "nodes/$node/status") || return 1
  [[ " $* " == *" $value "* ]]
}

# Any HTTP status, even 401 or 403, means the load balancer reached a live API server.
api_reachable() {
  [[ $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$API_ENDPOINT/livez" || true) != 000 ]]
}

# render_kubeadm_config <template> <out> <ip> <token> <ca-hash> <cert-key>
# Fills the ${...} placeholders Terraform left in a kubeadm template (see its header). The
# values only reach envsubst's environment, never kubeadm's.
render_kubeadm_config() {
  # shellcheck disable=SC2016 # envsubst takes the literal variable names.
  PRIVATE_IP=$3 JOIN_TOKEN=$4 CA_CERT_HASH=$5 CERT_KEY=$6 \
    envsubst '${PRIVATE_IP} ${JOIN_TOKEN} ${CA_CERT_HASH} ${CERT_KEY}' <"$1" >"$2"
}

# Joins this node (a worker, or cp-2 and later) through the API load balancer. The waits
# only bound how long a broken boot hangs before it reports failed:join.
join_cluster() {
  local config=$RUN_DIR/kubeadm-join.yaml ip token ca_hash cert_key=""

  status waiting
  wait_for 2400 "join token" param_published join/token
  if [[ $NODE_ROLE == control-plane ]]; then
    # etcd admits one learner at a time, so control planes join strictly in order.
    wait_for 2400 "$PREVIOUS_CONTROL_PLANE" node_status_in "$PREVIOUS_CONTROL_PLANE" initialized joined
    cert_key=$(retry 5 ssm_get join/certificate-key)
  fi
  wait_for 900 "API server via NLB" api_reachable

  # Separate assignments, so a failed read stops the script before kubeadm runs.
  ip=$(retry 5 imds local-ipv4)
  token=$(retry 5 ssm_get join/token)
  ca_hash=$(retry 5 ssm_get join/ca-cert-hash)
  render_kubeadm_config /etc/kube-lab/kubeadm-join.yaml.tmpl "$config" "$ip" "$token" "$ca_hash" "$cert_key"

  status joining
  kubeadm join --config "$config"
}
