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
  - one pair of surrounding quotes is stripped. A `#` inside the value is NOT a
    comment and is kept: systemd only treats a line starting with `#` as a
    comment, which `systemd-run -p EnvironmentFile=` confirms by reporting
    `OUT_FILE='/etc/opencode/env # staging'` for a trailing `# staging`;
  - a commented-out line is not a definition;
  - a unit's own `dropins:` blocks count. That is the repo's idiom for a
    drop-in, and Butane compiles it into `systemd.units[].dropins[]`, so
    ignoring it lets a drop-in set the variable unseen.

A value is returned verbatim apart from those rules. This is not a full
EnvironmentFile parser: `set -a` sourcing, `%` specifiers, and continuation
lines are out of scope, and a caller that needs them should say so rather than
assume they work.
"""
import pathlib
import re
import shlex
import sys

import yaml

# systemd's own grammar for a unit line: KEY=VALUE, with an optional `=` in the
# value. Anything else in the value is preserved.
ASSIGNMENT = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def split_value(raw):
    """Apply systemd's value rules to the text after the `=`.

    Only one surrounding pair of quotes is removed. A `#` is part of the value,
    which is what systemd does and what a comment-stripping parser gets wrong.
    """
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def unit_words(raw):
    """Split an `Environment=` value into assignments, honouring quotes.

    systemd accepts `Environment="A=1 2" B=3`, so splitting on whitespace would
    invent a definition named `2"`. shlex is not systemd's parser, but it agrees
    on quoting. A string it cannot parse is a hard failure, not a fallback: a
    silent re-split would mis-read exactly the input this is meant to catch.
    """
    return shlex.split(raw, posix=True)


def unit_lines(text):
    """Yield (section, key, value) for each line of a unit file body.

    Backslash continuations are joined first, as systemd does. Without that a
    static `Environment=` split across two lines was invisible: the assignment
    looked like an unknown directive on the second line.
    """
    section = ""
    joined, pending = [], ""
    for line in text.splitlines():
        if pending:
            pending += " " + line.strip()
        else:
            pending = line
        if pending.rstrip().endswith("\\"):
            pending = pending.rstrip()[:-1]
            continue
        joined.append(pending)
        pending = ""
    if pending:
        joined.append(pending)

    for line in joined:
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1]
            continue
        match = ASSIGNMENT.match(line)
        if match:
            yield section, match.group(1), match.group(2)


def collect(config, variable, repo_root=None):
    """Return (definitions, references), each a list of (kind, owner, value).

    `contents: local:` is how the repo includes the quadlet, so a parser that
    reads only `inline:` never opens the one shipped file most likely to carry a
    password. `repo_root` is the same directory Butane is given as `--files-dir`,
    so a local path resolves exactly as it does at build time.
    """
    definitions, references = [], []

    def body_of(contents):
        """Return a file's text, from `inline:` or from a `local:` include."""
        contents = contents or {}
        if contents.get("inline") is not None:
            return contents.get("inline") or ""
        local = contents.get("local")
        if local and repo_root:
            candidate = (pathlib.Path(repo_root) / local).resolve()
            root = pathlib.Path(repo_root).resolve()
            # Butane rejects a path escaping the files dir, and so does this.
            if root == candidate or root in candidate.parents:
                try:
                    return candidate.read_text()
                except OSError:
                    return ""
        return ""

    # Storage files: an inline env file is a definition; a drop-in written directly
    # under /etc/systemd/system/<unit>.d/ is a definition too.
    for entry in (config.get("storage") or {}).get("files") or []:
        path = entry.get("path") or ""
        inline = body_of(entry.get("contents"))

        # An installed program is not an env file, even when a unit loads it as one.
        # `oc-secrets` is a shell script full of `NAME=value` lines, and reading it
        # here reported `${SECRET_NAME:-opencode-password}` as a literal value. A
        # shebang is the reliable mark; an env file never starts with one.
        if inline.startswith("#!"):
            continue

        # A quadlet: `/etc/containers/systemd/<name>.container`. The generator turns
        # `[Container] Environment=` into podman's `--env`, which beats `--env-file`,
        # so a static password here wins at runtime. This file arrives through a
        # `local:` include, which is why reading only `inline:` left it unguarded.
        if path.startswith("/etc/containers/systemd/") and path.endswith(".container"):
            for section, key, value in unit_lines(inline):
                if section != "Container" or key != "Environment":
                    continue
                for assignment in unit_words(value):
                    name, _, val = assignment.partition("=")
                    if name == variable:
                        definitions.append(("container-env", path,
                                            split_value(val)))
            continue

        # Drop-ins reach systemd/podman from two directories: systemd's own, and the
        # podman generator's for quadlets. The generator merges
        # `[Container] Environment=` from a `.container.d/` drop-in into the unit's
        # `--env`, which beats `--env-file`, so both have to be read or a static
        # password can be set in one the scanner never opens.
        dropin = re.match(r"^/etc/(?:systemd/system/([^/]+)\.d"
                          r"|containers/systemd/([^/]+)\.d)/[^/]+\.conf$", path)
        if dropin:
            owner = dropin.group(1) or dropin.group(2)
            for section, key, value in unit_lines(inline):
                if key != "Environment":
                    continue
                for assignment in unit_words(value):
                    name, _, val = assignment.partition("=")
                    if name == variable:
                        kind = "container-env" if section == "Container" else "environment"
                        definitions.append((kind, owner, split_value(val)))
            continue

        # Only a file that is *used as* an env file counts. systemd applies these rules
        # to the paths a unit names in `EnvironmentFile=`, and to any config file with
        # `NAME=value` lines; it never applies them to a program.
        if inline and not inline.startswith("#!"):
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

    # Units: EnvironmentFile= references, Environment= definitions, and the unit's
    # own dropins:. Butane compiles `dropins:` into systemd.units[].dropins[], so a
    # drop-in that sets the variable is invisible to a reader that skips them. The
    # owner is the unit name either way, because that is what systemd applies it to.
    for entry in (config.get("systemd") or {}).get("units") or []:
        name = entry.get("name") or ""
        bodies = [entry.get("contents") or ""]
        for drop in entry.get("dropins") or []:
            bodies.append(drop.get("contents") or "")
        for body in bodies:
            for section, key, value in unit_lines(body):
                if section != "Service":
                    continue
                if key == "EnvironmentFile":
                    references.append(("envref", name, value.lstrip("-").strip()))
                elif key == "Environment":
                    for assignment in unit_words(value):
                        var, _, val = assignment.partition("=")
                        if var == variable:
                            definitions.append(("environment", name,
                                                split_value(val)))
    return definitions, references


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <butane-file> <VARIABLE>", file=sys.stderr)
        return 2
    path, variable = argv[1], argv[2]
    with open(path) as handle:
        config = yaml.safe_load(handle)

    # The repo root is the same directory Butane is given as --files-dir, so a
    # `local:` include resolves to the same bytes the build reads.
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    definitions, references = collect(config, variable, repo_root)
    for kind, owner, value in definitions:
        print(f"{kind}\t{owner}\t{value}")
    for kind, owner, value in references:
        print(f"{kind}\t{owner}\t{value}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
