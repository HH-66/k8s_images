#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

require_directory() {
  test -d "$1" || { echo "required directory is missing: $1" >&2; return 1; }
}

require_file() {
  test -f "$1" || { echo "required file is missing: $1" >&2; return 1; }
}

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

require_directory "${root}"
require_nonempty_file "${root}/SHA256SUMS"
require_nonempty_file "${root}/files/files.list"
require_nonempty_file "${root}/images/images.list"
require_nonempty_file "${root}/images/additional-images.list"
require_nonempty_file "${root}/debs/local/Packages.gz"
require_nonempty_file "${root}/pypi/index.html"
require_nonempty_file "${root}/files/kubespray-2.31.0.tar.gz"
require_file "${root}/playbook/offline-repo.yml"

while IFS= read -r path; do
  [[ -z "${path}" || "${path}" == \#* ]] && continue
  require_nonempty_file "${root}/${path}"
done < "${script_dir}/required-files.txt"

while IFS= read -r image; do
  [[ -z "${image}" || "${image}" == \#* ]] && continue
  if ! grep -Fx "${image}" "${root}/images/images.list" >/dev/null \
    && ! grep -Fx "${image}" "${root}/images/additional-images.list" >/dev/null; then
    echo "required image is missing from bundle lists: ${image}" >&2
    exit 1
  fi
done < "${script_dir}/required-images.txt"

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
