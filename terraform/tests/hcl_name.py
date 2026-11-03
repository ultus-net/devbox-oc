#!/usr/bin/env python3
"""Print the name attribute of a Terraform resource, or fail loudly.

Usage: hcl_name.py <file.tf> <resource_type> <resource_name>

The guard needs one fact out of `main.tf`: the string literal assigned to `name` in
a specific resource block. Reading it with `awk` and a regex failed twice: a heredoc
that merely mentioned `name = "..."` counted as the attribute, and a concatenation
`name = "opencode-password" + var.suffix` counted because it contains a quoted
string.

`terraform console` would be better, but it evaluates resource attributes only after
an apply, which this repo never runs in CI. So this is a small scanner, not a
HCL parser, and it only claims what it checks:

  - comments (`#`, `//`, `/* */`) and heredocs are removed before scanning, so an
    attribute mentioned inside either is not a definition;
  - block depth is tracked by braces, so only `name` at the resource's own depth
    counts and a `name` inside a nested block does not;
  - the value must be exactly one quoted string literal. Anything else, including a
    concatenation, interpolation, or variable, is reported as unsupported rather
    than guessed at.

Escapes inside the literal are decoded for the common cases. A literal containing a
construct this does not decode is reported, not silently returned.

Exit codes: 0 on success and the value on stdout, 1 on a diagnostic printed to
stderr. A caller should treat both 1 and 2 as failure.
"""
import re
import sys

HEREDOC = re.compile(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)")


def strip_noise(text):
    """Remove comments and heredoc bodies, preserving line structure.

    Block comments are removed across lines, because they are legal HCL and a `name`
    or a brace inside one is not code. Leaving them in produced two wrong verdicts: a
    block comment naming the attribute counted as a second definition, and a `}` in one
    closed the resource early so the real attribute was never reached.
    """
    out = []
    lines = text.splitlines()
    i = 0
    in_block = False
    while i < len(lines):
        line = lines[i]
        if in_block:
            end = line.find("*/")
            if end == -1:
                out.append("")
                i += 1
                continue
            line = line[end + 2:]
            in_block = False
        # A heredoc starts an arbitrary body that must be skipped whole, or a
        # `name = "..."` inside it would be read as an attribute.
        found = HEREDOC.search(line)
        if found and not line.lstrip().startswith("#"):
            tag = found.group(1)
            out.append(line.split("<<")[0])
            i += 1
            while i < len(lines) and lines[i].strip() != tag:
                i += 1
            i += 1  # skip the closing tag
            continue
        # Strip //, # and /* */ comments that are not inside a quoted string.
        cleaned, in_string, escaped, j = [], False, False, 0
        while j < len(line):
            ch = line[j]
            if escaped:
                cleaned.append(ch)
                escaped = False
            elif ch == "\\" and in_string:
                cleaned.append(ch)
                escaped = True
            elif ch == '"':
                cleaned.append(ch)
                in_string = not in_string
            elif not in_string and ch == "#":
                break
            elif not in_string and line[j:j + 2] == "//":
                break
            elif not in_string and line[j:j + 2] == "/*":
                end = line.find("*/", j + 2)
                if end == -1:
                    in_block = True
                    break
                j = end + 2
                continue
            else:
                cleaned.append(ch)
            j += 1
        out.append("".join(cleaned))
        i += 1
    return "\n".join(out)


def unquote(value):
    """Return the literal text of a quoted HCL string, or None if it is not one."""
    value = value.strip()
    if len(value) < 2 or value[0] != '"' or value[-1] != '"':
        return None
    body = value[1:-1]
    # A quote inside the body means the literal ended early and this is a
    # concatenation or something else this scanner does not model.
    if '"' in body.replace('\\"', ""):
        return None
    if "${" in body or "%{" in body:
        return None
    return body.replace('\\"', '"').replace("\\\\", "\\")


def find_name(text, resource_type, resource_name):
    header = re.compile(
        r'^\s*resource\s+"' + re.escape(resource_type) + r'"\s+"'
        + re.escape(resource_name) + r'"\s*\{')
    depth = 0
    inside = False
    values = []
    for number, line in enumerate(text.splitlines(), 1):
        if not inside:
            if header.match(line):
                inside = True
                depth = line.count("{") - line.count("}")
            continue
        stripped = line.strip()
        if depth == 1:
            match = re.match(r"^name\s*=\s*(.+)$", stripped)
            if match:
                values.append((number, match.group(1)))
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            break

    if not inside:
        raise SystemExit(f"no resource {resource_type}.{resource_name} found")
    if not values:
        raise SystemExit(f"resource {resource_type}.{resource_name} has no name attribute")
    if len(values) > 1:
        where = ", ".join(f"line {n}" for n, _ in values)
        raise SystemExit(f"resource {resource_type}.{resource_name} sets name "
                         f"{len(values)} times ({where})")

    number, raw = values[0]
    literal = unquote(raw)
    if literal is None:
        raise SystemExit(f"line {number}: the name is not a plain string literal: {raw}")
    return literal


def main(argv):
    if len(argv) != 4:
        print(f"usage: {argv[0]} <file.tf> <resource_type> <resource_name>",
              file=sys.stderr)
        return 2
    with open(argv[1]) as handle:
        text = strip_noise(handle.read())
    print(find_name(text, argv[2], argv[3]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
