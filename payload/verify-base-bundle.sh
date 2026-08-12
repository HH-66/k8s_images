#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

test -d "${root}"
test -s "${root}/SHA256SUMS"
test -s "${root}/files/files.list"
test -s "${root}/images/images.list"
test -s "${root}/images/additional-images.list"
test -s "${root}/debs/local/Packages.gz"
test -s "${root}/pypi/simple/index.html"
test -s "${root}/files/kubespray-2.31.0.tar.gz"
test -f "${root}/playbook/offline-repo.yml"

while IFS= read -r path; do
  [[ -z "${path}" || "${path}" == \#* ]] && continue
  test -s "${root}/${path}"
done < "${script_dir}/required-files.txt"

while IFS= read -r image; do
  [[ -z "${image}" || "${image}" == \#* ]] && continue
  grep -Fx "${image}" "${root}/images/images.list" >/dev/null \
    || grep -Fx "${image}" "${root}/images/additional-images.list" >/dev/null
done < "${script_dir}/required-images.txt"

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
