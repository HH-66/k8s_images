#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly expected_chart_sha256=bf87087a393ffb3f9e696437d3527d35a9b9e13857169ff0eea3a1403c659857
readonly expected_image='registry.k8s.io/kueue/kueue:v0.19.0@sha256:edfc34283d8ab63835f8cbd30c7d0fdb6a4ca0f69689866806a2712362ef43e0'

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

require_nonempty_file "${root}/SHA256SUMS"
require_nonempty_file "${root}/charts/kueue-0.19.0.tgz"
require_nonempty_file "${root}/images/kueue-controller-linux-amd64.tar"
require_nonempty_file "${root}/images/source-images.lock"
require_nonempty_file "${root}/tools/helm"
require_nonempty_file "${root}/values/kueue-values.yaml"
require_nonempty_file "${root}/provenance.json"
require_nonempty_file "${root}/licenses/kueue-Apache-2.0.txt"

printf '%s  %s\n' "${expected_chart_sha256}" "${root}/charts/kueue-0.19.0.tgz" \
  | sha256sum --check --strict
test "$(tar -xOzf "${root}/charts/kueue-0.19.0.tgz" \
  kueue/Chart.yaml | sed -n 's/^version: //p')" = 0.19.0
test "$(cat "${root}/images/source-images.lock")" = "${expected_image}"
test "$("${root}/tools/helm" version --short)" = v3.18.4+gd80839c

python3 - \
  "${root}/provenance.json" \
  "${root}/images/kueue-controller-linux-amd64.tar" \
  "${root}/values/kueue-values.yaml" <<'PY'
import json
import sys
import tarfile
from pathlib import Path

expected_digest = "sha256:edfc34283d8ab63835f8cbd30c7d0fdb6a4ca0f69689866806a2712362ef43e0"
with tarfile.open(sys.argv[2], "r") as archive:
    index = json.load(archive.extractfile("index.json"))
manifests = index.get("manifests", [])
if len(manifests) != 1 or manifests[0].get("digest") != expected_digest:
    raise SystemExit("Kueue OCI archive does not match the approved image digest")
values = Path(sys.argv[3]).read_text(encoding="utf-8")
expected_repository = "repository: 10.144.66.139:35000/kueue/kueue"
expected_tag = f"tag: v0.19.0@{expected_digest}"
if (
    expected_repository not in values
    or expected_tag not in values
    or "__KUEUE_IMAGE_AMD64_DIGEST__" in values
):
    raise SystemExit("Kueue values do not pin the approved local image")
for required in (
    "priorityClassName: system-cluster-critical",
    "timeout: 15m",
    "blockAdmission: true",
    "workload.jasper.ai/kueue-managed: \"true\"",
    "- batch/job",
):
    if required not in values:
        raise SystemExit(f"Kueue values are missing: {required}")
if "ray.io/rayjob" in values:
    raise SystemExit("Kueue must not enable RayJob before the KubeRay CRD is installed")
expected = {
    "schema_version": 1,
    "artifact": "jasper-k8s-kueue-offline",
    "profile": "h139-kueue-r3",
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "kueue": {
            "version": "0.19.0",
            "tag_object": "7b3cad14a540cd256dc9c658be5a23fff809ff68",
            "source_commit": "911a822a49bcfd99c9c62203a009efa4130ad604",
            "source_tree": "66bce3eb881062e29b57f836dff1905715ed24d2",
            "upstream_tag_signed": False,
            "chart_sha256": "bf87087a393ffb3f9e696437d3527d35a9b9e13857169ff0eea3a1403c659857",
            "image_manifest_digest": expected_digest,
        },
        "helm": {"version": "3.18.4"},
    },
}
document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if document != expected:
    raise SystemExit("unexpected Kueue provenance")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
