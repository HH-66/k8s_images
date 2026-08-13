#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/kuberay"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/kuberay"}
readonly archive_name=jasper-k8s-kuberay-offline.tar.zst

set -a
# shellcheck source=/dev/null
source "${addon_root}/versions.env"
set +a

require_command() {
  command -v "$1" >/dev/null || { echo "required command is missing: $1" >&2; exit 1; }
}

for command in curl git gzip python3 sha256sum skopeo tar zstd; do
  require_command "${command}"
done
test "$(uname -m)" = x86_64

rm -rf "${build_root}" "${dist_root}"
mkdir -p \
  "${build_root}/outputs/charts" \
  "${build_root}/outputs/images" \
  "${build_root}/outputs/licenses" \
  "${build_root}/outputs/tools" \
  "${build_root}/outputs/values" \
  "${dist_root}"

source_root="${build_root}/source"
git clone --filter=blob:none --no-checkout \
  https://github.com/ray-project/kuberay.git "${source_root}"
git -C "${source_root}" checkout --detach "${KUBERAY_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD)" = "${KUBERAY_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD^{tree})" = "${KUBERAY_SOURCE_TREE}"
test "$(git -C "${source_root}" rev-parse v${KUBERAY_VERSION}^{})" = \
  "${KUBERAY_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD:helm-chart/kuberay-operator)" = \
  "${KUBERAY_CHART_TREE}"
printf '%s  %s\n' "${KUBERAY_LICENSE_SHA256}" "${source_root}/LICENSE" \
  | sha256sum --check --strict
cp "${source_root}/LICENSE" \
  "${build_root}/outputs/licenses/kuberay-Apache-2.0.txt"

ray_license="${build_root}/outputs/licenses/ray-Apache-2.0.txt"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${ray_license}" \
  "https://raw.githubusercontent.com/ray-project/ray/${RAY_SOURCE_COMMIT}/LICENSE"
printf '%s  %s\n' "${RAY_LICENSE_SHA256}" "${ray_license}" \
  | sha256sum --check --strict

helm_archive="${build_root}/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${helm_archive}" \
  "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
printf '%s  %s\n' "${HELM_LINUX_AMD64_SHA256}" "${helm_archive}" \
  | sha256sum --check --strict
tar -xOzf "${helm_archive}" linux-amd64/helm > "${build_root}/outputs/tools/helm"
chmod 0755 "${build_root}/outputs/tools/helm"

chart="${build_root}/outputs/charts/kuberay-operator-${KUBERAY_VERSION}.tgz"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -cf - -C "${source_root}/helm-chart" kuberay-operator \
  | gzip -n -9 > "${chart}"
printf '%s  %s\n' "${KUBERAY_CHART_SHA256}" "${chart}" \
  | sha256sum --check --strict
"${build_root}/outputs/tools/helm" lint "${chart}"

operator_archive="${build_root}/outputs/images/kuberay-operator-linux-amd64.tar"
skopeo copy --policy "${addon_root}/containers-policy.json" \
  --override-os linux --override-arch amd64 --preserve-digests \
  "docker://${KUBERAY_OPERATOR_IMAGE}@${KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST}" \
  "oci-archive:${operator_archive}:${KUBERAY_OPERATOR_IMAGE_TAG}"
ray_archive="${build_root}/outputs/images/ray-linux-amd64.tar"
skopeo copy --policy "${addon_root}/containers-policy.json" \
  --override-os linux --override-arch amd64 --preserve-digests \
  "docker://${RAY_IMAGE}@${RAY_IMAGE_AMD64_DIGEST}" \
  "oci-archive:${ray_archive}:${RAY_IMAGE_TAG}"
printf '%s:%s@%s\n%s:%s@%s\n' \
  "${KUBERAY_OPERATOR_IMAGE}" "${KUBERAY_OPERATOR_IMAGE_TAG}" \
  "${KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST}" \
  "${RAY_IMAGE}" "${RAY_IMAGE_TAG}" "${RAY_IMAGE_AMD64_DIGEST}" \
  > "${build_root}/outputs/images/source-images.lock"

sed "s|__KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST__|${KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST}|g" \
  "${addon_root}/values.yaml" \
  > "${build_root}/outputs/values/kuberay-operator-values.yaml"
cp "${addon_root}/payload/verify-kuberay-bundle.sh" \
  "${build_root}/outputs/verify-kuberay-bundle.sh"
chmod 0755 "${build_root}/outputs/verify-kuberay-bundle.sh"

python3 - "${build_root}/outputs/provenance.json" \
  "${KUBERAY_VERSION}" "${KUBERAY_SOURCE_COMMIT}" "${KUBERAY_SOURCE_TREE}" \
  "${KUBERAY_CHART_TREE}" "${KUBERAY_CHART_SHA256}" \
  "${KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST}" \
  "${RAY_VERSION}" "${RAY_SOURCE_COMMIT}" "${RAY_SOURCE_TREE}" \
  "${RAY_IMAGE_AMD64_DIGEST}" "${HELM_VERSION}" "${ADDON_PROFILE}" <<'PY'
import json
import sys
from pathlib import Path

document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-kuberay-offline",
    "profile": sys.argv[13],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "kuberay-operator": {
            "version": sys.argv[2],
            "source_commit": sys.argv[3],
            "source_tree": sys.argv[4],
            "chart_tree": sys.argv[5],
            "chart_sha256": sys.argv[6],
            "upstream_tag_signed": False,
            "image_manifest_digest": sys.argv[7],
        },
        "ray-runtime": {
            "version": sys.argv[8],
            "source_commit": sys.argv[9],
            "source_tree": sys.argv[10],
            "source_commit_verified": True,
            "image_manifest_digest": sys.argv[11],
        },
        "helm": {"version": sys.argv[12]},
    },
}
Path(sys.argv[1]).write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

(
  cd "${build_root}/outputs"
  find . -type f ! -name SHA256SUMS -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
)
"${build_root}/outputs/verify-kuberay-bundle.sh" "${build_root}/outputs"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -cf - -C "${build_root}" outputs \
  | zstd -T0 -19 -o "${dist_root}/${archive_name}"
(
  cd "${dist_root}"
  sha256sum "${archive_name}" > "${archive_name}.sha256"
)
cp "${build_root}/outputs/provenance.json" "${dist_root}/provenance.json"
cp "${build_root}/outputs/images/source-images.lock" "${dist_root}/source-images.lock"
(
  cd "${dist_root}"
  sha256sum "${archive_name}" "${archive_name}.sha256" \
    provenance.json source-images.lock > SHA256SUMS
)
