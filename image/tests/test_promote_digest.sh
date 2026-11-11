#!/usr/bin/env bash
# image/tests/test_promote_digest.sh
#
# The main build repairs a stale digest record by pushing a branch and printing
# its compare URL. Grepping the workflow cannot prove that: it passes on a
# commented-out line. This runs image/promote-digest.sh with stub git and gh
# binaries on PATH and asserts what it actually did, so a repair that stops
# happening fails here, and so does a return to gh pr create: the workflow token
# is not permitted to open pull requests, and every attempt left a branch behind.
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
export GITHUB_REPOSITORY=ultus-net/devbox-oc
unset GITHUB_SERVER_URL || true

# The git stub records its argv and answers the remote-branch probe from a
# fixture. The gh stub records its argv and fails, so a repair that still tries
# to open a PR stops at the call rather than passing quietly.
cat > "$tmp/bin/git" <<'EOF'
#!/bin/sh
printf 'git %s\n' "$*" >> "$CALLS"
if [ "$1 $2" = "ls-remote --branches" ] && [ -n "${REMOTE_BRANCH:-}" ]; then
  printf '0\t%s\n' "$REMOTE_BRANCH"
fi
exit 0
EOF
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$CALLS"
echo "gh must not be called: the workflow token cannot open a PR" >&2
exit 1
EOF
chmod 0755 "$tmp/bin/git" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

a="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
b="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
url="https://github.com/ultus-net/devbox-oc/compare/main...chore/prod-digest-424242?expand=1"

# 1. A matching record passes without touching git or gh at all.
printf '# header\n%s\n' "$a" > "$PROD_DIGEST_FILE"
: > "$CALLS"
out="$("$promote" "ghcr.io/ultus-net/devbox@$a")" || fail "a matching digest failed: $out"
if [ -s "$CALLS" ]; then
  fail "a matching digest still touched git or gh: $(cat "$CALLS")"
fi

# 2. A stale record is repaired, the repair passes its own check, the branch is
#    pushed, and the failure names the compare URL an operator opens.
printf '# header stays\n%s\n' "$a" > "$PROD_DIGEST_FILE"
: > "$CALLS"
if out="$("$promote" "$b" 2>&1)"; then
  fail "a stale record passed: $out"
fi
case "$out" in
  *"$url"*) ;;
  *) fail "the stale failure did not print the compare URL: $out" ;;
esac
case "$out" in
  *"chore/prod-digest-424242"*) ;;
  *) fail "the stale failure did not name the branch it pushed: $out" ;;
esac
[ "$(sed -n '1p' "$PROD_DIGEST_FILE")" = "# header stays" ] || fail "the header was lost"
grep -qx "$b" "$PROD_DIGEST_FILE" || fail "the record was not updated to the promoted digest"
grep -qx 'git switch -c chore/prod-digest-424242' "$CALLS" || fail "no repair branch was created"
grep -qx "git add $PROD_DIGEST_FILE" "$CALLS" || fail "the record was not staged"
grep -qx 'git commit -m chore: record the promoted prod digest' "$CALLS" \
  || fail "the repair was not committed"
grep -qx 'git push origin chore/prod-digest-424242' "$CALLS" || fail "the repair branch was not pushed"
if grep -q '^gh ' "$CALLS"; then
  fail "the repair still calls gh, which cannot open a PR: $(cat "$CALLS")"
fi

# 3. A repair branch that already exists on the remote, with no PR, stops a
#    second branch from being pushed. A leaked branch must not accumulate.
printf '# header\n%s\n' "$a" > "$PROD_DIGEST_FILE"
: > "$CALLS"
export REMOTE_BRANCH="refs/heads/chore/prod-digest-111111"
if out="$("$promote" "$b" 2>&1)"; then
  fail "a stale record passed while a repair branch existed: $out"
fi
case "$out" in
  *"Delete it and re-run"*) ;;
  *) fail "the existing-branch refusal did not say to delete and re-run: $out" ;;
esac
# The probe must name the branch prefix. A truncated pattern would pass the
# fixture above and restore the branch leak it exists to stop.
grep -Fqx 'git ls-remote --branches origin refs/heads/chore/prod-digest-*' "$CALLS" \
  || fail "the repair probed a different ref pattern: $(cat "$CALLS")"
grep -qx "$a" "$PROD_DIGEST_FILE" || fail "the record changed while a repair branch existed"
if grep -qE '^git (switch|push|commit|add) ' "$CALLS"; then
  fail "a second branch was pushed while a repair branch existed: $(cat "$CALLS")"
fi
unset REMOTE_BRANCH

# 4. A missing repository slug fails before any git call, because the compare URL
#    cannot be built and a branch with no link is the failure this closes.
: > "$CALLS"
unset GITHUB_REPOSITORY
if out="$("$promote" "$b" 2>&1)"; then
  fail "a stale record passed with no repository slug: $out"
fi
case "$out" in
  *"GITHUB_REPOSITORY"*) ;;
  *) fail "the missing slug refusal was unclear: $out" ;;
esac
if grep -q '^git ' "$CALLS"; then
  fail "a branch was pushed with no compare URL: $(cat "$CALLS")"
fi
export GITHUB_REPOSITORY=ultus-net/devbox-oc

# 5. Malformed input is rejected before anything is pushed.
: > "$CALLS"
if out="$("$promote" "not-a-digest" 2>&1)"; then
  fail "a malformed digest passed: $out"
fi
if grep -q '^git ' "$CALLS"; then
  fail "a malformed digest still pushed a branch: $(cat "$CALLS")"
fi
if "$promote" >/dev/null 2>&1; then fail "a missing argument passed"; fi

echo "a stale record fails, is repaired on one branch, and never calls gh"
