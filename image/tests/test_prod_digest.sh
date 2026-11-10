#!/usr/bin/env bash
# image/tests/test_prod_digest.sh
#
# The digest record can go stale without anything failing. `check-prod-digest.sh`
# is the guard the main build runs after pushing :prod, and
# `write-prod-digest.sh` is what the build uses to repair the record. Both drive
# a fixture file, so the assertions run against real file content, not a copy of
# the logic.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image="$(cd "$here/.." && pwd)"
check="$image/check-prod-digest.sh"
write="$image/write-prod-digest.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
record="$tmp/prod-digest.txt"
export PROD_DIGEST_FILE="$record"

a="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
b="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

printf '# header stays\n# never hand-edit\n%s\n' "$a" > "$record"

# A record that matches the pushed digest passes, as a bare digest or a
# RepoDigest, because the workflow reads index 0 of RepoDigests.
out="$("$check" "$a")" || fail "a matching digest was rejected: $out"
[ "$out" = "the digest record matches the promoted image" ] || fail "unexpected output: $out"
"$check" "ghcr.io/ultus-net/devbox@$a" >/dev/null || fail "a RepoDigest argument was rejected"

# A stale record fails and names both values.
if out="$("$check" "$b" 2>&1)"; then
  fail "a stale record passed: $out"
fi
case "$out" in
  *"record holds $a"*"prod is $b"*) ;;
  *) fail "a stale failure did not name both digests: $out" ;;
esac

# PENDING is a valid shape before the first build, but stale once :prod exists.
printf 'sha256:PENDING-FIRST-BUILD\n' > "$record"
if out="$("$check" "$a" 2>&1)"; then
  fail "PENDING passed after a build: $out"
fi
case "$out" in *PENDING-FIRST-BUILD*) ;; *) fail "PENDING failure is unclear: $out" ;; esac

# Malformed input is rejected rather than compared.
for bad in "sha256:abc" "not-a-digest" "sha256:$(printf '0%.0s' 1 2 3)"; do
  if "$check" "$bad" >/dev/null 2>&1; then fail "accepted a malformed digest: $bad"; fi
done
if "$check" >/dev/null 2>&1; then fail "accepted a missing argument"; fi
if PROD_DIGEST_FILE="$tmp/absent.txt" "$check" "$a" >/dev/null 2>&1; then
  fail "accepted a missing record"
fi

# Two digest lines make the record ambiguous for a rollback, so it fails even
# when one of them matches the pushed digest.
printf '%s\n%s\n' "$a" "$b" > "$record"
if out="$("$check" "$a" 2>&1)"; then
  fail "a record with two digests passed: $out"
fi

# write-prod-digest.sh enforces the same input shape, and it never invents a
# record that does not exist.
for bad in "sha256:abc" "not-a-digest"; do
  if "$write" "$bad" >/dev/null 2>&1; then fail "wrote a malformed digest: $bad"; fi
done
if PROD_DIGEST_FILE="$tmp/absent.txt" "$write" "$a" >/dev/null 2>&1; then
  fail "wrote to a record that does not exist"
fi

# write-prod-digest.sh repairs the record and keeps the comment header.
printf '# header stays\n# never hand-edit\n%s\n%s\n' "$a" "$a" > "$record"
"$write" "$b" >/dev/null || fail "could not write the digest"
[ "$(sed -n '1p' "$record")" = "# header stays" ] || fail "the header was lost"
[ "$(sed -n '2p' "$record")" = "# never hand-edit" ] || fail "the header was lost"
[ "$(grep -cE '^sha256:[0-9a-f]{64}$' "$record")" = "1" ] || fail "the record holds more than one digest"
grep -qx "$b" "$record" || fail "the new digest is not in the record"

# The pair round-trips: what the build writes, the check then accepts.
"$check" "$b" >/dev/null || fail "the rewritten record fails its own check"

echo "a stale digest record fails and the repair keeps the header"
