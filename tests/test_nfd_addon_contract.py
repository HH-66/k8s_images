from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/nfd"


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class NFDAddonContractTests(unittest.TestCase):
    def test_versions_and_source_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("0.19.0", values["NFD_VERSION"])
        self.assertRegex(values["NFD_SOURCE_COMMIT"], r"^[0-9a-f]{40}$")
        self.assertRegex(values["NFD_CHART_SHA256"], r"^[0-9a-f]{64}$")
        self.assertRegex(
            values["NFD_IMAGE_AMD64_DIGEST"], r"^sha256:[0-9a-f]{64}$"
        )
        self.assertEqual("v0.19.0", values["NFD_IMAGE_TAG"])
        self.assertEqual("3.18.4", values["HELM_VERSION"])
        self.assertRegex(values["HELM_LINUX_AMD64_SHA256"], r"^[0-9a-f]{64}$")

    def test_values_enable_topology_updater_and_pin_the_amd64_image(self) -> None:
        values = env_values()
        config = yaml.safe_load((ADDON / "values.yaml").read_text(encoding="utf-8"))
        self.assertTrue(config["master"]["enable"])
        self.assertTrue(config["worker"]["enable"])
        self.assertTrue(config["topologyUpdater"]["enable"])
        self.assertTrue(config["topologyUpdater"]["createCRDs"])
        self.assertTrue(config["gc"]["enable"])
        self.assertEqual(
            "10.144.66.139:35000/nfd/node-feature-discovery",
            config["image"]["repository"],
        )
        self.assertEqual(
            "v0.19.0@" + values["NFD_IMAGE_AMD64_DIGEST"],
            config["image"]["tag"],
        )

    def test_builder_is_isolated_from_the_base_bundle(self) -> None:
        content = (ADDON / "scripts/build-bundle.sh").read_text(encoding="utf-8")
        self.assertIn('build/nfd', content)
        self.assertIn('dist/nfd', content)
        self.assertNotIn('kubespray-offline-base.tar.zst', content)
        self.assertIn("skopeo copy", content)
        self.assertIn('--policy "${addon_root}/containers-policy.json"', content)
        self.assertIn("--preserve-digests", content)
        self.assertIn('"oci-archive:${image_archive}:${NFD_IMAGE_TAG}"', content)
        self.assertIn("did not preserve the source manifest digest", content)
        self.assertIn('verify-nfd-bundle.sh', content)

    def test_payload_and_artifact_image_have_only_expected_files(self) -> None:
        dockerfile = (ADDON / "Dockerfile").read_text(encoding="utf-8")
        self.assertNotIn("FROM ubuntu", dockerfile)
        for name in (
            "jasper-k8s-nfd-offline.tar.zst",
            "provenance.json",
            "source-images.lock",
            "SHA256SUMS",
        ):
            self.assertIn(name, dockerfile)
        verifier = (ADDON / "payload/verify-nfd-bundle.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("sha256sum --check --strict SHA256SUMS", verifier)
        self.assertTrue(re.search(r"NFD provenance", verifier))

    def test_skopeo_policy_accepts_only_the_pinned_nfd_repository(self) -> None:
        policy = yaml.safe_load(
            (ADDON / "containers-policy.json").read_text(encoding="utf-8")
        )
        self.assertEqual([{"type": "reject"}], policy["default"])
        self.assertEqual(
            ["registry.k8s.io/nfd/node-feature-discovery"],
            list(policy["transports"]["docker"]),
        )


if __name__ == "__main__":
    unittest.main()
