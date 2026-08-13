#!/usr/bin/env python3
"""Apply the two reviewed Rancher pilot changes missing from chart values."""

from __future__ import annotations

import sys

import yaml


def fail(message: str) -> None:
    raise SystemExit(message)


documents = [document for document in yaml.safe_load_all(sys.stdin) if document]
issuer_count = 0
service_count = 0
output = []

for document in documents:
    api_version = document.get("apiVersion")
    kind = document.get("kind")
    metadata = document.get("metadata") or {}
    name = metadata.get("name")

    if api_version == "cert-manager.io/v1" and kind == "Issuer":
        if name != "rancher":
            fail(f"refusing to remove unexpected cert-manager Issuer: {name!r}")
        issuer_count += 1
        continue

    if api_version == "v1" and kind == "Service" and name == "rancher":
        spec = document.get("spec") or {}
        ports = spec.get("ports") or []
        if spec.get("type") != "NodePort":
            fail("Rancher Service is not NodePort")
        if len(ports) != 1:
            fail("Rancher Service must expose exactly one port")
        port = ports[0]
        if (
            port.get("name") != "https"
            or port.get("port") != 443
            or port.get("targetPort") != 443
            or port.get("protocol") != "TCP"
        ):
            fail("Rancher Service HTTPS port contract drifted")
        existing = port.get("nodePort")
        if existing not in (None, 30443):
            fail(f"Rancher Service already has unexpected nodePort: {existing}")
        port["nodePort"] = 30443
        service_count += 1

    output.append(document)

if issuer_count != 1:
    fail(f"expected exactly one Rancher cert-manager Issuer, found {issuer_count}")
if service_count != 1:
    fail(f"expected exactly one Rancher Service, found {service_count}")

yaml.safe_dump_all(output, sys.stdout, explicit_start=True, sort_keys=False)
