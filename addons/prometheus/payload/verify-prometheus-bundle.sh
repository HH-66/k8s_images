#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly chart_sha256=9e48c3b732eaf0636a0423504857b4c543b61bb883cf3291548ff4b9f3c14bbc

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

for path in \
  SHA256SUMS \
  charts/kube-prometheus-stack-88.2.0.tgz \
  images/alertmanager-linux-amd64.tar \
  images/grafana-linux-amd64.tar \
  images/grafana-sidecar-linux-amd64.tar \
  images/kube-state-metrics-linux-amd64.tar \
  images/node-exporter-linux-amd64.tar \
  images/prometheus-linux-amd64.tar \
  images/prometheus-config-reloader-linux-amd64.tar \
  images/prometheus-operator-linux-amd64.tar \
  images/source-images.lock \
  licenses/prometheus-community-helm-charts-Apache-2.0.txt \
  manifests/monitoring-policy.yaml \
  provenance.json \
  tools/helm \
  values/kube-prometheus-stack-values.yaml; do
  require_nonempty_file "${root}/${path}"
done

printf '%s  %s\n' "${chart_sha256}" \
  "${root}/charts/kube-prometheus-stack-88.2.0.tgz" \
  | sha256sum --check --strict
test "$(tar -xOzf "${root}/charts/kube-prometheus-stack-88.2.0.tgz" \
  kube-prometheus-stack/Chart.yaml | sed -n 's/^version: //p')" = 88.2.0
test "$("${root}/tools/helm" version --short)" = v3.18.4+gd80839c

python3 - \
  "${root}/provenance.json" \
  "${root}/images/source-images.lock" \
  "${root}/values/kube-prometheus-stack-values.yaml" \
  "${root}/charts/kube-prometheus-stack-88.2.0.tgz" \
  "${root}/tools/helm" \
  "${root}/images" <<'PY'
import json
import subprocess
import sys
import tarfile
import tempfile
import re
from pathlib import Path

expected = {
    "quay.io/prometheus/prometheus:v3.13.2-distroless": "sha256:ce95cfa77eff5aad28bd7a65aff19868cf78d9e17e4c254da7dfe22ade78318b",
    "quay.io/prometheus/alertmanager:v0.33.1": "sha256:a89f8d4520954079275441eecdb71444328bd90633dd4eddfc33b9ed657f349b",
    "quay.io/prometheus-operator/prometheus-operator:v0.93.0": "sha256:64eb7914e4705dbb64438e3b3193da1226ad2ea4db2924983693999888cda9b2",
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.93.0": "sha256:65b90f44d5535b106015ac60bafb57803f65dc928c187874de6cd7a9ec6c8905",
    "docker.io/grafana/grafana:13.1.3": "sha256:e27e68cfd5795c1bea54950766078a02e84dfa3bafe0a4d0e5382f713dfd8e4e",
    "quay.io/kiwigrid/k8s-sidecar:2.10.1": "sha256:440db6dcf9a724fa2c167612e147ad8839e75104732dc7ec89783e73199837f0",
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1": "sha256:7661da8c99b733d43117e4cba12bd9865d335e5777191d0af3d789807aded9f4",
    "quay.io/prometheus/node-exporter:v1.12.1": "sha256:da83fae85603c4e47e6c68369a7d746e2dda683dc35ea2e234b4f171e0d92798",
}
lock = Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
if lock != [f"{name}@{digest}" for name, digest in expected.items()]:
    raise SystemExit("unexpected Prometheus source image lock")

archives = sorted(Path(sys.argv[6]).glob("*-linux-amd64.tar"))
if len(archives) != len(expected):
    raise SystemExit("unexpected Prometheus OCI archive count")
observed = set()
for path in archives:
    with tarfile.open(path, "r") as archive:
        manifests = json.load(archive.extractfile("index.json")).get("manifests", [])
    if len(manifests) != 1:
        raise SystemExit(f"OCI archive does not have one manifest: {path}")
    observed.add(manifests[0].get("digest"))
if observed != set(expected.values()):
    raise SystemExit("Prometheus OCI archives do not match approved digests")

provenance = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
stack = provenance.get("components", {}).get("kube-prometheus-stack", {})
if provenance.get("profile") != "h139-prometheus-r1":
    raise SystemExit("unexpected Prometheus provenance profile")
if stack != {
    "version": "88.2.0",
    "source_commit": "18956245a31a887141bb31a040c145d6b5e6e056",
    "source_tree": "e22ae05c3093815cb1ff5c2f0caf1d9451e0b52a",
    "chart_sha256": "9e48c3b732eaf0636a0423504857b4c543b61bb883cf3291548ff4b9f3c14bbc",
}:
    raise SystemExit("unexpected kube-prometheus-stack provenance")

with tempfile.TemporaryDirectory() as directory:
    rendered = Path(directory) / "rendered.yaml"
    result = subprocess.run(
        [
            sys.argv[5], "template", "kube-prometheus-stack", sys.argv[4],
            "--namespace", "monitoring", "--values", sys.argv[3],
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    rendered.write_text(result.stdout, encoding="utf-8")
text = rendered.read_text(encoding="utf-8")
images = re.findall(r'^\s*image:\s*["\']?([^"\'\s]+)', text, re.MULTILINE)
if not images:
    raise SystemExit("rendered Prometheus chart has no images")
for image in images:
    if not image.startswith("10.144.66.139:35000/") or "@sha256:" not in image:
        raise SystemExit(f"rendered Prometheus chart uses an unapproved image: {image}")
for required in (
    "retention: \"7d\"",
    "retentionSize: \"80GB\"",
    "name: jasper-opt-in-pods",
    "name: nvidia-dcgm-exporter",
    "metrics.jasper.ai/scrape: \"true\"",
    "jasper.ai/monitoring: enabled",
    "sizeLimit: 100Gi",
    "--prometheus-config-reloader=10.144.66.139:35000/prometheus-operator/prometheus-config-reloader:v0.93.0@sha256:65b90f44d5535b106015ac60bafb57803f65dc928c187874de6cd7a9ec6c8905",
):
    if required not in text:
        raise SystemExit(f"rendered Prometheus chart is missing: {required}")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
