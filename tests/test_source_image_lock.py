from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "source_image_lock", ROOT / "scripts/source-image-lock.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SourceImageLockTests(unittest.TestCase):
    @mock.patch.object(MODULE.subprocess, "run")
    def test_index_locks_the_linux_amd64_child_manifest(self, run) -> None:
        amd64 = "sha256:" + "a" * 64
        run.return_value.stdout = json.dumps(
            {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "manifests": [
                    {
                        "digest": amd64,
                        "platform": {"os": "linux", "architecture": "amd64"},
                    },
                    {
                        "digest": "sha256:" + "b" * 64,
                        "platform": {"os": "linux", "architecture": "arm64"},
                    },
                ],
            }
        ).encode()
        self.assertEqual(
            amd64, MODULE.inspect_linux_amd64_digest("registry.example/repo:tag")
        )

    @mock.patch.object(MODULE.subprocess, "run")
    def test_index_without_one_linux_amd64_child_is_rejected(self, run) -> None:
        run.return_value.stdout = json.dumps(
            {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "manifests": [],
            }
        ).encode()
        with self.assertRaisesRegex(RuntimeError, "exactly one linux/amd64"):
            MODULE.inspect_linux_amd64_digest("registry.example/repo:tag")
