from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/kuberay"


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class KubeRayAddonContractTests(unittest.TestCase):
    def test_sources_versions_and_amd64_manifests_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("1.6.2", values["KUBERAY_VERSION"])
        self.assertEqual("2.56.1", values["RAY_VERSION"])
        for name in (
            "KUBERAY_SOURCE_COMMIT",
            "KUBERAY_SOURCE_TREE",
            "KUBERAY_CHART_TREE",
            "RAY_SOURCE_COMMIT",
            "RAY_SOURCE_TREE",
        ):
            self.assertRegex(values[name], r"^[0-9a-f]{40}$")
        self.assertEqual(
            "48c75ab69eec4a15bd8700b9a04ba1d82dac8b93a51588bf8758cc656dcb3c6f",
            values["KUBERAY_CHART_SHA256"],
        )
        for name in (
            "KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST",
            "RAY_IMAGE_AMD64_DIGEST",
        ):
            self.assertRegex(values[name], r"^sha256:[0-9a-f]{64}$")

    def test_values_enable_required_operator_contract_only(self) -> None:
        values = yaml.safe_load((ADDON / "values.yaml").read_text(encoding="utf-8"))
        self.assertEqual(1, values["replicas"])
        self.assertEqual("jasper-service-high", values["priorityClassName"])
        self.assertTrue(values["leaderElectionEnabled"])
        self.assertFalse(values["batchScheduler"]["enabled"])
        self.assertEqual("", values["batchScheduler"]["name"])
        gates = {item["name"]: item["enabled"] for item in values["featureGates"]}
        self.assertTrue(gates["RayJobDeletionPolicy"])
        self.assertFalse(values["metrics"]["serviceMonitor"]["enabled"])
        self.assertEqual(values["resources"]["requests"], values["resources"]["limits"])

    def test_builder_and_payload_are_digest_pinned(self) -> None:
        script = ADDON / "scripts/build-bundle.sh"
        verifier = ADDON / "payload/verify-kuberay-bundle.sh"
        subprocess.run(["bash", "-n", script], check=True)
        subprocess.run(["bash", "-n", verifier], check=True)
        content = script.read_text(encoding="utf-8")
        self.assertEqual(2, content.count("--preserve-digests"))
        self.assertIn("KUBERAY_SOURCE_COMMIT", content)
        self.assertIn("KUBERAY_CHART_SHA256", content)
        self.assertIn("RAY_SOURCE_COMMIT", content)
        self.assertIn("verify-kuberay-bundle.sh", content)

    def test_frozen_chart_renders_only_local_operator_image(self) -> None:
        chart = Path("/tmp/kuberay-operator-1.6.2.tgz")
        helm = Path("/tmp/jasper-k8s-tools/helm")
        if not chart.is_file() or not helm.is_file():
            self.skipTest("local Helm or frozen KubeRay chart is unavailable")
        values = (ADDON / "values.yaml").read_text(encoding="utf-8").replace(
            "__KUBERAY_OPERATOR_IMAGE_AMD64_DIGEST__", "sha256:" + "a" * 64
        )
        with tempfile.TemporaryDirectory() as directory:
            values_path = Path(directory) / "values.yaml"
            values_path.write_text(values, encoding="utf-8")
            rendered = subprocess.run(
                [
                    helm,
                    "template",
                    "kuberay-operator",
                    chart,
                    "--namespace",
                    "kuberay-system",
                    "--values",
                    values_path,
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        self.assertNotIn("quay.io", rendered)
        self.assertIn("10.144.66.139:35000/kuberay/operator", rendered)


if __name__ == "__main__":
    unittest.main()
