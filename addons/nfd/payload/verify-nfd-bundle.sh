#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly expected_chart_sha256=9e93b360e6167b782759026de40ba9d68d44c3e8b0b53b735592ad48fd3339ad
readonly expected_image='registry.k8s.io/nfd/node-feature-discovery:v0.19.0@sha256:aa5be8691e4d5876d8a774063b37e1430c75e09468ba98d8bd07f6deec1f1756'

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

require_nonempty_file "${root}/SHA256SUMS"
require_nonempty_file "${root}/charts/node-feature-discovery-0.19.0.tgz"
require_nonempty_file "${root}/images/nfd-linux-amd64.tar"
require_nonempty_file "${root}/images/source-images.lock"
require_nonempty_file "${root}/tools/helm"
require_nonempty_file "${root}/values/nfd-values.yaml"
require_nonempty_file "${root}/provenance.json"

printf '%s  %s\n' \
  "${expected_chart_sha256}" \
  "${root}/charts/node-feature-discovery-0.19.0.tgz" \
  | sha256sum --check --strict
test "$(tar -xOzf "${root}/charts/node-feature-discovery-0.19.0.tgz" \
  node-feature-discovery/Chart.yaml | sed -n 's/^version: //p')" = 0.19.0
test "$(cat "${root}/images/source-images.lock")" = "${expected_image}"
test "$(${root}/tools/helm version --short)" = v3.18.4+gd80839c

python3 - "${root}/provenance.json" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schema_version": 1,
    "artifact": "jasper-k8s-nfd-offline",
    "profile": "h139-nfd-r1",
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "node-feature-discovery": {
            "version": "0.19.0",
            "source_commit": "45d276ed9d3f0f67fb642aa78969721df3034451",
        },
        "helm": {"version": "3.18.4"},
    },
}
if document != expected:
    raise SystemExit("unexpected NFD provenance")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
