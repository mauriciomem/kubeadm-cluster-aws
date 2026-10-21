#!/bin/bash
# Control-plane bootstrap. cp-1 runs kubeadm init and installs the CNI and
# kubelet-csr-approver; the others join.
# Flow and status values: see main below, and the status protocol at the top of lib.sh.
set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source /etc/kube-lab/lib.sh

# The add-ons talk to the local API server, so they don't wait for NLB target registration.
LOCAL_KUBECONFIG=$RUN_DIR/admin-local.conf

# Own step, so a re-run after a failed publish doesn't re-init. That re-run has lost the
# token and key from init, so it mints new ones.
publish_join_material() {
  local ca_hash
  if [[ -z ${JOIN_TOKEN:-} ]]; then
    JOIN_TOKEN=$(kubeadm token create --ttl 24h)
  fi
  if [[ -z ${CERT_KEY:-} ]]; then
    CERT_KEY=$(upload_certs)
  fi
  ca_hash=$(openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt |
    openssl pkey -pubin -outform der |
    openssl dgst -sha256 -hex | sed 's/^.* //')

  retry 5 ssm_put join/ca-cert-hash "sha256:$ca_hash"
  retry 5 ssm_put join/certificate-key "$CERT_KEY"
  # Joiners poll the token, so it goes last.
  retry 5 ssm_put join/token "$JOIN_TOKEN"
  # Advanced, like the tier Terraform created it with (modules/cluster/ssm.tf).
  # file:// makes the AWS CLI read the value from the file.
  retry 5 ssm_put kubeconfig/admin file:///etc/kubernetes/admin.conf Advanced
}

init_cluster() {
  local config=$RUN_DIR/kubeadm-init.yaml ip
  ip=$(retry 5 imds local-ipv4)
  # Globals, so publish_join_material can publish them.
  JOIN_TOKEN=$(kubeadm token generate)
  CERT_KEY=$(kubeadm certs certificate-key)
  render_kubeadm_config /etc/kube-lab/kubeadm-init.yaml.tmpl "$config" "$ip" "$JOIN_TOKEN" "" "$CERT_KEY"

  status initializing
  # The skip flags keep the token and certificate key out of the bootstrap and cloud-init logs.
  kubeadm init --config "$config" --upload-certs --skip-token-print --skip-certificate-key-print
}

# A copy of admin.conf that talks to this node's API server directly. It asks IMDS for
# the IP again because a re-run skips init_cluster.
write_local_kubeconfig() {
  local ip
  ip=$(retry 5 imds local-ipv4)
  sed "s#^\(\s*server:\).*#\1 https://$ip:6443#" /etc/kubernetes/admin.conf >"$LOCAL_KUBECONFIG"
}

install_calico() {
  local base="https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests"
  local dir=/etc/kube-lab/calico
  install -d -m 0700 "$dir"

  # The v3 CRD bundle is the one Calico documents for Kubernetes 1.36 and later.
  fetch_verified "$base/v3_projectcalico_org.yaml" "$CALICO_CRDS_SHA256" "$dir/crds.yaml"
  fetch_verified "$base/tigera-operator.yaml" "$CALICO_OPERATOR_SHA256" "$dir/tigera-operator.yaml"

  # Server-side apply: the CRD bundle is too large for the client-side last-applied annotation.
  retry 5 kubectl apply --server-side --force-conflicts -f "$dir/crds.yaml"
  retry 5 kubectl apply --server-side --force-conflicts -f "$dir/tigera-operator.yaml"
  kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=5m
  retry 5 kubectl apply -f /etc/kube-lab/calico-installation.yaml

  # tigerastatus/calico only exists once the operator has started reconciling.
  wait_for 900 "Calico" kubectl wait --for=condition=Available tigerastatus/calico --timeout=60s
}

install_cilium() {
  local tarball
  tarball=$(mktemp)
  fetch_verified "https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-amd64.tar.gz" \
    "$CILIUM_CLI_SHA256" "$tarball"
  tar -xzf "$tarball" -C /usr/local/bin cilium
  rm -f "$tarball"

  # ipam.mode=kubernetes uses the kubeadm podSubnet; Cilium's own default pool overlaps 10.x VPCs.
  cilium install --version "$CILIUM_VERSION" \
    --set ipam.mode=kubernetes \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set kubeProxyReplacement=false

  # Not 'cilium status': it execs into the agents, and exec fails ("tls: internal error") until
  # kubelet-csr-approver, which runs after the CNI, approves the kubelets' serving certificates.
  kubectl -n kube-system rollout status daemonset/cilium --timeout=15m
  # Available, not rollout status: the operator's second replica can't schedule on a single node.
  kubectl -n kube-system wait --for=condition=Available deployment/cilium-operator --timeout=5m
  # Cilium 1.16 and later run Envoy as its own DaemonSet by default.
  if kubectl -n kube-system get daemonset/cilium-envoy >/dev/null 2>&1; then
    kubectl -n kube-system rollout status daemonset/cilium-envoy --timeout=5m
  fi
}

install_cni() {
  case $CNI in
    calico) install_calico ;;
    cilium) install_cilium ;;
    *)
      log "unknown CNI '$CNI'"
      return 1
      ;;
  esac
}

# Kubelets request serving certs (serverTLSBootstrap); this controller approves the valid
# ones. Without it, kubectl logs, exec and port-forward fail with "tls: internal error".
install_csr_approver() {
  retry 5 kubectl apply -f /etc/kube-lab/kubelet-csr-approver.yaml
}

# helm_enabled: the Helm CLI. Completion goes into a static file, so no shell runs helm at
# startup.
install_helm() {
  local dir
  dir=$(mktemp -d)
  fetch_verified "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" "$HELM_SHA256" "$dir/helm.tar.gz"
  tar -xzf "$dir/helm.tar.gz" -C "$dir" linux-amd64/helm
  install -m 0755 "$dir/linux-amd64/helm" /usr/local/bin/helm
  install -d /etc/bash_completion.d
  /usr/local/bin/helm completion bash >/etc/bash_completion.d/helm
  rm -rf "$dir"
}

enable_join_refresh() {
  systemctl daemon-reload
  systemctl enable --now kube-lab-refresh-join.timer
}

ready_node_count() {
  kubectl get nodes -o json |
    jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length'
}

all_nodes_ready() {
  local ready
  ready=$(ready_node_count) || return 1
  log "$ready/$EXPECTED_NODES nodes Ready"
  ((ready >= EXPECTED_NODES))
}

# 30 minutes is generous (the first live run took about four); it only bounds a stuck boot.
wait_for_all_nodes_ready() {
  wait_for 1800 "$EXPECTED_NODES nodes Ready" all_nodes_ready
  # CoreDNS scheduled while cp-1 was the only node, so both replicas sit on it, and stopping
  # cp-1 takes cluster DNS down until they're evicted (about 6 minutes in the HA test). A
  # restart now lets kubeadm's anti-affinity spread them. Not fatal: DNS works either way.
  kubectl -n kube-system rollout restart deployment/coredns &&
    kubectl -n kube-system rollout status deployment/coredns --timeout=5m ||
    log "CoreDNS did not restart cleanly; both replicas may still run on cp-1"
}

# cp-1 only. Node status: initializing -> initialized; cluster status: installing.
bootstrap_first_control_plane() {
  run_step init init_cluster
  run_step publish publish_join_material
  status initialized
  run_always local-kubeconfig write_local_kubeconfig
  export KUBECONFIG=$LOCAL_KUBECONFIG
  cluster_status installing
  run_step cni install_cni
  run_step csr-approver install_csr_approver
  run_step refresh-timer enable_join_refresh
  run_step wait-nodes wait_for_all_nodes_ready
}

main() {
  start_bootstrap
  prepare_node
  if [[ $IS_INIT_NODE == true ]]; then
    bootstrap_first_control_plane
  else
    run_step join join_cluster
  fi
  run_always root-kubeconfig setup_root_kubeconfig
  # Root has a kubeconfig on every control plane, so that's where Helm goes.
  if [[ $HELM_ENABLED == true ]]; then
    run_step helm install_helm
  fi
  status joined
  # Last, so every node status is final once wait-for-cluster.sh sees ready. cp-1 only.
  cluster_status ready
  finish_bootstrap
}

main "$@"
