#!/usr/bin/env bash
set -euo pipefail

readonly addon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root=$(cd "${addon_root}/../.." && pwd)
readonly build_root=${BUILD_ROOT:-"${repo_root}/build/prometheus"}
readonly dist_root=${DIST_ROOT:-"${repo_root}/dist/prometheus"}
readonly archive_name=jasper-k8s-prometheus-offline.tar.zst

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
  "${build_root}/outputs/manifests" \
  "${build_root}/outputs/tools" \
  "${build_root}/outputs/values" \
  "${dist_root}"

source_root="${build_root}/source"
git clone --filter=blob:none --no-checkout \
  https://github.com/prometheus-community/helm-charts.git "${source_root}"
git -C "${source_root}" checkout --detach "${KUBE_PROMETHEUS_STACK_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD)" = \
  "${KUBE_PROMETHEUS_STACK_SOURCE_COMMIT}"
test "$(git -C "${source_root}" rev-parse HEAD^{tree})" = \
  "${KUBE_PROMETHEUS_STACK_SOURCE_TREE}"
test "$(git -C "${source_root}" rev-parse kube-prometheus-stack-${KUBE_PROMETHEUS_STACK_VERSION}^{})" = \
  "${KUBE_PROMETHEUS_STACK_SOURCE_COMMIT}"
cp "${source_root}/LICENSE" \
  "${build_root}/outputs/licenses/prometheus-community-helm-charts-Apache-2.0.txt"

chart="${build_root}/outputs/charts/kube-prometheus-stack-${KUBE_PROMETHEUS_STACK_VERSION}.tgz"
curl --location --fail --show-error --retry 3 --retry-all-errors \
  --output "${chart}" \
  "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-${KUBE_PROMETHEUS_STACK_VERSION}/kube-prometheus-stack-${KUBE_PROMETHEUS_STACK_VERSION}.tgz"
printf '%s  %s\n' "${KUBE_PROMETHEUS_STACK_CHART_SHA256}" "${chart}" \
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

copy_image "${PROMETHEUS_IMAGE}" "${PROMETHEUS_IMAGE_TAG}" \
  "${PROMETHEUS_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/prometheus-linux-amd64.tar"
copy_image "${ALERTMANAGER_IMAGE}" "${ALERTMANAGER_IMAGE_TAG}" \
  "${ALERTMANAGER_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/alertmanager-linux-amd64.tar"
copy_image "${PROMETHEUS_OPERATOR_IMAGE}" "${PROMETHEUS_OPERATOR_IMAGE_TAG}" \
  "${PROMETHEUS_OPERATOR_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/prometheus-operator-linux-amd64.tar"
copy_image "${PROMETHEUS_CONFIG_RELOADER_IMAGE}" \
  "${PROMETHEUS_CONFIG_RELOADER_IMAGE_TAG}" \
  "${PROMETHEUS_CONFIG_RELOADER_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/prometheus-config-reloader-linux-amd64.tar"
copy_image "${GRAFANA_IMAGE}" "${GRAFANA_IMAGE_TAG}" \
  "${GRAFANA_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/grafana-linux-amd64.tar"
copy_image "${GRAFANA_SIDECAR_IMAGE}" "${GRAFANA_SIDECAR_IMAGE_TAG}" \
  "${GRAFANA_SIDECAR_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/grafana-sidecar-linux-amd64.tar"
copy_image "${KUBE_STATE_METRICS_IMAGE}" "${KUBE_STATE_METRICS_IMAGE_TAG}" \
  "${KUBE_STATE_METRICS_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/kube-state-metrics-linux-amd64.tar"
copy_image "${NODE_EXPORTER_IMAGE}" "${NODE_EXPORTER_IMAGE_TAG}" \
  "${NODE_EXPORTER_IMAGE_AMD64_DIGEST}" \
  "${build_root}/outputs/images/node-exporter-linux-amd64.tar"

python3 - "${addon_root}/values.yaml" \
  "${build_root}/outputs/values/kube-prometheus-stack-values.yaml" <<'PY'
import os
import sys
from pathlib import Path

replacements = {}
for key in (
        "PROMETHEUS_IMAGE_AMD64_DIGEST",
        "ALERTMANAGER_IMAGE_AMD64_DIGEST",
        "PROMETHEUS_OPERATOR_IMAGE_AMD64_DIGEST",
        "PROMETHEUS_CONFIG_RELOADER_IMAGE_AMD64_DIGEST",
        "GRAFANA_IMAGE_AMD64_DIGEST",
        "GRAFANA_SIDECAR_IMAGE_AMD64_DIGEST",
        "KUBE_STATE_METRICS_IMAGE_AMD64_DIGEST",
        "NODE_EXPORTER_IMAGE_AMD64_DIGEST",
):
    value = os.environ[key]
    replacements[f"__{key}__"] = value
    replacements[f"__{key}_HEX__"] = value.removeprefix("sha256:")
content = Path(sys.argv[1]).read_text(encoding="utf-8")
for placeholder, value in replacements.items():
    content = content.replace(placeholder, value)
if "__" in content:
    raise SystemExit("Prometheus values retain an unresolved placeholder")
Path(sys.argv[2]).write_text(content, encoding="utf-8")
PY

cp "${addon_root}/manifests/monitoring-policy.yaml" \
  "${build_root}/outputs/manifests/monitoring-policy.yaml"
cp "${addon_root}/payload/verify-prometheus-bundle.sh" \
  "${build_root}/outputs/verify-prometheus-bundle.sh"
chmod 0755 "${build_root}/outputs/verify-prometheus-bundle.sh"

python3 - "${build_root}/outputs/provenance.json" <<'PY'
import json
import os
import sys
from pathlib import Path

images = {}
for name in (
    "PROMETHEUS", "ALERTMANAGER", "PROMETHEUS_OPERATOR",
    "PROMETHEUS_CONFIG_RELOADER", "GRAFANA", "GRAFANA_SIDECAR",
    "KUBE_STATE_METRICS", "NODE_EXPORTER",
):
    images[name.lower().replace("_", "-")] = {
        "source": os.environ[f"{name}_IMAGE"],
        "tag": os.environ[f"{name}_IMAGE_TAG"],
        "image_manifest_digest": os.environ[f"{name}_IMAGE_AMD64_DIGEST"],
    }
document = {
    "schema_version": 1,
    "artifact": "jasper-k8s-prometheus-offline",
    "profile": os.environ["ADDON_PROFILE"],
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "kube-prometheus-stack": {
            "version": os.environ["KUBE_PROMETHEUS_STACK_VERSION"],
            "source_commit": os.environ["KUBE_PROMETHEUS_STACK_SOURCE_COMMIT"],
            "source_tree": os.environ["KUBE_PROMETHEUS_STACK_SOURCE_TREE"],
            "chart_sha256": os.environ["KUBE_PROMETHEUS_STACK_CHART_SHA256"],
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
"${build_root}/outputs/verify-prometheus-bundle.sh" "${build_root}/outputs"

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
