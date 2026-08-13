from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/kueue"


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class KueueAddonContractTests(unittest.TestCase):
    def test_versions_and_upstream_evidence_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("0.19.0", values["KUEUE_VERSION"])
        for name in (
            "KUEUE_TAG_OBJECT",
            "KUEUE_SOURCE_COMMIT",
            "KUEUE_SOURCE_TREE",
        ):
            self.assertRegex(values[name], r"^[0-9a-f]{40}$")
        self.assertEqual(
            "bf87087a393ffb3f9e696437d3527d35a9b9e13857169ff0eea3a1403c659857",
            values["KUEUE_CHART_SHA256"],
        )
        self.assertEqual("registry.k8s.io/kueue/kueue", values["KUEUE_IMAGE"])
        self.assertEqual("v0.19.0", values["KUEUE_IMAGE_TAG"])
        self.assertEqual("h139-kueue-r2", values["ADDON_PROFILE"])
        self.assertRegex(values["KUEUE_IMAGE_AMD64_DIGEST"], r"^sha256:[0-9a-f]{64}$")

    def test_values_enable_only_the_available_job_integration(self) -> None:
        values = yaml.safe_load((ADDON / "values.yaml").read_text(encoding="utf-8"))
        self.assertFalse(values["enablePrometheus"])
        self.assertFalse(values["enableCertManager"])
        self.assertEqual(1, values["controllerManager"]["replicas"])
        manager = values["controllerManager"]["manager"]
        self.assertEqual("system-cluster-critical", manager["priorityClassName"])
        self.assertEqual(manager["resources"]["requests"], manager["resources"]["limits"])
        config = yaml.safe_load(values["managerConfig"]["controllerManagerConfigYaml"])
        self.assertEqual(["batch/job"], config["integrations"]["frameworks"])
        self.assertTrue(config["waitForPodsReady"]["blockAdmission"])

    def test_builder_is_digest_pinned_and_verifies_the_bundle(self) -> None:
        script = ADDON / "scripts/build-bundle.sh"
        subprocess.run(["bash", "-n", script], check=True)
        content = script.read_text(encoding="utf-8")
        self.assertIn("${KUEUE_CHART_SHA256}", content)
        self.assertIn("${KUEUE_IMAGE_AMD64_DIGEST}", content)
        self.assertIn("--preserve-digests", content)
        self.assertIn("verify-kueue-bundle.sh", content)

    def test_frozen_release_chart_renders_only_the_local_image(self) -> None:
        chart = Path("/tmp/kueue-0.19.0.tgz")
        helm = Path("/tmp/jasper-k8s-tools/helm")
        if not chart.is_file() or not helm.is_file():
            self.skipTest("local Helm or frozen release chart is unavailable")
        values = (ADDON / "values.yaml").read_text(encoding="utf-8").replace(
            "__KUEUE_IMAGE_AMD64_DIGEST__", "sha256:" + "a" * 64
        )
        with tempfile.TemporaryDirectory() as directory:
            values_path = Path(directory) / "values.yaml"
            values_path.write_text(values, encoding="utf-8")
            rendered = subprocess.run(
                [
                    helm,
                    "template",
                    "kueue",
                    chart,
                    "--namespace",
                    "kueue-system",
                    "--values",
                    values_path,
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        self.assertNotIn("registry.k8s.io", rendered)
        self.assertIn("10.144.66.139:35000/kueue/kueue", rendered)
        self.assertNotIn("ray.io/rayjob", rendered)

    def test_artifact_is_scratch_and_contains_provenance(self) -> None:
        dockerfile = (ADDON / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("FROM scratch", dockerfile)
        self.assertIn("jasper-k8s-kueue-offline.tar.zst", dockerfile)
        verifier = (ADDON / "payload/verify-kueue-bundle.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("upstream_tag_signed", verifier)
        self.assertIn("ray.io/rayjob", verifier)
        self.assertIn("sha256sum --check --strict SHA256SUMS", verifier)


if __name__ == "__main__":
    unittest.main()
