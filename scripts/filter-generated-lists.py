#!/usr/bin/env python3
"""Reduce Kubespray's broad offline lists to the approved base-cluster profile."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


class ListError(RuntimeError):
    pass


def nonempty_lines(path: Path) -> list[str]:
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def require_unique(values: list[str], label: str) -> None:
    duplicates = sorted({value for value in values if values.count(value) > 1})
    if duplicates:
        raise ListError(f"{label} contains duplicates: {duplicates}")


def normalize_image(value: str) -> str:
    if "/" not in value.partition(":")[0]:
        return f"docker.io/library/{value}"
    first = value.split("/", 1)[0]
    if "." not in first and ":" not in first and first != "localhost":
        return f"docker.io/{value}"
    return value


def filter_images(generated: list[str], required: list[str]) -> list[str]:
    generated = [normalize_image(value) for value in generated]
    required = [normalize_image(value) for value in required]
    require_unique(generated, "generated image list")
    require_unique(required, "required image list")
    missing = sorted(set(required) - set(generated))
    if missing:
        raise ListError(f"generated image list is missing required entries: {missing}")
    return sorted(required)


def filter_files(generated: list[str], patterns: list[str]) -> list[str]:
    require_unique(generated, "generated file list")
    require_unique(patterns, "file allow pattern list")
    selected: list[str] = []
    for pattern_text in patterns:
        pattern = re.compile(pattern_text)
        matches = sorted(value for value in generated if pattern.fullmatch(value))
        if len(matches) != 1:
            raise ListError(
                "file allow patterns must each match exactly one generated URL; "
                f"pattern {pattern_text!r} matched {len(matches)} URLs: {matches}"
            )
        selected.append(matches[0])
    require_unique(selected, "file allow pattern selections")
    return sorted(selected)


def write_lines(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{value}\n" for value in values), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generated-images", required=True, type=Path)
    parser.add_argument("--required-images", required=True, type=Path)
    parser.add_argument("--generated-files", required=True, type=Path)
    parser.add_argument("--file-patterns", required=True, type=Path)
    parser.add_argument("--output-images", required=True, type=Path)
    parser.add_argument("--output-files", required=True, type=Path)
    args = parser.parse_args()

    try:
        images = filter_images(
            nonempty_lines(args.generated_images), nonempty_lines(args.required_images)
        )
        files = filter_files(
            nonempty_lines(args.generated_files), nonempty_lines(args.file_patterns)
        )
    except (OSError, UnicodeError, re.error, ListError) as error:
        parser.error(str(error))

    write_lines(args.output_images, images)
    write_lines(args.output_files, files)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
