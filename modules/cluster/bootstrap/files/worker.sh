#!/bin/bash
# Worker bootstrap: prepare the host and join through the API NLB.

# shellcheck source=/dev/null
source /etc/kube-lab/lib.sh
start_bootstrap

prepare_node
run_step join join_cluster
status joined
finish_bootstrap
