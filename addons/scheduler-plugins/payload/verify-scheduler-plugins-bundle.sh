#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly expected_chart_sha256=5b3a163fc9d2024690df066bbb6d652d147e508860dcfed3e19ef04e754f8468
readonly expected_scheduler_prefix='jasper-build/scheduler-plugins/kube-scheduler:v0.35.4-devel@'

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

require_nonempty_file "${root}/SHA256SUMS"
require_nonempty_file "${root}/charts/scheduler-plugins-0.35.4-devel.tgz"
require_nonempty_file "${root}/images/kube-scheduler-linux-amd64.tar"
require_nonempty_file "${root}/images/source-images.lock"
require_nonempty_file "${root}/tools/helm"
require_nonempty_file "${root}/values/scheduler-plugins-values.yaml"
require_nonempty_file "${root}/provenance.json"
require_nonempty_file "${root}/licenses/scheduler-plugins-Apache-2.0.txt"

printf '%s  %s\n' \
  "${expected_chart_sha256}" \
  "${root}/charts/scheduler-plugins-0.35.4-devel.tgz" \
  | sha256sum --check --strict
test "$(tar -xOzf "${root}/charts/scheduler-plugins-0.35.4-devel.tgz" \
  scheduler-plugins/Chart.yaml | sed -n 's/^version: //p')" = 0.35.4-devel
test "$(${root}/tools/helm version --short)" = v3.18.4+gd80839c

python3 - \
  "${root}/provenance.json" \
  "${root}/images/source-images.lock" \
  "${root}/images/kube-scheduler-linux-amd64.tar" \
  "${root}/values/scheduler-plugins-values.yaml" \
  "${expected_scheduler_prefix}" <<'PY'
import json
import re
import sys
import tarfile
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
locked_image = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
if not locked_image.startswith(sys.argv[5]):
    raise SystemExit("unexpected scheduler image lock repository or tag")
digest = locked_image.removeprefix(sys.argv[5])
if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit("scheduler image lock has an invalid manifest digest")
with tarfile.open(sys.argv[3], "r") as archive:
    index = json.load(archive.extractfile("index.json"))
manifests = index.get("manifests", [])
if len(manifests) != 1 or manifests[0].get("digest") != digest:
    raise SystemExit("scheduler OCI archive does not match the image lock")
values = Path(sys.argv[4]).read_text(encoding="utf-8")
expected_runtime_image = (
    "10.144.66.139:35000/scheduler-plugins/kube-scheduler:"
    f"v0.35.4-devel@{digest}"
)
if values.count(expected_runtime_image) != 2:
    raise SystemExit("scheduler values do not pin both images to the locked digest")
if "__SCHEDULER_IMAGE_AMD64_DIGEST__" in values:
    raise SystemExit("scheduler values retain an unresolved digest placeholder")
expected = {
    "schema_version": 1,
    "artifact": "jasper-k8s-scheduler-plugins-offline",
    "profile": "h139-scheduler-plugins-r1",
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "scheduler-plugins": {
            "version": "0.35.4-devel",
            "tag_object": "443724924518acc5bf1186ad7e12f076bb87928c",
            "source_commit": "2c75c8b5cb943435e94ffd325d9f1542d01f175f",
            "source_tree": "0674917df039647db144bf2792217b64a3cfcb40",
            "chart_tree": "242e8ccc4e08aef0c120d2a2153420b5b1ccfe52",
            "upstream_tag_signed": False,
            "image_origin": "built-from-source",
            "image_manifest_digest": digest,
        },
        "helm": {"version": "3.18.4"},
    },
}
if document != expected:
    raise SystemExit("unexpected scheduler-plugins provenance")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
