#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly expected_chart_sha256=59abb5852a24b3ae0ef757bfea3051f419acbf559ee5efd72f0672d28af56a68
readonly expected_images='nvcr.io/nvidia/gpu-operator:v26.3.3@sha256:ca6cbd45e11779164aa89fa9d20517bce4717b9a772f168a3c492075aad0abfe
nvcr.io/nvidia/k8s/container-toolkit:v1.19.1@sha256:05308cb0f8ad06f82f70d6f64321b3c99ab4836bb28fe50bb5d0cd0e79e7afba
nvcr.io/nvidia/k8s-device-plugin:v0.19.3@sha256:d6c456ffe537914357240e6641a40dfb5540822f9d3bee52788da5ec0646c551
nvcr.io/nvidia/k8s/dcgm-exporter:4.5.3-4.8.2-distroless@sha256:e9030b4fca0c8f110032f3b151b030e7e9db56604b407cf79631e1a3218b35e0'

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

require_nonempty_file "${root}/SHA256SUMS"
require_nonempty_file "${root}/charts/gpu-operator-v26.3.3.tgz"
require_nonempty_file "${root}/images/gpu-operator-linux-amd64.tar"
require_nonempty_file "${root}/images/container-toolkit-linux-amd64.tar"
require_nonempty_file "${root}/images/k8s-device-plugin-linux-amd64.tar"
require_nonempty_file "${root}/images/dcgm-exporter-linux-amd64.tar"
require_nonempty_file "${root}/images/source-images.lock"
require_nonempty_file "${root}/tools/helm"
require_nonempty_file "${root}/values/gpu-operator-values.yaml"
require_nonempty_file "${root}/provenance.json"

printf '%s  %s\n' \
  "${expected_chart_sha256}" \
  "${root}/charts/gpu-operator-v26.3.3.tgz" \
  | sha256sum --check --strict
test "$(tar -xOzf "${root}/charts/gpu-operator-v26.3.3.tgz" \
  gpu-operator/Chart.yaml | sed -n 's/^version: //p')" = v26.3.3
test "$(cat "${root}/images/source-images.lock")" = "${expected_images}"
test "$("${root}/tools/helm" version --short)" = v3.18.4+gd80839c

python3 - "${root}/provenance.json" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schema_version": 1,
    "artifact": "jasper-k8s-gpu-operator-offline",
    "profile": "h139-gpu-operator-r1",
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "gpu-operator": {
            "version": "26.3.3",
            "source_commit": "b0a49c0e7b2e061dcd83f2bb2fe4fe960c5d0338",
            "signed_tag_object": "9a0c55839ab61b890487f1bb7173216e518fbf45",
        },
        "helm": {"version": "3.18.4"},
    },
}
if document != expected:
    raise SystemExit("unexpected GPU Operator provenance")
PY

python3 - "${root}/values/gpu-operator-values.yaml" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text(encoding="utf-8")
if "10.144.66.139:35000/" not in content:
    raise SystemExit("GPU Operator values do not reference the local registry")
for forbidden in ("nvcr.io", "registry.k8s.io", "docker.io", "quay.io"):
    if forbidden in content:
        raise SystemExit(f"GPU Operator values contain a public registry: {forbidden}")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
