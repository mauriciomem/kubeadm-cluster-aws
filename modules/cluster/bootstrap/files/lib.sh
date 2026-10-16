#!/bin/bash
# Helpers shared by the kube-lab node scripts. Sourced, never executed directly.

# shellcheck source=/dev/null
source /etc/kube-lab/cluster.env

export HOME=${HOME:-/root}
export PATH=$PATH:/snap/bin
export DEBIAN_FRONTEND=noninteractive

# Trust anchors for the apt repositories; a key that doesn't match aborts the bootstrap.
DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
K8S_KEY_FINGERPRINT=DE15B14486CD377B9E876E1A234654DA9A296436

STATE_DIR=/var/lib/kube-lab
# tmpfs, so rendered kubeadm configs (they hold join secrets) never reach disk.
RUN_DIR=/run/kube-lab
LOG_FILE=/var/log/kube-lab-bootstrap.log
STEP=${STEP:-start}

# Logs go to stderr so functions can return values on stdout.
log() {
  printf '%s %s [%s] %s\n' "$(date -u +%FT%TZ)" "$NODE_NAME" "$STEP" "$*" >&2
}

# ssm_put_file <name> <file> [tier]
ssm_put_file() {
  aws ssm put-parameter --region "$REGION" --name "$SSM_PREFIX/$1" \
    --type SecureString --tier "${3:-Standard}" --overwrite --value "file://$2" >/dev/null
}

# Values go through a private temp file so secrets never show up in `ps`.
ssm_put() {
  local tmp rc=0
  tmp=$(mktemp)
  printf '%s' "$2" >"$tmp"
  ssm_put_file "$1" "$tmp" "${3:-Standard}" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

ssm_get() {
  aws ssm get-parameter --region "$REGION" --name "$SSM_PREFIX/$1" \
    --with-decryption --query Parameter.Value --output text
}

status() {
  ssm_put "nodes/$NODE_NAME/status" "$1" || log "could not publish node status '$1'"
}

cluster_status() {
  [[ $INIT == true ]] || return 0
  ssm_put status/cluster "$1" || log "could not publish cluster status '$1'"
}

on_error() {
  local rc=$?
  # With errtrace, subshells inherit the trap; report once, from the main shell.
  [[ $BASHPID == "$$" ]] || exit "$rc"
  log "failed with exit code $rc"
  status "failed:$STEP"
  cluster_status "failed:$STEP"
  exit "$rc"
}

# Call once at the top of each bootstrap script.
start_bootstrap() {
  set -Eeuo pipefail
  mkdir -p "$STATE_DIR"
  install -d -m 0700 "$RUN_DIR"
  [[ -e $LOG_FILE ]] || install -m 0600 /dev/null "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap on_error ERR
  trap 'rm -f "$RUN_DIR"/kubeadm-*.yaml' EXIT
}

finish_bootstrap() {
  STEP=complete
  log "bootstrap complete"
}

# A marker file per step lets a manual re-run skip work that already succeeded.
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

next_delay() {
  local doubled=$(($1 * 2))
  echo $((doubled > 60 ? 60 : doubled))
}

# retry <attempts> <command...>: exponential backoff from 5s, capped at 60s.
# Logs only the command and its first argument: later ones can be secrets.
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

# wait_for <timeout-seconds> <description> <command...>: polls until the command succeeds.
wait_for() {
  local deadline=$((SECONDS + $1)) what=$2 delay=5
  shift 2
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

imds() {
  local token
  token=$(curl -sf -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token) &&
    curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

# https_get <url> [curl args...]: refuses plain HTTP and TLS < 1.2, including on redirects.
https_get() {
  local url=$1
  shift
  curl --proto '=https' --tlsv1.2 -fsSL "$@" "$url"
}

# fetch_verified <url> <sha256> <dest>
fetch_verified() {
  retry 5 https_get "$1" -o "$3"
  echo "$2  $3" | sha256sum --check --quiet -
}

install_aws_cli() {
  retry 5 snap wait system seed.loaded
  retry 5 snap install aws-cli --classic
}

prepare_host() {
  swapoff -a
  sed -ri '/\sswap\s/s/^#*/#/' /etc/fstab

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

# install_apt_key <url> <fingerprint> <dest> [dearmor]
install_apt_key() {
  local tmp actual
  tmp=$(mktemp)
  retry 5 https_get "$1" -o "$tmp"
  # Exactly one primary key, and it is the pinned one: extra keys in the file are rejected.
  actual=$(gpg --show-keys --with-colons "$tmp" |
    awk -F: '$1 == "pub" { p++ } $1 == "fpr" && !f { f = $10 } END { if (p == 1) print f }')
  if [[ $actual != "$2" ]]; then
    log "apt key from $1 must be exactly one key with fingerprint '$2', got '$actual'"
    return 1
  fi
  install -d -m 0755 /etc/apt/keyrings
  if [[ ${4:-} == dearmor ]]; then
    gpg --dearmor --yes -o "$3" "$tmp"
  else
    install -m 0644 "$tmp" "$3"
  fi
  chmod 0644 "$3"
  rm -f "$tmp"
}

# The actual work of unattended upgrades runs inside apt-daily-upgrade.service.
# unattended-upgrades.service is a long-running shutdown helper, always active, so not checked.
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

install_packages() {
  quiesce_apt
  apt_get update
  apt_get install -y ca-certificates curl gnupg gettext-base jq

  # containerd.io from Docker's repo: Ubuntu's own containerd is too old for the 1.37 upgrade lab.
  install_apt_key https://download.docker.com/linux/ubuntu/gpg "$DOCKER_KEY_FINGERPRINT" /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
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

  configure_containerd
  configure_shell
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

prepare_node() {
  run_step awscli install_aws_cli
  status bootstrapping
  run_step host prepare_host
  run_step packages install_packages
}

# upload_certs: re-uploads control-plane certificates under a new key and prints the key.
# It is read from kubeadm's stdout, never logged; supplying our own key with
# --skip-certificate-key-print would put it in argv instead.
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

param_published() {
  local value
  value=$(ssm_get "$1") || return 1
  [[ -n $value && $value != pending ]]
}

# node_status_in <node> <status...>
node_status_in() {
  local value
  value=$(ssm_get "nodes/$1/status") || return 1
  [[ " ${*:2} " == *" $value "* ]]
}

# Any HTTP status, even 401 or 403, means the NLB reached a live API server.
api_reachable() {
  [[ $(curl --proto '=https' --tlsv1.2 -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$API_ENDPOINT/livez" || true) != 000 ]]
}

# Fills runtime placeholders in a kubeadm template. The result holds secrets: root-only, on tmpfs,
# and removed on exit.
render_kubeadm_config() {
  (
    umask 077
    # shellcheck disable=SC2016 # envsubst takes the literal variable names.
    envsubst '${PRIVATE_IP} ${JOIN_TOKEN} ${CA_CERT_HASH} ${CERT_KEY}' <"$1" >"$2"
  )
}

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
