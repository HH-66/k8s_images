#!/usr/bin/env bash
set -euo pipefail

readonly root=${1:-outputs}
readonly chart_sha256=59a589ad5b2c5bc11f6bc51fdd252f04725b21f3f4c2f76fb24452077f0552dd

require_nonempty_file() {
  test -s "$1" || { echo "required file is missing or empty: $1" >&2; return 1; }
}

for path in \
  SHA256SUMS \
  charts/rancher-2.15.0.tgz \
  images/fleet-agent-linux-amd64.tar \
  images/fleet-linux-amd64.tar \
  images/rancher-agent-linux-amd64.tar \
  images/rancher-linux-amd64.tar \
  images/rancher-shell-linux-amd64.tar \
  images/rancher-webhook-linux-amd64.tar \
  images/remotedialer-proxy-linux-amd64.tar \
  images/source-images.lock \
  licenses/rancher-Apache-2.0.txt \
  provenance.json \
  scripts/post-render-rancher.py \
  tools/helm \
  values/rancher-values.yaml; do
  require_nonempty_file "${root}/${path}"
done

printf '%s  %s\n' "${chart_sha256}" "${root}/charts/rancher-2.15.0.tgz" \
  | sha256sum --check --strict
test "$(tar -xOzf "${root}/charts/rancher-2.15.0.tgz" \
  rancher/Chart.yaml | sed -n 's/^version: //p')" = 2.15.0
test "$(tar -xOzf "${root}/charts/rancher-2.15.0.tgz" \
  rancher/Chart.yaml | sed -n 's/^appVersion: //p')" = v2.15.0
test "$("${root}/tools/helm" version --short)" = v3.18.4+gd80839c

python3 - \
  "${root}/provenance.json" \
  "${root}/images/source-images.lock" \
  "${root}/images" \
  "${root}/values/rancher-values.yaml" \
  "${root}/charts/rancher-2.15.0.tgz" \
  "${root}/tools/helm" \
  "${root}/scripts/post-render-rancher.py" <<'PY'
import json
import subprocess
import sys
import tarfile
from pathlib import Path

import yaml

expected = {
    "docker.io/rancher/rancher:v2.15.0": "sha256:59d2643bdf3b76bfbc90410aff1f2b08765ac741d3d2349673381dcd685bf5f1",
    "docker.io/rancher/fleet:v0.16.0": "sha256:08685c8058c16ff5cca179cf1d86e72a16a875500fc8b638c31b2d4ba1f2f101",
    "docker.io/rancher/fleet-agent:v0.16.0": "sha256:ec74409e6b155c7e1c878f1a929b839ab2d1d0cc585a38e989852af202dc2eb7",
    "docker.io/rancher/rancher-webhook:v0.11.0": "sha256:1663d231bb2d323e423b2edea6377a674a92cc790c21f369c5ac1e6e4720a6f4",
    "docker.io/rancher/remotedialer-proxy:v0.8.0": "sha256:6ea82ef79f8bd7639cde154941f5d93f11ddb58af923f6691de867f285af8cb6",
    "docker.io/rancher/shell:v0.8.1": "sha256:f293af9c635f0646f07e918788b97450406e6d0de1041b8afa9ed263ecff76bf",
    "docker.io/rancher/rancher-agent:v2.15.0": "sha256:d8d0d3d8868ffe96785bc291d7f9725bb74b5b1d2bb9647ec2fb00a179b2fb5c",
}
lock = Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
if lock != [f"{name}@{digest}" for name, digest in expected.items()]:
    raise SystemExit("unexpected Rancher source image lock")

archives = sorted(Path(sys.argv[3]).glob("*-linux-amd64.tar"))
if len(archives) != len(expected):
    raise SystemExit("unexpected Rancher OCI archive count")
observed = set()
for path in archives:
    with tarfile.open(path, "r") as archive:
        manifests = json.load(archive.extractfile("index.json")).get("manifests", [])
    if len(manifests) != 1:
        raise SystemExit(f"OCI archive does not have one manifest: {path}")
    observed.add(manifests[0].get("digest"))
if observed != set(expected.values()):
    raise SystemExit("Rancher OCI archives do not match approved digests")

provenance = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rancher = provenance.get("components", {}).get("rancher", {})
if provenance.get("profile") != "h139-rancher-r1":
    raise SystemExit("unexpected Rancher provenance profile")
if rancher != {
    "version": "2.15.0",
    "source_commit": "9994cd93198c4b1692bcda733eb08d1e81c26eed",
    "source_tree": "28581577d87f04c8eacac18ccfc1fa5ba8753377",
    "chart_sha256": "59a589ad5b2c5bc11f6bc51fdd252f04725b21f3f4c2f76fb24452077f0552dd",
    "upstream_tag_signed": False,
}:
    raise SystemExit("unexpected Rancher source provenance")
images = provenance.get("components", {}).get("images", {})
if {item.get("image_manifest_digest") for item in images.values()} != set(expected.values()):
    raise SystemExit("unexpected Rancher image provenance")

values = yaml.safe_load(Path(sys.argv[4]).read_text(encoding="utf-8"))
if values["networkExposure"]["type"] != "none" or values["ingress"]["enabled"]:
    raise SystemExit("Rancher network exposure values drifted")
if values["service"] != {"type": "NodePort", "disableHTTP": True}:
    raise SystemExit("Rancher Service values drifted")
if values["tls"] != "ingress" or values["ingress"]["tls"]["source"] != "rancher":
    raise SystemExit("Rancher dynamic TLS values drifted")
if values["privateCA"] or not values["useBundledSystemChart"]:
    raise SystemExit("Rancher air-gap TLS/catalog values drifted")

result = subprocess.run(
    [
        sys.argv[6], "template", "rancher", sys.argv[5],
        "--namespace", "cattle-system", "--values", sys.argv[4],
        "--post-renderer", sys.argv[7],
    ],
    check=True,
    capture_output=True,
    text=True,
)
documents = [document for document in yaml.safe_load_all(result.stdout) if document]
for document in documents:
    api_version = document.get("apiVersion", "")
    kind = document.get("kind")
    if kind in {"Ingress", "Gateway", "HTTPRoute", "Issuer", "Certificate"}:
        raise SystemExit(f"Rancher render contains forbidden network/TLS resource: {kind}")
    if api_version.startswith("cert-manager.io/"):
        raise SystemExit("Rancher render retains a cert-manager resource")

services = [item for item in documents if item.get("kind") == "Service"]
main = [item for item in services if item.get("metadata", {}).get("name") == "rancher"]
if len(main) != 1:
    raise SystemExit("Rancher render does not have exactly one main Service")
spec = main[0]["spec"]
if spec.get("type") != "NodePort" or spec.get("ports") != [{
    "port": 443,
    "targetPort": 443,
    "protocol": "TCP",
    "name": "https",
    "nodePort": 30443,
}]:
    raise SystemExit("Rancher HTTPS-only NodePort contract drifted")

deployments = [item for item in documents if item.get("kind") == "Deployment"]
rancher_deployments = [
    item for item in deployments if item.get("metadata", {}).get("name") == "rancher"
]
if len(rancher_deployments) != 1 or rancher_deployments[0]["spec"].get("replicas") != 1:
    raise SystemExit("Rancher render is not a single replica")
pod_spec = rancher_deployments[0]["spec"]["template"]["spec"]
if pod_spec.get("priorityClassName") != "jasper-service-high":
    raise SystemExit("Rancher priority class drifted")
container = pod_spec["containers"][0]
if container.get("image") != (
    "10.144.66.139:35000/rancher/rancher:v2.15.0@"
    "sha256:59d2643bdf3b76bfbc90410aff1f2b08765ac741d3d2349673381dcd685bf5f1"
):
    raise SystemExit("Rancher render does not use the local registry")
if "--no-cacerts" in container.get("args", []):
    raise SystemExit("Rancher dynamic self-signed CA generation was disabled")
environment = {item["name"]: item.get("value") for item in container.get("env", [])}
if environment.get("CATTLE_SYSTEM_DEFAULT_REGISTRY") != "10.144.66.139:35000":
    raise SystemExit("Rancher system default registry is missing")
if environment.get("CATTLE_SYSTEM_CATALOG") != "bundled":
    raise SystemExit("Rancher bundled system chart mode is missing")
PY

(cd "${root}" && sha256sum --check --strict SHA256SUMS)
