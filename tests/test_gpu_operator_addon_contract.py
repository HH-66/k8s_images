from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/gpu-operator"
HELM = Path("/tmp/jasper-k8s-tools/helm")
LOCAL_CHART = Path("/tmp/gpu-operator-v26.3.3.tgz")


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class GPUOperatorAddonContractTests(unittest.TestCase):
    def test_versions_sources_and_amd64_manifests_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("26.3.3", values["GPU_OPERATOR_VERSION"])
        self.assertEqual(
            "b0a49c0e7b2e061dcd83f2bb2fe4fe960c5d0338",
            values["GPU_OPERATOR_SOURCE_COMMIT"],
        )
        self.assertEqual(
            "9a0c55839ab61b890487f1bb7173216e518fbf45",
            values["GPU_OPERATOR_SIGNED_TAG_OBJECT"],
        )
        self.assertRegex(values["GPU_OPERATOR_CHART_SHA256"], r"^[0-9a-f]{64}$")
        for name in (
            "GPU_OPERATOR_IMAGE_AMD64_DIGEST",
            "TOOLKIT_IMAGE_AMD64_DIGEST",
            "DEVICE_PLUGIN_IMAGE_AMD64_DIGEST",
            "DCGM_EXPORTER_IMAGE_AMD64_DIGEST",
        ):
            self.assertRegex(values[name], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual("3.18.4", values["HELM_VERSION"])
        self.assertEqual("h139-gpu-operator-r1", values["ADDON_PROFILE"])

    def test_values_enable_only_the_host_driver_pilot_components(self) -> None:
        config = yaml.safe_load((ADDON / "values.yaml").read_text(encoding="utf-8"))
        self.assertFalse(config["nfd"]["enabled"])
        self.assertFalse(config["driver"]["enabled"])
        self.assertEqual("none", config["mig"]["strategy"])
        for name in ("toolkit", "devicePlugin", "gfd", "dcgmExporter"):
            self.assertTrue(config[name]["enabled"], name)
        for name in (
            "dcgm",
            "migManager",
            "nodeStatusExporter",
            "gds",
            "gdrcopy",
            "vgpuManager",
            "vgpuDeviceManager",
            "vfioManager",
            "kataManager",
            "sandboxWorkloads",
            "sandboxDevicePlugin",
            "kataSandboxDevicePlugin",
            "ccManager",
        ):
            self.assertFalse(config[name]["enabled"], name)
        self.assertEqual(
            "system-node-critical", config["operator"]["priorityClassName"]
        )
        self.assertEqual(
            "system-node-critical", config["daemonsets"]["priorityClassName"]
        )
        self.assertFalse(config["operator"]["cleanupCRD"])
        self.assertFalse(config["operator"]["upgradeCRD"])
        self.assertFalse(config["dcgmExporter"]["serviceMonitor"]["enabled"])

    def test_values_have_no_public_registry_fallback(self) -> None:
        content = (ADDON / "values.yaml").read_text(encoding="utf-8")
        for forbidden in ("nvcr.io", "registry.k8s.io", "docker.io", "quay.io"):
            self.assertNotIn(forbidden, content)
        config = yaml.safe_load(content)
        expected_prefix = "10.144.66.139:35000/"
        for name in (
            "validator",
            "operator",
            "driver",
            "toolkit",
            "devicePlugin",
            "gfd",
            "dcgm",
            "dcgmExporter",
            "migManager",
            "nodeStatusExporter",
            "gds",
            "gdrcopy",
            "vgpuManager",
            "vgpuDeviceManager",
            "vfioManager",
            "kataManager",
            "sandboxDevicePlugin",
            "kataSandboxDevicePlugin",
            "ccManager",
        ):
            self.assertTrue(
                config[name]["repository"].startswith(expected_prefix), name
            )
            self.assertRegex(config[name]["version"], r"@sha256:[0-9a-f]{64}$")
        for name in ("driver", "vgpuManager", "vfioManager"):
            manager = config[name]["manager" if name == "driver" else "driverManager"]
            self.assertTrue(manager["repository"].startswith(expected_prefix), name)
            self.assertRegex(manager["version"], r"@sha256:[0-9a-f]{64}$")

    def test_builder_downloads_exactly_four_preserved_amd64_archives(self) -> None:
        content = (ADDON / "scripts/build-bundle.sh").read_text(encoding="utf-8")
        self.assertIn("build/gpu-operator", content)
        self.assertIn("dist/gpu-operator", content)
        self.assertEqual(
            4, len(re.findall(r"^  copy_image \\\n", content, re.MULTILINE))
        )
        self.assertIn('--policy "${addon_root}/containers-policy.json"', content)
        self.assertIn("--preserve-digests", content)
        self.assertIn('"oci-archive:${archive}:${source_tag}" >&2', content)
        self.assertIn("did not preserve the source manifest digest", content)
        self.assertIn("verify-gpu-operator-bundle.sh", content)

    def test_payload_and_artifact_image_have_only_expected_files(self) -> None:
        dockerfile = (ADDON / "Dockerfile").read_text(encoding="utf-8")
        self.assertNotIn("FROM ubuntu", dockerfile)
        for name in (
            "jasper-k8s-gpu-operator-offline.tar.zst",
            "provenance.json",
            "source-images.lock",
            "SHA256SUMS",
        ):
            self.assertIn(name, dockerfile)
        verifier = (ADDON / "payload/verify-gpu-operator-bundle.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("sha256sum --check --strict SHA256SUMS", verifier)
        self.assertIn("unexpected GPU Operator provenance", verifier)

    def test_skopeo_policy_accepts_only_the_four_pinned_repositories(self) -> None:
        policy = yaml.safe_load(
            (ADDON / "containers-policy.json").read_text(encoding="utf-8")
        )
        self.assertEqual([{"type": "reject"}], policy["default"])
        self.assertEqual(
            {
                "nvcr.io/nvidia/gpu-operator",
                "nvcr.io/nvidia/k8s/container-toolkit",
                "nvcr.io/nvidia/k8s-device-plugin",
                "nvcr.io/nvidia/k8s/dcgm-exporter",
            },
            set(policy["transports"]["docker"]),
        )

    @unittest.skipUnless(
        HELM.is_file() and LOCAL_CHART.is_file(),
        "local Helm/chart evidence is unavailable",
    )
    def test_frozen_chart_renders_only_local_digest_pinned_images(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "rendered.yaml"
            with output.open("wb") as handle:
                subprocess.run(
                    [
                        HELM,
                        "template",
                        "gpu-operator",
                        LOCAL_CHART,
                        "--namespace",
                        "gpu-operator",
                        "--values",
                        ADDON / "values.yaml",
                    ],
                    check=True,
                    stdout=handle,
                )
            rendered = output.read_text(encoding="utf-8")
            documents = list(yaml.safe_load_all(rendered))
        workload_images: set[str] = set()

        def collect_pod_spec(spec: dict[str, object]) -> None:
            for field in ("initContainers", "containers", "ephemeralContainers"):
                for container in spec.get(field, []):
                    if isinstance(container, dict) and isinstance(
                        container.get("image"), str
                    ):
                        workload_images.add(container["image"])

        for document in documents:
            if not isinstance(document, dict):
                continue
            kind = document.get("kind")
            spec = document.get("spec", {})
            if kind in {"Deployment", "DaemonSet", "StatefulSet", "Job"}:
                template = spec.get("template", {})
                collect_pod_spec(template.get("spec", {}))
            elif kind == "CronJob":
                template = (
                    spec.get("jobTemplate", {}).get("spec", {}).get("template", {})
                )
                collect_pod_spec(template.get("spec", {}))
        self.assertEqual(
            {
                "10.144.66.139:35000/nvidia/gpu-operator:v26.3.3@sha256:ca6cbd45e11779164aa89fa9d20517bce4717b9a772f168a3c492075aad0abfe"
            },
            workload_images,
        )
        cluster_policy = next(
            document
            for document in documents
            if isinstance(document, dict) and document.get("kind") == "ClusterPolicy"
        )
        policy_text = yaml.safe_dump(cluster_policy["spec"], sort_keys=False)
        deployment = next(
            document
            for document in documents
            if isinstance(document, dict)
            and document.get("kind") == "Deployment"
            and document.get("metadata", {}).get("name") == "gpu-operator"
        )
        deployment_text = yaml.safe_dump(deployment["spec"], sort_keys=False)
        for forbidden in ("nvcr.io", "registry.k8s.io", "docker.io", "quay.io"):
            self.assertNotIn(forbidden, policy_text)
            self.assertNotIn(forbidden, deployment_text)


if __name__ == "__main__":
    unittest.main()
