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

# Each EnvironmentFile the quadlet loads must be the path `oc-secrets` writes on a
# fresh boot.
#
# Six rounds of text heuristics lived here and every one lied in both directions.
# They accepted a comment, an `echo "see <path>"` mention, a writer for
# `/etc/opencode/env-backup`, a write to `${OUT_FILE}_BACKUP`, a `chmod` carrying an
# unrelated `> /dev/null`, and an `mv` to `${OUT_FILE}.new`. They rejected a literal
# redirect, `export`, `mv -f`, `install -m`, `cp`, `tee`, and `dd of=`.
#
# Round 8 then ran the writer with `OUT_FILE` pointed at a sandbox. That was worse
# than the heuristics: it always set `OUT_FILE`, which systemd never does, so it
# proved only the override path. A writer that refuses to run without `OUT_FILE`
# passed the guard and wrote nothing at boot. It also accepted
# `OPENCODE_PASSWORD=probe-password` followed by `OPENCODE_PASSWORD=legacy`,
# because systemd takes the last assignment and `grep -x` does not.
#
# So the responsibility is split along what each check can actually decide:
#
#   1. That the writer writes the right content is proved by running it, in
#      host/tests/test_oc-secrets.sh, which owns that script and checks content and
#      mode. Nothing here re-proves it.
#   2. That the path the quadlet loads is the path the writer uses when nothing
#      overrides it is decided here, by reading the declaration and evaluating it
#      with bash, plus proving that no shipped env file sets `OUT_FILE`.
#
# The value is evaluated by bash rather than unquoted by a regex, so quoting and a
# `${OUT_FILE:-...}` fallback resolve the same way they do at runtime.
here="$(cd "$(dirname "$0")/.." && pwd)"
writer="$here/bin/oc-secrets"
[ -f "$writer" ] || fail "no $writer, so nothing declares where the password goes"

# python3 reads the Butane source below. Its absence must fail, not silently leave
# the Ignition allowance empty: an empty allowance rejects every path, which looks
# like a real finding and hides the missing dependency.
command -v python3 >/dev/null 2>&1 || fail "python3 is required and absent"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 has no PyYAML module"

# The last `OUT_FILE=` assignment is the one bash would end with, and the one
# systemd would read if the file were sourced. Taking the last also means a second,
# later assignment cannot hide behind the first. The pattern is anchored to the
# variable name with its optional declaration keywords, so `PREFIX_OUT_FILE=` is a
# different variable and a comment mentioning the name is not an assignment.
assign_re='^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+|declare([[:space:]]+-[A-Za-z]+)*[[:space:]]+|local([[:space:]]+-[A-Za-z]+)*[[:space:]]+)?OUT_FILE='
decl_lines="$(grep -E "$assign_re" "$writer" || true)"
[ -n "$decl_lines" ] || fail "oc-secrets no longer assigns OUT_FILE, so its output path is unknown"
last_decl="$(printf '%s\n' "$decl_lines" | tail -1)"
rhs="${last_decl#*OUT_FILE=}"
# Strip a trailing comment, which is shell syntax rather than part of the value.
rhs="${rhs%%[[:space:]]#*}"

# `env -u OUT_FILE` is the boot condition: systemd sets no OUT_FILE, so the value
# that runs is the declared default and nothing else. bash evaluates the right-hand
# side, so quoting and a `:-` fallback resolve exactly as they do on the host. A
# value that does not evaluate is a failure, not an empty string to compare later.
# The single quotes are deliberate: `$DECL_RHS` must reach the eval unexpanded.
# shellcheck disable=SC2016
declared="$(env -u OUT_FILE DECL_RHS="$rhs" bash -c '
  set -u
  eval "OUT_FILE=$DECL_RHS"
  printf %s "$OUT_FILE"
' 2>/dev/null || true)"
[ -n "$declared" ] \
  || fail "oc-secrets declares an OUT_FILE that does not evaluate: $rhs"
case "$declared" in
  /?*) ;;
  *) fail "oc-secrets declares an output path that is not absolute: $declared" ;;
esac

# If anything on the boot path sets OUT_FILE, the value above is not what runs, and
# this guard would be checking a path the host never uses.
override_files="$(python3 "$here/tests/env_file_paths.py" \
  "$here/../os/butane/ucore.bu" OUT_FILE)"
[ -z "$override_files" ] \
  || fail "a shipped env file sets OUT_FILE ($override_files), so the declared default is not what runs"
if printf '%s\n' "$container_section" | grep -Eq '^Environment=.*OUT_FILE'; then
  fail "the quadlet sets OUT_FILE in [Container], so the declared default is not what runs"
fi

# Paths Ignition itself could satisfy: a storage file whose own content defines the
# variable the container needs. A directory, a shipped script, and an env file for a
# different unit all appear as storage paths, so a path-only match would accept a
# reference no component fulfils. See env_file_paths.py.
mapfile -t ign_paths < <(python3 "$here/tests/env_file_paths.py" \
  "$here/../os/butane/ucore.bu" OPENCODE_PASSWORD)

# Each loaded path must be the writer's declared path or an Ignition env file that
# really defines the password. A path that merely starts with a claimed one is a
# different file and does not count.
for path in "${env_paths[@]}"; do
  [ -n "$path" ] || continue
  claimed=0
  [ "$path" = "$declared" ] && claimed=1
  for storage_path in "${ign_paths[@]}"; do
    [ "$path" = "$storage_path" ] && claimed=1
  done
  [ "$claimed" -eq 1 ] \
    || fail "the quadlet loads $path, but no component declares it: oc-secrets writes $declared"
done

# The container's password comes from that file, so the writer and the reader must
# agree on the name.
grep -q 'OPENCODE_PASSWORD' "$here/bin/oc-idle-check" \
  || fail "oc-idle-check does not read the password oc-secrets writes"

echo "persistent data is on the data disk"
