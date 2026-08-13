#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly kubepi_digest=sha256:51965fd88187c3d68119cf85a06c200885a8e3d0f10290b9e80338f10e3d896a
readonly nginx_digest=sha256:8a4f4b94275ff59d809477799cbbaf1a7ab65ed1871403d05e31fd66bdb8db82

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

for path in \
  SHA256SUMS \
  images/kubepi-linux-amd64.tar \
  images/nginx-linux-amd64.tar \
  images/source-images.lock \
  licenses/kubepi-GPLv3-FIT2CLOUD.txt \
  licenses/nginx-BSD-2-Clause.txt \
  manifests/kubepi-core.yaml \
  manifests/kubepi-nodeport.yaml \
  provenance.json; do
  require_nonempty_file "${root}/${path}"
done

test "$(cat "${root}/images/source-images.lock")" = \
  $'docker.io/1panel/kubepi:v2.0.2@'"${kubepi_digest}"$'\n'docker.io/library/nginx:1.30.4-alpine3.24@"${nginx_digest}"

python3 - \
  "${root}/provenance.json" \
  "${root}/images/kubepi-linux-amd64.tar" \
  "${root}/images/nginx-linux-amd64.tar" \
  "${root}/manifests/kubepi-core.yaml" \
  "${root}/manifests/kubepi-nodeport.yaml" <<'PY'
import json
import sys
import tarfile
from pathlib import Path

import yaml

kubepi_digest = "sha256:51965fd88187c3d68119cf85a06c200885a8e3d0f10290b9e80338f10e3d896a"
nginx_digest = "sha256:8a4f4b94275ff59d809477799cbbaf1a7ab65ed1871403d05e31fd66bdb8db82"
for path, expected in ((sys.argv[2], kubepi_digest), (sys.argv[3], nginx_digest)):
    with tarfile.open(path, "r") as archive:
        manifests = json.load(archive.extractfile("index.json")).get("manifests", [])
    if len(manifests) != 1 or manifests[0].get("digest") != expected:
        raise SystemExit(f"OCI archive does not match approved digest: {path}")

documents = list(yaml.safe_load_all(Path(sys.argv[4]).read_text(encoding="utf-8")))
deployment = next(item for item in documents if item.get("kind") == "Deployment")
pod_spec = deployment["spec"]["template"]["spec"]
if pod_spec.get("serviceAccountName") != "kubepi":
    raise SystemExit("KubePi ServiceAccount drifted")
if pod_spec.get("priorityClassName") != "jasper-service-default":
    raise SystemExit("KubePi priority class drifted")
containers = {item["name"]: item for item in pod_spec["containers"]}
if containers["kubepi"]["image"] != (
    "10.144.66.139:35000/1panel/kubepi:v2.0.2@" + kubepi_digest
):
    raise SystemExit("KubePi image is not locally digest pinned")
if containers["tls-proxy"]["image"] != (
    "10.144.66.139:35000/library/nginx:1.30.4-alpine3.24@" + nginx_digest
):
    raise SystemExit("KubePi TLS proxy image is not locally digest pinned")
if any(item.get("securityContext", {}).get("privileged") for item in containers.values()):
    raise SystemExit("KubePi pilot must not use privileged containers")
if containers["kubepi"]["resources"]["requests"] == containers["kubepi"]["resources"]["limits"]:
    raise SystemExit("KubePi pilot must remain Burstable")
if "127.0.0.1" not in containers["kubepi"].get("args", []):
    raise SystemExit("KubePi must listen only on the Pod loopback interface")
binding = next(item for item in documents if item.get("kind") == "ClusterRoleBinding")
if binding["roleRef"].get("name") != "cluster-admin":
    raise SystemExit("KubePi pilot is not bound to cluster-admin")
service = next(item for item in documents if item.get("kind") == "Service")
if service["spec"].get("type") != "ClusterIP":
    raise SystemExit("KubePi core service must remain private during bootstrap")

nodeport = list(yaml.safe_load_all(Path(sys.argv[5]).read_text(encoding="utf-8")))
if len(nodeport) != 1 or nodeport[0]["spec"].get("type") != "NodePort":
    raise SystemExit("KubePi exposure manifest drifted")
if nodeport[0]["spec"]["ports"][0].get("nodePort") != 30444:
    raise SystemExit("KubePi HTTPS NodePort drifted")

expected = {
    "schema_version": 1,
    "artifact": "jasper-k8s-kubepi-offline",
    "profile": "h139-kubepi-r1",
    "target": {"os": "linux", "architecture": "amd64"},
    "components": {
        "kubepi": {
            "version": "2.0.2",
            "source_commit": "4bced650e1381714e9cd3ab2d4e604bc77d4aa84",
            "source_tree": "b7b86f0d4c8eecca608e7d9f10fbbfa3d6be2717",
            "upstream_tag_signed": False,
            "image_manifest_digest": kubepi_digest,
        },
        "nginx-tls-proxy": {
            "version": "1.30.4-alpine3.24",
            "source_commit": "e0f008fab4e1ce252c9451590c6a2aff305dd03c",
            "image_manifest_digest": nginx_digest,
        },
    },
}
if json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")) != expected:
    raise SystemExit("unexpected KubePi provenance")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
