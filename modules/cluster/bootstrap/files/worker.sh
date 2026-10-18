#!/bin/bash
# Worker bootstrap: prepare the host and join through the API NLB.
# Flow: prepare_node -> join_cluster (both in lib.sh).
# Node status: bootstrapping -> waiting -> joining -> joined.
set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source /etc/kube-lab/lib.sh

main() {
  start_bootstrap
  prepare_node
  run_step join join_cluster
  status joined
  finish_bootstrap
}

main "$@"
