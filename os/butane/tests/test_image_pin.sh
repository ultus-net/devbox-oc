#!/usr/bin/env bash
# os/butane/tests/test_image_pin.sh
#
# The installed host runs one digest. This drives image-ref.sh through the shapes
# a build can pass: a bare repository, the recorded digest, another digest, a tag,
# and a record with nothing to pin. A refusal is the property here, so each case
# checks the exit status and the message names the reason.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pin="$here/../image-ref.sh"
build="$here/../build.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$pin" ] || fail "no executable image-ref.sh at $pin"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

digest=5b9d548651dade448e26ca449ec0611ffe1a0a3d77c241deead3022302f7b5ec
other=0000000000000000000000000000000000000000000000000000000000000000
repo=ghcr.io/ultus-net/devbox
record="$tmp/prod-digest.txt"
printf '# recorded by the promotion PR\nsha256:%s\n' "$digest" > "$record"
export PROD_DIGEST_FILE="$record"
unset ALLOW_UNPINNED_IMAGE || true

out="$("$pin" "$repo")"
[ "$out" = "$repo@sha256:$digest" ] \
  || fail "a bare repository did not resolve to the recorded digest: $out"

out="$("$pin" "$repo@sha256:$digest")"
[ "$out" = "$repo@sha256:$digest" ] \
  || fail "the recorded digest was not accepted unchanged: $out"

out="$("$pin")"
[ "$out" = "ghcr.io/ultus-net/devbox@sha256:$digest" ] \
  || fail "the default repository did not resolve to the recorded digest: $out"

if err="$("$pin" "$repo@sha256:$other" 2>&1 >/dev/null)"; then
  fail "an unrecorded digest was accepted"
fi
case "$err" in
  *"pins sha256:$other but the record holds sha256:$digest"*) ;;
  *) fail "the unrecorded digest refusal does not name both digests: $err" ;;
esac

if err="$("$pin" "$repo:prod" 2>&1 >/dev/null)"; then
  fail "a tag reference was accepted"
fi
case "$err" in
  *"refusing the tag reference"*) ;;
  *) fail "the tag refusal does not say what it refused: $err" ;;
esac

# The harness sets the escape for its loopback fixture tags. It is loud on
# stderr, so a real build that inherits it shows up in the log.
out="$(ALLOW_UNPINNED_IMAGE=1 "$pin" 127.0.0.1:5000/devbox:newer 2>"$tmp/warn")"
[ "$out" = "127.0.0.1:5000/devbox:newer" ] \
  || fail "the fixture tag was not passed through: $out"
grep -q 'WARNING: unpinned image' "$tmp/warn" \
  || fail "the fixture tag did not warn about the unpinned image"

out="$(ALLOW_UNPINNED_IMAGE=1 "$pin" "$repo@sha256:$other" 2>/dev/null)"
[ "$out" = "$repo@sha256:$other" ] \
  || fail "the escape did not pass an unrecorded digest through: $out"

# Nothing recorded yet means nothing to pin. The promotion PR comes first.
printf '# nothing promoted yet\nsha256:PENDING-FIRST-BUILD\n' > "$record"
if err="$("$pin" "$repo" 2>&1 >/dev/null)"; then
  fail "a PENDING record was accepted as a pin"
fi
case "$err" in
  *"no promoted digest to pin"*) ;;
  *) fail "the PENDING refusal does not name the cause: $err" ;;
esac

# A record that holds two digests cannot name one pin.
printf 'sha256:%s\nsha256:%s\n' "$digest" "$other" > "$record"
if err="$("$pin" "$repo" 2>&1 >/dev/null)"; then
  fail "a two-digest record was accepted as a pin"
fi
case "$err" in
  *"holds 2 digests"*) ;;
  *) fail "the multi-digest refusal does not count them: $err" ;;
esac

printf 'sha256:%s\n' "${digest%?}" > "$record"
if err="$("$pin" "$repo" 2>&1 >/dev/null)"; then
  fail "a 63-character digest was accepted as a pin"
fi
case "$err" in
  *"no promoted digest to pin"*) ;;
  *) fail "a malformed digest line was not ignored: $err" ;;
esac

printf 'sha256:%s\n' "$digest" > "$record"

# A trailing slash would emit repo/@sha256:<digest>, which names no repository.
if err="$("$pin" "$repo/" 2>&1 >/dev/null)"; then
  fail "a trailing-slash reference was accepted"
fi
case "$err" in
  *"ends in a slash"*) ;;
  *) fail "the trailing-slash refusal does not name the cause: $err" ;;
esac

# A digest with no repository would emit @sha256:<digest>, which podman cannot
# pull. Match on the refusal, not on the shape, so a later parser still has to
# say why.
if err="$("$pin" "@sha256:$digest" 2>&1 >/dev/null)"; then
  fail "a digest with no repository was accepted"
fi
case "$err" in
  *"names no repository"*) ;;
  *) fail "the empty-repository refusal does not name the cause: $err" ;;
esac

# A digest after an empty path component is the same defect one slash over:
# repo/@sha256:<recorded> is not a reference podman can pull.
if err="$("$pin" "$repo/@sha256:$digest" 2>&1 >/dev/null)"; then
  fail "a digest after an empty path component was accepted"
fi
case "$err" in
  *"ends in a slash"*) ;;
  *) fail "the empty-path refusal does not name the cause: $err" ;;
esac

# So is an empty component in the middle of a bare reference.
if err="$("$pin" "$repo//devbox" 2>&1 >/dev/null)"; then
  fail "a bare reference with an empty path component was accepted"
fi
case "$err" in
  *"empty path component"*) ;;
  *) fail "the mid-path refusal does not name the cause: $err" ;;
esac

# The colon is the tag separator, so a digest after it leaves an empty tag
# position. podman cannot pull repo:@sha256:<digest>, and the shape check has to
# refuse it before the digest is compared or the escape is consulted.
if err="$("$pin" "$repo:@sha256:$digest" 2>&1 >/dev/null)"; then
  fail "a digest after an empty tag position was accepted"
fi
case "$err" in
  *"empty component before the tag or digest"*) ;;
  *) fail "the empty tag-position refusal does not name the cause: $err" ;;
esac

# Two references glued together name one repository and a digest for another.
if err="$("$pin" "a@b@sha256:$digest" 2>&1 >/dev/null)"; then
  fail "a reference with two @ was accepted"
fi
case "$err" in
  *"more than one @"*) ;;
  *) fail "the two-@ refusal does not name the cause: $err" ;;
esac

# A tag and a digest together are not a reference either.
if err="$("$pin" "$repo:prod@sha256:$digest" 2>&1 >/dev/null)"; then
  fail "a reference with a tag and a digest was accepted"
fi
case "$err" in
  *"names a tag and a digest"*) ;;
  *) fail "the tag-and-digest refusal does not name the cause: $err" ;;
esac

# The escape is for a digest that no record names, not for a shape podman cannot
# pull, so it does not waive any of the three refusals above.
if err="$(ALLOW_UNPINNED_IMAGE=1 "$pin" "$repo:@sha256:$digest" 2>&1 >/dev/null)"; then
  fail "the escape accepted a digest after an empty tag position"
fi
case "$err" in
  *"empty component before the tag or digest"*) ;;
  *) fail "the escape changed the empty tag-position refusal: $err" ;;
esac

# build.sh resolves the reference before it compiles, so a tag fails without
# Butane and without touching the committed artifact.
if err="$(SSH_PUBKEY=x IMAGE="$repo:prod" BUTANE=/bin/false \
  "$build" "$tmp/ucore.ign" 2>&1)"; then
  fail "build.sh accepted a tag image"
fi
case "$err" in
  *"refusing the tag reference"*) ;;
  *) fail "build.sh did not fail at the image pin: $err" ;;
esac
if [ -e "$tmp/ucore.ign" ]; then
  fail "a refused build wrote an artifact"
fi

echo "the build pins one digest and refuses every reference that can move"
