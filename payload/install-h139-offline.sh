#!/usr/bin/env bash
set -euo pipefail

readonly artifact_root=${1:-/opt/jasper-k8s-offline/artifact}
readonly install_root=${2:-/opt/jasper-k8s-offline/current}
readonly archive=${artifact_root}/kubespray-offline-base.tar.zst
readonly checksum=${artifact_root}/kubespray-offline-base.tar.zst.sha256

test "$(id -u)" -eq 0 || { echo 'must run as root' >&2; exit 1; }
test -r /etc/os-release
source /etc/os-release
test "${ID}" = ubuntu
test "${VERSION_ID}" = 24.04
test "$(dpkg --print-architecture)" = amd64
test -s "${archive}"
test -s "${checksum}"
test ! -e "${install_root}" || { echo "destination exists: ${install_root}" >&2; exit 1; }

(cd "${artifact_root}" && sha256sum --check --strict "$(basename "${checksum}")")
mkdir -p "$(dirname "${install_root}")"
staging=$(mktemp -d "$(dirname "${install_root}")/.install.XXXXXX")
trap 'rm -rf "${staging}"' EXIT
tar --zstd -xf "${archive}" -C "${staging}"
"${staging}/outputs/verify-base-bundle.sh" "${staging}/outputs"
mv "${staging}/outputs" "${install_root}"
trap - EXIT
rmdir "${staging}"

cd "${install_root}"
mkdir -p charts
tar -xzf files/cilium-chart/cilium-1.19.3.tgz -C charts
test -f charts/cilium/Chart.yaml
./setup-container.sh
./start-nginx.sh
REGISTRY_DIR=/var/lib/jasper-k8s-registry ./start-registry.sh
./load-push-all-images.sh
./extract-kubespray.sh
cp -R playbook/. kubespray-2.31.0/
./verify-h139-offline.sh "${install_root}"
