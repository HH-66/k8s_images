#!/usr/bin/env python3
"""Create a lock of the exact source image manifests used by the bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
INDEX_MEDIA_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


def read_images(paths: list[Path]) -> list[str]:
    images: list[str] = []
    for path in paths:
        images.extend(
            line.strip()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        )
    if len(images) != len(set(images)):
        raise RuntimeError("source image lists contain duplicate entries")
    return sorted(images)


def inspect_linux_amd64_digest(image: str) -> str:
    result = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", image, "--raw"],
        check=True,
        capture_output=True,
    )
    document = json.loads(result.stdout)
    media_type = document.get("mediaType", "")
    if media_type in INDEX_MEDIA_TYPES:
        matches = [
            descriptor
            for descriptor in document.get("manifests", [])
            if descriptor.get("platform", {}).get("os") == "linux"
            and descriptor.get("platform", {}).get("architecture") == "amd64"
            and not descriptor.get("platform", {}).get("variant")
        ]
        if len(matches) != 1:
            raise RuntimeError(
                f"{image} must resolve to exactly one linux/amd64 manifest"
            )
        digest = matches[0].get("digest", "")
    else:
        digest = "sha256:" + hashlib.sha256(result.stdout).hexdigest()
    if not DIGEST.fullmatch(digest):
        raise RuntimeError(
            f"registry returned no valid linux/amd64 manifest digest for {image}"
        )
    return digest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image-list", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        lines = [
            f"{image}@{inspect_linux_amd64_digest(image)}"
            for image in read_images(args.image_list)
        ]
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
        RuntimeError,
    ) as error:
        parser.error(str(error))
    args.output.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
