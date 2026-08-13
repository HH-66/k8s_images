from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/rancher"


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class RancherAddonContractTests(unittest.TestCase):
    def test_sources_versions_and_amd64_manifests_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("2.15.0", values["RANCHER_VERSION"])
        self.assertEqual(
            "9994cd93198c4b1692bcda733eb08d1e81c26eed",
            values["RANCHER_SOURCE_COMMIT"],
        )
        self.assertEqual(
            "59a589ad5b2c5bc11f6bc51fdd252f04725b21f3f4c2f76fb24452077f0552dd",
            values["RANCHER_CHART_SHA256"],
        )
        digests = [
            value
            for key, value in values.items()
            if key.endswith("_IMAGE_AMD64_DIGEST")
        ]
        self.assertEqual(7, len(digests))
        for digest in digests:
            self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")

    def test_values_define_https_nodeport_pilot_without_ingress(self) -> None:
        values = yaml.safe_load((ADDON / "values.yaml").read_text(encoding="utf-8"))
        self.assertEqual("10.144.66.139", values["hostname"])
        self.assertEqual("none", values["networkExposure"]["type"])
        self.assertFalse(values["ingress"]["enabled"])
        self.assertEqual("rancher", values["ingress"]["tls"]["source"])
        self.assertEqual("ingress", values["tls"])
        self.assertEqual(
            {"type": "NodePort", "disableHTTP": True}, values["service"]
        )
        self.assertEqual(1, values["replicas"])
        self.assertEqual("jasper-service-high", values["priorityClassName"])
        self.assertEqual("10.144.66.139:35000", values["systemDefaultRegistry"])
        self.assertTrue(values["useBundledSystemChart"])
        self.assertFalse(values["postDelete"]["enabled"])
        self.assertEqual(
            "v2.15.0@sha256:59d2643bdf3b76bfbc90410aff1f2b08765ac741d3d2349673381dcd685bf5f1",
            values["image"]["tag"],
        )

    def test_builder_and_payload_are_digest_pinned(self) -> None:
        builder = ADDON / "scripts/build-bundle.sh"
        verifier = ADDON / "payload/verify-rancher-bundle.sh"
        renderer = ADDON / "payload/post-render-rancher.py"
        subprocess.run(["bash", "-n", builder], check=True)
        subprocess.run(["bash", "-n", verifier], check=True)
        subprocess.run(["python3", "-m", "py_compile", renderer], check=True)
        content = builder.read_text(encoding="utf-8")
        self.assertEqual(7, content.count('copy_image "${'))
        self.assertIn("--preserve-digests", content)
        self.assertIn("verify-rancher-bundle.sh", content)

    def test_post_renderer_removes_only_issuer_and_sets_nodeport(self) -> None:
        documents = [
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {"name": "rancher"},
                "spec": {
                    "type": "NodePort",
                    "ports": [
                        {
                            "port": 443,
                            "targetPort": 443,
                            "protocol": "TCP",
                            "name": "https",
                        }
                    ],
                },
            },
            {
                "apiVersion": "cert-manager.io/v1",
                "kind": "Issuer",
                "metadata": {"name": "rancher"},
                "spec": {"ca": {"secretName": "tls-rancher"}},
            },
            {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "keep"}},
        ]
        result = subprocess.run(
            ["python3", ADDON / "payload/post-render-rancher.py"],
            input=yaml.safe_dump_all(documents, explicit_start=True, sort_keys=False),
            check=True,
            capture_output=True,
            text=True,
        )
        rendered = [item for item in yaml.safe_load_all(result.stdout) if item]
        self.assertEqual(["Service", "ConfigMap"], [item["kind"] for item in rendered])
        self.assertEqual(30443, rendered[0]["spec"]["ports"][0]["nodePort"])

    def test_frozen_chart_renders_expected_network_and_tls_contract(self) -> None:
        chart = Path("/tmp/rancher-2.15.0.tgz")
        helm = Path("/tmp/jasper-k8s-tools/helm")
        if not chart.is_file() or not helm.is_file():
            self.skipTest("local Helm or frozen Rancher chart is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            rendered = subprocess.run(
                [
                    helm,
                    "template",
                    "rancher",
                    chart,
                    "--namespace",
                    "cattle-system",
                    "--values",
                    ADDON / "values.yaml",
                    "--post-renderer",
                    ADDON / "payload/post-render-rancher.py",
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        documents = [item for item in yaml.safe_load_all(rendered) if item]
        kinds = {item["kind"] for item in documents}
        self.assertFalse(kinds & {"Ingress", "Gateway", "HTTPRoute", "Issuer", "Certificate"})
        service = next(
            item
            for item in documents
            if item["kind"] == "Service" and item["metadata"]["name"] == "rancher"
        )
        self.assertEqual(30443, service["spec"]["ports"][0]["nodePort"])
        deployment = next(
            item
            for item in documents
            if item["kind"] == "Deployment" and item["metadata"]["name"] == "rancher"
        )
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        self.assertNotIn("--no-cacerts", container["args"])


if __name__ == "__main__":
    unittest.main()
