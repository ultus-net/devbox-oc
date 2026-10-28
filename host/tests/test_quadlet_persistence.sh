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
# writes, and that component must really write it.
#
# Text heuristics were tried here for six rounds and every one lied in both
# directions. They accepted a comment, an `echo "see <path>"` mention, a writer for
# `/etc/opencode/env-backup`, a write to `${OUT_FILE}_BACKUP`, a `chmod` line carrying
# an unrelated `> /dev/null`, and an `mv` to `${OUT_FILE}.new`. They rejected a literal
# redirect, a variable declared inside a function, `export`, `mv -f`, `install -m`,
# `cp`, `tee`, `dd of=`, and a backslash-wrapped `mv`. Enumerating write commands is
# the same trap in a smaller costume: the list of ways to create a file is open-ended.
#
# So the writer is run instead. `oc-secrets` is the one component that declares this
# path, so pointing its own variable at a sandbox and checking that the file appears
# with the right content answers the question directly, for any write mechanism and
# any formatting. The earlier attempt at a probe failed because it searched for an
# unknown producer by variable name; here the producer and its variable are both known
# from the declaration below, which is what makes running it decidable.
#
# What remains unproven is reachability at runtime: the probe supplies its own stub
# for IMDS and Key Vault, so it does not prove the service wiring. That is covered by
# the unit-level suites.
here="$(cd "$(dirname "$0")/.." && pwd)"
writer="$here/bin/oc-secrets"
[ -f "$writer" ] || fail "no $writer, so nothing declares where the password goes"

# The declared output path, with the shell spelling normalised: quotes and the
# `${OUT_FILE:-...}` fallback are the same value as a bare literal.
assignments="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?OUT_FILE=[[:space:]]*//p' "$writer")"
[ -n "$assignments" ] || fail "oc-secrets no longer declares OUT_FILE, so its output path is unknown"
# More than one assignment means the first one read here is not necessarily the one
# written, so the declaration would be ambiguous. The behavioural probe below would
# catch it, but a named failure is clearer than a missing file.
[ "$(printf '%s\n' "$assignments" | wc -l)" -eq 1 ] \
  || fail "oc-secrets assigns OUT_FILE more than once, so its output path is ambiguous"
declared="$assignments"
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

# Paths Ignition itself could satisfy: a storage file whose own content defines the
# variable the container needs. A directory, a shipped script, and an env file for a
# different unit all appear as storage paths, so a path-only match would accept a
# reference no component fulfils. See env_file_paths.py.
mapfile -t ign_paths < <(python3 "$here/tests/env_file_paths.py" \
  "$here/../os/butane/ucore.bu" OPENCODE_PASSWORD)

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

# oc-secrets must really write that file. Run it with its own variable pointed at a
# sandbox path, and require the password line to appear there. IMDS and Key Vault are
# the only network seams, so a stub curl covers both.
probe="$(mktemp -d "$here/tests/.probe.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe/bin"
cat > "$probe/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do
  case "$a" in http://*|https://*) url="$a" ;; esac
done
case "$url" in
  *169.254.169.254*) printf '%s' '{"access_token":"probe"}' ;;
  *vault.azure.net/secrets/*) printf '%s' '{"value":"probe-password"}' ;;
  *) printf '%s' '{}' ;;
esac
STUB
chmod +x "$probe/bin/curl"

# The writer installs its parent directory and writes atomically, so the sandbox is
# simply its target path. VAULT_NAME and SECRET_NAME are supplied in the form the
# script demands. A failed run is not evidence of a missing write, so it is reported
# with its output rather than silently treated as a pass or a fail.
if ! env -i PATH="$probe/bin:/usr/bin:/bin" HOME="$probe" TMPDIR="$probe" \
     VAULT_NAME=probe OUT_FILE="$probe/written.env" \
     bash "$writer" >"$probe/out" 2>&1; then
  fail "oc-secrets failed to run, so its write cannot be verified: $(tail -1 "$probe/out")"
fi
grep -qx 'OPENCODE_PASSWORD=probe-password' "$probe/written.env" 2>/dev/null \
  || fail "oc-secrets does not write OPENCODE_PASSWORD to the OUT_FILE it declares"

# The container's password comes from that file, so the writer and the reader must
# agree on the name.
grep -q 'OPENCODE_PASSWORD' "$here/bin/oc-idle-check" \
  || fail "oc-idle-check does not read the password oc-secrets writes"

echo "persistent data is on the data disk"
