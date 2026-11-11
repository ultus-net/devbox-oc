#!/usr/bin/env bash
# A doc set that omits the recovery path is incomplete. This asserts the files
# exist and that each operational topic is written down somewhere.
#
# It checks presence, not prose quality: a topic mentioned in passing passes.
# That is deliberate, because the alternative is a test that encodes wording.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

for f in README.md CHANGELOG.md docs/design.md docs/install.md docs/runbook.md \
  docs/web-access.md docs/vm.md; do
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

# The client path is the one door. The invariant section must name every route
# that would publish the server, and the prohibition must stay a prohibition,
# not merely a mention. Scope the greps to the section, so a token elsewhere in
# the file cannot satisfy them.
web="$root/docs/web-access.md"

# Print one section, from its heading to the next level-two heading. A check
# scoped this way cannot be satisfied by the same token in another section.
section() {
  awk -v want="$1" 'index($0, want) == 1 { f = 1; next }
    f && /^## / { exit }
    f' "$web"
}

invariant="$(section "## The invariant:")"
[ -n "$invariant" ] || fail "web-access doc has no invariant section"
for term in "tailscale funnel" "pair --remote" "service set remote" desktop \
  internet; do
  printf '%s\n' "$invariant" | grep -Fqi -- "$term" \
    || fail "web-access invariant does not name: $term"
done

# The prohibition must be inside the invariant and must stay a prohibition. A
# rewrite that recommends the routes, or moves the warning elsewhere, fails.
printf '%s\n' "$invariant" | grep -Fqi "remote access stays off" \
  || fail "web-access invariant does not keep remote access off"
printf '%s\n' "$invariant" | grep -Fqi "never use them" \
  || fail "web-access invariant does not prohibit the OpenTunnel routes"
grep -Eq 'Never run .opencode pair --remote.' "$web" \
  || fail "web-access doc does not prohibit opencode pair --remote"

# Each proof command has to live in the section that explains it.
verify="$(section "## Verify the path")"
teardown="$(section "## Take the publication down")"
cors="$(section "### CORS")"
for topic in "tailscale funnel status" "serve reset" "--cors"; do
  case "$topic" in
    "serve reset") body="$teardown" ;;
    "--cors") body="$cors" ;;
    *) body="$verify" ;;
  esac
  printf '%s\n' "$body" | grep -Fq -- "$topic" \
    || fail "web-access section does not cover: $topic"
done
for topic in "api/info" "not on the tailnet"; do
  printf '%s\n' "$verify" | grep -Fq -- "$topic" \
    || fail "web-access verify section does not cover: $topic"
done
printf '%s\n' "$verify" | grep -Fqi "Available on the internet" \
  || fail "web-access verify does not give the funnel pass condition"
grep -Fqi "tailnet only" "$web" \
  || fail "web-access doc does not scope the publication to the tailnet"

for f in README.md docs/design.md docs/install.md docs/runbook.md; do
  grep -Fq "docs/web-access.md" "$root/$f" \
    || fail "$f does not link the web-access doc"
done

# The VM harness is the only dogfood path that runs without the Mini. It must
# say how to repeat a first boot and that the harness adds no inbound listener.
vm_doc="$root/docs/vm.md"
for topic in "--rebuild" "first boot" "127.0.0.1" "ghcr.io/ultus-net/devbox:prod"; do
  grep -Fq -- "$topic" "$vm_doc" \
    || fail "vm doc does not cover: $topic"
done

for f in README.md AGENTS.md; do
  grep -Fq "docs/vm.md" "$root/$f" || fail "$f does not link the VM doc"
done

# The VM rehearsal is the gate before bare metal. Every document that sends work
# to the Mini must name the command and the pass condition, so the step cannot be
# dropped from one of them without a failure.
for f in README.md AGENTS.md docs/install.md docs/runbook.md; do
  grep -Fq "./vm/run-vm.sh --rebuild" "$root/$f" \
    || fail "$f does not name the VM rehearsal command"
done
grep -Fq "VM DOGFOOD: pass" "$root/docs/install.md" \
  || fail "install doc does not state the VM pass condition"

# The attestations only count as evidence if the operator can read them, so the
# runbook names the inspection command and the unsigned limit.
runbook="$root/docs/runbook.md"
for topic in "imagetools inspect" "unsigned"; do
  grep -Fqi -- "$topic" "$runbook" \
    || fail "runbook does not cover the image attestations: $topic"
done

echo "docs complete"
