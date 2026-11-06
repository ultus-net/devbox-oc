#!/usr/bin/env bash
# host/tests/test_hermes-env.sh
#
# hermes-env is the only route from the operator-managed secrets file into the
# control plane. Run it with fixtures rather than reading its source: the
# properties that matter are what it writes, its mode, that it refuses a missing
# required key or provider key, and that it never copies an unlisted secret.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/hermes-env"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

run_env() (
  env SECRETS_FILE="$1" OUT_FILE="$2" "$script"
)

# T1: a complete set produces an environment file at mode 0600 with the required
# keys and the provider key, and nothing else.
printf 'OPENCODE_PASSWORD=s3cret-value\nAPI_SERVER_KEY=api-key-value\nOPENROUTER_API_KEY=sk-or-value\n' \
  > "$tmp/secrets.env"
run_env "$tmp/secrets.env" "$tmp/env" >/dev/null || fail "T1 hermes-env exited non-zero"
[ -f "$tmp/env" ] || fail "T1 no environment file written"
[ "$(stat -c '%a' "$tmp/env")" = "600" ] || fail "T1 environment file is not 0600"
grep -qx 'OPENCODE_PASSWORD=s3cret-value' "$tmp/env" || fail "T1 missing OpenCode password"
grep -qx 'API_SERVER_KEY=api-key-value' "$tmp/env" || fail "T1 missing API server key"
grep -qx 'OPENROUTER_API_KEY=sk-or-value' "$tmp/env" || fail "T1 missing provider key"
[ "$(wc -l < "$tmp/env")" -eq 3 ] || fail "T1 wrote keys the operator did not set"

# T2: a missing secrets file is a labelled failure, not an empty write.
rc=0
run_env "$tmp/absent.env" "$tmp/env2" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T2 hermes-env succeeded with no secrets file"
[ ! -e "$tmp/env2" ] || fail "T2 hermes-env wrote a file with no secrets"

# T3: a missing required key fails closed and does not clobber a good file.
printf 'OPENCODE_PASSWORD=only\nOPENROUTER_API_KEY=sk-or-value\n' > "$tmp/nokey.env"
printf 'API_SERVER_KEY=previous\n' > "$tmp/keep"
rc=0
run_env "$tmp/nokey.env" "$tmp/keep" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T3 hermes-env accepted a missing API_SERVER_KEY"
[ "$(cat "$tmp/keep")" = "API_SERVER_KEY=previous" ] \
  || fail "T3 a failed run overwrote the existing environment file"

# T4: a provider key is mandatory, so the agent cannot start unable to reach a model.
printf 'OPENCODE_PASSWORD=s3cret-value\nAPI_SERVER_KEY=api-key-value\n' > "$tmp/noprov.env"
rc=0
run_env "$tmp/noprov.env" "$tmp/env3" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "T4 hermes-env accepted a missing provider key"
[ ! -e "$tmp/env3" ] || fail "T4 hermes-env wrote a file with no provider key"

# T5: optional keys are copied when set, and a secret outside the allowlist is not
# leaked into the control plane's environment.
printf 'OPENCODE_PASSWORD=s3cret-value\nAPI_SERVER_KEY=api-key-value\nANTHROPIC_API_KEY=sk-ant-value\nTELEGRAM_BOT_TOKEN=123:abc\nAWS_SECRET_ACCESS_KEY=do-not-leak\n' \
  > "$tmp/full.env"
run_env "$tmp/full.env" "$tmp/env4" >/dev/null || fail "T5 hermes-env exited non-zero"
grep -qx 'ANTHROPIC_API_KEY=sk-ant-value' "$tmp/env4" || fail "T5 dropped a provider key"
grep -qx 'TELEGRAM_BOT_TOKEN=123:abc' "$tmp/env4" || fail "T5 dropped an optional key"
if grep -q 'AWS_SECRET_ACCESS_KEY' "$tmp/env4"; then
  fail "T5 copied a secret outside the allowlist into the container"
fi

# T6: last assignment wins and one pair of quotes is stripped, as systemd's
# EnvironmentFile does.
printf 'API_SERVER_KEY=first\nAPI_SERVER_KEY="second"\nOPENCODE_PASSWORD=p\nOPENROUTER_API_KEY=k\n' \
  > "$tmp/twice.env"
run_env "$tmp/twice.env" "$tmp/env5" >/dev/null || fail "T6 hermes-env exited non-zero"
grep -qx 'API_SERVER_KEY=second' "$tmp/env5" || fail "T6 wrong winning value"

# T7: the writer default and the quadlet consumer must name the same path. Each
# test above overrides OUT_FILE, so without this a change to the default leaves
# both suites green while the container reads a file nothing writes.
out_line="$(grep -m1 '^OUT_FILE=' "$script")"
default_out="${out_line#*:-}"
default_out="${default_out%%\"*}"
default_out="${default_out%\}}"
[ -n "$default_out" ] || fail "T7 cannot read the OUT_FILE default from hermes-env"
quadlet="$here/../quadlet/hermes.container"
quadlet_env="$(sed -n 's/^EnvironmentFile=//p' "$quadlet" | head -1)"
[ "$default_out" = "$quadlet_env" ] \
  || fail "T7 hermes-env writes $default_out but the quadlet loads $quadlet_env"

echo "hermes-env writes a 0600 allowlisted environment file and fails closed"
