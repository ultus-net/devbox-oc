#!/usr/bin/env python3
"""List Ignition storage files whose own content defines a given variable.

Usage: env_file_paths.py <butane-file> <VARIABLE>

Prints one path per line, in source order. Exits 0 with no output when no storage
file defines the variable, which is the ordinary case: the password normally comes
from a host script, not from Ignition.

A `- path:` line alone is not enough. Directories, shipped scripts, and env files for
other units all appear as storage paths, so a path-only match accepts a reference no
component fulfils. The file must define the variable in its own inline content.

This reads the document with a YAML parser rather than anchoring on indentation. An
awk version of this check lived in host/tests/test_quadlet_persistence.sh and silently
stopped matching as soon as the `files:` key moved or the block was reformatted, which
turned a legitimate Ignition-provided env file into a false reject.
"""
import sys

import yaml


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <butane-file> <VARIABLE>", file=sys.stderr)
        return 2
    path, variable = argv[1], argv[2]
    with open(path) as handle:
        config = yaml.safe_load(handle)

    for entry in (config.get("storage") or {}).get("files") or []:
        inline = (entry.get("contents") or {}).get("inline") or ""
        for line in inline.splitlines():
            stripped = line.strip()
            if stripped.startswith("#") or "=" not in stripped:
                continue
            name = stripped.split("=", 1)[0].strip()
            if name == variable:
                print(entry.get("path") or "")
                break
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
