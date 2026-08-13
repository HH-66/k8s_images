from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/kubepi"


def env_values() -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in (ADDON / "versions.env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )


class KubePiAddonContractTests(unittest.TestCase):
    def test_versions_sources_images_and_licenses_are_exact(self) -> None:
        values = env_values()
        self.assertEqual("2.0.2", values["KUBEPI_VERSION"])
        self.assertEqual(
            "4bced650e1381714e9cd3ab2d4e604bc77d4aa84",
            values["KUBEPI_SOURCE_COMMIT"],
        )
        self.assertRegex(values["KUBEPI_SOURCE_TREE"], r"^[0-9a-f]{40}$")
        self.assertRegex(values["KUBEPI_LICENSE_SHA256"], r"^[0-9a-f]{64}$")
        self.assertEqual("v2.0.2", values["KUBEPI_IMAGE_TAG"])
        self.assertRegex(
            values["KUBEPI_IMAGE_AMD64_DIGEST"], r"^sha256:[0-9a-f]{64}$"
        )
        self.assertEqual("1.30.4-alpine3.24", values["NGINX_VERSION"])
        self.assertRegex(values["NGINX_DOCKER_SOURCE_COMMIT"], r"^[0-9a-f]{40}$")
        self.assertRegex(values["NGINX_LICENSE_SHA256"], r"^[0-9a-f]{64}$")
        self.assertRegex(
            values["NGINX_IMAGE_AMD64_DIGEST"], r"^sha256:[0-9a-f]{64}$"
        )

    def test_manifest_is_private_hardened_burstable_and_cluster_admin(self) -> None:
        documents = list(
            yaml.safe_load_all(
                (ADDON / "manifests/kubepi-core.yaml").read_text(encoding="utf-8")
            )
        )
        binding = next(item for item in documents if item["kind"] == "ClusterRoleBinding")
        self.assertEqual("cluster-admin", binding["roleRef"]["name"])
        deployment = next(item for item in documents if item["kind"] == "Deployment")
        spec = deployment["spec"]["template"]["spec"]
        self.assertEqual("kubepi", spec["serviceAccountName"])
        self.assertEqual("jasper-service-default", spec["priorityClassName"])
        self.assertEqual("h139", spec["nodeSelector"]["kubernetes.io/hostname"])
        init_containers = {item["name"]: item for item in spec["initContainers"]}
        self.assertEqual(
            ["/bin/sh", "-c"], init_containers["prepare-config"]["command"]
        )
        self.assertIn(
            "cp /config-source/app.yml /config-runtime/app.yml",
            init_containers["prepare-config"]["args"][0],
        )
        containers = {item["name"]: item for item in spec["containers"]}
        self.assertEqual(2, len(containers))
        self.assertFalse(containers["kubepi"]["securityContext"]["privileged"])
        self.assertFalse(
            containers["kubepi"]["securityContext"]["allowPrivilegeEscalation"]
        )
        self.assertEqual("kubepi-server", containers["kubepi"]["args"][0])
        self.assertEqual("127.0.0.1", containers["kubepi"]["args"][4])
        mounts = {
            item["name"]: item for item in containers["kubepi"]["volumeMounts"]
        }
        self.assertEqual("/etc/kubepi", mounts["runtime-config"]["mountPath"])
        self.assertNotIn("readOnly", mounts["runtime-config"])
        volumes = {item["name"]: item for item in spec["volumes"]}
        self.assertEqual(
            "kubepi-runtime", volumes["runtime-config-source"]["secret"]["secretName"]
        )
        self.assertEqual({}, volumes["runtime-config"]["emptyDir"])
        self.assertEqual(["/usr/sbin/nginx"], containers["tls-proxy"]["command"])
        self.assertNotEqual(
            containers["kubepi"]["resources"]["requests"],
            containers["kubepi"]["resources"]["limits"],
        )
        service = next(item for item in documents if item["kind"] == "Service")
        self.assertEqual("ClusterIP", service["spec"]["type"])
        nodeport = yaml.safe_load(
            (ADDON / "manifests/kubepi-nodeport.yaml").read_text(encoding="utf-8")
        )
        self.assertEqual(30444, nodeport["spec"]["ports"][0]["nodePort"])

    def test_builder_and_verifier_are_offline_bundle_scoped(self) -> None:
        builder_path = ADDON / "scripts/build-bundle.sh"
        verifier_path = ADDON / "payload/verify-kubepi-bundle.sh"
        subprocess.run(["bash", "-n", builder_path], check=True)
        subprocess.run(["bash", "-n", verifier_path], check=True)
        builder = builder_path.read_text(encoding="utf-8")
        self.assertIn("build/kubepi", builder)
        self.assertIn("dist/kubepi", builder)
        self.assertEqual(2, builder.count("copy_image \"${"))
        self.assertIn("--preserve-digests", builder)
        self.assertIn("verify-kubepi-bundle.sh", builder)
        self.assertNotIn("kubectl", builder)
        self.assertNotIn("ssh ", builder)
        verifier = verifier_path.read_text(encoding="utf-8")
        self.assertIn("sha256sum --check --strict SHA256SUMS", verifier)
        self.assertIn("KubePi pilot must not use privileged containers", verifier)
        self.assertIn("KubePi core service must remain private", verifier)

    def test_skopeo_policy_accepts_only_two_pinned_repositories(self) -> None:
        policy = yaml.safe_load(
            (ADDON / "containers-policy.json").read_text(encoding="utf-8")
        )
        self.assertEqual([{"type": "reject"}], policy["default"])
        self.assertEqual(
            {"docker.io/1panel/kubepi", "docker.io/library/nginx"},
            set(policy["transports"]["docker"]),
        )

    def test_artifact_image_is_scratch_and_contains_provenance(self) -> None:
        dockerfile = (ADDON / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("FROM scratch", dockerfile)
        for name in (
            "jasper-k8s-kubepi-offline.tar.zst",
            "provenance.json",
            "source-images.lock",
            "SHA256SUMS",
        ):
            self.assertIn(name, dockerfile)


if __name__ == "__main__":
    unittest.main()
