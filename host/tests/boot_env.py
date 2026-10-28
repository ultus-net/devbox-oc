#!/usr/bin/env python3
"""List every place the boot environment defines a variable.

Usage: boot_env.py <butane-file> <VARIABLE>

Prints one TSV line per definition:

    kind<TAB>owner<TAB>value

`kind` is one of:

  envfile       a storage file whose inline content defines the variable;
                `owner` is that file's path
  environment   an `Environment=` line in a unit or a unit drop-in;
                `owner` is the unit name
  envref        a unit's `EnvironmentFile=`; `value` is the file it loads.
                This is a reference, not a definition, and is printed so a
                caller can ask which units receive a given file.

Why this exists: the quadlet guard used to learn where the password goes by
parsing `oc-secrets` and evaluating the fragment with bash. That executed code
from the file it was auditing, and a non-line-initial assignment was invisible
to it. Both defects disappear if the answer comes from the shipped configuration
instead of from a shell script's text.

Semantics follow systemd where the difference is observable:

  - the last assignment of a key wins, whether the earlier one is in the same
    file or an earlier `Environment=` line;
  - one pair of surrounding quotes is stripped, and a trailing comment is not
    part of the value;
  - a commented-out line is not a definition.

A value is returned verbatim apart from those rules. This is not a full
EnvironmentFile parser: `set -a` sourcing, `%` specifiers, and continuation
lines are out of scope, and a caller that needs them should say so rather than
assume they work.
"""
import re
import sys

import yaml

# systemd's own grammar for a unit line: KEY=VALUE, with an optional `=` in the
# value. Anything else in the value is preserved.
ASSIGNMENT = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def split_value(raw):
    """Apply systemd's EnvironmentFile value rules to the text after the `=`."""
    value = raw.strip()
    if " #" in value:
        value = value.split(" #", 1)[0].rstrip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def unit_lines(text):
    """Yield (section, key, value) for each line of a unit file body."""
    section = ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1]
            continue
        match = ASSIGNMENT.match(line)
        if match:
            yield section, match.group(1), match.group(2)


def collect(config, variable):
    """Return (definitions, references), each a list of (kind, owner, value)."""
    definitions, references = [], []

    # Storage files: an inline env file is a definition; a unit body contributes
    # Environment= lines, and a drop-in under /etc/systemd/system/<unit>.d/ too.
    for entry in (config.get("storage") or {}).get("files") or []:
        path = entry.get("path") or ""
        inline = (entry.get("contents") or {}).get("inline") or ""

        dropin = re.match(r"^/etc/systemd/system/([^/]+)\.d/[^/]+\.conf$", path)
        if dropin:
            for section, key, value in unit_lines(inline):
                if section == "Service" and key == "Environment":
                    for assignment in value.split():
                        name, _, val = assignment.partition("=")
                        if name == variable:
                            definitions.append(("environment", dropin.group(1),
                                                split_value(val)))
            continue

        if inline:
            # An env file: the last assignment of the key in this file wins.
            last = None
            for line in inline.splitlines():
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                match = ASSIGNMENT.match(line)
                if match and match.group(1) == variable:
                    last = split_value(match.group(2))
            if last is not None:
                definitions.append(("envfile", path, last))

    # Units: EnvironmentFile= references, and Environment= definitions. A later
    # unit's Environment= for the same key overrides an earlier env file, so this
    # is collected in source order and the caller resolves precedence.
    for entry in (config.get("systemd") or {}).get("units") or []:
        name = entry.get("name") or ""
        for section, key, value in unit_lines(entry.get("contents") or ""):
            if section not in ("Service", "Unit"):
                continue
            if key == "EnvironmentFile":
                references.append(("envref", name, value.lstrip("-").strip()))
            elif key == "Environment":
                for assignment in value.split():
                    var, _, val = assignment.partition("=")
                    if var == variable:
                        definitions.append(("environment", name, split_value(val)))
    return definitions, references


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <butane-file> <VARIABLE>", file=sys.stderr)
        return 2
    path, variable = argv[1], argv[2]
    with open(path) as handle:
        config = yaml.safe_load(handle)

    definitions, references = collect(config, variable)
    for kind, owner, value in definitions:
        print(f"{kind}\t{owner}\t{value}")
    for kind, owner, value in references:
        print(f"{kind}\t{owner}\t{value}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
