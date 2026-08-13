#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/gpu-operator"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/gpu-operator"}
readonly archive_name=jasper-k8s-gpu-operator-offline.tar.zst

set -a
# shellcheck source=/dev/null
source "${addon_root}/versions.env"
set +a

require_command() {
  command -v "$1" >/dev/null || { echo "required command is missing: $1" >&2; exit 1; }
}

for command in curl python3 sha256sum skopeo tar zstd; do
  require_command "${command}"
done
test "$(uname -m)" = x86_64

rm -rf "${build_root}" "${dist_root}"
mkdir -p \
  "${build_root}/outputs/charts" \
  "${build_root}/outputs/images" \
  "${build_root}/outputs/tools" \
  "${build_root}/outputs/values" \
  "${dist_root}"

chart="${build_root}/outputs/charts/gpu-operator-v${GPU_OPERATOR_VERSION}.tgz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${chart}" \
  "https://helm.ngc.nvidia.com/nvidia/charts/gpu-operator-v${GPU_OPERATOR_VERSION}.tgz"
printf '%s  %s\n' "${GPU_OPERATOR_CHART_SHA256}" "${chart}" \
  | sha256sum --check --strict

helm_archive="${build_root}/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${helm_archive}" \
  "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
printf '%s  %s\n' "${HELM_LINUX_AMD64_SHA256}" "${helm_archive}" \
  | sha256sum --check --strict
tar -xOzf "${helm_archive}" linux-amd64/helm \
  > "${build_root}/outputs/tools/helm"
chmod 0755 "${build_root}/outputs/tools/helm"

copy_image() {
  local source_image=$1
  local source_tag=$2
  local source_digest=$3
  local archive_name=$4
  local archive="${build_root}/outputs/images/${archive_name}"

  skopeo copy \
    --policy "${addon_root}/containers-policy.json" \
    --override-os linux \
    --override-arch amd64 \
    --preserve-digests \
    "docker://${source_image}@${source_digest}" \
    "oci-archive:${archive}:${source_tag}" >&2
  python3 - "${archive}" "${source_digest}" "${source_tag}" <<'PY'
import json
import sys
import tarfile

with tarfile.open(sys.argv[1], "r") as archive:
    index = json.load(archive.extractfile("index.json"))
manifests = index.get("manifests", [])
if len(manifests) != 1:
    raise SystemExit("GPU Operator OCI archive must contain exactly one manifest")
descriptor = manifests[0]
if descriptor.get("digest") != sys.argv[2]:
    raise SystemExit("GPU Operator OCI archive did not preserve the source manifest digest")
if descriptor.get("annotations", {}).get("org.opencontainers.image.ref.name") != sys.argv[3]:
    raise SystemExit("GPU Operator OCI archive has an unexpected tag annotation")
PY
  printf '%s:%s@%s\n' "${source_image}" "${source_tag}" "${source_digest}"
}

{
  copy_image \
    "${GPU_OPERATOR_IMAGE}" \
    "${GPU_OPERATOR_IMAGE_TAG}" \
    "${GPU_OPERATOR_IMAGE_AMD64_DIGEST}" \
    gpu-operator-linux-amd64.tar
  copy_image \
    "${TOOLKIT_IMAGE}" \
    "${TOOLKIT_IMAGE_TAG}" \
    "${TOOLKIT_IMAGE_AMD64_DIGEST}" \
    container-toolkit-linux-amd64.tar
  copy_image \
    "${DEVICE_PLUGIN_IMAGE}" \
    "${DEVICE_PLUGIN_IMAGE_TAG}" \
    "${DEVICE_PLUGIN_IMAGE_AMD64_DIGEST}" \
    k8s-device-plugin-linux-amd64.tar
  copy_image \
    "${DCGM_EXPORTER_IMAGE}" \
    "${DCGM_EXPORTER_IMAGE_TAG}" \
    "${DCGM_EXPORTER_IMAGE_AMD64_DIGEST}" \
    dcgm-exporter-linux-amd64.tar
} > "${build_root}/outputs/images/source-images.lock"

cp "${addon_root}/values.yaml" \
  "${build_root}/outputs/values/gpu-operator-values.yaml"
cp "${addon_root}/payload/verify-gpu-operator-bundle.sh" \
  "${build_root}/outputs/verify-gpu-operator-bundle.sh"
chmod 0755 "${build_root}/outputs/verify-gpu-operator-bundle.sh"

python3 - \
  "${build_root}/outputs/provenance.json" \
  "${GPU_OPERATOR_VERSION}" \
  "${GPU_OPERATOR_SOURCE_COMMIT}" \
  "${GPU_OPERATOR_SIGNED_TAG_OBJECT}" \
  "${HELM_VERSION}" \
  "${ADDON_PROFILE}" <<'PY'
import json
import sys
from pathlib import Path

document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-gpu-operator-offline",
    "profile": sys.argv[6],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "gpu-operator": {
            "version": sys.argv[2],
            "source_commit": sys.argv[3],
            "signed_tag_object": sys.argv[4],
        },
        "helm": {"version": sys.argv[5]},
    },
}
Path(sys.argv[1]).write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

(
  cd "${build_root}/outputs"
  find . -type f ! -name SHA256SUMS -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > SHA256SUMS
)
"${build_root}/outputs/verify-gpu-operator-bundle.sh" \
  "${build_root}/outputs"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -cf - -C "${build_root}" outputs \
  | zstd -T0 -19 -o "${dist_root}/${archive_name}"
(
  cd "${dist_root}"
  sha256sum "${archive_name}" > "${archive_name}.sha256"
)
cp "${build_root}/outputs/provenance.json" "${dist_root}/provenance.json"
cp "${build_root}/outputs/images/source-images.lock" \
  "${dist_root}/source-images.lock"
(
  cd "${dist_root}"
  sha256sum \
    "${archive_name}" \
    "${archive_name}.sha256" \
    provenance.json \
    source-images.lock > SHA256SUMS
)
