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

# Each EnvironmentFile must be the exact file a shipped component declares it
# writes. Four text heuristics were tried here and every one lied in both
# directions: they accepted a comment, an `echo "see <path>"` mention, a writer for
# `/etc/opencode/env-backup`, a write to `${OUT_FILE}_BACKUP`, and a `chmod` line
# carrying an unrelated `> /dev/null`; they rejected a literal redirect, a variable
# declared inside a function, and `export`. Running the writer to see whether the
# file appears does not work either, because a producer that never assigns the path
# to a variable cannot be aimed at a sandbox.
#
# So this checks a property that is decidable rather than guessing at shell
# semantics: the path the quadlet loads must be exactly the path `oc-secrets`
# declares as its output, or an exact Ignition storage path. Anything else is a
# reference to a file no component claims.
#
# The limitation is deliberate and stated: this proves the reader and the declared
# writer agree, not that the writer's implementation still writes. The last two
# assertions cover the implementation for the one shape this repo ships, and a
# refactor of oc-secrets is expected to update them. A guard that fails loudly on a
# refactor is a maintenance cost. A guard that passes on a missing password is a
# billing defect.
here="$(cd "$(dirname "$0")/.." && pwd)"
writer="$here/bin/oc-secrets"
[ -f "$writer" ] || fail "no $writer, so nothing declares where the password goes"

# The declared output path, with the shell spelling normalised: quotes and the
# `${OUT_FILE:-...}` fallback are the same value as a bare literal.
declared="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?OUT_FILE=[[:space:]]*//p' "$writer" | head -1)"
[ -n "$declared" ] || fail "oc-secrets no longer declares OUT_FILE, so its output path is unknown"
declared="${declared%%[[:space:]]#*}"
declared="${declared//\"/}"
declared="${declared//\'/}"
# Unwrap a `${OUT_FILE:-...}` fallback. Both expansions are no-ops on a plain
# literal, so the shape does not need to be detected first.
declared="${declared#*\$\{OUT_FILE:-}"
declared="${declared%\}}"
case "$declared" in
  /?*) ;;
  *) fail "oc-secrets declares an output path that is not absolute: $declared" ;;
esac

# Paths Ignition writes itself. A storage entry creates its file, so an exact match
# here is as good as a script that declares the same path.
ign_paths=()
while read -r storage_path; do
  storage_path="${storage_path%%[[:space:]]#*}"
  storage_path="${storage_path//\"/}"
  storage_path="${storage_path//\'/}"
  [ -n "$storage_path" ] && ign_paths+=("$storage_path")
done < <(sed -n -E 's/^[[:space:]]*- path:[[:space:]]*//p' "$here/../os/butane/ucore.bu")

# Each loaded path must be one a shipped component claims: either the writer's
# declared output, or an exact Ignition storage path. A path that merely starts with
# a claimed one is a different file and does not count.
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

# oc-secrets must still write its declared path. Its shipped mechanism is a
# temporary file moved into place, so accept either that or a redirect to it.
# A `chmod` or a read of the same variable is not a write, so the reference has to
# sit on a line that also carries a redirect or an mv.
# shellcheck disable=SC2016  # the literal "$OUT_FILE" is what is being searched for
awk -v ref='"$OUT_FILE"' '
  $0 ~ /^[[:space:]]*#/ { next }
  index($0, ref) && ($0 ~ /(^|[[:space:]])mv[[:space:]]/ || $0 ~ />>?/) { found = 1 }
  END { exit(found ? 0 : 1) }
' "$writer" \
  || fail "oc-secrets declares OUT_FILE but no longer writes it"

# The container's password comes from that file, so the writer and the reader must
# agree on the name.
grep -q 'OPENCODE_PASSWORD=' "$writer" \
  || fail "oc-secrets does not write OPENCODE_PASSWORD"
grep -q 'OPENCODE_PASSWORD' "$here/bin/oc-idle-check" \
  || fail "oc-idle-check does not read the password oc-secrets writes"

echo "persistent data is on the data disk"
