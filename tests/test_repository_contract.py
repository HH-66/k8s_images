from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def lines(path: str) -> list[str]:
    return [
        line.strip()
        for line in (ROOT / path).read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


class RepositoryContractTests(unittest.TestCase):
    def test_version_pins_are_exact(self) -> None:
        values = dict(line.split("=", 1) for line in lines("versions.env"))
        self.assertEqual("2.31.0", values["KUBESPRAY_OFFLINE_VERSION"])
        self.assertRegex(values["KUBESPRAY_OFFLINE_COMMIT"], r"^[0-9a-f]{40}$")
        self.assertEqual("2.31.0", values["KUBESPRAY_VERSION"])
        self.assertRegex(values["KUBESPRAY_COMMIT"], r"^[0-9a-f]{40}$")
        self.assertEqual("1.35.4", values["KUBERNETES_VERSION"])

    def test_base_cluster_has_no_addons(self) -> None:
        profile = (ROOT / "config/base-cluster.yml").read_text(encoding="utf-8")
        self.assertIn("kube_network_plugin: cilium\n", profile)
        self.assertIn("container_manager: containerd\n", profile)
        for key in (
            "helm_enabled",
            "registry_enabled",
            "metrics_server_enabled",
            "local_path_provisioner_enabled",
            "local_volume_provisioner_enabled",
            "cert_manager_enabled",
            "gateway_api_enabled",
            "prometheus_operator_crds_enabled",
            "kube_network_plugin_multus",
        ):
            self.assertIn(f"{key}: false\n", profile, key)

    def test_required_lists_are_unique_and_pinned(self) -> None:
        images = lines("config/required-kubespray-images.txt") + lines(
            "config/required-bootstrap-images.txt"
        )
        self.assertEqual(len(images), len(set(images)))
        self.assertTrue(all(re.search(r":[^/:]+$", image) for image in images))
        self.assertEqual(sorted(images), sorted(lines("payload/required-images.txt")))
        self.assertEqual(
            lines("config/required-files.txt"), lines("payload/required-files.txt")
        )

    def test_workflow_has_no_h139_deployment_and_no_latest_tag(self) -> None:
        content = (ROOT / ".github/workflows/build-and-push-acr.yml").read_text()
        self.assertNotIn("ssh ", content)
        self.assertNotIn(":latest", content)
        self.assertIn("docker login", content)
        self.assertIn("--password-stdin", content)
        self.assertIn("@${digest}", content)
        self.assertIn(
            "ACR_IMAGE: registry.cn-shenzhen.aliyuncs.com/liuhh/k8s-images",
            content,
        )
        self.assertNotIn("${{ vars.", content)
        self.assertIn("Digest:[[:space:]]*", content)
        self.assertNotIn("--raw | sha256sum", content)

    def test_list_generation_reuses_prepared_ansible_venv(self) -> None:
        content = (ROOT / "scripts/build-bundle.sh").read_text()
        prepare = content.index("./prepare-py.sh")
        activate = content.index('source "${offline_source}/.venv/bin/activate"')
        generate = content.index("./contrib/offline/generate_list.sh")
        self.assertLess(prepare, activate)
        self.assertLess(activate, generate)
        self.assertEqual(1, content.count("./prepare-pkgs.sh"))
        self.assertEqual(1, content.count("./prepare-py.sh"))

    def test_kubespray_archive_contains_an_exact_source_marker(self) -> None:
        content = (ROOT / "scripts/build-bundle.sh").read_text()
        self.assertIn(".jasper-kubespray-source.json", content)
        self.assertIn('"source": "kubernetes-sigs/kubespray"', content)
        self.assertIn('"commit": sys.argv[3]', content)

    def test_upstream_additional_image_list_is_replaced_by_the_reviewed_list(
        self,
    ) -> None:
        content = (ROOT / "scripts/build-bundle.sh").read_text()
        replace = content.index('"${offline_source}/imagelists/jasper-base.txt"')
        download = content.index("./download-additional-containers.sh")
        self.assertLess(replace, download)
        self.assertIn("! -name jasper-base.txt -delete", content)


if __name__ == "__main__":
    unittest.main()
