#!/usr/bin/env bash
# host/tests/test_quadlet_persistence.sh
set -euo pipefail
q="${1:-$(cd "$(dirname "$0")/../.." && pwd)/host/quadlet/opencode.container}"
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$q" ] || fail "quadlet missing"

# podman's generator only reads /etc/containers/systemd/, and the file is not
# executable, so 0644 is the mode the source has to carry.
[ "$(stat -c '%a' "$q")" = "644" ] || fail "quadlet is not mode 0644"

# Named volumes are the specific mistake this guards against, so test them
# first: a named source never starts with /srv/, so the path scan below would
# otherwise be the check that fires and hide this diagnosis.
if grep -Eq '^Volume=[a-z0-9_-]+:/' "$q"; then
  fail "a named volume is used; it would live on the OS disk"
fi

# Every volume that maps a persistent path must be under /srv, i.e. the data disk.
# Read via process substitution, not a pipe: `fail` inside a pipeline runs in a
# subshell, so `exit 1` would not stop the script and the check would pass
# vacuously on the first offending line.
while read -r line; do
  src="$(printf '%s' "${line#Volume=}" | cut -d: -f1)"
  case "$src" in
    /srv/*) ;;
    *) fail "persistent volume outside the data disk: $src" ;;
  esac
done < <(grep -E '^Volume=' "$q")

# The session DB path specifically must be persisted.
grep -q '/home/dev/.local/share/opencode' "$q" || fail "session data is not persisted"

# `After=` only orders the units. If the secret bootstrap fails, the container
# would start with no OPENCODE_PASSWORD and no ACR auth, then serve nothing and
# never idle-stop. Requires= makes a failed bootstrap refuse to start the unit.
#
# The placement matters. podman's generator reads only [Unit] for dependencies, so
# a Requires= sitting in [Container] would satisfy a naive grep and do nothing.
unit_section="$(awk '/^\[Unit\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$unit_section" ] || fail "quadlet has no [Unit] section"
printf '%s\n' "$unit_section" | grep -Eq '^Requires=.*oc-secrets\.service' \
  || fail "quadlet does not require oc-secrets.service in its [Unit] section"

# Read from [Container] only. podman's generator reads EnvironmentFile= there; the
# same key in [Unit] is parsed by systemd, ignored for the container, and the
# workload starts with no OPENCODE_PASSWORD while billing continues. Match the
# directive at line start too, or a commented-out line names a file it never loads.
container_section="$(awk '/^\[Container\]/{on=1;next} /^\[/{on=0} on' "$q")"
[ -n "$container_section" ] || fail "quadlet has no [Container] section"
mapfile -t env_paths < <(printf '%s\n' "$container_section" | sed -n 's/^EnvironmentFile=//p')
[ "${#env_paths[@]}" -gt 0 ] \
  || fail "quadlet loads no EnvironmentFile in [Container], so the container has no password"

# Each EnvironmentFile the quadlet loads must be the path the writer writes on a
# fresh boot.
#
# Six rounds of text heuristics lived here and every one lied in both directions.
# They accepted a comment, an `echo "see <path>"` mention, a writer for
# `/etc/opencode/env-backup`, a write to `${OUT_FILE}_BACKUP`, a `chmod` carrying an
# unrelated `> /dev/null`, and an `mv` to `${OUT_FILE}.new`. They rejected a literal
# redirect, `export`, `mv -f`, `install -m`, `cp`, `tee`, and `dd of=`.
#
# Round 8 ran the writer instead. That was worse: it supplied `OUT_FILE`, which
# systemd never does, so it proved only the override path, and it kept the same
# blind spot when the writer also assigned the variable itself.
#
# Round 9 parsed the writer and evaluated the fragment with bash. That was still
# wrong twice over: the eval executed code from the file being audited, and a
# non-line-initial assignment was invisible to the parser.
#
# Round 10 moved the definition into the Ignition env file but allowed the quadlet to
# load *any* Ignition file that defined OPENCODE_PASSWORD. That accepted a static
# password in a storage file in place of the Key Vault path, so the allowance is gone:
# the container loads the one path oc-secrets writes, and nothing else.
#
# Nothing here executes a shipped script or evaluates its text. That the writer
# writes the right content is proved by running it, in host/tests/test_oc-secrets.sh.
here="$(cd "$(dirname "$0")/.." && pwd)"
butane="$here/../os/butane/ucore.bu"

# python3 reads the Butane source. Its absence must fail, not silently leave the
# Ignition allowance empty: an empty allowance rejects every path, which looks like a
# real finding and hides the missing dependency.
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

# Every definition of OUT_FILE in the shipped configuration, parsed from the Butane
# source. Exactly one may exist, and it must be an env file: an `Environment=` line
# would win at runtime and make the env file a decoy. A unit's own `dropins:` counts,
# because Butane compiles those into the artifact and systemd applies them.
boot_env="$(python3 "$here/tests/boot_env.py" "$butane" OUT_FILE)"
definitions="$(printf '%s\n' "$boot_env" | awk -F'\t' '$1 != "envref"')"
[ -n "$definitions" ] || fail "nothing in the shipped configuration defines OUT_FILE"

count="$(printf '%s\n' "$definitions" | wc -l)"
[ "$count" -eq 1 ] \
  || fail "OUT_FILE is defined $count times, so which one wins is a coin toss:
$definitions"

kind="$(printf '%s\n' "$definitions" | cut -f1)"
env_owner="$(printf '%s\n' "$definitions" | cut -f2)"
declared="$(printf '%s\n' "$definitions" | cut -f3)"
[ "$kind" = "envfile" ] \
  || fail "OUT_FILE is set by a unit's Environment= ($env_owner), not by an env file, so the env file is a decoy"
case "$declared" in
  /?*) ;;
  *) fail "OUT_FILE is defined as a path that is not absolute: $declared" ;;
esac

# Both readers of that path must load the file that defines it, or the definition
# never reaches them: the writer writes there, and the idle gate reads the password
# from it. oc-idle-check used to carry its own hardcoded default, so moving the path
# left it reading the old file with every guard green.
for unit in oc-secrets.service oc-idle.service; do
  printf '%s\n' "$boot_env" | awk -F'\t' '$1 == "envref"' \
    | grep -qxF "envref	$unit	$env_owner" \
    || fail "$unit does not load $env_owner, so the OUT_FILE it defines never reaches it"
done

# Each loaded path must be exactly the path oc-secrets writes. A path that merely
# starts with it is a different file, and no other file may be substituted even if it
# happens to define the same variable: that is a static password bypassing Key Vault.
for path in "${env_paths[@]}"; do
  [ -n "$path" ] || continue
  [ "$path" = "$declared" ] \
    || fail "the quadlet loads $path, but oc-secrets writes $declared ($env_owner)"
done

# No shipped file may define the password at all. It comes from Key Vault at boot, and
# any static definition is a secret baked into Ignition, which ships as the VM's
# custom_data and stays readable in the deployment history. Checking the quadlet alone
# missed two routes: an Ignition storage file at the declared path, and a podman
# generator drop-in whose `[Container] Environment=` becomes `--env` and beats
# `--env-file`. So the rule is on every definition, not on shapes.
#
# Two readers, because they cover different files. boot_env.py parses the Butane
# source, which is where storage files and drop-ins live. The quadlet cannot come from
# there: ucore.bu includes it with `local:` from a file build.sh deletes after
# compiling, so at guard time it exists only as host/quadlet/opencode.container, and
# build.sh is what renders it into the artifact. Its own `[Container] Environment=`
# still reaches podman's `--env`, so it is read directly, with continuations joined.
static_password="$(python3 "$here/tests/boot_env.py" "$butane" OPENCODE_PASSWORD \
  | awk -F'\t' '$1 != "envref"')"
[ -z "$static_password" ] \
  || fail "a shipped file defines OPENCODE_PASSWORD, so a secret is baked into Ignition rather than fetched from Key Vault at boot:
$static_password"

# A backslash continuation is a single systemd line, and a value may be indented, so
# join continuations first and allow leading whitespace. Matching only column 0 missed
# the wrapped spelling.
container_password="$(sed ':a;/\\$/N;s/\\\n//;ta' "$q" \
  | awk '/^\[/{s=$0} s=="[Container]"' \
  | grep -E '^[[:space:]]*Environment=.*OPENCODE_PASSWORD' || true)"
[ -z "$container_password" ] \
  || fail "the quadlet sets OPENCODE_PASSWORD in [Container], which podman applies as
--env and the env file oc-secrets writes does not override it:
$container_password"

# The container reads the password from the file OUT_FILE names, so the probe must read
# that same file. That is proved behaviourally in host/tests/test_oc-idle-check.sh,
# which hands the probe a busy password file and requires the box to stay up. No text
# rule here: a grep for `ENV_FILE=` accepted spellings it did not anticipate and
# rejected a comment that merely mentioned one.
grep -q 'OPENCODE_PASSWORD' "$here/bin/oc-idle-check" \
  || fail "oc-idle-check does not read the password oc-secrets writes"

echo "persistent data is on the data disk"
