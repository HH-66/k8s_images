#!/usr/bin/env bash
set -euo pipefail

readonly repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist"}
readonly offline_source=${build_root}/kubespray-offline
readonly archive_name=kubespray-offline-base.tar.zst

set -a
# shellcheck source=/dev/null
source "${repo_root}/versions.env"
set +a
readonly kubespray_source=${offline_source}/cache/kubespray-${KUBESPRAY_VERSION}
readonly kubespray_git_dir=${build_root}/kubespray-git
readonly kubespray_source_marker=.jasper-kubespray-source.json

require_command() {
  command -v "$1" >/dev/null || { echo "required command is missing: $1" >&2; exit 1; }
}

for command in git python3 docker curl tar zstd sha256sum; do
  require_command "${command}"
done
test "$(uname -m)" = x86_64
grep -qx 'VERSION_ID="24.04"' /etc/os-release

rm -rf "${build_root}" "${dist_root}"
mkdir -p "${build_root}" "${dist_root}"

git clone --filter=blob:none --no-checkout \
  https://github.com/kubespray-offline/kubespray-offline.git "${offline_source}"
git -C "${offline_source}" checkout --detach "${KUBESPRAY_OFFLINE_COMMIT}"
test "$(git -C "${offline_source}" rev-parse HEAD)" = "${KUBESPRAY_OFFLINE_COMMIT}"
test "$(git -C "${offline_source}" describe --tags --exact-match)" = \
  "v${KUBESPRAY_OFFLINE_VERSION}"

git clone --filter=blob:none --no-checkout \
  https://github.com/kubernetes-sigs/kubespray.git "${kubespray_git_dir}"
git -C "${kubespray_git_dir}" checkout --detach "${KUBESPRAY_COMMIT}"
mkdir -p "${kubespray_source}"
git -C "${kubespray_git_dir}" archive "${KUBESPRAY_COMMIT}" \
  | tar -xf - -C "${kubespray_source}"
test "$(git -C "${kubespray_git_dir}" rev-parse HEAD)" = "${KUBESPRAY_COMMIT}"
test "$(git -C "${kubespray_git_dir}" describe --tags --exact-match)" = \
  "v${KUBESPRAY_VERSION}"

# generate_list.sh invokes ansible-playbook.  Bootstrap the upstream build venv
# before list generation, then reuse that same venv for the remaining download
# steps.
(
  cd "${offline_source}"
  ./prepare-pkgs.sh
  VENV_DIR="${offline_source}/.venv" ./prepare-py.sh
)
# shellcheck source=/dev/null
source "${offline_source}/.venv/bin/activate"
command -v ansible-playbook >/dev/null

cp "${repo_root}/config/base-cluster.yml" "${kubespray_source}/base-cluster.yml"
(
  cd "${kubespray_source}"
  DOWNLOAD_YML=roles/kubespray_defaults/defaults/main/download.yml \
    ./contrib/offline/generate_list.sh -e @base-cluster.yml
)

mkdir -p "${offline_source}/outputs/files" "${offline_source}/outputs/images"
python3 "${repo_root}/scripts/filter-generated-lists.py" \
  --generated-images "${kubespray_source}/contrib/offline/temp/images.list" \
  --required-images "${repo_root}/config/required-kubespray-images.txt" \
  --generated-files "${kubespray_source}/contrib/offline/temp/files.list" \
  --file-patterns "${repo_root}/config/allow-kubespray-file-patterns.txt" \
  --output-images "${offline_source}/outputs/images/images.list" \
  --output-files "${offline_source}/outputs/files/files.list"
python3 "${repo_root}/scripts/verify-resolved-versions.py" \
  --versions "${repo_root}/config/required-versions.env" \
  --images "${offline_source}/outputs/images/images.list" \
  --files "${offline_source}/outputs/files/files.list"

cp "${repo_root}/config/required-bootstrap-images.txt" \
  "${offline_source}/outputs/images/additional-images.list"
cp "${repo_root}/config/required-bootstrap-images.txt" \
  "${offline_source}/imagelists/jasper-base.txt"
find "${offline_source}/imagelists" -maxdepth 1 -type f \
  ! -name jasper-base.txt -delete

rm -f "${kubespray_source}/base-cluster.yml"
python3 - \
  "${kubespray_source}/${kubespray_source_marker}" \
  "${KUBESPRAY_VERSION}" \
  "${KUBESPRAY_COMMIT}" <<'PY'
import json
import sys
from pathlib import Path

marker = {
    "schema_version": 1,
    "source": "kubernetes-sigs/kubespray",
    "version": sys.argv[2],
    "tag": f"v{sys.argv[2]}",
    "commit": sys.argv[3],
}
Path(sys.argv[1]).write_text(
    json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -czf "${offline_source}/outputs/files/kubespray-${KUBESPRAY_VERSION}.tar.gz" \
  -C "${offline_source}/cache" "kubespray-${KUBESPRAY_VERSION}"

python3 "${repo_root}/scripts/source-image-lock.py" \
  --image-list "${repo_root}/config/required-kubespray-images.txt" \
  --image-list "${repo_root}/config/required-bootstrap-images.txt" \
  --output "${build_root}/source-images.before.lock"
export SOURCE_DATE_EPOCH=0

(
  cd "${offline_source}"
  export KUBESPRAY_VERSION SKIP_DOWNLOAD_IMAGES=false
  export VENV_DIR="${offline_source}/.venv"
  ./pypi-mirror.sh
  docker=/usr/bin/docker ./download-images.sh
  "${repo_root}/scripts/download-filtered-files.sh" \
    outputs/files/files.list outputs/files
  docker=/usr/bin/docker ./download-additional-containers.sh
  ./create-repo.sh
  ./copy-target-scripts.sh
)

mkdir -p "${offline_source}/outputs/licenses"
cp "${repo_root}/LICENSE" "${offline_source}/outputs/licenses/jasper-builder-Apache-2.0.txt"
cp "${offline_source}/LICENSE" \
  "${offline_source}/outputs/licenses/kubespray-offline-Apache-2.0.txt"
cp "${kubespray_source}/LICENSE" \
  "${offline_source}/outputs/licenses/kubespray-Apache-2.0.txt"
cp -R "${repo_root}/payload/." "${offline_source}/outputs/"
chmod 0755 \
  "${offline_source}/outputs/install-h139-offline.sh" \
  "${offline_source}/outputs/verify-base-bundle.sh" \
  "${offline_source}/outputs/verify-h139-offline.sh"

(
  cd "${offline_source}/outputs"
  find . -type f ! -name SHA256SUMS -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > SHA256SUMS
)
"${offline_source}/outputs/verify-base-bundle.sh" "${offline_source}/outputs"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -cf - -C "${offline_source}" outputs \
  | zstd -T0 -19 -o "${dist_root}/${archive_name}"
(
  cd "${dist_root}"
  sha256sum "${archive_name}" > "${archive_name}.sha256"
)

python3 "${repo_root}/scripts/source-image-lock.py" \
  --image-list "${repo_root}/config/required-kubespray-images.txt" \
  --image-list "${repo_root}/config/required-bootstrap-images.txt" \
  --output "${dist_root}/source-images.lock"
cmp "${build_root}/source-images.before.lock" "${dist_root}/source-images.lock"

python3 - "${repo_root}/versions.env" "${dist_root}/provenance.json" <<'PY'
import json
import sys
from pathlib import Path

values = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line and not line.startswith("#"):
        key, value = line.split("=", 1)
        values[key] = value
document = {
    "schema_version": 1,
    "artifact": "jasper-kubespray-offline-base",
    "target": {"os": values["TARGET_OS"], "architecture": values["TARGET_ARCH"]},
    "profile": values["BUNDLE_PROFILE"],
    "kubespray_offline": {
        "version": values["KUBESPRAY_OFFLINE_VERSION"],
        "commit": values["KUBESPRAY_OFFLINE_COMMIT"],
    },
    "kubespray": {
        "version": values["KUBESPRAY_VERSION"],
        "commit": values["KUBESPRAY_COMMIT"],
    },
    "components": {
        "kubernetes": values["KUBERNETES_VERSION"],
        "containerd": values["CONTAINERD_VERSION"],
        "etcd": values["ETCD_VERSION"],
        "cilium": values["CILIUM_VERSION"],
    },
}
Path(sys.argv[2]).write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

(
  cd "${dist_root}"
  sha256sum \
    "${archive_name}" \
    "${archive_name}.sha256" \
    provenance.json \
    source-images.lock > SHA256SUMS
)
