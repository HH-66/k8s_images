#!/usr/bin/env python3
"""Validate one tagless ACR repository name used by the release workflow."""

from __future__ import annotations

import argparse
import re


REGISTRY_RE = re.compile(
    r"^(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)"
    r"(?:\.(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?))*|\[[0-9A-Fa-f:.]+\])"
    r"(?::([1-9][0-9]{0,4}))?$"
)
REPOSITORY_COMPONENT_RE = re.compile(r"^[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*$")


def validate(value: str) -> None:
    if "/" not in value or "@" in value:
        raise ValueError("must be registry/repository without a digest")
    registry, repository = value.split("/", 1)
    registry_match = REGISTRY_RE.fullmatch(registry)
    if registry_match is None:
        raise ValueError("registry has invalid syntax")
    if registry_match.group(1) and int(registry_match.group(1)) > 65535:
        raise ValueError("registry port must not exceed 65535")
    components = repository.split("/")
    if not components or any(
        not REPOSITORY_COMPONENT_RE.fullmatch(component) for component in components
    ):
        raise ValueError("repository has invalid syntax or contains a tag")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    args = parser.parse_args()
    try:
        validate(args.repository)
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
