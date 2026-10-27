#!/usr/bin/env bash
# os/butane/tests/test_units_have_scripts.sh
set -euo pipefail
ign="${1:-}"
# Called with no argument from tests/verify.sh, where no .ign may exist (it needs
# a container engine to compile). Skip explicitly rather than break the gate.
if [ -z "$ign" ] || [ ! -f "$ign" ]; then
  echo "SKIP: no ignition file to check (compile with os/butane/build.sh first)"
  exit 0
fi
fail() { echo "FAIL: $1" >&2; exit 1; }
for p in /usr/local/sbin/oc-secrets /usr/local/sbin/oc-acr-login \
         /usr/local/sbin/oc-idle-check /usr/local/sbin/oc-snapshot \
         /usr/local/sbin/oc-tailnet /usr/local/sbin/oc-tailnet-up \
         /usr/local/sbin/lib-imds.sh; do
  jq -e --arg p "$p" '.storage.files | map(.path) | index($p)' "$ign" >/dev/null \
    || fail "not baked into the image: $p"
done
# Every ExecStart must point at a path the config actually provides, unless it is
# a binary the OS image already ships. rpm-ostree is the rebase tool; it is not
# something this repo bakes in, and requiring it here would be a false failure.
SHIPPED_BINARIES='/usr/bin/rpm-ostree /usr/bin/systemctl /usr/bin/touch'
for exe in $(jq -r '.systemd.units[]?.contents // empty' "$ign" \
             | grep -oE '^ExecStart=[^ ]+' | cut -d= -f2 | sort -u); do
  case " $SHIPPED_BINARIES " in
    *" $exe "*) continue ;;
  esac
  jq -e --arg p "$exe" '.storage.files | map(.path) | index($p)' "$ign" >/dev/null \
    || fail "unit runs a missing executable: $exe"
done
# Modes are load-bearing: a non-executable script is not run by systemd, and the
# quadlet is data rather than a program.
mode_of() { jq -r --arg p "$1" '.storage.files[] | select(.path == $p) | .mode' "$ign"; }
while read -r p; do
  [ "$(mode_of "$p")" = "493" ] || fail "$p is not 0755"
done < <(jq -r '.storage.files[].path | select(startswith("/usr/local/sbin/") and (endswith(".sh") | not))' "$ign")
[ "$(mode_of /usr/local/sbin/lib-imds.sh)" = "420" ] || fail "lib-imds.sh is not 0644"
[ "$(mode_of /etc/containers/systemd/opencode.container)" = "420" ] \
  || fail "quadlet is not 0644"

# Terraform ships this compiled artifact, not ucore.bu. Source-level tests alone
# leave the deployed host broken when only the .bu was changed, so the two units
# whose absence made the box unreachable are checked here as well.
jq -e '.systemd.units[] | select(.name == "tailscaled.service") | .enabled' "$ign" >/dev/null \
  || fail "tailscaled.service is not enabled in the compiled Ignition"

net="$(jq -r '.systemd.units[] | select(.name == "oc-tailnet.service") | .contents // empty' "$ign")"
[ -n "$net" ] || fail "oc-tailnet.service has no contents in the compiled Ignition"
printf '%s\n' "$net" | grep -Eq '^EnvironmentFile=/etc/devbox/oc-secrets\.env$' \
  || fail "oc-tailnet.service does not load the env file naming its vault in the compiled Ignition"

# Every unit the source declares must reach the artifact. Checking two named
# units by hand leaves the rest able to vanish: the autorebase pair can be
# dropped from the .ign and the box still boots plain FCOS, which is the failure
# this whole file exists to catch.
bu="${BU:-$(cd "$(dirname "$0")/.." && pwd)/ucore.bu}"
if [ -f "$bu" ]; then
  # Only the systemd section declares units. Taking every `- name:` line in the
  # file also accepts the user list, whose entries are not units.
  units_block="$(sed -n '/^systemd:/,$p' "$bu")"
  [ -n "$units_block" ] || fail "ucore.bu has no systemd section"
  src_units="$(printf '%s\n' "$units_block" \
    | grep -oE '^    - name: [A-Za-z0-9@._-]+' | sed 's/^    - name: //' | sort -u)"
  ign_units="$(jq -r '.systemd.units[].name' "$ign" | sort -u)"
  [ -n "$src_units" ] || fail "ucore.bu declares no units"

  # Parity runs both ways. Source-only parity lets the artifact keep a unit the
  # source dropped, and artifact-only parity lets a unit vanish on the way in.
  # Either way Terraform ships the artifact, so the artifact is what boots.
  missing="$(comm -23 <(printf '%s\n' "$src_units") <(printf '%s\n' "$ign_units") | tr '\n' ' ')"
  [ -z "${missing// /}" ] \
    || fail "declared in ucore.bu but absent from the compiled Ignition: $missing"
  extra="$(comm -13 <(printf '%s\n' "$src_units") <(printf '%s\n' "$ign_units") | tr '\n' ' ')"
  [ -z "${extra// /}" ] \
    || fail "in the compiled Ignition but not declared in ucore.bu: $extra"

  # Enablement is a source attribute that has to survive compilation. Asserting it
  # against the .bu alone never proves the shipped artifact enables anything.
  while read -r name; do
    [ -n "$name" ] || continue
    want="$(printf '%s\n' "$units_block" \
      | awk -v u="    - name: ${name}" '$0==u{on=1;next} /^    - name: /{on=0} on' \
      | sed -n 's/^[[:space:]]*enabled:[[:space:]]*\(true\|false\)[[:space:]]*$/\1/p' | head -1)"
    [ -n "$want" ] || continue
    got="$(jq -r --arg n "$name" \
      '.systemd.units[] | select(.name == $n) | (.enabled // false)' "$ign")"
    [ "$got" = "$want" ] \
      || fail "${name} is enabled=${want} in ucore.bu but enabled=${got} in the compiled Ignition"
  done <<< "$src_units"

  # The artifact must be exactly what the repo's own build produces. A hand-built
  # or stale artifact passes every structural check above and still ships different
  # file contents. Only checked when the compiler is available, since the gate
  # must run on a machine without one.
  if [ -n "${BUTANE:-}" ] && [ -x "${BUTANE}" ]; then
    repro="$(mktemp)"
    if ! "$(dirname "$bu")/build-placeholder.sh" "$repro" >/dev/null 2>&1; then
      rm -f "$repro"
      fail "build-placeholder.sh failed, so the committed artifact cannot be reproduced"
    fi
    if ! diff <(jq -S . "$repro") <(jq -S . "$ign") >/dev/null; then
      rm -f "$repro"
      fail "the committed Ignition differs from what build-placeholder.sh produces"
    fi
    rm -f "$repro"
  else
    echo "SKIP: no BUTANE set, artifact reproducibility unchecked" >&2
  fi
else
  echo "SKIP: no ucore.bu next to the ignition file, unit parity unchecked" >&2
fi

echo "all units reference baked-in scripts"
