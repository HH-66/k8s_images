#!/usr/bin/env bash
set -euo pipefail

readonly list=${1:?usage: download-filtered-files.sh LIST OUTPUT_DIR}
readonly output_root=${2:?usage: download-filtered-files.sh LIST OUTPUT_DIR}

destination_for() {
  local url=$1
  local filename=${url##*/}
  case "${url}" in
    https://dl.k8s.io/release/v1.35.4/bin/linux/amd64/*)
      printf '%s/kubernetes/v1.35.4/%s\n' "${output_root}" "${filename}"
      ;;
    https://github.com/etcd-io/etcd/releases/download/v3.6.10/*)
      printf '%s/kubernetes/etcd/%s\n' "${output_root}" "${filename}"
      ;;
    https://github.com/containernetworking/plugins/releases/download/v1.9.1/*)
      printf '%s/kubernetes/cni/%s\n' "${output_root}" "${filename}"
      ;;
    https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.35.0/*)
      printf '%s/kubernetes/cri-tools/%s\n' "${output_root}" "${filename}"
      ;;
    https://github.com/opencontainers/runc/releases/download/v1.4.2/*)
      printf '%s/runc/v1.4.2/%s\n' "${output_root}" "${filename}"
      ;;
    https://github.com/containerd/nerdctl/releases/download/v2.2.2/*)
      printf '%s/%s\n' "${output_root}" "${filename}"
      ;;
    https://github.com/containerd/containerd/releases/download/v2.2.3/*)
      printf '%s/%s\n' "${output_root}" "${filename}"
      ;;
    https://github.com/cilium/cilium-cli/releases/download/v0.18.9/*)
      printf '%s/cilium-cli/v0.18.9/%s\n' "${output_root}" "${filename}"
      ;;
    *)
      echo "refusing URL outside the base-cluster map: ${url}" >&2
      return 1
      ;;
  esac
}

while IFS= read -r url; do
  [[ -z "${url}" || "${url}" == \#* ]] && continue
  destination=$(destination_for "${url}")
  mkdir -p "$(dirname "${destination}")"
  curl --location --fail --show-error \
    --retry 3 --retry-all-errors \
    --output "${destination}" "${url}"
done < "${list}"
