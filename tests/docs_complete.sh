#!/usr/bin/env bash
# A doc set that omits the recovery path is incomplete. This asserts the files
# exist and that each operational topic is actually written down somewhere.
#
# It checks presence, not prose quality: a topic mentioned in passing passes.
# That is deliberate, because the alternative is a test that encodes wording.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

for f in README.md CHANGELOG.md docs/runbook.md docs/vendoring.md; do
  [ -s "$root/$f" ] || fail "missing or empty: $f"
done

for topic in restore rollback tailnet snapshot vendoring; do
  grep -riq "$topic" "$root/docs" "$root/README.md" || fail "no documentation for: $topic"
done

# Deployment topics are scoped to the runbook, not the whole docs tree. A
# recursive scan would pass vacuously, because the plan documents in
# docs/superpowers already contain these words.
for topic in "first deploy" regenerate "pair --url"; do
  grep -riq -- "$topic" "$root/docs/runbook.md" \
    || fail "runbook has no first-deployment coverage for: $topic"
done

# The idle contract must state what is NOT protected, or an operator will be
# surprised when the box stops under a connected client.
grep -riq "not protected" "$root/README.md" || fail "README does not state what the idle gate does not protect"

# The published image is Fedora CoreOS, and Ignition rebases it onto ucore on
# first boot. An operator who does not know that reads two reboots and several
# minutes of unreachability as a failed deploy, so the runbook must name both
# stages and give a command that proves the booted OS really is ucore.
grep -riq "rpm-ostree status" "$root/docs/runbook.md" \
  || fail "runbook does not tell the operator how to confirm the booted OS is ucore"
grep -riq "tailscaled" "$root/docs/runbook.md" \
  || fail "runbook does not name tailscaled, the unit most likely to be down"
for stage in ucore-unsigned-autorebase ucore-signed-autorebase; do
  grep -riq -- "$stage" "$root/docs/runbook.md" \
    || fail "runbook does not name the $stage stage of the first boot"
done

echo "docs complete"
