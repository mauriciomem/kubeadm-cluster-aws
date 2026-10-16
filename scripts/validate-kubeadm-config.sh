#!/usr/bin/env bash
# Runs `kubeadm config validate` (pinned kubeadm) on the rendered kubeadm configs of three
# topologies: init and worker join, control-plane join, and the no-workers variants with
# `taints: []`. Runtime placeholders get dummy values of the right shape.
# kubeadm is Linux-only: on macOS this runs the check in a container if Docker is up,
# otherwise it skips and CI covers it.
#
#   ./scripts/validate-kubeadm-config.sh
set -euo pipefail

KUBEADM_VERSION=${KUBEADM_VERSION:-v1.36.5}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=build/kubeadm-validate
tools=build/.tools

cd "$repo_root"

render_variants() {
  local variant name args node f
  rm -rf "$work"
  for variant in "default:" "ha:-var control_plane_count=3" "no-workers:-var control_plane_count=3 -var worker_count=0"; do
    name=${variant%%:*}
    args=${variant#*:}
    # shellcheck disable=SC2086 # args are separate -var flags
    ./scripts/render-templates.sh $args >/dev/null
    mkdir -p "$work/$name"
    cp build/nodes/cp-1/files/etc/kube-lab/kubeadm-init.yaml.tmpl "$work/$name/cp-1-init.yaml.tmpl"
    for f in build/nodes/*/files/etc/kube-lab/kubeadm-join.yaml.tmpl; do
      node=${f#build/nodes/}
      node=${node%%/*}
      cp "$f" "$work/$name/$node-join.yaml.tmpl"
    done
  done
}

fetch_kubeadm() {
  local arch url bin
  case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *)
      echo "unsupported architecture $(uname -m)" >&2
      return 1
      ;;
  esac
  bin=$tools/kubeadm-$KUBEADM_VERSION-$arch
  if [[ ! -x $bin ]]; then
    url=https://dl.k8s.io/release/$KUBEADM_VERSION/bin/linux/$arch/kubeadm
    mkdir -p "$tools"
    curl --proto '=https' --tlsv1.2 -fsSL -o "$bin.tmp" "$url"
    echo "$(curl --proto '=https' --tlsv1.2 -fsSL "$url.sha256")  $bin.tmp" | sha256sum --check --quiet -
    chmod 0755 "$bin.tmp"
    mv "$bin.tmp" "$bin"
  fi
  echo "$bin"
}

validate() {
  local kubeadm tmpl out rc=0
  kubeadm=$(fetch_kubeadm)
  for tmpl in "$work"/*/*.yaml.tmpl; do
    out=${tmpl%.tmpl}
    sed -e 's/\${PRIVATE_IP}/10.10.0.10/g' \
      -e 's/\${JOIN_TOKEN}/abcdef.0123456789abcdef/g' \
      -e "s/\\\${CA_CERT_HASH}/sha256:$(printf 'a%.0s' {1..64})/g" \
      -e "s/\\\${CERT_KEY}/$(printf 'b%.0s' {1..64})/g" \
      "$tmpl" >"$out"
    if "$kubeadm" config validate --config "$out" >"$out.log" 2>&1; then
      echo "ok    ${out#"$work"/}"
    else
      echo "FAIL  ${out#"$work"/}"
      sed 's/^/      /' "$out.log"
      rc=1
    fi
  done
  return "$rc"
}

if [[ ${1:-} == --validate-only ]]; then
  validate
elif [[ $(uname -s) == Linux ]]; then
  render_variants
  validate
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  render_variants
  # Streamed in, not bind-mounted: Docker VMs (colima, Docker Desktop) don't share every path.
  COPYFILE_DISABLE=1 tar --no-xattrs -cf - scripts/validate-kubeadm-config.sh "$work" |
    docker run --rm -i -e KUBEADM_VERSION ubuntu:24.04 bash -c \
      'apt-get -qq update >/dev/null && apt-get -qq install -y curl ca-certificates >/dev/null 2>&1 &&
       mkdir /work && cd /work && tar --warning=no-unknown-keyword -xf - && ./scripts/validate-kubeadm-config.sh --validate-only'
else
  echo "SKIPPED: kubeadm runs on Linux only and Docker is not available; CI runs this check." >&2
fi
