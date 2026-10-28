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
# So the path is not read out of a shell script at all. It is a single definition in
# the unit env file that Ignition writes, and this guard checks the whole chain from
# parsed configuration:
#
#   oc-secrets.service loads that env file, the env file defines OUT_FILE, and the
#   value equals the EnvironmentFile the container loads.
#
# Nothing here executes a shipped script or evaluates its text. That the writer
# writes the right content is proved by running it, in host/tests/test_oc-secrets.sh,
# which owns that script.
here="$(cd "$(dirname "$0")/.." && pwd)"
butane="$here/../os/butane/ucore.bu"

# python3 reads the Butane source. Its absence must fail, not silently leave the
# Ignition allowance empty: an empty allowance rejects every path, which looks like a
# real finding and hides the missing dependency.
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

# Every definition of OUT_FILE in the shipped configuration, parsed from the Butane
# source. Exactly one may exist, and it must be an env file: an `Environment=` line
# would win at runtime and make the env file a decoy.
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

# The unit that runs the writer must load the file that defines the path, or the
# definition never reaches the process.
printf '%s\n' "$boot_env" | awk -F'\t' '$1 == "envref"' | grep -qxF "envref	oc-secrets.service	$env_owner" \
  || fail "oc-secrets.service does not load $env_owner, so the OUT_FILE it defines never reaches the writer"

# Paths Ignition itself could satisfy: a storage file whose own content defines the
# variable the container needs. A directory, a shipped script, and an env file for a
# different unit all appear as storage paths, so a path-only match would accept a
# reference no component fulfils.
mapfile -t ign_paths < <(python3 "$here/tests/boot_env.py" "$butane" OPENCODE_PASSWORD \
  | awk -F'\t' '$1 == "envfile" { print $2 }')

# Each loaded path must be the path defined for the writer or an Ignition env file
# that really defines the password. A path that merely starts with a claimed one is a
# different file and does not count.
for path in "${env_paths[@]}"; do
  [ -n "$path" ] || continue
  claimed=0
  [ "$path" = "$declared" ] && claimed=1
  for storage_path in "${ign_paths[@]}"; do
    [ "$path" = "$storage_path" ] && claimed=1
  done
  [ "$claimed" -eq 1 ] \
    || fail "the quadlet loads $path, but no shipped component defines it: OUT_FILE is $declared ($env_owner)"
done

# The container's password comes from that file, so the writer and the reader must
# agree on the name.
grep -q 'OPENCODE_PASSWORD' "$here/bin/oc-idle-check" \
  || fail "oc-idle-check does not read the password oc-secrets writes"

echo "persistent data is on the data disk"
