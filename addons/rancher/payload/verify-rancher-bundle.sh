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
    "docker.io/rancher/rancher:v2.15.0": "sha256:8b1b2c65d5acd4abbd7709ac4589b0fed66e576f0e54278705b5754304c5a933",
    "docker.io/rancher/fleet:v0.16.0": "sha256:077b65408abd61a503a853fd30dd3896da8159b13bf146bcc2f11e6710171aec",
    "docker.io/rancher/fleet-agent:v0.16.0": "sha256:af9d2889ae81f817082b8a941e6a1b6941ed354bf184a1d038dcb485cc2bca8e",
    "docker.io/rancher/rancher-webhook:v0.11.0": "sha256:685ab68868a8782073afb622cfff11ef3134f39bfbda752000293cf8ca2571ad",
    "docker.io/rancher/remotedialer-proxy:v0.8.0": "sha256:402423af0e0ae6d3f4b7e54db1bc055d23c7303917818d34876113b13516b35b",
    "docker.io/rancher/shell:v0.8.1": "sha256:928944dedfdccdcbcb14227377427798747ca468212341c5706e8745203037b0",
    "docker.io/rancher/rancher-agent:v2.15.0": "sha256:bc58d78aea17a2ca875e6dd2c071d3a9dd4a2fee24f659ad3dacc855905c9bfd",
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
    "sha256:8b1b2c65d5acd4abbd7709ac4589b0fed66e576f0e54278705b5754304c5a933"
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
