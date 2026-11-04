#!/usr/bin/env bash
# A doc set that omits the recovery path is incomplete. This asserts the files
# exist and that each operational topic is written down somewhere.
#
# It checks presence, not prose quality: a topic mentioned in passing passes.
# That is deliberate, because the alternative is a test that encodes wording.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

for f in README.md CHANGELOG.md docs/design.md docs/install.md docs/runbook.md; do
  [ -s "$root/$f" ] || fail "missing or empty: $f"
done

# Match whole words: `ups` must not pass on the `backups` that already appears.
for topic in restore rollback tailnet restic ups; do
  grep -riqw "$topic" "$root/docs" "$root/README.md" || fail "no documentation for: $topic"
done

# First install is a different procedure from daily operation, so it must be
# written down, and it must name the two checks that catch a half-finished
# install: the booted OS and the tailnet daemon.
grep -riq "first install" "$root/docs/install.md" \
  || fail "install doc has no first-install heading"
for topic in "rpm-ostree status" tailscaled "coreos-installer" restic; do
  grep -riq -- "$topic" "$root/docs/install.md" \
    || fail "install doc does not cover: $topic"
done

# A Mini in a server room has risks a cloud VM hid. The design must name them,
# or the operator will not know why the UPS and the power path matter.
for topic in "ups" "power loss" "thermal"; do
  grep -riqw "$topic" "$root/docs/design.md" \
    || fail "design doc does not record the hardware risk: $topic"
done

# The reinstall path must say that install step 4.4 formats the data disk. A
# runbook that tells the operator to re-run it wipes /srv, which is the one
# failure the data-disk invariant exists to prevent.
grep -q "Do not run install step 4.4" "$root/docs/runbook.md" \
  || fail "runbook does not warn against formatting the data disk on an OS reinstall"
grep -q "First install only" "$root/docs/install.md" \
  || fail "install doc does not mark data-disk preparation as first-install only"

# The only shell path is Tailscale SSH. The docs must say sshd is masked, or an
# operator will look for it and think the box is broken.
grep -riq "sshd is masked\|masked" "$root/docs/design.md" \
  || fail "design doc does not say sshd is masked"

# The unverified list is load-bearing: nothing here has run on the target Mini.
grep -riq "not verified" "$root/README.md" \
  || fail "README does not state what is unverified"

echo "docs complete"
