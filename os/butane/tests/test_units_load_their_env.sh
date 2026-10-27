#!/usr/bin/env bash
# os/butane/tests/test_units_load_their_env.sh
#
# A systemd unit does not inherit another unit's EnvironmentFile. So a script that
# needs VAULT_NAME or TS_AUTHKEY_SECRET must have the env file that defines them
# loaded by its own unit, or it runs with those variables unset.
#
# That is exactly how the tailnet join broke: the Terraform secret existed, the
# script read the right name, and the unit never loaded the file that says which
# vault to ask.
#
# Every check here is derived from the config and the scripts, not from a list of
# expected values, so it keeps working when a unit is added.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bu="${1:-$here/../ucore.bu}"
# Three levels up: os/butane/tests -> repo root -> host/bin.
bindir="${2:-$here/../../../host/bin}"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$bu" ] || fail "no such file: $bu"
# Without this the script reads nothing, every unit looks satisfied, and the check
# passes vacuously. Fail loudly instead.
[ -d "$bindir" ] || fail "no such directory: $bindir"
[ -f "$bindir/oc-tailnet-up" ] || fail "bindir does not hold the host scripts: $bindir"
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

python3 - "$bu" "$bindir" <<'PY'
import os
import re
import sys

import yaml

bu_path, bindir = sys.argv[1], sys.argv[2]

with open(bu_path) as handle:
    config = yaml.safe_load(handle)

# Map each env file the config creates to the variable names it defines. A line
# like `VAULT_NAME=__VAULT_NAME__` defines VAULT_NAME; a comment does not.
env_files = {}
for entry in (config.get("storage") or {}).get("files") or []:
    path = entry.get("path") or ""
    if not path.endswith(".env"):
        continue
    names = set()
    inline = (entry.get("contents") or {}).get("inline") or ""
    for line in inline.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        names.add(line.split("=", 1)[0].strip())
    env_files[path] = names

units = (config.get("systemd") or {}).get("units") or []

# Scripts written inline by the config, keyed by basename, so an ExecStart that
# points at one is checked like a host/bin script rather than skipped.
inline_scripts = {}
for entry in (config.get("storage") or {}).get("files") or []:
    path = entry.get("path") or ""
    inline = (entry.get("contents") or {}).get("inline") or ""
    if inline:
        inline_scripts[path.rsplit("/", 1)[-1]] = inline

def script_vars(exec_path):
    """Variables a script references, following its lib-imds.sh include.

    A script can live in host/bin or inline in the Butane config, so both are
    consulted. A path that resolves to neither yields no variables, which would
    make the unit look satisfied. Raise instead: a silently skipped script is the
    vacuity this guard exists to avoid.
    """
    base = exec_path.rsplit("/", 1)[-1]
    texts = []

    # Binaries the OS image ships are not ours to inspect. Every other ExecStart
    # must resolve, or the unit's requirements go unchecked.
    if exec_path in {"/usr/bin/rpm-ostree", "/usr/bin/systemctl", "/usr/bin/touch"}:
        return set()

    main = f"{bindir}/{base}"
    if os.path.isfile(main):
        with open(main) as handle:
            texts.append(handle.read())
    elif base in inline_scripts:
        texts.append(inline_scripts[base])

    if not texts:
        raise SystemExit(
            f"FAIL: {exec_path} resolves to neither {bindir} nor an inline script, "
            "so its variables cannot be checked"
        )

    seen = set()
    for text in texts:
        seen |= set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)", text))
        seen |= set(re.findall(r"\$([A-Z_][A-Z0-9_]*)", text))
    lib = f"{bindir}/lib-imds.sh"
    if os.path.isfile(lib):
        with open(lib) as handle:
            text = handle.read()
        seen |= set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)", text))
        seen |= set(re.findall(r"\$([A-Z_][A-Z0-9_]*)", text))
    return seen


# A config with no units or no env files would make every loop below a no-op and
# the guard would report success without checking anything.
if not units:
    raise SystemExit(f"FAIL: {bu_path} declares no systemd units to check")
if not env_files:
    raise SystemExit(f"FAIL: {bu_path} writes no env file, so nothing can be checked")


# Names the host system supplies. The unit sets some inline, systemd passes
# others, so their absence from an env file is not a defect.
SYSTEM_PROVIDED = {
    "HOME",
    "PATH",
    "STATE_DIR",
    "AUTH_KEY_FILE",
    "LOGIN_SERVER",
    "API",
    "ENV_FILE",
    "STATE",
    "PIN_FILE",
    "OUT_FILE",
    "OUT",
    "SECRET_NAME",
    "IMAGE",
    "CONTAINER_NAME",
}


def inline_assignments(unit_contents):
    """Variable names a unit's own Environment= lines define."""
    names = set()
    for line in unit_contents.splitlines():
        if not line.startswith("Environment="):
            continue
        for item in line.split("=", 1)[1].split():
            if "=" in item:
                names.add(item.split("=", 1)[0])
    return names


def required_vars(exec_path):
    """Variables the script demands with ${VAR:?}, which fail when unset."""
    base = exec_path.rsplit("/", 1)[-1]
    if base in inline_scripts:
        text = inline_scripts[base]
    elif os.path.isfile(f"{bindir}/{base}"):
        with open(f"{bindir}/{base}") as handle:
            text = handle.read()
    else:
        return set()
    return set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*):\?", text))


def strip_heredocs(text):
    """Drop heredoc bodies, which are data rather than code.

    A `LOCATION=westeurope` line inside a heredoc is text written to a file or
    stdout, not an assignment, so counting it as a default hides a variable that is
    never set. oc-snapshot already uses a heredoc, so this is not hypothetical.
    """
    out = []
    delimiter = None
    strip_tabs = False
    for line in text.splitlines():
        if delimiter is not None:
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                delimiter = None
            out.append("# heredoc body")
            continue
        out.append(line)
        match = re.search(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line)
        if match:
            strip_tabs = match.group(1) == "-"
            delimiter = match.group(3)
    return "\n".join(out)


def code_only(line):
    """The line with expansions and quoted strings removed.

    Structural judgement has to run on code, not on data. `REGISTRY="${ACR_NAME}
    .azurecr.io"` contains a brace and is not a block, and `echo "if you like"`
    contains a keyword and is not a conditional, so a raw substring test misreads
    both.
    """
    previous = None
    while previous != line:
        previous = line
        line = re.sub(r"\$\{[^{}]*\}", "", line)
    line = re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*", "", line)
    line = re.sub(r"'[^']*'", "''", line)
    line = re.sub(r'"(\\.|[^"\\])*"', '""', line)
    return line


def top_level_assignments(text):
    """Names assigned by a statement that runs unconditionally.

    Only a line at column zero can run unconditionally, and only its semicolon-
    separated segments that are plain assignments or `export`/`readonly` count.
    A line carrying a control-flow keyword, or a block brace, is a conditional or
    a function body, so its assignments do not supply a value on every path.
    """
    names = set()
    for line in text.splitlines():
        if not line or line[0].isspace() or line.lstrip().startswith("#"):
            continue
        code = code_only(line)
        if re.search(r"\b(if|then|else|elif|fi|for|while|until|do|done|case|esac|function)\b", code):
            continue
        if "{" in code or "}" in code:
            continue
        for segment in line.split(";"):
            match = re.match(r"\s*(?:export\s+|readonly\s+)?([A-Z_][A-Z0-9_]*)=", segment)
            if match:
                names.add(match.group(1))
    return names


def unsettable_vars(exec_path):
    """Variables a script reads with no usable local fallback.

    Only scripts that read no external env file at runtime are checked. A script
    that sources `$ENV_FILE` takes its values from a file oc-secrets writes on the
    host, which this config cannot see, so treating those variables as undefined
    would be a false failure. Everything else must resolve locally or from an env
    file the unit loads.

    A `${VAR:-}` with an empty default is not a fallback: it is the pattern the
    tailnet join used while silently skipping Key Vault.
    """
    base = exec_path.rsplit("/", 1)[-1]
    if exec_path in {"/usr/bin/rpm-ostree", "/usr/bin/systemctl", "/usr/bin/touch"}:
        return set()
    if base in inline_scripts:
        text = inline_scripts[base]
    elif os.path.isfile(f"{bindir}/{base}"):
        with open(f"{bindir}/{base}") as handle:
            text = handle.read()
    else:
        return set()
    # A leading dot plus an expansion is a runtime include, so this script's
    # requirements are satisfied by something outside this config.
    if re.search(r'^\s*\.\s+"?\$\{?[A-Z_]', text, re.M):
        return set()
    # Heredoc bodies are data, so strip them before reading assignments.
    text = strip_heredocs(text)
    read = set(re.findall(r"\$\{?([A-Z_][A-Z0-9_]*)", text))
    # Names a statement assigns unconditionally. Heredoc text is already gone, and
    # an assignment inside a conditional does not count, because it does not run on
    # every path and cannot supply the value a top-level read needs.
    local = top_level_assignments(text)
    # `local` and `declare` are function-scoped, so an indented one only helps a read
    # inside that function. This scanner cannot follow that, so it accepts them at
    # any indent, and a top-level read of a name only a function assigns is reported.
    # That false failure is deliberate: it is visible on the first run, while a
    # silent unset is not. No shipped script hits it.
    local |= set(re.findall(
        r"(?:^|[\s;{])(?:local|declare)\s+(?:-\w+\s+)*([A-Z_][A-Z0-9_]*)=", text, re.M))
    local |= set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*):=[^}]*\}", text))
    local |= set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*):-[^}][^}]*\}", text))
    return read - local - SYSTEM_PROVIDED

failures = []
for unit in units:
    contents = unit.get("contents") or ""
    if not contents:
        continue
    name = unit.get("name", "<unnamed>")
    loaded = set(
        line.split("=", 1)[1].strip()
        for line in contents.splitlines()
        if line.startswith("EnvironmentFile=")
    )
    execs = [
        line.split("=", 1)[1].split()[0]
        for line in contents.splitlines()
        if line.startswith("ExecStart=") and len(line.split("=", 1)) == 2
    ]
    needed = set()
    required = set()
    unsettable = set()
    for exec_path in execs:
        needed |= script_vars(exec_path)
        required |= required_vars(exec_path)
        unsettable |= unsettable_vars(exec_path)
    if not needed:
        continue

    # `${VAR:?}` makes a script refuse to run when VAR is unset, so a loaded env
    # file that no longer defines it is as fatal as not loading the file at all.
    # System-provided names are skipped: the unit sets them, or systemd passes them.
    provided = set()
    for env_path in loaded:
        provided |= env_files.get(env_path, set())
    provided |= inline_assignments(contents)
    for var in sorted(required - provided - SYSTEM_PROVIDED):
        failures.append(
            f"{name} runs a script that requires {var}, "
            "but nothing loaded by the unit defines it"
        )

    # A variable read with no fallback and no definition is the silent half of the
    # same defect: the script runs, the value is empty, and it misbehaves later.
    for var in sorted(unsettable - provided - required):
        failures.append(
            f"{name} runs a script that reads {var} with no default, "
            "but nothing loaded by the unit defines it"
        )

    for env_path, names in env_files.items():
        if env_path in loaded:
            continue
        missing = sorted((needed | required) & names)
        if missing:
            failures.append(
                f"{name} runs a script needing {', '.join(missing)} "
                f"but does not load {env_path}"
            )

# Every variable an env file defines must still be read by some script. A rename
# on one side only leaves an orphan here, which is otherwise silent: the file
# defines a name nothing uses, and the script reads a name nothing defines.
all_referenced = set()
for unit in units:
    for line in (unit.get("contents") or "").splitlines():
        if line.startswith("ExecStart=") and len(line.split("=", 1)) == 2:
            path = line.split("=", 1)[1].split()[0]
            all_referenced |= script_vars(path)
for path, names in env_files.items():
    orphans = sorted(names - all_referenced)
    for var in orphans:
        failures.append(
            f"{path} defines {var}, which no script reads: "
            "the definition and the reader have drifted apart"
        )

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sys.exit(1)
PY

echo "every unit loads the env file its scripts need"
