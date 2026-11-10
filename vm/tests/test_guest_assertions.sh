#!/usr/bin/env bash
# vm/tests/test_guest_assertions.sh
#
# The guest check runs inside the VM, so the host cannot execute it end to end.
# Two of its assertions are pure enough to lift out of the script and run against
# fixtures: the booted-deployment parse, and the findmnt source strip behind the
# separate-device assertion. Each fixture is the output shape the guest sees,
# including the state that used to pass when it should not.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/../guest-check.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$check" ] || fail "no guest check at $check"

# Lift a function verbatim. The guest check defines each at column 0, so a
# top-level closing brace ends it.
extract() {
  awk -v name="$1" 'index($0, name "() {") == 1 { on = 1 } on { print } on && /^}/ { exit }' "$check"
}

booted_body="$(extract booted_line)"
[ -n "$booted_body" ] || fail "the guest check defines no booted_line"
eval "$booted_body"

source_body="$(extract source_device)"
[ -n "$source_body" ] || fail "the guest check defines no source_device"
eval "$source_body"

# `rpm-ostree status` output, booted deployment first.
booted_ucore='State: idle
Deployments:
● ostree-unverified-registry:ghcr.io/ublue-os/ucore-minimal:stable
                   Digest: sha256:aaaa
              Version: 44.20261023.3.1
    ostree-image-signed:docker://quay.io/fedora/fedora-coreos:stable
                   Digest: sha256:bbbb
              Version: 44.20261023.3.1'

# The rebase has pulled ucore but the box is still on Fedora CoreOS. Every line
# here names ucore-minimal somewhere, so a whole-output grep accepts it.
booted_fcos_staged='State: idle
Deployments:
● ostree-image-signed:docker://quay.io/fedora/fedora-coreos:stable
                   Digest: sha256:bbbb
              Version: 44.20261023.3.1
    ostree-unverified-registry:ghcr.io/ublue-os/ucore-minimal:stable
                   Digest: sha256:aaaa
              Version: 44.20261023.3.1'

got="$(printf '%s\n' "$booted_ucore" | booted_line)"
case "$got" in
  *ucore-minimal*) ;;
  *) fail "booted_line did not find ucore in the booted deployment" ;;
esac

got="$(printf '%s\n' "$booted_fcos_staged" | booted_line)"
[ -n "$got" ] || fail "booted_line returned nothing for a booted deployment"
case "$got" in
  *ucore-minimal*) fail "booted_line accepted a staged ucore that is not booted" ;;
  *) ;;
esac

# Teeth: the fixture must be able to fool the parse the old check used, or it
# proves nothing.
if ! printf '%s\n' "$booted_fcos_staged" | grep -q ucore-minimal; then
  fail "the staged-rebase fixture does not discriminate: a whole-output grep rejects it too"
fi

# findmnt reports the os-tree subvolume as /dev/vda4[/ostree/deploy/...]. The
# parent device is what decides whether an OS reinstall destroys /srv.
got="$(source_device '/dev/vda4[/ostree/deploy/fedora-coreos/var]')"
[ "$got" = /dev/vda4 ] || fail "source_device kept the subvolume suffix: $got"
got="$(source_device /dev/vdb1)"
[ "$got" = /dev/vdb1 ] || fail "source_device changed a plain device: $got"

# Teeth: the fixture must reject a strip that keeps the subvolume suffix.
naive_source() { printf '%s' "$1"; }
[ "$(naive_source '/dev/vda4[/x]')" != /dev/vda4 ] \
  || fail "the source_device fixture does not discriminate"

echo "guest assertions parse the booted deployment and the parent device"
