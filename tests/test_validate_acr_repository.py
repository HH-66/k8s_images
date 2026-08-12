from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validate_acr_repository", ROOT / "scripts/validate-acr-repository.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ValidateACRRepositoryTests(unittest.TestCase):
    def test_valid_acr_repository_is_accepted(self) -> None:
        MODULE.validate("registry-vpc.cn-shanghai.aliyuncs.com/jasper/offline_base")

    def test_tag_digest_quotes_and_whitespace_are_rejected(self) -> None:
        for value in (
            "registry.example.com/jasper/offline:latest",
            "registry.example.com/jasper/offline@sha256:" + "a" * 64,
            "registry.example.com/jasper/off'line",
            "registry.example.com/jasper/off line",
            "registry.example.com/jasper/off;line",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.validate(value)
