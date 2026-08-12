#!/usr/bin/env python3
"""Verify the generated Kubespray lists still resolve to the reviewed versions."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def values(path: Path) -> dict[str, str]:
    return dict(
        line.strip().split("=", 1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )


def lines(path: Path) -> list[str]:
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def require(items: list[str], expected: str, label: str) -> None:
    if expected not in items:
        raise RuntimeError(f"{label} did not resolve to {expected}")


def verify(version_file: Path, image_file: Path, url_file: Path) -> None:
    version = values(version_file)
    images = lines(image_file)
    urls = lines(url_file)
    expected_images = {
        f"quay.io/cilium/cilium:v{version['CILIUM_VERSION']}": "Cilium",
        f"quay.io/cilium/operator-generic:v{version['CILIUM_VERSION']}": "Cilium operator",
        f"registry.k8s.io/coredns/coredns:v{version['COREDNS_VERSION']}": "CoreDNS",
        f"registry.k8s.io/cpa/cluster-proportional-autoscaler:v{version['DNS_AUTOSCALER_VERSION']}": "DNS autoscaler",
        f"registry.k8s.io/dns/k8s-dns-node-cache:{version['NODELOCALDNS_VERSION']}": "NodeLocal DNS",
        f"registry.k8s.io/pause:{version['POD_INFRA_VERSION']}": "pause",
    }
    for component in (
        "kube-apiserver",
        "kube-controller-manager",
        "kube-proxy",
        "kube-scheduler",
    ):
        expected_images[f"registry.k8s.io/{component}:v{version['KUBE_VERSION']}"] = (
            component
        )
    for image, label in expected_images.items():
        require(images, image, label)

    expected_urls = {
        f"https://dl.k8s.io/release/v{version['KUBE_VERSION']}/bin/linux/amd64/{binary}": binary
        for binary in ("kubeadm", "kubectl", "kubelet")
    }
    expected_urls.update(
        {
            f"https://github.com/etcd-io/etcd/releases/download/v{version['ETCD_VERSION']}/etcd-v{version['ETCD_VERSION']}-linux-amd64.tar.gz": "etcd",
            f"https://github.com/containernetworking/plugins/releases/download/v{version['CNI_VERSION']}/cni-plugins-linux-amd64-v{version['CNI_VERSION']}.tgz": "CNI plugins",
            f"https://github.com/kubernetes-sigs/cri-tools/releases/download/v{version['CRICTL_VERSION']}/crictl-v{version['CRICTL_VERSION']}-linux-amd64.tar.gz": "crictl",
            f"https://github.com/opencontainers/runc/releases/download/v{version['RUNC_VERSION']}/runc.amd64": "runc",
            f"https://github.com/containerd/nerdctl/releases/download/v{version['NERDCTL_VERSION']}/nerdctl-{version['NERDCTL_VERSION']}-linux-amd64.tar.gz": "nerdctl",
            f"https://github.com/containerd/containerd/releases/download/v{version['CONTAINERD_VERSION']}/containerd-{version['CONTAINERD_VERSION']}-linux-amd64.tar.gz": "containerd",
            f"https://github.com/cilium/cilium-cli/releases/download/v{version['CILIUM_CLI_VERSION']}/cilium-linux-amd64.tar.gz": "Cilium CLI",
        }
    )
    for url, label in expected_urls.items():
        require(urls, url, label)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--versions", required=True, type=Path)
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--files", required=True, type=Path)
    args = parser.parse_args()
    try:
        verify(args.versions, args.images, args.files)
    except (OSError, UnicodeError, ValueError, RuntimeError, re.error) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
