from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "filter_generated_lists", ROOT / "scripts/filter-generated-lists.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FilterGeneratedListsTests(unittest.TestCase):
    def test_images_are_reduced_to_required_sorted_entries(self) -> None:
        generated = ["unused:1", "required-b:2", "required-a:1"]
        required = ["required-b:2", "required-a:1"]
        self.assertEqual(
            [
                "docker.io/library/required-a:1",
                "docker.io/library/required-b:2",
            ],
            MODULE.filter_images(generated, required),
        )

    def test_short_docker_hub_name_is_normalized(self) -> None:
        self.assertEqual(
            ["docker.io/library/registry:3.1.0"],
            MODULE.filter_images(
                ["registry:3.1.0"], ["docker.io/library/registry:3.1.0"]
            ),
        )

    def test_missing_required_image_fails_closed(self) -> None:
        with self.assertRaisesRegex(MODULE.ListError, "missing required"):
            MODULE.filter_images(["required-a:1"], ["required-a:1", "required-b:2"])

    def test_duplicate_generated_image_fails_closed(self) -> None:
        with self.assertRaisesRegex(MODULE.ListError, "generated image list"):
            MODULE.filter_images(["required-a:1", "required-a:1"], ["required-a:1"])

    def test_file_patterns_each_match_exactly_one_generated_url(self) -> None:
        generated = [
            "https://example.invalid/binary-v2",
            "https://example.invalid/unused",
            "https://example.invalid/binary-v1",
        ]
        patterns = [
            r"^https://example\.invalid/binary-v1$",
            r"^https://example\.invalid/binary-v2$",
        ]
        self.assertEqual(
            [
                "https://example.invalid/binary-v1",
                "https://example.invalid/binary-v2",
            ],
            MODULE.filter_files(generated, patterns),
        )

    def test_ambiguous_file_pattern_fails_closed(self) -> None:
        with self.assertRaisesRegex(MODULE.ListError, "exactly one"):
            MODULE.filter_files(
                ["https://example.invalid/a", "https://example.invalid/b"],
                [r"^https://example\.invalid/[ab]$"],
            )


if __name__ == "__main__":
    unittest.main()
