#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-/opt/jasper-k8s-offline/current}
readonly nerdctl=/usr/local/bin/nerdctl
readonly service_address=${JASPER_OFFLINE_SERVICE_ADDRESS:-10.144.66.139}

test "$(id -u)" -eq 0 || { echo 'must run as root' >&2; exit 1; }
test -x "${nerdctl}"
test -f "${root}/kubespray-2.31.0/cluster.yml"
test -f "${root}/kubespray-2.31.0/offline-repo.yml"
test -f "${root}/kubespray-2.31.0/.jasper-kubespray-source.json"
systemctl is-active --quiet containerd
"${root}/verify-base-bundle.sh" "${root}"
curl --fail --silent --show-error --head \
  "http://${service_address}/files/files.list" >/dev/null
curl --fail --silent --show-error \
  "http://${service_address}:35000/v2/" >/dev/null

while IFS= read -r image; do
  [[ -z "${image}" || "${image}" == \#* ]] && continue
  case "${image}" in
    registry.k8s.io/*|k8s.gcr.io/*|gcr.io/*|ghcr.io/*|docker.io/*|quay.io/*)
      local_image=${image#*/}
      ;;
    *) local_image=${image} ;;
  esac
  "${nerdctl}" --namespace default manifest inspect \
    --insecure-registry "${service_address}:35000/${local_image}" >/dev/null
done < "${root}/images/images.list"
