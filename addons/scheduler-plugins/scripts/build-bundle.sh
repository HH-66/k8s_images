#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/scheduler-plugins"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/scheduler-plugins"}
readonly archive_name=jasper-k8s-scheduler-plugins-offline.tar.zst

set -a
# shellcheck source=/dev/null
source "${addon_root}/versions.env"
set +a

require_command() {
  command -v "$1" >/dev/null || { echo "required command is missing: $1" >&2; exit 1; }
}

for command in curl docker git python3 sha256sum skopeo tar zstd; do
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
  https://github.com/kubernetes-sigs/scheduler-plugins.git "${source_root}"
git -C "${source_root}" checkout --detach "${SCHEDULER_PLUGINS_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD)" = \
  "${SCHEDULER_PLUGINS_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD^{tree})" = \
  "${SCHEDULER_PLUGINS_SOURCE_TREE}"
test "$(git -C "${source_root}" rev-parse v${SCHEDULER_PLUGINS_VERSION}^{})" = \
  "${SCHEDULER_PLUGINS_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse v${SCHEDULER_PLUGINS_VERSION})" = \
  "${SCHEDULER_PLUGINS_TAG_OBJECT}"
test "$(git -C "${source_root}" rev-parse HEAD:manifests/install/charts/as-a-second-scheduler)" = \
  "${SCHEDULER_PLUGINS_CHART_TREE}"
printf '%s  %s\n' "${SCHEDULER_PLUGINS_LICENSE_SHA256}" \
  "${source_root}/LICENSE" | sha256sum --check --strict
grep -qx 'go 1.25.0' "${source_root}/go.mod"
grep -Eq '^[[:space:]]*k8s\.io/kubernetes v1\.35\.4$' "${source_root}/go.mod"

chart_source="${build_root}/chart-source/scheduler-plugins"
mkdir -p "${chart_source}"
git -C "${source_root}" archive \
  "${SCHEDULER_PLUGINS_SOURCE_COMMIT}:manifests/install/charts/as-a-second-scheduler" \
  | tar -xf - -C "${chart_source}"
rm "${chart_source}/crds"
python3 - "${chart_source}/Chart.yaml" "${SCHEDULER_PLUGINS_VERSION}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
updated = []
for line in lines:
    if line.startswith("version:"):
        line = f"version: {version}"
    elif line.startswith("appVersion:"):
        line = f"appVersion: {version}"
    updated.append(line)
path.write_text("\n".join(updated) + "\n", encoding="utf-8")
PY

helm_archive="${build_root}/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${helm_archive}" \
  "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
printf '%s  %s\n' "${HELM_LINUX_AMD64_SHA256}" "${helm_archive}" \
  | sha256sum --check --strict
tar -xOzf "${helm_archive}" linux-amd64/helm \
  > "${build_root}/outputs/tools/helm"
chmod 0755 "${build_root}/outputs/tools/helm"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -cf - -C "${build_root}/chart-source" scheduler-plugins \
  | gzip -n -9 \
  > "${build_root}/outputs/charts/scheduler-plugins-${SCHEDULER_PLUGINS_VERSION}.tgz"
"${build_root}/outputs/tools/helm" lint \
  "${build_root}/outputs/charts/scheduler-plugins-${SCHEDULER_PLUGINS_VERSION}.tgz"

scheduler_dockerfile="${build_root}/scheduler.Dockerfile"
python3 - \
  "${source_root}/build/scheduler/Dockerfile" \
  "${scheduler_dockerfile}" \
  "${KUBERNETES_BINARY_VERSION}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
old = "RUN make build-scheduler GO_BUILD_ENV='CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH}'"
new = (
    "RUN make build-scheduler "
    f"VERSION={sys.argv[3]} "
    "GO_BUILD_ENV='CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH}'"
)
if source.count(old) != 1:
    raise SystemExit("unexpected upstream scheduler Dockerfile build command")
Path(sys.argv[2]).write_text(source.replace(old, new), encoding="utf-8")
PY
scheduler_ref="jasper-build/scheduler-plugins/kube-scheduler:v${SCHEDULER_PLUGINS_VERSION}"
docker build \
  --platform linux/amd64 \
  --build-arg "GO_BASE_IMAGE=${GO_BASE_IMAGE}" \
  --build-arg "DISTROLESS_BASE_IMAGE=${DISTROLESS_BASE_IMAGE}" \
  --tag "${scheduler_ref}" \
  --file "${scheduler_dockerfile}" \
  "${source_root}"
test "$(docker run --rm --platform linux/amd64 \
  --entrypoint /bin/kube-scheduler \
  "${scheduler_ref}" --version 2>&1)" = "Kubernetes ${KUBERNETES_BINARY_VERSION}"
scheduler_archive="${build_root}/outputs/images/kube-scheduler-linux-amd64.tar"
skopeo copy \
  "docker-daemon:${scheduler_ref}" \
  "oci-archive:${scheduler_archive}:v${SCHEDULER_PLUGINS_VERSION}"
scheduler_digest=$(python3 - \
  "${scheduler_archive}" \
  "v${SCHEDULER_PLUGINS_VERSION}" <<'PY'
import json
import re
import sys
import tarfile

with tarfile.open(sys.argv[1], "r") as archive:
    index = json.load(archive.extractfile("index.json"))
manifests = index.get("manifests", [])
if len(manifests) != 1:
    raise SystemExit("scheduler OCI archive must contain exactly one manifest")
descriptor = manifests[0]
digest = descriptor.get("digest", "")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit("scheduler OCI archive has an invalid manifest digest")
if descriptor.get("annotations", {}).get("org.opencontainers.image.ref.name") != sys.argv[2]:
    raise SystemExit("scheduler OCI archive has an unexpected tag annotation")
print(digest)
PY
)
printf '%s@%s\n' "${scheduler_ref}" "${scheduler_digest}" \
  > "${build_root}/outputs/images/source-images.lock"

python3 - \
  "${addon_root}/values.yaml" \
  "${build_root}/outputs/values/scheduler-plugins-values.yaml" \
  "${scheduler_digest}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
placeholder = "__SCHEDULER_IMAGE_AMD64_DIGEST__"
if source.count(placeholder) != 2:
    raise SystemExit("scheduler values must contain exactly two digest placeholders")
Path(sys.argv[2]).write_text(
    source.replace(placeholder, sys.argv[3]), encoding="utf-8"
)
PY
cp "${source_root}/LICENSE" \
  "${build_root}/outputs/licenses/scheduler-plugins-Apache-2.0.txt"
cp "${addon_root}/payload/verify-scheduler-plugins-bundle.sh" \
  "${build_root}/outputs/verify-scheduler-plugins-bundle.sh"
chmod 0755 "${build_root}/outputs/verify-scheduler-plugins-bundle.sh"

python3 - \
  "${build_root}/outputs/provenance.json" \
  "${SCHEDULER_PLUGINS_VERSION}" \
  "${SCHEDULER_PLUGINS_TAG_OBJECT}" \
  "${SCHEDULER_PLUGINS_SOURCE_COMMIT}" \
  "${SCHEDULER_PLUGINS_SOURCE_TREE}" \
  "${SCHEDULER_PLUGINS_CHART_TREE}" \
  "${KUBERNETES_BINARY_VERSION}" \
  "${scheduler_digest}" \
  "${HELM_VERSION}" \
  "${ADDON_PROFILE}" <<'PY'
import json
import sys
from pathlib import Path

document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-scheduler-plugins-offline",
    "profile": sys.argv[10],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "scheduler-plugins": {
            "version": sys.argv[2],
            "tag_object": sys.argv[3],
            "source_commit": sys.argv[4],
            "source_tree": sys.argv[5],
            "chart_tree": sys.argv[6],
            "upstream_tag_signed": False,
            "image_origin": "built-from-source",
            "binary_version": sys.argv[7],
            "image_manifest_digest": sys.argv[8],
        },
        "helm": {"version": sys.argv[9]},
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
"${build_root}/outputs/verify-scheduler-plugins-bundle.sh" \
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
