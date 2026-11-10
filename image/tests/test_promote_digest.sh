#!/usr/bin/env bash
# image/tests/test_promote_digest.sh
#
# The main build repairs a stale digest record by pushing a branch and opening a
# PR. Grepping the workflow cannot prove that: it passes on a commented-out line.
# This runs image/promote-digest.sh with stub git and gh binaries on PATH and
# asserts what it actually did, so a repair that stops happening fails here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image="$(cd "$here/.." && pwd)"
promote="$image/promote-digest.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$promote" ] || fail "image/promote-digest.sh is not executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export PROD_DIGEST_FILE="$tmp/prod-digest.txt"
export CALLS="$tmp/calls"
export GITHUB_RUN_ID=424242

# Both stubs record their argv, and gh answers pr list from a fixture so the
# already-open branch path can be driven without a network.
cat > "$tmp/bin/git" <<'EOF'
#!/bin/sh
printf 'git %s\n' "$*" >> "$CALLS"
EOF
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "pr list") printf '%s\n' "${OPEN_BRANCHES:-}" ;;
esac
EOF
chmod 0755 "$tmp/bin/git" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

a="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
b="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# 1. A matching record passes without touching git or gh at all.
printf '# header\n%s\n' "$a" > "$PROD_DIGEST_FILE"
: > "$CALLS"
out="$("$promote" "ghcr.io/ultus-net/devbox@$a")" || fail "a matching digest failed: $out"
[ -s "$CALLS" ] && fail "a matching digest still touched git or gh: $(cat "$CALLS")"

# 2. A stale record is repaired, the repair passes its own check, and the PR is
#    opened on the run-id branch.
printf '# header stays\n%s\n' "$a" > "$PROD_DIGEST_FILE"
: > "$CALLS"
if out="$("$promote" "$b" 2>&1)"; then
  fail "a stale record passed: $out"
fi
case "$out" in
  *"opened chore/prod-digest-424242"*) ;;
  *) fail "the stale failure did not name the branch it opened: $out" ;;
esac
[ "$(sed -n '1p' "$PROD_DIGEST_FILE")" = "# header stays" ] || fail "the header was lost"
grep -qx "$b" "$PROD_DIGEST_FILE" || fail "the record was not updated to the promoted digest"
grep -qx 'git switch -c chore/prod-digest-424242' "$CALLS" || fail "no repair branch was created"
grep -qx 'git push origin chore/prod-digest-424242' "$CALLS" || fail "the repair branch was not pushed"
grep -q '^gh pr create --base main --head chore/prod-digest-424242' "$CALLS" \
  || fail "no repair PR was opened for the branch"

# 3. An already-open repair PR stops a second branch from being pushed.
printf '# header\n%s\n' "$a" > "$PROD_DIGEST_FILE"
: > "$CALLS"
export OPEN_BRANCHES="chore/prod-digest-111111"
if out="$("$promote" "$b" 2>&1)"; then
  fail "a stale record passed while a repair PR was open: $out"
fi
case "$out" in
  *"already open"*) ;;
  *) fail "the open-PR refusal was unclear: $out" ;;
esac
grep -qx "$a" "$PROD_DIGEST_FILE" || fail "the record changed while a repair PR was open"
if grep -q '^git ' "$CALLS"; then
  fail "a second branch was pushed while a repair PR was open: $(cat "$CALLS")"
fi
unset OPEN_BRANCHES

# 4. Malformed input is rejected before anything is pushed.
: > "$CALLS"
if out="$("$promote" "not-a-digest" 2>&1)"; then
  fail "a malformed digest passed: $out"
fi
if grep -q '^git ' "$CALLS"; then
  fail "a malformed digest still pushed a branch: $(cat "$CALLS")"
fi
if "$promote" >/dev/null 2>&1; then fail "a missing argument passed"; fi

echo "a stale record fails, is repaired, and opens exactly one repair PR"
