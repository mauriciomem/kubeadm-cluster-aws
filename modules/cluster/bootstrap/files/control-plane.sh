#!/bin/bash
# Control-plane bootstrap. cp-1 runs kubeadm init and installs the add-ons; the others join.

# shellcheck source=/dev/null
source /etc/kube-lab/lib.sh
start_bootstrap

# Bootstrap talks to the local API server so add-ons don't wait for NLB target registration.
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
  retry 5 ssm_put_file kubeconfig/admin /etc/kubernetes/admin.conf Advanced
  unset JOIN_TOKEN CERT_KEY
}

init_cluster() {
  local config=$RUN_DIR/kubeadm-init.yaml
  export PRIVATE_IP JOIN_TOKEN CERT_KEY CA_CERT_HASH=""

  PRIVATE_IP=$(retry 5 imds local-ipv4)
  JOIN_TOKEN=$(kubeadm token generate)
  CERT_KEY=$(kubeadm certs certificate-key)
  render_kubeadm_config /etc/kube-lab/kubeadm-init.yaml.tmpl "$config"
  # Still needed by publish_join_material, but not in kubeadm's environment.
  export -n JOIN_TOKEN CERT_KEY

  status initializing
  # The skip flags keep the token and certificate key out of the bootstrap and cloud-init logs.
  kubeadm init --config "$config" --upload-certs --skip-token-print --skip-certificate-key-print
  rm -f "$config"
}

write_local_kubeconfig() {
  local ip
  ip=$(retry 5 imds local-ipv4)
  install -d -m 0700 "$RUN_DIR"
  (
    umask 077
    sed "s#^\(\s*server:\).*#\1 https://$ip:6443#" /etc/kubernetes/admin.conf >"$LOCAL_KUBECONFIG"
  )
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
  cilium status --wait --wait-duration 15m
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

# Kubelets request serving certs (serverTLSBootstrap); this controller approves the valid ones.
install_csr_approver() {
  retry 5 kubectl apply -f /etc/kube-lab/kubelet-csr-approver.yaml
}

install_metrics_server() {
  local manifest=/etc/kube-lab/metrics-server.yaml
  fetch_verified "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml" \
    "$METRICS_SERVER_SHA256" "$manifest"
  retry 5 kubectl apply -f "$manifest"
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

wait_for_cluster() {
  wait_for 1800 "$EXPECTED_NODES nodes Ready" all_nodes_ready
  # Not fatal: nodes work without metrics, and a stuck rollout points at kubelet serving CSRs.
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=5m ||
    log "metrics-server is not ready yet; check 'kubectl get csr' and the kubelet-csr-approver logs"
}

bootstrap_first_control_plane() {
  run_step init init_cluster
  run_step publish publish_join_material
  status initialized
  write_local_kubeconfig
  export KUBECONFIG=$LOCAL_KUBECONFIG
  cluster_status installing
  run_step cni install_cni
  run_step csr-approver install_csr_approver
  run_step metrics-server install_metrics_server
  run_step refresh-timer enable_join_refresh
  run_step wait-cluster wait_for_cluster
  rm -f "$LOCAL_KUBECONFIG"
}

prepare_node
if [[ $INIT == true ]]; then
  bootstrap_first_control_plane
else
  run_step join join_cluster
fi
setup_root_kubeconfig
status joined
cluster_status ready
finish_bootstrap
