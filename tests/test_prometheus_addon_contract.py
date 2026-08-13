from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path
import re

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/prometheus"


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class PrometheusAddonContractTests(unittest.TestCase):
    def test_sources_versions_and_amd64_manifests_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("88.2.0", values["KUBE_PROMETHEUS_STACK_VERSION"])
        self.assertEqual(
            "18956245a31a887141bb31a040c145d6b5e6e056",
            values["KUBE_PROMETHEUS_STACK_SOURCE_COMMIT"],
        )
        self.assertEqual(
            "9e48c3b732eaf0636a0423504857b4c543b61bb883cf3291548ff4b9f3c14bbc",
            values["KUBE_PROMETHEUS_STACK_CHART_SHA256"],
        )
        digests = [
            value
            for key, value in values.items()
            if key.endswith("_IMAGE_AMD64_DIGEST")
        ]
        self.assertEqual(8, len(digests))
        for digest in digests:
            self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")

    def test_values_define_the_pilot_monitoring_contract(self) -> None:
        values = yaml.safe_load((ADDON / "values.yaml").read_text(encoding="utf-8"))
        spec = values["prometheus"]["prometheusSpec"]
        self.assertEqual("7d", spec["retention"])
        self.assertEqual("80GB", spec["retentionSize"])
        self.assertEqual({"sizeLimit": "100Gi"}, spec["storageSpec"]["emptyDir"])
        self.assertEqual(
            {"matchLabels": {"release": "kube-prometheus-stack"}},
            spec["podMonitorSelector"],
        )
        self.assertEqual(
            {"matchLabels": {"release": "kube-prometheus-stack"}},
            spec["serviceMonitorSelector"],
        )
        self.assertEqual(
            "jasper-opt-in-pods",
            values["prometheus"]["additionalPodMonitors"][0]["name"],
        )
        self.assertEqual(
            "nvidia-dcgm-exporter",
            values["prometheus"]["additionalServiceMonitors"][0]["name"],
        )
        self.assertFalse(values["prometheusOperator"]["admissionWebhooks"]["enabled"])
        self.assertFalse(values["prometheusOperator"]["tls"]["enabled"])
        self.assertFalse(values["grafana"]["persistence"]["enabled"])
        self.assertEqual(
            {"cpu": "100m", "memory": "256Mi"},
            values["grafana"]["sidecar"]["resources"]["requests"],
        )
        self.assertEqual(
            values["grafana"]["sidecar"]["resources"]["requests"],
            values["grafana"]["sidecar"]["resources"]["limits"],
        )
        self.assertEqual(10, values["grafana"]["readinessProbe"]["initialDelaySeconds"])

    def test_builder_and_payload_are_digest_pinned(self) -> None:
        script = ADDON / "scripts/build-bundle.sh"
        verifier = ADDON / "payload/verify-prometheus-bundle.sh"
        subprocess.run(["bash", "-n", script], check=True)
        subprocess.run(["bash", "-n", verifier], check=True)
        content = script.read_text(encoding="utf-8")
        self.assertEqual(1, content.count("copy_image()"))
        self.assertEqual(8, content.count("copy_image \"${"))
        self.assertIn("--preserve-digests", content)
        self.assertIn("verify-prometheus-bundle.sh", content)
        verifier_content = verifier.read_text(encoding="utf-8")
        self.assertIn("text = result.stdout", verifier_content)
        self.assertNotIn("rendered.read_text", verifier_content)

    def test_frozen_chart_renders_only_local_digest_images(self) -> None:
        chart = Path("/tmp/kube-prometheus-stack-88.2.0.tgz")
        helm = Path("/tmp/jasper-k8s-tools/helm")
        if not chart.is_file() or not helm.is_file():
            self.skipTest("local Helm or frozen kube-prometheus-stack chart is unavailable")
        content = (ADDON / "values.yaml").read_text(encoding="utf-8")
        for key, value in env_values().items():
            content = content.replace(
                f"__{key}_HEX__", value.removeprefix("sha256:")
            ).replace(f"__{key}__", value)
        self.assertNotIn("__", content)
        with tempfile.TemporaryDirectory() as directory:
            values_path = Path(directory) / "values.yaml"
            values_path.write_text(content, encoding="utf-8")
            rendered = subprocess.run(
                [
                    helm,
                    "template",
                    "kube-prometheus-stack",
                    chart,
                    "--namespace",
                    "monitoring",
                    "--values",
                    values_path,
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        images = re.findall(r'^\s*image:\s*["\']?([^"\'\s]+)', rendered, re.MULTILINE)
        self.assertTrue(images)
        for image in images:
            self.assertTrue(image.startswith("10.144.66.139:35000/"), image)
            self.assertIn("@sha256:", image)
        self.assertIn("retention: \"7d\"", rendered)
        self.assertIn("name: jasper-opt-in-pods", rendered)
        self.assertIn("name: nvidia-dcgm-exporter", rendered)


if __name__ == "__main__":
    unittest.main()
