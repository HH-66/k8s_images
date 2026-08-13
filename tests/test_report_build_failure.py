from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/report-build-failure.py"


class ReportBuildFailureTests(unittest.TestCase):
    def test_reports_only_the_last_thirty_lines_as_one_annotation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "build.log"
            log.write_text(
                "\n".join(f"line {number}%" for number in range(35)) + "\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                ["python3", SCRIPT, log],
                check=True,
                capture_output=True,
                text=True,
            )
        self.assertTrue(result.stdout.startswith("::error title=Bundle build failed::"))
        self.assertNotIn("line 4", result.stdout)
        self.assertIn("line 5%25%0Aline 6%25", result.stdout)
        self.assertIn("line 34%25", result.stdout)


if __name__ == "__main__":
    unittest.main()
