#!/usr/bin/env bash
# image/promote-digest.sh
#
# The main build promotes :prod and then owns the rollback record. This compares
# the promoted digest with image/prod-digest.txt and, when the record is stale,
# publishes a repair branch and prints its compare URL. It cannot open the PR:
# the workflow token is not permitted to create pull requests, and a build that
# tried left a branch behind on every run.
#
# Exit 0 when the record already matched. Exit 1 when the record was stale, or a
# repair branch already exists: the run must be red so the drift is never silent.
#
# This lives in a script, not in the workflow, so the repair path runs against
# stub git binaries instead of being asserted by grepping the YAML.
#
# Usage: promote-digest.sh <repo-digest-or-digest>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
record="${PROD_DIGEST_FILE:-$here/prod-digest.txt}"
branch_prefix="chore/prod-digest"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || fail "usage: promote-digest.sh <pushed-digest>"
pushed="${1##*@}"
# Reject a malformed digest before the remote probe, so bad input never reaches
# git. check-prod-digest.sh repeats the check as its own input guard.
case "$pushed" in
  sha256:*) ;;
  *) fail "the pushed digest is not a sha256 digest: $1" ;;
esac
printf '%s' "${pushed#sha256:}" | grep -qE '^[0-9a-f]{64}$' \
  || fail "the pushed digest is not 64 hex characters: $1"

if "$here/check-prod-digest.sh" "$pushed"; then
  exit 0
fi

slug="${GITHUB_REPOSITORY:-}"
[ -n "$slug" ] || fail "GITHUB_REPOSITORY is unset, so the compare URL cannot be built"

# One repair branch at a time. A branch per stale run would pile up. It may
# record a digest an earlier run promoted, so merging it blind can write a record
# that no longer matches :prod: delete it and re-run instead.
existing="$(git ls-remote --branches origin "refs/heads/${branch_prefix}-*")" \
  || fail "could not list ${branch_prefix}- branches on origin"
[ -z "$existing" ] \
  || fail "the record is stale but a ${branch_prefix}- branch already exists; it may record an older digest. Delete it and re-run the image build."

"$here/write-prod-digest.sh" "$pushed"
# Prove the repair before pushing it. A branch that does not fix the check only
# moves the failure into the PR.
"$here/check-prod-digest.sh" "$pushed" >/dev/null \
  || fail "the repaired record still does not match ${pushed}"

branch="${branch_prefix}-${GITHUB_RUN_ID:-local}"
server="${GITHUB_SERVER_URL:-https://github.com}"
url="${server}/${slug}/compare/main...${branch}?expand=1"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch -c "$branch"
git add "$record"
git commit -m "chore: record the promoted prod digest"
git push origin "$branch" || fail "could not push ${branch} to origin"

# The step summary is what an operator reads first, so the link goes there too.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf 'The digest record is stale. Open and merge: %s\n' "$url" >> "$GITHUB_STEP_SUMMARY"
fi
fail "the record was stale; pushed ${branch}. Open and merge: ${url}"
