#!/usr/bin/env bash
# image/promote-digest.sh
#
# The main build promotes :prod and then owns the rollback record. This compares
# the promoted digest with image/prod-digest.txt, repairs a stale record on a
# branch, and opens a PR, because a workflow token cannot push to main.
#
# Exit 0 when the record already matched. Exit 1 when the record was stale or a
# repair PR is already open: the run must be red so the drift is never silent.
#
# This lives in a script, not in the workflow, so the repair path runs against
# stub git and gh binaries instead of being asserted by grepping the YAML.
#
# Usage: promote-digest.sh <repo-digest-or-digest>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
record="${PROD_DIGEST_FILE:-$here/prod-digest.txt}"
branch_prefix="chore/prod-digest"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || fail "usage: promote-digest.sh <pushed-digest>"
pushed="${1##*@}"

if "$here/check-prod-digest.sh" "$pushed"; then
  exit 0
fi

# One open repair PR at a time. A branch per stale run would leave a pile of PRs,
# and merging an older one re-stales the record it just fixed.
open_branches="$(gh pr list --state open --json headRefName --jq '.[].headRefName')"
if grep -q "^${branch_prefix}" <<<"$open_branches"; then
  fail "the record is stale but a ${branch_prefix} PR is already open; merge or close it first"
fi

"$here/write-prod-digest.sh" "$pushed"
# Prove the repair before pushing it. A branch that does not fix the check only
# moves the failure into the PR.
"$here/check-prod-digest.sh" "$pushed" >/dev/null \
  || fail "the repaired record still does not match ${pushed}"

branch="${branch_prefix}-${GITHUB_RUN_ID:-local}"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch -c "$branch"
git add "$record"
git commit -m "chore: record the promoted prod digest"
git push origin "$branch"
gh pr create --base main --head "$branch" \
  --title "chore: record the promoted prod digest" \
  --body "The main build promoted ${pushed} while image/prod-digest.txt was stale, so the next rollback would have restored the wrong image. This PR updates the record.

The run that opened it failed on purpose. A workflow token does not trigger workflows, so this PR carries no CI result: read the one-line diff and merge it as a human override."

fail "the record was stale; opened ${branch} for ${pushed}"
