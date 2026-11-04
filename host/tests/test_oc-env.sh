#!/usr/bin/env bash
# host/tests/test_oc-env.sh
#
# oc-env is the only route from the operator-managed secrets file into the
# container. Run it with fixtures rather than reading its source: the properties
# that matter are what it writes, its mode, and that it refuses to write an empty
# password.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/oc-env"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

run_env() (
  env SECRETS_FILE="$1" OUT_FILE="$2" "$script"
)

# T1: a password produces an environment file at mode 0600.
printf 'OPENCODE_PASSWORD=s3cret-value\n' > "$tmp/secrets.env"
run_env "$tmp/secrets.env" "$tmp/env" >/dev/null || fail "T1 oc-env exited non-zero"
[ -f "$tmp/env" ] || fail "T1 no environment file written"
[ "$(cat "$tmp/env")" = "OPENCODE_PASSWORD=s3cret-value" ] || fail "T1 wrong content"
[ "$(stat -c '%a' "$tmp/env")" = "600" ] || fail "T1 environment file is not 0600"

# T2: a missing secrets file is a labelled failure, not an empty write.
rc=0
run_env "$tmp/absent.env" "$tmp/env2" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T2 oc-env succeeded with no secrets file"
[ ! -e "$tmp/env2" ] || fail "T2 oc-env wrote a file with no secrets"

# T3: an empty password fails closed and does not clobber a good file.
printf 'OPENCODE_PASSWORD=\n' > "$tmp/empty.env"
printf 'OPENCODE_PASSWORD=previous\n' > "$tmp/keep"
rc=0
run_env "$tmp/empty.env" "$tmp/keep" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T3 oc-env accepted an empty password"
[ "$(cat "$tmp/keep")" = "OPENCODE_PASSWORD=previous" ] \
  || fail "T3 a failed run overwrote the existing environment file"

# T4: last assignment wins, as systemd's EnvironmentFile does, and one pair of
# quotes is stripped.
printf 'OPENCODE_PASSWORD=first\nOPENCODE_PASSWORD="second"\n' > "$tmp/twice.env"
run_env "$tmp/twice.env" "$tmp/env3" >/dev/null || fail "T4 oc-env exited non-zero"
[ "$(cat "$tmp/env3")" = "OPENCODE_PASSWORD=second" ] || fail "T4 wrong winning value"

# T5: the writer default and the quadlet consumer must name the same path. Each
# test above overrides OUT_FILE, so without this a change to the default leaves
# both suites green while the container reads a file nothing writes.
out_line="$(grep -m1 '^OUT_FILE=' "$script")"
default_out="${out_line#*:-}"
default_out="${default_out%%\"*}"
default_out="${default_out%\}}"
[ -n "$default_out" ] || fail "T5 cannot read the OUT_FILE default from oc-env"
quadlet="$here/../quadlet/opencode.container"
quadlet_env="$(sed -n 's/^EnvironmentFile=//p' "$quadlet" | head -1)"
[ "$default_out" = "$quadlet_env" ] \
  || fail "T5 oc-env writes $default_out but the quadlet loads $quadlet_env"

echo "oc-env writes a 0600 environment file and fails closed"
