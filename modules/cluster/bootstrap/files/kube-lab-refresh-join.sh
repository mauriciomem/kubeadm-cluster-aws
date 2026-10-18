#!/bin/bash
# Installed on cp-1 as /usr/local/sbin/kube-lab-refresh-join.
# Publishes a fresh join token to SSM (run every 12h by kube-lab-refresh-join.timer).
# With --upload-certs it also re-uploads control-plane certificates, which kubeadm
# deletes after 2h; run that by hand on cp-1 before adding a control plane later.
#
# It doesn't call start_bootstrap, so there is no ERR trap: a failed refresh must not mark
# cp-1 or the cluster failed. Failures show in journalctl -u kube-lab-refresh-join.
set -Eeuo pipefail

export STEP=refresh-join
# shellcheck source-path=SCRIPTDIR source=lib.sh
source /etc/kube-lab/lib.sh

main() {
  local token cert_key
  export KUBECONFIG=/etc/kubernetes/admin.conf
  # ssm_put stages values in RUN_DIR, a tmpfs that is empty after a reboot.
  install -d -m 0700 "$RUN_DIR"

  if [[ ${1:-} == --upload-certs ]]; then
    cert_key=$(upload_certs)
    retry 5 ssm_put join/certificate-key "$cert_key"
    unset cert_key
    log "uploaded control-plane certificates (valid for 2h)"
  fi

  # Separate assignment, so a failed token create stops the script instead of publishing "".
  token=$(kubeadm token create --ttl 24h)
  retry 5 ssm_put join/token "$token"
  unset token
  log "published a new join token (valid for 24h)"
}

main "$@"
