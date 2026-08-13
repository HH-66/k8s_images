#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/nfd"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/nfd"}
readonly archive_name=jasper-k8s-nfd-offline.tar.zst

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

chart="${build_root}/outputs/charts/node-feature-discovery-${NFD_VERSION}.tgz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${chart}" \
  "https://github.com/kubernetes-sigs/node-feature-discovery/releases/download/v${NFD_VERSION}/node-feature-discovery-chart-${NFD_VERSION}.tgz"
printf '%s  %s\n' "${NFD_CHART_SHA256}" "${chart}" \
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

image_ref="${NFD_IMAGE}@${NFD_IMAGE_AMD64_DIGEST}"
image_archive="${build_root}/outputs/images/nfd-linux-amd64.tar"
skopeo copy \
  --policy "${addon_root}/containers-policy.json" \
  --override-os linux \
  --override-arch amd64 \
  --preserve-digests \
  "docker://${image_ref}" \
  "oci-archive:${image_archive}:${NFD_IMAGE_TAG}"
python3 - \
  "${image_archive}" \
  "${NFD_IMAGE_AMD64_DIGEST}" \
  "${NFD_IMAGE_TAG}" <<'PY'
import json
import sys
import tarfile

with tarfile.open(sys.argv[1], "r") as archive:
    index = json.load(archive.extractfile("index.json"))
manifests = index.get("manifests", [])
if len(manifests) != 1:
    raise SystemExit("NFD OCI archive must contain exactly one manifest")
descriptor = manifests[0]
if descriptor.get("digest") != sys.argv[2]:
    raise SystemExit("NFD OCI archive did not preserve the source manifest digest")
if descriptor.get("annotations", {}).get("org.opencontainers.image.ref.name") != sys.argv[3]:
    raise SystemExit("NFD OCI archive has an unexpected tag annotation")
PY
printf '%s:%s@%s\n' "${NFD_IMAGE}" "${NFD_IMAGE_TAG}" "${NFD_IMAGE_AMD64_DIGEST}" \
  > "${build_root}/outputs/images/source-images.lock"

cp "${addon_root}/values.yaml" "${build_root}/outputs/values/nfd-values.yaml"
cp "${addon_root}/payload/verify-nfd-bundle.sh" \
  "${build_root}/outputs/verify-nfd-bundle.sh"
chmod 0755 "${build_root}/outputs/verify-nfd-bundle.sh"

python3 - \
  "${build_root}/outputs/provenance.json" \
  "${NFD_VERSION}" \
  "${NFD_SOURCE_COMMIT}" \
  "${HELM_VERSION}" \
  "${ADDON_PROFILE}" <<'PY'
import json
import sys
from pathlib import Path

document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-nfd-offline",
    "profile": sys.argv[5],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "node-feature-discovery": {
            "version": sys.argv[2],
            "source_commit": sys.argv[3],
        },
        "helm": {"version": sys.argv[4]},
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
"${build_root}/outputs/verify-nfd-bundle.sh" "${build_root}/outputs"

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
