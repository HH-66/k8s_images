from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_resolved_versions", ROOT / "scripts/verify-resolved-versions.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerifyResolvedVersionsTests(unittest.TestCase):
    @staticmethod
    def reviewed_urls() -> list[str]:
        version = MODULE.values(ROOT / "config/required-versions.env")
        urls = [
            f"https://dl.k8s.io/release/v{version['KUBE_VERSION']}/bin/linux/amd64/{binary}"
            for binary in ("kubeadm", "kubectl", "kubelet")
        ]
        urls.extend(
            [
                f"https://github.com/etcd-io/etcd/releases/download/v{version['ETCD_VERSION']}/etcd-v{version['ETCD_VERSION']}-linux-amd64.tar.gz",
                f"https://github.com/containernetworking/plugins/releases/download/v{version['CNI_VERSION']}/cni-plugins-linux-amd64-v{version['CNI_VERSION']}.tgz",
                f"https://github.com/kubernetes-sigs/cri-tools/releases/download/v{version['CRICTL_VERSION']}/crictl-v{version['CRICTL_VERSION']}-linux-amd64.tar.gz",
                f"https://github.com/opencontainers/runc/releases/download/v{version['RUNC_VERSION']}/runc.amd64",
                f"https://github.com/containerd/nerdctl/releases/download/v{version['NERDCTL_VERSION']}/nerdctl-{version['NERDCTL_VERSION']}-linux-amd64.tar.gz",
                f"https://github.com/containerd/containerd/releases/download/v{version['CONTAINERD_VERSION']}/containerd-{version['CONTAINERD_VERSION']}-linux-amd64.tar.gz",
                f"https://github.com/cilium/cilium-cli/releases/download/v{version['CILIUM_CLI_VERSION']}/cilium-linux-amd64.tar.gz",
            ]
        )
        return urls

    def test_reviewed_lists_match_version_contract(self) -> None:
        version_file = ROOT / "config/required-versions.env"
        images = ROOT / "config/required-kubespray-images.txt"
        with tempfile.TemporaryDirectory() as temporary:
            files = Path(temporary) / "files.list"
            files.write_text(
                "".join(f"{url}\n" for url in self.reviewed_urls()),
                encoding="utf-8",
            )
            MODULE.verify(version_file, images, files)

    def test_drifted_component_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            versions = root / "versions.env"
            images = root / "images.list"
            files = root / "files.list"
            versions.write_text(
                (ROOT / "config/required-versions.env").read_text(),
                encoding="utf-8",
            )
            images.write_text(
                (ROOT / "config/required-kubespray-images.txt")
                .read_text()
                .replace("v1.19.3", "v1.19.4"),
                encoding="utf-8",
            )
            files.write_text(
                "".join(f"{url}\n" for url in self.reviewed_urls()),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "Cilium did not resolve"):
                MODULE.verify(versions, images, files)


if __name__ == "__main__":
    unittest.main()
