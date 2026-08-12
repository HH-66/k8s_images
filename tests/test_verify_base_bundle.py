from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "payload/verify-base-bundle.sh"


class VerifyBaseBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.bundle = Path(self.temporary_directory.name)
        for relative_path in (
            "SHA256SUMS",
            "files/files.list",
            "images/images.list",
            "images/additional-images.list",
            "debs/local/Packages.gz",
        ):
            path = self.bundle / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("placeholder\n", encoding="utf-8")

    def verify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(VERIFY), str(self.bundle)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_missing_pypi_index_reports_served_path(self) -> None:
        result = self.verify()

        self.assertEqual(1, result.returncode)
        self.assertIn(
            f"required file is missing or empty: {self.bundle}/pypi/index.html",
            result.stderr,
        )
        self.assertNotIn("pypi/simple/index.html", result.stderr)

    def test_pypi_index_at_served_path_advances_verification(self) -> None:
        index = self.bundle / "pypi/index.html"
        index.parent.mkdir(parents=True)
        index.write_text("<html></html>\n", encoding="utf-8")

        result = self.verify()

        self.assertEqual(1, result.returncode)
        self.assertIn(
            "required file is missing or empty: "
            f"{self.bundle}/files/kubespray-2.31.0.tar.gz",
            result.stderr,
        )


if __name__ == "__main__":
    unittest.main()
