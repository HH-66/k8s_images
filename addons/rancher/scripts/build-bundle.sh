#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/rancher"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/rancher"}
readonly archive_name=jasper-k8s-rancher-offline.tar.zst

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
python3 -c 'import yaml' >/dev/null || {
  echo 'required Python module is missing: PyYAML' >&2
  exit 1
}
test "$(uname -m)" = x86_64

rm -rf "${build_root}" "${dist_root}"
mkdir -p \
  "${build_root}/outputs/charts" \
  "${build_root}/outputs/images" \
  "${build_root}/outputs/licenses" \
  "${build_root}/outputs/scripts" \
  "${build_root}/outputs/tools" \
  "${build_root}/outputs/values" \
  "${dist_root}"

source_root="${build_root}/source"
git clone --filter=blob:none --no-checkout \
  https://github.com/rancher/rancher.git "${source_root}"
git -C "${source_root}" checkout --detach "${RANCHER_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD)" = "${RANCHER_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD^{tree})" = "${RANCHER_SOURCE_TREE}"
test "$(git -C "${source_root}" rev-parse v${RANCHER_VERSION}^{})" = \
  "${RANCHER_SOURCE_COMMIT}"
printf '%s  %s\n' "${RANCHER_LICENSE_SHA256}" "${source_root}/LICENSE" \
  | sha256sum --check --strict
cp "${source_root}/LICENSE" \
  "${build_root}/outputs/licenses/rancher-Apache-2.0.txt"

chart="${build_root}/outputs/charts/rancher-${RANCHER_VERSION}.tgz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${chart}" \
  "https://releases.rancher.com/server-charts/latest/rancher-${RANCHER_VERSION}.tgz"
printf '%s  %s\n' "${RANCHER_CHART_SHA256}" "${chart}" \
  | sha256sum --check --strict

helm_archive="${build_root}/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${helm_archive}" \
  "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
printf '%s  %s\n' "${HELM_LINUX_AMD64_SHA256}" "${helm_archive}" \
  | sha256sum --check --strict
tar -xOzf "${helm_archive}" linux-amd64/helm > "${build_root}/outputs/tools/helm"
chmod 0755 "${build_root}/outputs/tools/helm"
"${build_root}/outputs/tools/helm" lint "${chart}"

copy_image() {
  source_ref=$1
  source_tag=$2
  source_digest=$3
  archive_path=$4
  skopeo copy --policy "${addon_root}/containers-policy.json" \
    --override-os linux --override-arch amd64 --preserve-digests \
    "docker://${source_ref}@${source_digest}" \
    "oci-archive:${archive_path}:${source_tag}"
  printf '%s:%s@%s\n' "${source_ref}" "${source_tag}" "${source_digest}" \
    >> "${build_root}/outputs/images/source-images.lock"
}

copy_image "${RANCHER_IMAGE}" "${RANCHER_IMAGE_TAG}" \
  "${RANCHER_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/rancher-linux-amd64.tar"
copy_image "${FLEET_IMAGE}" "${FLEET_IMAGE_TAG}" \
  "${FLEET_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/fleet-linux-amd64.tar"
copy_image "${FLEET_AGENT_IMAGE}" "${FLEET_AGENT_IMAGE_TAG}" \
  "${FLEET_AGENT_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/fleet-agent-linux-amd64.tar"
copy_image "${RANCHER_WEBHOOK_IMAGE}" "${RANCHER_WEBHOOK_IMAGE_TAG}" \
  "${RANCHER_WEBHOOK_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/rancher-webhook-linux-amd64.tar"
copy_image "${REMOTEDIALER_PROXY_IMAGE}" "${REMOTEDIALER_PROXY_IMAGE_TAG}" \
  "${REMOTEDIALER_PROXY_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/remotedialer-proxy-linux-amd64.tar"
copy_image "${RANCHER_SHELL_IMAGE}" "${RANCHER_SHELL_IMAGE_TAG}" \
  "${RANCHER_SHELL_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/rancher-shell-linux-amd64.tar"
copy_image "${RANCHER_AGENT_IMAGE}" "${RANCHER_AGENT_IMAGE_TAG}" \
  "${RANCHER_AGENT_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/rancher-agent-linux-amd64.tar"

cp "${addon_root}/values.yaml" \
  "${build_root}/outputs/values/rancher-values.yaml"
cp "${addon_root}/payload/post-render-rancher.py" \
  "${build_root}/outputs/scripts/post-render-rancher.py"
cp "${addon_root}/payload/verify-rancher-bundle.sh" \
  "${build_root}/outputs/verify-rancher-bundle.sh"
chmod 0755 \
  "${build_root}/outputs/scripts/post-render-rancher.py" \
  "${build_root}/outputs/verify-rancher-bundle.sh"

python3 - "${build_root}/outputs/provenance.json" <<'PY'
import json
import os
import sys
from pathlib import Path

images = {}
for name in (
    "RANCHER", "FLEET", "FLEET_AGENT", "RANCHER_WEBHOOK",
    "REMOTEDIALER_PROXY", "RANCHER_SHELL", "RANCHER_AGENT",
):
    images[name.lower().replace("_", "-")] = {
        "source": os.environ[f"{name}_IMAGE"],
        "tag": os.environ[f"{name}_IMAGE_TAG"],
        "image_manifest_digest": os.environ[f"{name}_IMAGE_AMD64_DIGEST"],
    }
document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-rancher-offline",
    "profile": os.environ["ADDON_PROFILE"],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "rancher": {
            "version": os.environ["RANCHER_VERSION"],
            "source_commit": os.environ["RANCHER_SOURCE_COMMIT"],
            "source_tree": os.environ["RANCHER_SOURCE_TREE"],
            "chart_sha256": os.environ["RANCHER_CHART_SHA256"],
            "upstream_tag_signed": False,
        },
        "images": images,
        "helm": {"version": os.environ["HELM_VERSION"]},
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
"${build_root}/outputs/verify-rancher-bundle.sh" "${build_root}/outputs"

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
