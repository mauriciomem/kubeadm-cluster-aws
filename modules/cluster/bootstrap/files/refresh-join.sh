#!/bin/bash
# Publishes a fresh join token to SSM (run every 12h by kube-lab-refresh-join.timer).
# With --upload-certs it also re-uploads control-plane certificates, which kubeadm
# deletes after 2h; run that by hand on cp-1 before adding a control plane later.

export STEP=refresh-join
# shellcheck source=/dev/null
source /etc/kube-lab/lib.sh
set -Eeuo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

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
