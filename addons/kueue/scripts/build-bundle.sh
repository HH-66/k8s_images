#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/kueue"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/kueue"}
readonly archive_name=jasper-k8s-kueue-offline.tar.zst

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
  "${build_root}/outputs/licenses" \
  "${build_root}/outputs/tools" \
  "${build_root}/outputs/values" \
  "${dist_root}"

chart="${build_root}/outputs/charts/kueue-${KUEUE_VERSION}.tgz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${chart}" \
  "https://github.com/kubernetes-sigs/kueue/releases/download/v${KUEUE_VERSION}/kueue-${KUEUE_VERSION}.tgz"
printf '%s  %s\n' "${KUEUE_CHART_SHA256}" "${chart}" \
  | sha256sum --check --strict

license="${build_root}/outputs/licenses/kueue-Apache-2.0.txt"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${license}" \
  "https://raw.githubusercontent.com/kubernetes-sigs/kueue/${KUEUE_SOURCE_COMMIT}/LICENSE"
printf '%s  %s\n' "${KUEUE_LICENSE_SHA256}" "${license}" \
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
"${build_root}/outputs/tools/helm" lint "${chart}"

image_archive="${build_root}/outputs/images/kueue-controller-linux-amd64.tar"
skopeo copy \
  --policy "${addon_root}/containers-policy.json" \
  --override-os linux \
  --override-arch amd64 \
  --preserve-digests \
  "docker://${KUEUE_IMAGE}@${KUEUE_IMAGE_AMD64_DIGEST}" \
  "oci-archive:${image_archive}:${KUEUE_IMAGE_TAG}"
printf '%s:%s@%s\n' \
  "${KUEUE_IMAGE}" "${KUEUE_IMAGE_TAG}" "${KUEUE_IMAGE_AMD64_DIGEST}" \
  > "${build_root}/outputs/images/source-images.lock"

sed "s|__KUEUE_IMAGE_AMD64_DIGEST__|${KUEUE_IMAGE_AMD64_DIGEST}|g" \
  "${addon_root}/values.yaml" \
  > "${build_root}/outputs/values/kueue-values.yaml"
cp "${addon_root}/payload/verify-kueue-bundle.sh" \
  "${build_root}/outputs/verify-kueue-bundle.sh"
chmod 0755 "${build_root}/outputs/verify-kueue-bundle.sh"

python3 - \
  "${build_root}/outputs/provenance.json" \
  "${KUEUE_VERSION}" \
  "${KUEUE_TAG_OBJECT}" \
  "${KUEUE_SOURCE_COMMIT}" \
  "${KUEUE_SOURCE_TREE}" \
  "${KUEUE_CHART_SHA256}" \
  "${KUEUE_IMAGE_AMD64_DIGEST}" \
  "${HELM_VERSION}" \
  "${ADDON_PROFILE}" <<'PY'
import json
import sys
from pathlib import Path

document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-kueue-offline",
    "profile": sys.argv[9],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "kueue": {
            "version": sys.argv[2],
            "tag_object": sys.argv[3],
            "source_commit": sys.argv[4],
            "source_tree": sys.argv[5],
            "upstream_tag_signed": False,
            "chart_sha256": sys.argv[6],
            "image_manifest_digest": sys.argv[7],
        },
        "helm": {"version": sys.argv[8]},
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
"${build_root}/outputs/verify-kueue-bundle.sh" "${build_root}/outputs"

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
  sha256sum \
    "${archive_name}" \
    "${archive_name}.sha256" \
    provenance.json \
    source-images.lock > SHA256SUMS
)
