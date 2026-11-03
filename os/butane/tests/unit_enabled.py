#!/usr/bin/env python3
"""Print the `enabled` flag for one systemd unit in a Butane source.

Usage: unit_enabled.py <ucore.bu> <unit-name>

Prints `true`, `false`, or `absent`. `absent` is distinct from `false`: Butane
renders no flag when the key is missing, while `enabled: false` is an explicit
statement, and a comparison against the compiled artifact has to tell them apart.

Two shell guards used to derive this by hand, first with a hardcoded six-space
indent and then by taking the indent from the unit's own `- name:` line. Both broke
on ordinary YAML that compiles to the same flag: `enabled: yes`, a trailing comment,
and a blank line after `- name:` all compiled correctly and still failed or passed
the wrong way. A YAML parser answers the question the guards actually ask, so this
reads the document instead of guessing at its shape.
"""
import sys

import yaml


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <butane-file> <unit-name>", file=sys.stderr)
        return 2
    path, name = argv[1], argv[2]
    with open(path) as handle:
        config = yaml.safe_load(handle)

    units = (config.get("systemd") or {}).get("units") or []
    matches = [unit for unit in units if unit.get("name") == name]
    if not matches:
        print(f"no unit named {name} in {path}", file=sys.stderr)
        return 3
    if len(matches) > 1:
        print(f"{name} is declared {len(matches)} times in {path}", file=sys.stderr)
        return 4

    value = matches[0].get("enabled")
    if value is None:
        print("absent")
    elif value is True:
        print("true")
    else:
        print("false")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
