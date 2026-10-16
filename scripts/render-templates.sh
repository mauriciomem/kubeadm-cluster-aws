#!/usr/bin/env bash
# Renders the node bootstrap content into build/ for shellcheck and size checks, offline.
# Inputs come from the root module (via terraform console), so this sees the same
# node map and pins as a real apply. Only the NLB DNS name and cluster suffix are fake.
#
#   ./scripts/render-templates.sh
#   ./scripts/render-templates.sh -var cni=cilium -var control_plane_count=3 -var worker_count=0
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
harness=tests/render
build="$repo_root/build"
state="$build/render.tfstate"

cd "$repo_root"
mkdir -p "$build"
rm -rf "${build:?}/nodes" "$build"/*.sh

terraform init -backend=false -input=false >/dev/null
# operator_cidrs is a placeholder for the required variable. node_cidrs mirrors the
# network module's private /20s, since data sources are not read offline.
echo 'jsonencode({ nodes = local.nodes, software = local.software, region = var.region, node_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)] })' |
  terraform console -var 'operator_cidrs=["192.0.2.0/24"]' "$@" |
  jq -r 'fromjson' >"$build/render.tfvars.json"

terraform -chdir="$harness" init -backend=false -input=false >/dev/null
terraform -chdir="$harness" apply -auto-approve -input=false -state="$state" \
  -var-file="$build/render.tfvars.json" >/dev/null
terraform -chdir="$harness" output -state="$state" -json nodes >"$build/nodes.json"

for node in $(jq -r 'keys[]' "$build/nodes.json"); do
  dir="$build/nodes/$node"
  mkdir -p "$dir"
  jq -r --arg n "$node" '.[$n].cloud_config' "$build/nodes.json" >"$dir/cloud-config.yaml"
  jq -r --arg n "$node" '.[$n].script' "$build/nodes.json" >"$dir/bootstrap.sh"
  for path in $(jq -r --arg n "$node" '.[$n].files | keys[]' "$build/nodes.json"); do
    mkdir -p "$dir/files$(dirname "$path")"
    jq -j --arg n "$node" --arg p "$path" '.[$n].files[$p]' "$build/nodes.json" >"$dir/files$path"
  done

  # Flat .sh copies so `shellcheck build/*.sh` covers every shell file a node receives.
  cp "$dir/bootstrap.sh" "$build/$node-bootstrap.sh"
  cp "$dir/files/etc/kube-lab/lib.sh" "$build/$node-lib.sh"
  if [[ -f $dir/files/usr/local/sbin/kube-lab-refresh-join ]]; then
    cp "$dir/files/usr/local/sbin/kube-lab-refresh-join" "$build/$node-refresh-join.sh"
  fi
done

# EC2 limits user data to 16384 bytes before base64. The MIME wrapper adds well under 1 KB.
printf '%-10s %12s %12s\n' node raw_bytes gzip_bytes
for dir in "$build"/nodes/*; do
  raw=$(cat "$dir/cloud-config.yaml" "$dir/bootstrap.sh" | wc -c | tr -d ' ')
  gz=$(cat "$dir/cloud-config.yaml" "$dir/bootstrap.sh" | gzip -9 | wc -c | tr -d ' ')
  printf '%-10s %12s %12s\n' "$(basename "$dir")" "$raw" "$gz"
done
