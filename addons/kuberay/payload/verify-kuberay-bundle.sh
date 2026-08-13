#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly operator_digest=sha256:2602383ef61afe1b4c55bdcb24da2ff55ee31b6674cbe53b1583e5219e5e3376
readonly ray_digest=sha256:6b3d2572a37eac048517530e91b6c34d894cdab20805e8878f365c7014fb50db

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

for path in \
  SHA256SUMS \
  charts/kuberay-operator-1.6.2.tgz \
  images/kuberay-operator-linux-amd64.tar \
  images/ray-linux-amd64.tar \
  images/source-images.lock \
  licenses/kuberay-Apache-2.0.txt \
  licenses/ray-Apache-2.0.txt \
  provenance.json \
  tools/helm \
  values/kuberay-operator-values.yaml; do
  require_nonempty_file "${root}/${path}"
done

test "$(tar -xOzf "${root}/charts/kuberay-operator-1.6.2.tgz" \
  kuberay-operator/Chart.yaml | sed -n 's/^version: //p')" = 1.6.2
test "$("${root}/tools/helm" version --short)" = v3.18.4+gd80839c
test "$(cat "${root}/images/source-images.lock")" = \
  $'quay.io/kuberay/operator:v1.6.2@'"${operator_digest}"$'\n'docker.io/rayproject/ray:2.56.1@"${ray_digest}"

python3 - \
  "${root}/provenance.json" \
  "${root}/images/kuberay-operator-linux-amd64.tar" \
  "${root}/images/ray-linux-amd64.tar" \
  "${root}/values/kuberay-operator-values.yaml" <<'PY'
import json
import sys
import tarfile
from pathlib import Path

operator_digest = "sha256:2602383ef61afe1b4c55bdcb24da2ff55ee31b6674cbe53b1583e5219e5e3376"
ray_digest = "sha256:6b3d2572a37eac048517530e91b6c34d894cdab20805e8878f365c7014fb50db"
for path, expected in ((sys.argv[2], operator_digest), (sys.argv[3], ray_digest)):
    with tarfile.open(path, "r") as archive:
        manifests = json.load(archive.extractfile("index.json")).get("manifests", [])
    if len(manifests) != 1 or manifests[0].get("digest") != expected:
        raise SystemExit(f"OCI archive does not match approved digest: {path}")
values = Path(sys.argv[4]).read_text(encoding="utf-8")
for required in (
    "repository: 10.144.66.139:35000/kuberay/operator",
    f"tag: v1.6.2@{operator_digest}",
    "priorityClassName: jasper-service-high",
    "name: RayJobDeletionPolicy",
    "serviceMonitor:\n    enabled: false",
):
    if required not in values:
        raise SystemExit(f"KubeRay values are missing: {required}")
if "__KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST__" in values:
    raise SystemExit("KubeRay values retain an image placeholder")
expected = {
    "schema_version": 1,
    "artifact": "jasper-k8s-kuberay-offline",
    "profile": "h139-kuberay-r1",
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "kuberay-operator": {
            "version": "1.6.2",
            "source_commit": "598eb66aa077c55ae04fa87b192238a3ec184e88",
            "source_tree": "c008b051b147671a757a1bc78ce394bc3f1f5586",
            "chart_tree": "37001313ae112c744ff601f590f4a7600a382de9",
            "chart_sha256": "48c75ab69eec4a15bd8700b9a04ba1d82dac8b93a51588bf8758cc656dcb3c6f",
            "upstream_tag_signed": False,
            "image_manifest_digest": operator_digest,
        },
        "ray-runtime": {
            "version": "2.56.1",
            "source_commit": "936f0d7d49d9da8ac1a9f04cc8a89faf2cb3c42a",
            "source_tree": "dd8306daf842a918b633861b62812c2e030c8ea9",
            "source_commit_verified": True,
            "image_manifest_digest": ray_digest,
        },
        "helm": {"version": "3.18.4"},
    },
}
if json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")) != expected:
    raise SystemExit("unexpected KubeRay provenance")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
