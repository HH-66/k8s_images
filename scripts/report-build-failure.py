#!/usr/bin/env python3
"""Expose a bounded, non-secret bundle build failure in the run annotation."""

from __future__ import annotations

import sys
from pathlib import Path


def escape_workflow_command(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: report-build-failure.py BUILD_LOG")
    lines = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
    diagnostic = "\n".join(lines[-30:]) or "bundle builder exited without output"
    print(f"::error title=Bundle build failed::{escape_workflow_command(diagnostic)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
