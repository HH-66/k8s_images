#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/kubepi"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/kubepi"}
readonly archive_name=jasper-k8s-kubepi-offline.tar.zst

set -a
# shellcheck source=/dev/null
source "${addon_root}/versions.env"
set +a

require_command() {
  command -v "$1" >/dev/null || { echo "required command is missing: $1" >&2; exit 1; }
}

for command in curl git python3 sha256sum skopeo tar zstd; do
  require_command "${command}"
done
python3 -c 'import yaml' >/dev/null || {
  echo 'required Python module is missing: PyYAML' >&2
  exit 1
}
test "$(uname -m)" = x86_64

rm -rf "${build_root}" "${dist_root}"
mkdir -p \
  "${build_root}/outputs/images" \
  "${build_root}/outputs/licenses" \
  "${build_root}/outputs/manifests" \
  "${dist_root}"

source_root="${build_root}/source"
git clone --filter=blob:none --no-checkout \
  https://github.com/1Panel-dev/KubePi.git "${source_root}"
git -C "${source_root}" checkout --detach "${KUBEPI_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD)" = "${KUBEPI_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse 'HEAD^{tree}')" = "${KUBEPI_SOURCE_TREE}"
test "$(git -C "${source_root}" rev-parse "v${KUBEPI_VERSION}^{}")" = \
  "${KUBEPI_SOURCE_COMMIT}"
printf '%s  %s\n' "${KUBEPI_LICENSE_SHA256}" "${source_root}/LICENSE" \
  | sha256sum --check --strict
cp "${source_root}/LICENSE" \
  "${build_root}/outputs/licenses/kubepi-GPLv3-FIT2CLOUD.txt"

nginx_license="${build_root}/outputs/licenses/nginx-BSD-2-Clause.txt"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${nginx_license}" \
  "https://raw.githubusercontent.com/nginxinc/docker-nginx/${NGINX_DOCKER_SOURCE_COMMIT}/LICENSE"
printf '%s  %s\n' "${NGINX_LICENSE_SHA256}" "${nginx_license}" \
  | sha256sum --check --strict

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

copy_image "${KUBEPI_IMAGE}" "${KUBEPI_IMAGE_TAG}" \
  "${KUBEPI_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/kubepi-linux-amd64.tar"
copy_image "${NGINX_IMAGE}" "${NGINX_IMAGE_TAG}" \
  "${NGINX_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/nginx-linux-amd64.tar"

sed \
  -e "s|__KUBEPI_IMAGE_AMD64_DIGEST__|${KUBEPI_IMAGE_AMD64_DIGEST}|g" \
  -e "s|__NGINX_IMAGE_AMD64_DIGEST__|${NGINX_IMAGE_AMD64_DIGEST}|g" \
  "${addon_root}/manifests/kubepi-core.yaml" \
  > "${build_root}/outputs/manifests/kubepi-core.yaml"
cp "${addon_root}/manifests/kubepi-nodeport.yaml" \
  "${build_root}/outputs/manifests/kubepi-nodeport.yaml"
cp "${addon_root}/payload/verify-kubepi-bundle.sh" \
  "${build_root}/outputs/verify-kubepi-bundle.sh"
chmod 0755 "${build_root}/outputs/verify-kubepi-bundle.sh"

python3 - "${build_root}/outputs/provenance.json" <<'PY'
import json
import os
import sys
from pathlib import Path

document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-kubepi-offline",
    "profile": os.environ["ADDON_PROFILE"],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "kubepi": {
            "version": os.environ["KUBEPI_VERSION"],
            "source_commit": os.environ["KUBEPI_SOURCE_COMMIT"],
            "source_tree": os.environ["KUBEPI_SOURCE_TREE"],
            "upstream_tag_signed": False,
            "image_manifest_digest": os.environ["KUBEPI_IMAGE_AMD64_DIGEST"],
        },
        "nginx-tls-proxy": {
            "version": os.environ["NGINX_VERSION"],
            "source_commit": os.environ["NGINX_DOCKER_SOURCE_COMMIT"],
            "image_manifest_digest": os.environ["NGINX_IMAGE_AMD64_DIGEST"],
        },
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
"${build_root}/outputs/verify-kubepi-bundle.sh" "${build_root}/outputs"

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
  sha256sum "${archive_name}" "${archive_name}.sha256" \
    provenance.json source-images.lock > SHA256SUMS
)
