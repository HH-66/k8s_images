from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/scheduler-plugins"
HELM = Path("/tmp/jasper-k8s-tools/helm")
LOCAL_CHART = Path("/tmp/scheduler-plugins-0.35.4-devel.tgz")


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class SchedulerPluginsAddonContractTests(unittest.TestCase):
    def test_devel_tag_and_kubernetes_compatibility_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("0.35.4-devel", values["SCHEDULER_PLUGINS_VERSION"])
        for name in (
            "SCHEDULER_PLUGINS_TAG_OBJECT",
            "SCHEDULER_PLUGINS_SOURCE_COMMIT",
            "SCHEDULER_PLUGINS_SOURCE_TREE",
            "SCHEDULER_PLUGINS_CHART_TREE",
        ):
            self.assertRegex(values[name], r"^[0-9a-f]{40}$")
        self.assertRegex(values["SCHEDULER_PLUGINS_LICENSE_SHA256"], r"^[0-9a-f]{64}$")
        self.assertIn("@sha256:", values["GO_BASE_IMAGE"])
        self.assertIn("@sha256:", values["DISTROLESS_BASE_IMAGE"])
        self.assertEqual("h139-scheduler-plugins-r1", values["ADDON_PROFILE"])
        self.assertEqual("v1.35.4", values["KUBERNETES_BINARY_VERSION"])

    def test_values_enable_only_nrt_match_with_overreserve_cache(self) -> None:
        config = yaml.safe_load((ADDON / "values.yaml").read_text(encoding="utf-8"))
        self.assertEqual("topology-aware-scheduler", config["scheduler"]["name"])
        self.assertEqual(1, config["scheduler"]["replicaCount"])
        self.assertTrue(config["scheduler"]["leaderElect"])
        self.assertEqual(0, config["controller"]["replicaCount"])
        self.assertEqual(config["scheduler"]["image"], config["controller"]["image"])
        self.assertTrue(
            config["scheduler"]["image"].endswith(
                "@__SCHEDULER_IMAGE_AMD64_DIGEST__"
            )
        )
        self.assertEqual(["NodeResourceTopologyMatch"], config["plugins"]["enabled"])
        args = config["pluginConfig"][0]["args"]
        self.assertEqual(5, args["cacheResyncPeriodSeconds"])
        self.assertEqual("OnlyExclusiveResources", args["cache"]["foreignPodsDetect"])
        self.assertEqual("OnlyExclusiveResources", args["cache"]["resyncMethod"])

    def test_builder_uses_exact_source_and_builds_only_the_scheduler(self) -> None:
        content = (ADDON / "scripts/build-bundle.sh").read_text(encoding="utf-8")
        self.assertIn('checkout --detach "${SCHEDULER_PLUGINS_SOURCE_COMMIT}"', content)
        self.assertIn("k8s\\.io/kubernetes v1\\.35\\.4", content)
        self.assertIn('build/scheduler/Dockerfile', content)
        self.assertNotIn('build/controller/Dockerfile', content)
        self.assertIn('VERSION={sys.argv[3]}', content)
        self.assertIn('Kubernetes ${KUBERNETES_BINARY_VERSION}', content)
        self.assertIn('--entrypoint /bin/kube-scheduler', content)
        self.assertIn('skopeo copy', content)
        self.assertIn('scheduler_digest=$(python3 -', content)
        self.assertIn('upstream_tag_signed', content)

    def test_payload_contains_license_and_exact_provenance(self) -> None:
        dockerfile = (ADDON / "Dockerfile").read_text(encoding="utf-8")
        self.assertNotIn("FROM ubuntu", dockerfile)
        self.assertIn("jasper-k8s-scheduler-plugins-offline.tar.zst", dockerfile)
        verifier = (ADDON / "payload/verify-scheduler-plugins-bundle.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("scheduler-plugins-Apache-2.0.txt", verifier)
        self.assertIn("upstream_tag_signed", verifier)
        self.assertIn("sha256sum --check --strict SHA256SUMS", verifier)

    @unittest.skipUnless(
        HELM.is_file() and LOCAL_CHART.is_file(),
        "local Helm/chart evidence is unavailable",
    )
    def test_frozen_chart_renders_only_the_local_scheduler_image(self) -> None:
        values = (
            (ADDON / "values.yaml")
            .read_text(encoding="utf-8")
            .replace(
                "__SCHEDULER_IMAGE_AMD64_DIGEST__",
                "sha256:" + "a" * 64,
            )
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "rendered.yaml"
            values_path = Path(directory) / "values.yaml"
            values_path.write_text(values, encoding="utf-8")
            with output.open("wb") as handle:
                subprocess.run(
                    [
                        HELM,
                        "template",
                        "scheduler-plugins",
                        LOCAL_CHART,
                        "--namespace",
                        "scheduler-plugins",
                        "--values",
                        values_path,
                    ],
                    check=True,
                    stdout=handle,
                )
            rendered = output.read_text(encoding="utf-8")
        self.assertNotIn("registry.k8s.io", rendered)
        self.assertNotIn("controller:v", rendered)
        self.assertIn("NodeResourceTopologyMatch", rendered)
        self.assertIn("OnlyExclusiveResources", rendered)
        self.assertEqual(
            2,
            len(re.findall(r"image: 10\.144\.66\.139:35000/scheduler-plugins/", rendered)),
        )


if __name__ == "__main__":
    unittest.main()
